import Foundation

@main struct ConnectionRecoveryTests {
    static func main() {
        var recovery = ConnectionRecovery()
        precondition(!recovery.shouldRestart(pid: 101, hasDebugPort: nil, endpointAvailable: false, now: 0))
        precondition(!recovery.shouldRestart(pid: 101, hasDebugPort: false, endpointAvailable: false, now: 1))
        precondition(!recovery.shouldRestart(pid: 101, hasDebugPort: false, endpointAvailable: false, now: 4))
        precondition(recovery.shouldRestart(pid: 101, hasDebugPort: false, endpointAvailable: false, now: 5))
        precondition(!recovery.shouldRestart(pid: 101, hasDebugPort: false, endpointAvailable: false, now: 50))
        // 新进程有接口参数：即使接口暂时不可达也不能重启。
        precondition(!recovery.shouldRestart(pid: 102, hasDebugPort: true, endpointAvailable: false, now: 51))
        precondition(!recovery.shouldRestart(pid: 102, hasDebugPort: true, endpointAvailable: false, now: 100))
        // 用户退出后普通方式重开：新的进程仍能自动接入。
        precondition(!recovery.shouldRestart(pid: 103, hasDebugPort: false, endpointAvailable: false, now: 101))
        precondition(recovery.shouldRestart(pid: 103, hasDebugPort: false, endpointAvailable: false, now: 105))
        // 接口已经可访问时不能因运行时初始化或歌词状态失败重启。
        precondition(!recovery.shouldRestart(pid: 104, hasDebugPort: false, endpointAvailable: false, now: 110))
        precondition(!recovery.shouldRestart(pid: 104, hasDebugPort: false, endpointAvailable: true, now: 115))
        precondition(!recovery.shouldRestart(pid: 104, hasDebugPort: false, endpointAvailable: false, now: 116))
        recovery.resetPending()
        precondition(!recovery.shouldRestart(pid: 104, hasDebugPort: false, endpointAvailable: false, now: 200))
        recovery.markAttempted(pid: 104)
        precondition(!recovery.shouldRestart(pid: 104, hasDebugPort: false, endpointAvailable: false, now: 210))
        precondition(PlayerLaunchMode.hasDebugPort(in: "/Applications/NeteaseMusic.app/Contents/MacOS/NeteaseMusic --remote-debugging-port=19222", port: 19222))
        precondition(PlayerLaunchMode.hasDebugPort(in: "NeteaseMusic --remote-debugging-port 19222", port: 19222))
        precondition(!PlayerLaunchMode.hasDebugPort(in: "NeteaseMusic --remote-debugging-port=192220", port: 19222))
        precondition(!PlayerLaunchMode.hasDebugPort(in: "NeteaseMusic", port: 19222))
        precondition(PlayerLaunchMode.hasDebugPort(pid: -1, port: 19222) == nil)
        print("PASS: ordinary relaunch recovery, startup grace, one attempt per process, unavailable flagged endpoint, runtime initialization, unknown launch mode and exact debug-port parsing.")
    }
}
