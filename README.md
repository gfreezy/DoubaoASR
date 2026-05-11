# DoubaoASR

A self-contained Swift package that streams microphone audio to Doubao IME's
ASR endpoint over WebSocket and emits live transcripts. Reverse-engineered from
the Doubao IME Android app — no third-party dependencies, no SwiftProtobuf, no
C-level Opus library.

- 🎙️ Live partial + final transcripts
- 🌐 Auto language detection (Chinese / English; whatever Doubao supports)
- 🔇 VAD-aware: long utterances split into segments, each with its own interim/final cycle
- 📦 Native Opus encoding via `AVAudioConverter` + `kAudioFormatOpus` (no third-party C lib)
- 🔐 Hand-rolled protobuf wire codec (no SwiftProtobuf dep)
- 💾 Anonymous device registration cached to disk; subsequent launches start in milliseconds

> ⚠️ **Unofficial.** This package mimics the Doubao Android IME's ASR client
> using endpoints and credentials that are not part of any public SDK. It works
> today but may stop at any time if ByteDance changes its protocol. **Do not
> ship it in production-critical paths.**

## Requirements

- macOS 14+
- Swift 5.9+
- Microphone permission (`NSMicrophoneUsageDescription` in your app's `Info.plist`)
- Network access to `*.doubao.com` and `*.snssdk.com`

## Install

Swift Package Manager — add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/gfreezy/DoubaoASR.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "DoubaoASR", package: "DoubaoASR")
        ]
    )
]
```

Or for local development:

```swift
.package(path: "../DoubaoASR")
```

## Usage

```swift
import DoubaoASR

let asr = DoubaoASR()

asr.start(
    onPartial: { text in
        // Live transcript — updates as the user speaks. Includes both
        // VAD-finalized segments and the in-progress interim text.
        print("partial:", text)
    },
    onAudioLevel: { level in
        // 0...1 RMS suitable for driving a waveform UI.
    },
    onError: { error in
        print("error:", error.localizedDescription)
    }
)

// Later, when the user releases the push-to-talk key:
asr.stop { final in
    print("final:", final)
    // `final` is the assembled transcript — same content as the last
    // `onPartial` call, plus anything the server flushed within ~2.5s
    // of receiving FinishSession.
}
```

`DoubaoASR` is **one-shot per recording**. Call `start()` to begin a new
session, `stop()` to end it. The WebSocket is opened on `start()` and closed on
`stop()` — see "Why we don't reuse the WebSocket" below.

## Credentials

`DoubaoCredentialStore.shared` lazily registers a fake Android device on first
use and caches the resulting `device_id` + JWT to disk:

```
~/Library/Application Support/SpeechMore/credentials.json
```

> The directory name is `SpeechMore` for historical reasons (this package was
> extracted from a host app of that name). It will likely become configurable
> in a future release.

### Warmup

Registration takes a few hundred milliseconds. Call `warmup()` after launch so
the first recording isn't delayed by it:

```swift
DoubaoCredentialStore.shared.warmup()
```

### Reset

If you hit `exceedconcurrentquota` or other auth errors, wipe the cache and
re-register:

```swift
DoubaoCredentialStore.shared.reset()
DoubaoCredentialStore.shared.warmup()
```

## Audio pipeline

| Stage              | Format                       | Notes                                          |
|--------------------|------------------------------|------------------------------------------------|
| Microphone         | Float32, hardware sample rate | `AVAudioEngine.inputNode` tap                  |
| Resample           | 16 kHz Int16 mono            | `AVAudioConverter`                             |
| Frame              | 20 ms = 320 samples = 640 B  | Buffered until a full frame is available       |
| Encode             | Opus                         | `AVAudioConverter` + `kAudioFormatOpus`        |
| Wire               | Custom protobuf over WebSocket | First/middle/last frame state in `frame_state` |

## Behavior notes

### Why we don't reuse the WebSocket

Keeping the WS open across recordings made Doubao's per-device concurrent quota
fill up after 2-3 fast sessions — the server appears to count each
finished-but-not-WS-closed session as still occupying a slot. We close the WS
after every `stop()`. The ~600 ms TLS + StartTask cost per recording is the
price.

### VAD segmentation

For long audio Doubao splits the stream into VAD-bounded utterances. Each
utterance has its own cumulative `text` field that does **not** include prior
utterances. `DoubaoASR` joins all VAD-finalized segments + the current interim
into the strings emitted by `onPartial` / returned from `stop()`.

### `stop()` waits for the final response

`stop()` sends `FinishSession` and then waits up to 2.5 s for `SessionFinished`.
Doubao's first-response latency is ~1.5–2 s, so a short utterance may not have
produced any text by the time the user releases the push-to-talk key — without
this wait you'd lose the result.

## API

```swift
public final class DoubaoASR {
    public init()
    public func start(onPartial: @escaping (String) -> Void,
                      onAudioLevel: @escaping (Float) -> Void,
                      onError: @escaping (Error) -> Void)
    public func stop(completion: @escaping (String) -> Void)
}

public final class DoubaoCredentialStore {
    public static let shared: DoubaoCredentialStore
    public func warmup()
    public func reset()
    public var fileURLForDiagnostics: URL { get }
}
```

## License

MIT — see [LICENSE](LICENSE).
