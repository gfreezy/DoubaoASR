import Foundation
import AVFoundation

/// Streaming Doubao IME ASR client. One recording per instance:
/// call `start()` to begin capturing the mic and streaming to Doubao,
/// then `stop()` to flush and receive the final transcript.
///
/// The WebSocket is opened on `start()` and closed on `stop()` — matches
/// the Python reference. Reusing the connection across recordings caused
/// Doubao's per-device concurrent quota to fill up after a few fast
/// sessions; the ~600ms TLS+StartTask cost per call is the price.
public final class DoubaoASR {
    private let audioEngine = AVAudioEngine()
    private var pcmConverter: AVAudioConverter?
    private var pcmTargetFormat: AVAudioFormat!
    private var opusEncoder: OpusEncoder?

    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?

    private let queue = DispatchQueue(label: "com.doubaoasr.session", qos: .userInitiated)

    // State
    private var requestId: String = UUID().uuidString.lowercased()
    private var token: String = ""
    private var deviceId: String = ""
    private var pcmBuffer = Data()
    private var didSendFirstFrame = false
    private var canSendAudio = false
    private var frameTimestampMs: Int64 = 0
    /// VAD-finalized utterances within this recording session, in order.
    private var committedSegments: [String] = []
    /// Latest interim text for the *current* (not-yet-finalized) utterance.
    private var currentInterim: String = ""
    private var isRunning = false
    private var startedSemaphore: DispatchSemaphore?

    // stop()
    /// Fresh semaphore per session — recreated in start() so signal counts from
    /// previous sessions (e.g. from teardown() after a failed start) don't leak forward
    /// and cause wait() to return immediately without ever giving the server a chance
    /// to deliver final results.
    private var finishedSemaphore = DispatchSemaphore(value: 0)
    private var didReceiveFinal = false

    /// Whether StartTask has been sent + acked on the current WebSocket. Doubao ties a
    /// task to a connection — sending StartTask twice on the same WS yields
    /// "task already started". Currently we close the WS after every stop() so this
    /// flag always resets to false, but the gate is kept so future re-enabling of WS
    /// reuse can flip it back on without reintroducing the bug.
    private var taskStarted: Bool = false

    /// One-shot filter used by sendInitialMessages to wait for a specific control
    /// response (TaskStarted/SessionStarted) while the persistent receive loop runs.
    private var pendingResponseFilter: ((AsrResponse) -> Bool)?
    private var pendingResponseSemaphore: DispatchSemaphore?
    private var pendingResponseResult: AsrResponse?

    // Callbacks (assigned in start)
    private var onPartial: ((String) -> Void)?
    private var onAudioLevel: ((Float) -> Void)?
    private var onError: ((Error) -> Void)?

    /// Creates an idle recognizer. No mic access, network, or registration
    /// happens until `start()` is called.
    public init() {}

    // MARK: - Lifecycle

