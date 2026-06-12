import Foundation
import Network

/// HTTP server bound to 127.0.0.1:8912. Started at app launch, runs
/// for the app's lifetime. Routes incoming requests from browser
/// extensions to the appropriate `HTTPExtensionBridge` based on a
/// `browser` field (in the body for POSTs, in the query string for GETs).
///
/// The protocol is intentionally simple — same shape as the file-IPC
/// path it parallels:
///
///   - `POST /state` — extension reports a play/pause/timeupdate event.
///     Body is JSON with the same shape as state.json (paused, href,
///     currentTime, duration, …) plus a top-level `browser` field.
///   - `GET /poll?browser=Safari` — extension polls for the next queued
///     command. Returns `{}` if nothing is pending, otherwise the
///     queued command object (`{id, command, time?, delta?, …}`).
///
/// Wire format is plain HTTP/1.1 with a tiny hand-rolled parser. No
/// external dependencies. Only two endpoints — keep it that way; if
/// the surface grows, swap to a real router.
final class LocalControlServer {

    static let port: NWEndpoint.Port = 8912

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.animeautosubs.LocalControlServer")
    private let bridgesLock = NSLock()
    private var bridgesByBrowser: [String: HTTPExtensionBridge] = [:]

    /// Register a bridge to receive `/state` events and supply commands
    /// to `/poll` for a given browser identifier (e.g. "Safari", "Chrome").
    /// Bridges are typically registered at app launch and live forever.
    func register(_ bridge: HTTPExtensionBridge, for browser: String) {
        bridgesLock.lock(); defer { bridgesLock.unlock() }
        bridgesByBrowser[browser] = bridge
    }

    private func bridge(for browser: String) -> HTTPExtensionBridge? {
        bridgesLock.lock(); defer { bridgesLock.unlock() }
        return bridgesByBrowser[browser]
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: params, on: Self.port)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[ipc-http] listening on 127.0.0.1:\(Self.port)")
                case .failed(let err):
                    print("[ipc-http] listener failed: \(err)")
                case .cancelled:
                    print("[ipc-http] listener cancelled")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[ipc-http] failed to start listener on :\(Self.port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            if let error = error {
                print("[ipc-http] receive error: \(error)")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data = data, !data.isEmpty { buf.append(data) }

            if let request = self.parseRequest(buf) {
                self.handleRequest(request, on: conn)
                return
            }

            // No complete request yet — wait for more bytes, unless the
            // connection has closed and we still don't have a complete
            // request (malformed or truncated client).
            if isComplete {
                conn.cancel()
                return
            }
            self.receiveRequest(conn, buffer: buf)
        }
    }

    private func handleRequest(_ request: HTTPRequest, on conn: NWConnection) {
        // Route. Keep this small — if it grows, swap to a real router.
        switch (request.method, request.path) {
        case ("POST", "/state"):
            handleStatePost(body: request.body, conn: conn)
        case ("GET", "/poll"):
            handlePollGet(query: request.query, conn: conn)
        case ("OPTIONS", _):
            // CORS preflight — answer permissively for localhost.
            respond(conn, status: 204, headers: corsHeaders, body: Data())
        default:
            respond(conn, status: 404, body: "not found")
        }
    }

    private func handleStatePost(body: Data, conn: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let dict = obj as? [String: Any] else {
            respond(conn, status: 400, body: "invalid JSON")
            return
        }
        guard let browser = dict["browser"] as? String, !browser.isEmpty else {
            respond(conn, status: 400, body: "missing browser")
            return
        }
        guard let bridge = bridge(for: browser) else {
            // Unknown browser — extension is talking to us but we have
            // no bridge registered. Acknowledge so the extension doesn't
            // retry-loop; log so we notice.
            print("[ipc-http] /state: no bridge for browser=\(browser)")
            respond(conn, status: 200, body: "{}")
            return
        }
        DispatchQueue.main.async {
            bridge.receiveState(dict)
        }
        respond(conn, status: 200, body: "{}")
    }

    private func handlePollGet(query: [String: String], conn: NWConnection) {
        guard let browser = query["browser"], !browser.isEmpty else {
            respond(conn, status: 400, body: "missing browser query")
            return
        }
        guard let bridge = bridge(for: browser) else {
            respond(conn, status: 200, body: "{}")
            return
        }
        // popNextCommand mutates state — bridges are @MainActor, so hop
        // the read onto main and reply once we have the result.
        DispatchQueue.main.async {
            let cmd = bridge.popNextCommand()
            let body: Data
            if let cmd = cmd, let data = try? JSONSerialization.data(withJSONObject: cmd) {
                body = data
            } else {
                body = Data("{}".utf8)
            }
            self.queue.async {
                self.respond(conn, status: 200, headers: ["Content-Type": "application/json"], body: body)
            }
        }
    }

    // MARK: - HTTP response

    private var corsHeaders: [String: String] {
        // Permissive CORS so the extension's fetch() from a non-loopback
        // page origin (the source video site) succeeds. Localhost-only
        // listener; the surface is otherwise unreachable.
        return [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        ]
    }

    private func respond(_ conn: NWConnection, status: Int, headers: [String: String] = [:], body: String) {
        respond(conn, status: status, headers: headers, body: Data(body.utf8))
    }

    private func respond(_ conn: NWConnection, status: Int, headers: [String: String] = [:], body: Data) {
        let reason = (status == 200) ? "OK"
                   : (status == 204) ? "No Content"
                   : (status == 400) ? "Bad Request"
                   : (status == 404) ? "Not Found"
                   : "Status"
        var responseHeaders: [String: String] = headers
        responseHeaders["Content-Length"] = "\(body.count)"
        if responseHeaders["Content-Type"] == nil {
            responseHeaders["Content-Type"] = "text/plain; charset=utf-8"
        }
        for (k, v) in corsHeaders where responseHeaders[k] == nil {
            responseHeaders[k] = v
        }
        responseHeaders["Connection"] = "close"

        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in responseHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - HTTP request parsing

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }

    private func parseRequest(_ buffer: Data) -> HTTPRequest? {
        // Find header/body delimiter (\r\n\r\n).
        let crlfcrlf = Data([0x0d, 0x0a, 0x0d, 0x0a])
        guard let separator = buffer.range(of: crlfcrlf) else { return nil }

        let headerData = buffer.subdata(in: 0..<separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let target = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = value
        }

        let (path, query) = splitPathAndQuery(target)

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        let availableBody = buffer.count - bodyStart
        if contentLength > 0 && availableBody < contentLength {
            return nil  // need more bytes
        }
        let body: Data
        if contentLength > 0 {
            body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = Data()
        }
        return HTTPRequest(method: method, path: path, query: query, body: body)
    }

    private func splitPathAndQuery(_ target: String) -> (String, [String: String]) {
        if let q = target.firstIndex(of: "?") {
            let path = String(target[..<q])
            let queryString = String(target[target.index(after: q)...])
            var pairs: [String: String] = [:]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    pairs[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                } else if kv.count == 1 {
                    pairs[kv[0]] = ""
                }
            }
            return (path, pairs)
        }
        return (target, [:])
    }
}
