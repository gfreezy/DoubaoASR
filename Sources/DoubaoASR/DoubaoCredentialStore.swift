import Foundation
import CryptoKit
import Security
import TalkerCommonSync

struct DeviceCredentials: Codable {
    var deviceId: String
    var installId: String
    var cdid: String
    var openudid: String
    var clientudid: String
    var token: String
}

/// Manages the anonymous device registration + JWT that Doubao requires
/// before any ASR call. Credentials are cached to
/// `~/Library/Application Support/SpeechMore/credentials.json` so subsequent
/// app launches start in milliseconds.
public final class DoubaoCredentialStore {
    /// Shared singleton. There is no reason to construct multiple instances —
    /// they would race over the same on-disk cache.
    public static let shared = DoubaoCredentialStore()

    /// Mutable cache + its lock, fused into one value via `Lock<T>`. The
    /// `withLock` API forces every access through the lock and prevents the
    /// "lock held across an await point" footgun that bare `NSLock` invites
    /// once async/await is in the picture.
    private let cached: Lock<DeviceCredentials?>
    private let fileURL: URL

    enum DoubaoError: Error, LocalizedError {
        case registrationFailed(String)
        case tokenFetchFailed(String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let s): return "Device registration failed: \(s)"
            case .tokenFetchFailed(let s):   return "Token fetch failed: \(s)"
            case .decodeFailed(let s):       return "Decode failed: \(s)"
            }
        }
    }

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("SpeechMore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("credentials.json")
        self.cached = Lock(Self.load(from: fileURL))
    }

    /// Fire-and-forget background refresh so the first call has zero registration latency.
    public func warmup() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.ensureCredentials()
        }
    }

    /// Wipe the cached credentials.json and re-register on next ensureCredentials().
    public func reset() {
        cached.withLock { c in
            c = nil
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Path to the on-disk credential cache. Read-only; intended for
    /// diagnostics ("show me where it's stored") and integration tests.
    public var fileURLForDiagnostics: URL { fileURL }

    /// Synchronous; never call from the main thread on first run.
    func ensureCredentials() throws -> DeviceCredentials {
        try cached.withLock { c in
            if var existing = c, !existing.deviceId.isEmpty {
                if existing.token.isEmpty || Self.isJWTExpired(existing.token) {
                    existing.token = try fetchToken(deviceId: existing.deviceId, cdid: existing.cdid)
                    c = existing
                    try? Self.save(existing, to: fileURL)
                }
                return existing
            }

            var fresh = try registerDevice()
            fresh.token = try fetchToken(deviceId: fresh.deviceId, cdid: fresh.cdid)
            c = fresh
            try? Self.save(fresh, to: fileURL)
            return fresh
        }
    }

    static func isJWTExpired(_ token: String, marginSec: TimeInterval = 60) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let payload = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return false }
        return Date().timeIntervalSince1970 >= exp - marginSec
    }

    // MARK: - Registration

    private func registerDevice() throws -> DeviceCredentials {
        let cdid = UUID().uuidString.lowercased()
        let openudid = randomHex(bytes: 8)
        let clientudid = UUID().uuidString.lowercased()

        var headerDict: [String: Any] = DoubaoConstants.appConfig.merging(DoubaoConstants.deviceConfig) { _, new in new }
        headerDict["device_id"] = 0
        headerDict["install_id"] = 0
        headerDict["openudid"] = openudid
        headerDict["clientudid"] = clientudid
        headerDict["cdid"] = cdid
        headerDict["region"] = "CN"
        headerDict["tz_name"] = "Asia/Shanghai"
        headerDict["tz_offset"] = 28800
        headerDict["sim_region"] = "cn"
        headerDict["carrier_region"] = "cn"
        headerDict["cpu_abi"] = "arm64-v8a"
        headerDict["build_serial"] = "unknown"
        headerDict["not_request_sender"] = 0
        headerDict["sig_hash"] = ""
        headerDict["google_aid"] = ""
        headerDict["mc"] = ""
        headerDict["serial_number"] = ""

        let body: [String: Any] = [
            "magic_tag": "ss_app_log",
            "header": headerDict,
            "_gen_time": Int(Date().timeIntervalSince1970 * 1000)
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var components = URLComponents(url: DoubaoConstants.registerURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "os", value: "android"),
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "_rticket", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "cdid", value: cdid),
            URLQueryItem(name: "channel", value: DoubaoConstants.appConfig["channel"] as? String ?? "official"),
            URLQueryItem(name: "aid", value: String(DoubaoConstants.aid)),
            URLQueryItem(name: "app_name", value: DoubaoConstants.appConfig["app_name"] as? String ?? "oime"),
            URLQueryItem(name: "version_code", value: String(DoubaoConstants.appConfig["version_code"] as? Int ?? 0)),
            URLQueryItem(name: "version_name", value: DoubaoConstants.appConfig["version_name"] as? String ?? ""),
            URLQueryItem(name: "manifest_version_code", value: String(DoubaoConstants.appConfig["manifest_version_code"] as? Int ?? 0)),
            URLQueryItem(name: "update_version_code", value: String(DoubaoConstants.appConfig["update_version_code"] as? Int ?? 0)),
            URLQueryItem(name: "resolution", value: DoubaoConstants.deviceConfig["resolution"] as? String),
            URLQueryItem(name: "dpi", value: DoubaoConstants.deviceConfig["dpi"] as? String),
            URLQueryItem(name: "device_type", value: DoubaoConstants.deviceConfig["device_type"] as? String),
            URLQueryItem(name: "device_brand", value: DoubaoConstants.deviceConfig["device_brand"] as? String),
            URLQueryItem(name: "language", value: DoubaoConstants.deviceConfig["language"] as? String),
            URLQueryItem(name: "os_api", value: DoubaoConstants.deviceConfig["os_api"] as? String),
            URLQueryItem(name: "os_version", value: DoubaoConstants.deviceConfig["os_version"] as? String),
            URLQueryItem(name: "ac", value: "wifi"),
        ]

        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(DoubaoConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        let (data, http) = try syncRequest(req)
        guard (200..<300).contains(http.statusCode) else {
            throw DoubaoError.registrationFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DoubaoError.decodeFailed("register: not JSON")
        }
        let deviceId: String
        if let s = json["device_id_str"] as? String, !s.isEmpty, s != "0" {
            deviceId = s
        } else if let n = json["device_id"] as? NSNumber, n.intValue != 0 {
            deviceId = n.stringValue
        } else {
            throw DoubaoError.registrationFailed("missing or zero device_id in response: \(json)")
        }
        NSLog("[DoubaoASR] registered device_id=\(deviceId)")
        let installId: String
        if let s = json["install_id_str"] as? String, !s.isEmpty {
            installId = s
        } else if let n = json["install_id"] as? NSNumber {
            installId = n.stringValue
        } else {
            installId = ""
        }

        return DeviceCredentials(
            deviceId: deviceId,
            installId: installId,
            cdid: cdid,
            openudid: openudid,
            clientudid: clientudid,
            token: ""
        )
    }

    // MARK: - Token

    private func fetchToken(deviceId: String, cdid: String) throws -> String {
        var components = URLComponents(url: DoubaoConstants.settingsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "device_platform", value: "android"),
            URLQueryItem(name: "os", value: "android"),
            URLQueryItem(name: "ssmix", value: "a"),
            URLQueryItem(name: "_rticket", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "cdid", value: cdid),
            URLQueryItem(name: "channel", value: DoubaoConstants.appConfig["channel"] as? String ?? "official"),
            URLQueryItem(name: "aid", value: String(DoubaoConstants.aid)),
            URLQueryItem(name: "app_name", value: DoubaoConstants.appConfig["app_name"] as? String ?? "oime"),
            URLQueryItem(name: "version_code", value: String(DoubaoConstants.appConfig["version_code"] as? Int ?? 0)),
            URLQueryItem(name: "version_name", value: DoubaoConstants.appConfig["version_name"] as? String ?? ""),
            URLQueryItem(name: "device_id", value: deviceId),
        ]

        let bodyStr = "body=null"
        let bodyData = Data(bodyStr.utf8)
        let stub = Insecure.MD5.hash(data: bodyData).map { String(format: "%02X", $0) }.joined()

        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(DoubaoConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(stub, forHTTPHeaderField: "x-ss-stub")
        req.httpBody = bodyData

        let (data, http) = try syncRequest(req)
        guard (200..<300).contains(http.statusCode) else {
            throw DoubaoError.tokenFetchFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let settings = dataDict["settings"] as? [String: Any],
              let asrConfig = settings["asr_config"] as? [String: Any],
              let appKey = asrConfig["app_key"] as? String else {
            throw DoubaoError.decodeFailed("token: missing data.settings.asr_config.app_key")
        }
        return appKey
    }

    // MARK: - Helpers

    private func syncRequest(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        var outData: Data?
        var outResp: URLResponse?
        var outErr: Error?
        let sem = DispatchSemaphore(value: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        let session = URLSession(configuration: cfg)
        let task = session.dataTask(with: req) { d, r, e in
            outData = d; outResp = r; outErr = e; sem.signal()
        }
        task.resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        if let e = outErr { throw e }
        guard let http = outResp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (outData ?? Data(), http)
    }

    private func randomHex(bytes count: Int) -> String {
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        return buf.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> DeviceCredentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    private static func save(_ creds: DeviceCredentials, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(creds).write(to: url, options: .atomic)
    }
}
