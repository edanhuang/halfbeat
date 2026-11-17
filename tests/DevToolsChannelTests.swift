import Foundation
import Network

// 用本机 WebSocket 服务模拟播放器调试接口，验证心跳复用同一条连接，且断线、超时后能自动重连。
// 运行：xcrun swiftc -parse-as-library DevToolsChannel.swift tests/DevToolsChannelTests.swift -o /tmp/devtools-tests && /tmp/devtools-tests
final class FakeDevTools: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake-devtools")
    private let listener: NWListener
    private var live: [NWConnection] = []
    private var accepted = 0

    init() throws {
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [unowned self] connection in
            accepted += 1
            live.append(connection)
            connection.start(queue: queue)
            receive(on: connection)
        }
    }

    func start() async -> URL {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.resume() } }
            listener.start(queue: queue)
        }
        return URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/devtools/page/1")!
    }

    var acceptedCount: Int { queue.sync { accepted } }

    /// 模拟播放器退出或页面重载：服务端主动断开所有连接。
    func dropAll() { queue.sync { live.forEach { $0.cancel() }; live.removeAll() } }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = body["id"] as? Int else { return }
            let expression = ((body["params"] as? [String: Any])?["expression"] as? String) ?? ""
            // "hang" 不回复，用于验证超时后能关闭并重连。
            if expression != "hang" {
                let reply: [String: Any] = ["id": id, "result": ["result": ["type": "string", "value": expression]]]
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "reply", metadata: [metadata])
                connection.send(content: try! JSONSerialization.data(withJSONObject: reply), contentContext: context,
                                isComplete: true, completion: .contentProcessed { _ in })
            }
            self.receive(on: connection)
        }
    }
}

@main @MainActor struct DevToolsChannelTests {
    static func main() async throws {
        let server = try FakeDevTools()
        let url = await server.start()
        let channel = DevToolsChannel(timeout: 0.5)

        // 1. 连续 200 次心跳只建立一条连接，且每次拿到的是本次 id 的响应。
        for index in 0..<200 {
            let response = try await channel.evaluate("tick-\(index)", at: url)
            precondition(response.contains("\"tick-\(index)\""), "Response must match this request: \(response)")
        }
        precondition(channel.openCount == 1, "Heartbeats must reuse one socket, opened \(channel.openCount)")
        precondition(server.acceptedCount == 1, "Server saw \(server.acceptedCount) connections")

        // 2. 服务端断开后，本次调用失败并释放连接，下一次自动重连成功。
        server.dropAll()
        var failed = false
        do { _ = try await channel.evaluate("after-drop", at: url) } catch { failed = true }
        precondition(failed && !channel.isOpen, "A dropped socket must surface an error and be released")
        _ = try await channel.evaluate("reconnected", at: url)
        precondition(channel.openCount == 2, "Expected exactly one reconnect, opened \(channel.openCount)")

        // 3. 无响应时按超时失败，不会卡住后续心跳；之前迟到的响应不会被误认。
        var timedOut = false
        do { _ = try await channel.evaluate("hang", at: url) } catch { timedOut = (error as? URLError)?.code == .timedOut }
        precondition(timedOut && !channel.isOpen, "A silent page must time out and release the socket")
        let recovered = try await channel.evaluate("recovered", at: url)
        precondition(recovered.contains("\"recovered\""))

        // 4. 调试地址变化（页面重载换了 target id）时切换到新地址。
        let reloaded = URL(string: url.absoluteString.replacingOccurrences(of: "/page/1", with: "/page/2"))!
        _ = try await channel.evaluate("new-target", at: reloaded)
        precondition(channel.target == reloaded && channel.openCount == 4)

        channel.close()
        print("PASS: heartbeat reuses one socket, reconnect after drop, timeout release, stale-id skip and target switch.")
    }
}