    /// Begins capturing the microphone and streaming audio to Doubao.
    ///
    /// - Parameters:
    ///   - onPartial: Called on the main queue with the live transcript as it
    ///     evolves. Includes both VAD-finalized segments and the in-progress
    ///     interim text. May be called many times per second; updates are
    ///     cumulative (not deltas).
    ///   - onAudioLevel: Called on the main queue with a 0...1 RMS level
    ///     suitable for driving a waveform UI.
    ///   - onError: Called on the main queue if registration, the WebSocket
    ///     handshake, or the ASR session fails. After an error you should
    ///     still call `stop()` to clean up.
    ///
    /// Calling `start()` while already running is a no-op.
    public func start(onPartial: @escaping (String) -> Void,
                      onAudioLevel: @escaping (Float) -> Void,
                      onError: @escaping (Error) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        self.onPartial = onPartial
        self.onAudioLevel = onAudioLevel
        self.onError = onError
        self.committedSegments = []
        self.currentInterim = ""
        self.pcmBuffer = Data()
        self.didSendFirstFrame = false
        self.canSendAudio = false
        self.didReceiveFinal = false
        self.framesSentCount = 0
        self.totalMicBytesIn = 0
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedSemaphore = DispatchSemaphore(value: 0)

        queue.async { [weak self] in
            guard let self = self else { return }
            NSLog("[DoubaoASR] start() requestId=\(self.requestId)")

            do {
                let creds = try DoubaoCredentialStore.shared.ensureCredentials()
                self.token = creds.token
                self.deviceId = creds.deviceId
                NSLog("[DoubaoASR] credentials ready device_id=\(creds.deviceId) token_len=\(creds.token.count)")

                self.opusEncoder = try OpusEncoder()
                NSLog("[DoubaoASR] opus encoder ready")

                // Start mic FIRST so audio buffers while we set up the WebSocket.
                // Doubao kills sessions that go ~900ms without audio after StartSession.
                try self.startMicTap()
                NSLog("[DoubaoASR] mic tap started (pre-WS)")

                if self.ws == nil {
                    try self.openWebSocket()
                    NSLog("[DoubaoASR] websocket opened (fresh)")
                } else {
                    NSLog("[DoubaoASR] reusing existing websocket")
                }
                try self.sendInitialMessages(deviceId: self.deviceId)
                NSLog("[DoubaoASR] StartTask + StartSession both succeeded; pcmBufferBytes=\(self.pcmBuffer.count)")

                // Now drain whatever audio accumulated during WS setup.
                self.canSendAudio = true
                self.flushPendingFrames()
            } catch {
                NSLog("[DoubaoASR] start() failed: \(error.localizedDescription)")
                self.deliverError(error)
                // On failure, kill the WS so the next attempt does a clean reconnect.
                self.closeWebSocket()
                self.teardownAudio()
                self.isRunning = false
                self.signalFinished()
            }
        }
    }

    /// Stops capturing the microphone, sends `FinishSession`, and waits up to
    /// 2.5 s for the server to flush its final transcript.
    ///
    /// - Parameter completion: Called on the main queue with the final
    ///   transcript (assembled from all VAD-finalized segments plus the last
    ///   interim). Will be called exactly once. Empty string is possible if
    ///   the user released before producing any speech, or if `start()` never
    ///   reached the streaming phase.
    ///
    /// Safe to call when not running — completion fires with whatever was
    /// already captured.
    public func stop(completion: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(""); return }
            NSLog("[DoubaoASR] stop() isRunning=\(self.isRunning)")

            // Even if we never fully started, deliver whatever we have.
            guard self.isRunning else { completion(self.assembledText()); return }
            self.isRunning = false

            self.teardownAudio()

            // Drain remaining PCM as a final frame, then FinishSession.
            do {
                try self.flushAndSendLastFrame()
                try self.sendFinishSession()
            } catch {
                NSLog("[DoubaoASR] stop send error: \(error.localizedDescription)")
            }

            // Wait for SessionFinished. Doubao streaming ASR has ~1.5-2s first-response
            // latency, so for short utterances the server may not have produced any text
            // by the time the user releases. Give it 2.5s after FinishSession to flush.
            let waitStart = Date()
            let result = self.finishedSemaphore.wait(timeout: .now() + 2.5)
            NSLog("[DoubaoASR] post-Finish wait \(Int(Date().timeIntervalSince(waitStart) * 1000))ms result=\(result == .success ? "signaled" : "timedOut")")

            // Close the WebSocket after every session — same lifecycle as the Python
            // reference. Keeping the WS open across sessions made Doubao's per-device
            // concurrent quota fill up after 2-3 fast sessions because the server
            // appeared to count each finished-but-not-WS-closed session as still
            // occupying a slot. The ~600ms TLS+StartTask cost per call is the price.
            self.closeWebSocket()

