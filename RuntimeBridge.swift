import Foundation

// 通过播放器的本机调试接口安装内存适配，不修改签名应用或绕过资源校验；内部模块变化时连接应失败并显示状态。
final class RuntimeBridge {
    static let port = 19222
    // 必须与 bridge.js 返回的 version 一致：不一致时会停掉旧实例再注入新的。
    static let bridgeVersion = "2.2.1"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()
    private var checking = false
    private let expression: String
    private let connectionURL: URL
    // 调试接口可访问与运行时适配成功是两种状态，不能把初始化等待误判为需要重启。
    private(set) var debugEndpointAvailable = false
    var connected = false
    var error: String?

    init(support: URL) {
        connectionURL = support.appendingPathComponent("connection.json")
        let source = (try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("bridge.js"), encoding: .utf8)) ?? ""
        let resolver = (try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("runtime.js"), encoding: .utf8)) ?? ""
        let paths = ["config": support.appendingPathComponent("config.json").path,
                     "status": support.appendingPathComponent("status.json").path]
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: paths), encoding: .utf8)!
        // 定期重连会重复执行这段入口；同版本复用已有实例，升级时先清理旧订阅，避免多个适配器同时调整歌词。
        expression = """
        (()=>{
          if(window.__lyricOffsetBridge&&window.__lyricOffsetBridge.version==='\(Self.bridgeVersion)'){
            // 页面被隐藏时浏览器会把页面计时器节流到分钟级，每次心跳都由菜单栏主动拉起一次检查。
            if(typeof window.__lyricOffsetBridge.pump==='function')window.__lyricOffsetBridge.pump().catch(()=>{});
            return 'connected';
          }
          if(!window.webpackJsonp)throw new Error('Unsupported player runtime');
          const id=9876543;
          window.webpackJsonp.push([[id],{[id]:(module,exports,require)=>{window.__lyricOffsetRequire=require}},[[id]]]);
          const {tool,native}=(\(resolver))(window.__lyricOffsetRequire);
          if(window.__lyricOffsetBridge)window.__lyricOffsetBridge.stop();
          window.__lyricOffsetBridge=(\(source))(native,tool,\(encoded));
          return 'connected';
        })()
        """
    }
    @MainActor func tick() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer {
                checking = false
                let value: [String: Any] = ["connected": connected, "error": error ?? "", "updatedAtMs": Date().timeIntervalSince1970 * 1000]
                if let data = try? JSONSerialization.data(withJSONObject: value) { try? data.write(to: connectionURL, options: .atomic) }
            }
            do {
                let url = URL(string: "http://127.0.0.1:\(Self.port)/json/list")!
                let data: Data
                do {
                    let (responseData, response) = try await session.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          (try? JSONSerialization.jsonObject(with: responseData)) is [[String: Any]] else {
                        throw URLError(.badServerResponse)
                    }
                    data = responseData
                    debugEndpointAvailable = true
                } catch {
                    debugEndpointAvailable = false
                    throw error
                }
                // 只向网易云主播放器页面注入，且拒绝目标列表提供的非本机 WebSocket 地址。
                guard let pages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let page = pages.first(where: { ($0["url"] as? String) == "orpheus://orpheus/app.html" }),
                      let address = page["webSocketDebuggerUrl"] as? String,
                      let socketURL = URL(string: address), socketURL.scheme == "ws",
                      socketURL.host == "127.0.0.1", socketURL.port == Self.port else {
                    throw NSError(domain: "Halfbeat", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到受支持的网易云播放器页面"])
                }
                let socket = session.webSocketTask(with: socketURL)
                socket.resume()
                defer { socket.cancel(with: .goingAway, reason: nil) }
                let request: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true]]
                let message = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
                try await socket.send(.string(message))
                let response: String = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        while true {
                            let message = try await socket.receive()
                            let text: String
                            switch message {
                            case .string(let value): text = value
                            case .data(let value): text = String(data: value, encoding: .utf8) ?? ""
                            @unknown default: continue
                            }
                            if let raw = text.data(using: .utf8),
                               let body = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                               body["id"] as? Int == 1 { return text }
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        // 必须主动取消挂起的接收，否则一次无响应连接会占住 checking，导致后续重连永久停滞。
                        socket.cancel(with: .goingAway, reason: nil)
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                guard let raw = response.data(using: .utf8),
                      let body = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let result = body["result"] as? [String: Any], result["exceptionDetails"] == nil,
                      let value = result["result"] as? [String: Any], value["value"] as? String == "connected" else {
                    throw NSError(domain: "Halfbeat", code: 2, userInfo: [NSLocalizedDescriptionKey: "播放器适配失败：\(response.prefix(1200))"])
                }
                connected = true; error = nil
            } catch {
                connected = false; self.error = error.localizedDescription
            }
        }
    }
}
