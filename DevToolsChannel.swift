import Foundation

// 与播放器调试页面保持一条 WebSocket 长连接，每次心跳复用它发送 Runtime.evaluate。
// 实测（macOS 26）每个 URLSessionWebSocketTask 在 cancel 后仍常驻内存，invalidate 所属 session 也不释放，
// 每个约 45KB。旧实现每 2 秒新建一个，连续运行一周累积约 3 万个、500MB+。
// 因此只能让重连尽量少发生：心跳复用连接，仅在出错或调试地址变化时重建。
@MainActor
final class DevToolsChannel {
    let timeout: TimeInterval
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // 只连本机调试端口，绕开系统代理；不设资源超时，避免长连接被定时掐断。
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
    private var socket: URLSessionWebSocketTask?
    private(set) var target: URL?
    private var nextID = 0
    /// 建立过的连接数，用于回归测试确认心跳复用而不是每次重连。
    private(set) var openCount = 0

    nonisolated init(timeout: TimeInterval = 3) { self.timeout = timeout }

    var isOpen: Bool { socket != nil }

    /// 返回与本次请求 id 匹配的原始响应文本；任何发送、接收或超时错误都会关闭连接，下次调用自动重连。
    func evaluate(_ expression: String, at url: URL) async throws -> String {
        if socket == nil || target != url { open(url) }
        guard let socket else { throw URLError(.cannotConnectToHost) }
        nextID += 1
        let id = nextID
        let request: [String: Any] = ["id": id, "method": "Runtime.evaluate",
                                      "params": ["expression": expression, "returnByValue": true]]
        let message = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let timeout = self.timeout
        do {
            try await socket.send(.string(message))
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    while true {
                        let text: String
                        switch try await socket.receive() {
                        case .string(let value): text = value
                        case .data(let value): text = String(data: value, encoding: .utf8) ?? ""
                        @unknown default: continue
                        }
                        // 跳过上一次超时请求迟到的响应，只认本次 id。
                        if let raw = text.data(using: .utf8),
                           let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                           body["id"] as? Int == id { return text }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // receive 不响应任务取消，必须取消 socket 才能让挂起的接收结束，否则任务组无法返回。
                    socket.cancel(with: .goingAway, reason: nil)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        target = nil
    }

    private func open(_ url: URL) {
        close()
        let socket = session.webSocketTask(with: url)
        socket.resume()
        self.socket = socket
        target = url
        openCount += 1
    }
}