            let final = self.assembledText()
            NSLog("[DoubaoASR] stop() final='\(final)' segments=\(self.committedSegments.count)")
            DispatchQueue.main.async { completion(final) }
        }
    }

    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    private func closeWebSocket() {
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
        taskStarted = false
    }

    // MARK: - WebSocket

    private func openWebSocket() throws {
        var components = URLComponents(string: DoubaoConstants.websocketURL)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: String(DoubaoConstants.aid)),
            URLQueryItem(name: "device_id", value: deviceId)
        ]
        var req = URLRequest(url: components.url!)
        req.setValue(DoubaoConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("v2", forHTTPHeaderField: "proto-version")
        req.setValue("true", forHTTPHeaderField: "x-custom-keepalive")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let sess = URLSession(configuration: cfg)
        self.session = sess
        self.ws = sess.webSocketTask(with: req)
        self.ws?.resume()
        // The receive loop is shared across all sessions on this connection.
        startReceiveLoop()
    }

    private func sendInitialMessages(deviceId: String) throws {
        // StartTask: only on first session of this WebSocket (Doubao binds task to
        // connection; second StartTask would error "task already started").
        if !taskStarted {
            try sendData(AsrMessageBuilder.startTask(requestId: requestId, token: token))
            let resp = try waitForResponse(timeout: 5.0) {
                $0.messageType == "TaskStarted" || $0.messageType == "TaskFailed" || $0.messageType == "SessionFailed"
            }
            NSLog("[DoubaoASR] StartTask resp messageType=\(resp.messageType) code=\(resp.statusCode) msg=\(resp.statusMessage)")
            if resp.messageType != "TaskStarted" {
                throw NSError(domain: "DoubaoASR", code: Int(resp.statusCode),
                              userInfo: [NSLocalizedDescriptionKey: "StartTask: \(resp.statusMessage.isEmpty ? "failed" : resp.statusMessage) (\(resp.statusCode))"])
            }
            taskStarted = true
        } else {
            NSLog("[DoubaoASR] reusing task on existing WebSocket — skipping StartTask")
        }

        let configJSON = sessionConfigJSON(deviceId: deviceId)
        try sendData(AsrMessageBuilder.startSession(requestId: requestId, token: token, configJSON: configJSON))
        let resp2 = try waitForResponse(timeout: 5.0) {
            $0.messageType == "SessionStarted" || $0.messageType == "TaskFailed" || $0.messageType == "SessionFailed"
        }
        NSLog("[DoubaoASR] StartSession resp messageType=\(resp2.messageType) code=\(resp2.statusCode) msg=\(resp2.statusMessage)")
        if resp2.messageType != "SessionStarted" {
            throw NSError(domain: "DoubaoASR", code: Int(resp2.statusCode),
                          userInfo: [NSLocalizedDescriptionKey: "StartSession: \(resp2.statusMessage.isEmpty ? "failed" : resp2.statusMessage) (\(resp2.statusCode))"])
        }
    }

    /// Synchronously block the caller's queue until `handleResponseData` sees a
    /// response matching `predicate`. Used by sendInitialMessages so we can keep a
    /// single shared receive loop running on the WebSocket (instead of competing
    /// `ws.receive` calls that would race for messages on a reused connection).
    private func waitForResponse(timeout: TimeInterval, where predicate: @escaping (AsrResponse) -> Bool) throws -> AsrResponse {
        let sem = DispatchSemaphore(value: 0)
        pendingResponseFilter = predicate
        pendingResponseSemaphore = sem
        pendingResponseResult = nil

        let timedOut = sem.wait(timeout: .now() + timeout) == .timedOut
        let result = pendingResponseResult
        pendingResponseFilter = nil
        pendingResponseSemaphore = nil
        pendingResponseResult = nil

        if timedOut { throw URLError(.timedOut) }
        guard let r = result else { throw URLError(.cannotParseResponse) }
        return r
    }

    private func sessionConfigJSON(deviceId: String) -> String {
        let payload: [String: Any] = [
            "audio_info": [
                "channel": DoubaoConstants.channels,
                "format": "speech_opus",
                "sample_rate": DoubaoConstants.sampleRate
            ],
            "enable_punctuation": true,
            "enable_speech_rejection": false,
            "extra": [
                "app_name": "com.android.chrome",
                "cell_compress_rate": 8,
                "did": deviceId,
                "enable_asr_threepass": true,
                "enable_asr_twopass": true,
                "input_mode": "tool"
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func sendFinishSession() throws {
        try sendData(AsrMessageBuilder.finishSession(requestId: requestId, token: token))
    }

    private func sendData(_ data: Data) throws {
        guard let ws = ws else { throw URLError(.networkConnectionLost) }
        let sem = DispatchSemaphore(value: 0)
        var sendErr: Error?
        ws.send(.data(data)) { err in
            sendErr = err
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5.0) == .timedOut {
            throw URLError(.timedOut)
        }
        if let e = sendErr { throw e }
    }

    private func startReceiveLoop() {
        guard let ws = ws else { return }
        ws.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                let data: Data
                switch msg {
                case .data(let d):   data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default:    data = Data()
                }
                if !data.isEmpty {
                    self.handleResponseData(data)
                }
                // Keep listening as long as the WebSocket is alive.
                if self.ws != nil {
                    self.startReceiveLoop()
                }
            case .failure(let err):
                NSLog("[DoubaoASR] receive failed: \(err.localizedDescription)")
                self.queue.async {
                    if self.isRunning {
                        self.deliverError(err)
                    }
                    // Connection is dead — drop references so next start() reopens.
                    self.ws = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.taskStarted = false
                    self.pendingResponseFilter = nil
                    self.pendingResponseSemaphore?.signal()
                    self.pendingResponseSemaphore = nil
                    self.signalFinished()
                }
            }
        }
    }

    private func handleResponseData(_ data: Data) {
        guard let resp = try? AsrResponse.decode(data) else {
            NSLog("[DoubaoASR] recv: decode failed (\(data.count) bytes)")
            return
        }
        NSLog("[DoubaoASR] recv requestId=\(resp.requestId) messageType=\(resp.messageType) code=\(resp.statusCode) jsonLen=\(resp.resultJson.count)")

        // Drop responses for prior (closed) sessions on this reused WebSocket. Server
        // echoes our request_id; if it doesn't match the current session, it's stale.
        if !resp.requestId.isEmpty && !self.requestId.isEmpty && resp.requestId != self.requestId {
            NSLog("[DoubaoASR] dropping stale (current=\(self.requestId))")
            return
        }

        // sendInitialMessages waits for a specific control response — if this matches,
        // hand it back synchronously and skip the streaming-result handling below.
        if let pred = pendingResponseFilter, pred(resp) {
            pendingResponseResult = resp
            pendingResponseFilter = nil
            pendingResponseSemaphore?.signal()
            return
        }

        switch resp.messageType {
        case "SessionFinished":
            NSLog("[DoubaoASR] SessionFinished code=\(resp.statusCode)")
            signalFinished()
            return
        case "TaskFailed", "SessionFailed":
            NSLog("[DoubaoASR] \(resp.messageType) statusCode=\(resp.statusCode) statusMessage=\(resp.statusMessage) resultJson=\(resp.resultJson)")
            let msg = resp.statusMessage.isEmpty ? "ASR failed (\(resp.statusCode))" : "\(resp.statusMessage) (\(resp.statusCode))"
            deliverError(NSError(domain: "DoubaoASR", code: Int(resp.statusCode),
                                  userInfo: [NSLocalizedDescriptionKey: msg]))
            signalFinished()
            return
        default:
            break
        }

        // Parse result_json (per asr.py:589-684)
        guard !resp.resultJson.isEmpty,
              let rj = try? JSONSerialization.jsonObject(with: Data(resp.resultJson.utf8)) as? [String: Any] else {
            return
        }
        guard let results = rj["results"] as? [[String: Any]], !results.isEmpty else {
            return  // heartbeat
        }

        var text = ""
        var isInterim = true
        var vadFinished = false
        var nonstreamResult = false
        for r in results {
            if let t = r["text"] as? String, !t.isEmpty { text = t }
            if let i = r["is_interim"] as? Bool, i == false { isInterim = false }
            if let v = r["is_vad_finished"] as? Bool, v { vadFinished = true }
            if let extra = r["extra"] as? [String: Any], let n = extra["nonstream_result"] as? Bool, n {
                nonstreamResult = true
            }
        }

        if !text.isEmpty {
            // Doubao chunks long audio into VAD-bounded utterances. Each utterance has its
            // own cumulative `text` field that does NOT include prior utterances. So when
            // is_vad_finished=true && !is_interim, we commit `text` as a finalized
            // segment; the next utterance's interims start from empty again. The HUD and
            // final paste join all committed segments + the in-progress interim.
            if (!isInterim && vadFinished) || nonstreamResult {
                committedSegments.append(text)
                currentInterim = ""
                NSLog("[DoubaoASR] segment final='\(text)' totalSegments=\(committedSegments.count)")
            } else {
                currentInterim = text
            }
            let display = committedSegments.joined() + currentInterim
            DispatchQueue.main.async { [display, weak self] in self?.onPartial?(display) }
        }
    }

    private func assembledText() -> String {
        committedSegments.joined() + currentInterim
    }

    private func signalFinished() {
        finishedSemaphore.signal()
    }

    // MARK: - Mic capture

    private func startMicTap() throws {
        let inputNode = audioEngine.inputNode
        let inFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(DoubaoConstants.sampleRate),
            channels: AVAudioChannelCount(DoubaoConstants.channels),
            interleaved: true
        ) else {
            throw OpusEncoder.OpusError.formatBuildFailed
        }
        self.pcmTargetFormat = target

        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw OpusEncoder.OpusError.converterInitFailed
        }
        self.pcmConverter = converter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private var totalMicBytesIn: Int = 0
    private var totalPcmBytesOut: Int = 0

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let level = AudioLevel.computeRMS(buffer)
        DispatchQueue.main.async { [weak self] in self?.onAudioLevel?(level) }

        guard let converter = pcmConverter,
              let target = pcmTargetFormat else { return }

        let inFrames = Int(buffer.frameLength)
        totalMicBytesIn += inFrames * 4   // assume Float32 stereo or whatever — diagnostic only

        // Convert variable-rate mic buffer → 16kHz Int16 mono.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let e = convError {
            NSLog("[DoubaoASR] mic convert error: \(e)")
            return
        }
        // status .inputRanDry (1) is normal for streaming resampling — converter consumed our
        // input and needs more, but may have already produced output. Use whatever's in outBuf.
        _ = status
        let n = Int(outBuf.frameLength)
        guard n > 0, let src = outBuf.int16ChannelData?[0] else { return }

        let byteCount = n * MemoryLayout<Int16>.size
        totalPcmBytesOut += byteCount
        let chunk = Data(bytes: src, count: byteCount)

        queue.async { [weak self] in
            self?.appendAndDrainPCM(chunk)
        }
    }

    private var framesSentCount = 0

    private func appendAndDrainPCM(_ data: Data) {
        guard isRunning else { return }
        pcmBuffer.append(data)
        flushPendingFrames()
    }

    /// Sends as many complete 20ms frames as the buffer holds. No-op until
    /// `canSendAudio` is true (i.e., until StartSession has succeeded).
    private func flushPendingFrames() {
        guard canSendAudio else { return }
        let frameSize = DoubaoConstants.bytesPerFrame
        while pcmBuffer.count >= frameSize {
            let frame = pcmBuffer.prefix(frameSize)
            pcmBuffer.removeFirst(frameSize)
            do {
                let state: FrameState = didSendFirstFrame ? .middle : .first
                try encodeAndSend(Data(frame), state: state)
                if !didSendFirstFrame {
                    NSLog("[DoubaoASR] sent FIRST frame")
                }
                didSendFirstFrame = true
                framesSentCount += 1
            } catch {
                NSLog("[DoubaoASR] encodeAndSend error: \(error.localizedDescription)")
                deliverError(error)
                return
            }
        }
    }

    private func flushAndSendLastFrame() throws {
        NSLog("[DoubaoASR] flushAndSendLastFrame framesSent=\(framesSentCount) pcmBufferRemaining=\(pcmBuffer.count) didSendFirst=\(didSendFirstFrame) totalPcmBytesOut=\(totalPcmBytesOut)")
        let frameSize = DoubaoConstants.bytesPerFrame
        if pcmBuffer.isEmpty {
            // Still need a LAST marker if any frames were sent.
            if didSendFirstFrame {
                let silent = Data(count: frameSize)
                try encodeAndSend(silent, state: .last)
                NSLog("[DoubaoASR] sent LAST silent")
            }
            return
        }
        // Pad final partial frame with zeros.
        if pcmBuffer.count < frameSize {
            pcmBuffer.append(Data(count: frameSize - pcmBuffer.count))
        }
        let frame = Data(pcmBuffer.prefix(frameSize))
        pcmBuffer.removeAll()
        try encodeAndSend(frame, state: .last)
        NSLog("[DoubaoASR] sent LAST frame")
    }

    private func encodeAndSend(_ pcmFrame: Data, state: FrameState) throws {
        guard let encoder = opusEncoder else { return }
        let opus = try encoder.encode(pcmFrame)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = AsrMessageBuilder.taskRequest(
            audio: opus,
            requestId: requestId,
            frameState: state,
            timestampMs: now
        )
        try sendData(msg)
    }

    // MARK: - Helpers

    private func deliverError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
