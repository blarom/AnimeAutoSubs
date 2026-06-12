import Foundation
import Darwin

/// Long-lived `whisper-server` (from whisper.cpp) process. Replaces the
/// per-chunk `whisper-cli` subprocess model — the server loads the model
/// once at startup and processes requests over HTTP, eliminating ~150-
/// 300 ms of fork + model-load overhead per transcription.
///
/// One process, fixed thread count, requests processed serially at the
/// HTTP layer. The OperationQueue upstream caps how many requests can
/// be in flight at the bridge; the server itself executes them one at
/// a time but the per-request overhead is now milliseconds.
final class WhisperServer {

    /// Single shared instance — multiple `WhisperTranscriber` instances
    /// reuse the same server process so we don't fork one per view.
    static let shared = WhisperServer(
        modelPath: NSHomeDirectory() + "/Library/Application Support/AnimeAutoSubs/ggml-small.bin"
    )

    private let modelPath: String
    private let binaryPath: String
    private let host: String
    private let port: Int
    private let threads: Int

    private let lock = NSLock()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var started: Bool = false

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
    var inferenceURL: URL { baseURL.appendingPathComponent("inference") }
    var isStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }

    init(modelPath: String,
         binaryPath: String = "/opt/homebrew/bin/whisper-server",
         host: String = "127.0.0.1",
         port: Int = 8911,
         threads: Int = 4) {
        self.modelPath = modelPath
        self.binaryPath = binaryPath
        self.host = host
        self.port = port
        self.threads = threads
    }

    /// Lazy start. Idempotent — concurrent callers serialize on the lock
    /// and only the first one launches the process. Blocks the calling
    /// thread until the server is accepting connections (or `timeout`
    /// elapses). Safe to call from a background queue.
    func ensureStarted(timeout: TimeInterval = 10) throws {
        lock.lock()
        if started { lock.unlock(); return }
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw WhisperServerError.binaryMissing(binaryPath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperServerError.modelMissing(modelPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = [
            "-m", modelPath,
            "-t", "\(threads)",
            "--host", host,
            "--port", "\(port)",
            "-l", "ja",
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // Drain pipes so the process doesn't block on a full kernel
        // buffer. Surface stderr (model-load lines, errors) at info
        // level; drop stdout since `whisper-server` echoes a per-request
        // log line that would double-log alongside our `[whisper]` line.
        out.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                let line = s.trimmingCharacters(in: .newlines)
                if !line.isEmpty { print("[whisper-server] \(line)") }
            }
        }
        do {
            try p.run()
        } catch {
            throw WhisperServerError.launchFailed(error)
        }
        process = p
        stdoutPipe = out
        stderrPipe = err

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if p.isRunning == false {
                throw WhisperServerError.exitedEarly
            }
            if probePort() {
                started = true
                print("[whisper-server] ready at \(baseURL.absoluteString) (model loaded, \(threads) threads)")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw WhisperServerError.startupTimeout(timeout)
    }

    /// Terminates the underlying process. Safe to call multiple times.
    /// Call at app shutdown so the child doesn't linger.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        started = false
    }

    /// Cheap TCP connect probe to check if the server is accepting
    /// connections yet. Used during `ensureStarted` to wait for the
    /// model-load to complete.
    private func probePort() -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }
}

enum WhisperServerError: Error, CustomStringConvertible {
    case binaryMissing(String)
    case modelMissing(String)
    case launchFailed(Error)
    case exitedEarly
    case startupTimeout(TimeInterval)

    var description: String {
        switch self {
        case .binaryMissing(let p): return "whisper-server binary not found at \(p)"
        case .modelMissing(let p): return "whisper model not found at \(p)"
        case .launchFailed(let e): return "failed to launch whisper-server: \(e)"
        case .exitedEarly: return "whisper-server exited before accepting connections"
        case .startupTimeout(let t): return "whisper-server didn't start within \(t)s"
        }
    }
}
