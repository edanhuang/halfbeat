import Foundation

enum AppIdentity {
    static var displayName: String { displayName(in: .main) }

    // 与 Finder 共用 InfoPlist.strings 的语言选择，避免系统名称已切换、App 自身标题仍固定为中文。
    static func displayName(in bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Halfbeat"
    }
}
