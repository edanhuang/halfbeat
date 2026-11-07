import Foundation

// 连接失败不等于缺少接口。仅对已确认未带调试参数的进程自动接入，
// 每个进程最多一次；启动宽限期内和已经有接口的进程都只重试连接。
struct ConnectionRecovery {
    var graceSeconds: TimeInterval = 4
    private var pendingPID: pid_t?
    private var pendingSince: TimeInterval = 0
    private var attempted = Set<pid_t>()

    mutating func resetPending() { pendingPID = nil }
    mutating func markAttempted(pid: pid_t) { attempted.insert(pid) }

    mutating func shouldRestart(pid: pid_t, hasDebugPort: Bool?, endpointAvailable: Bool,
                                now: TimeInterval) -> Bool {
        guard hasDebugPort == false, !endpointAvailable, !attempted.contains(pid) else {
            resetPending()
            return false
        }
        guard pendingPID == pid else {
            pendingPID = pid
            pendingSince = now
            return false
        }
        guard now - pendingSince >= graceSeconds else { return false }
        markAttempted(pid: pid)
        resetPending()
        return true
    }
}

enum PlayerLaunchMode {
    static func hasDebugPort(in command: String, port: Int) -> Bool {
        let arguments = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, argument) in arguments.enumerated() {
            if argument == "--remote-debugging-port=\(port)" { return true }
            if argument == "--remote-debugging-port", index + 1 < arguments.count,
               arguments[index + 1] == String(port) { return true }
        }
        return false
    }

    static func hasDebugPort(pid: pid_t, port: Int) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let command = String(data: data, encoding: .utf8),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return hasDebugPort(in: command, port: port)
    }
}
