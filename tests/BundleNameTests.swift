import Foundation

@main struct BundleNameTests {
    static func main() {
        // 裸命令行程序的主 Bundle 会限制被加载 Bundle 的语言，必须由同样包含本地化资源的隔离 App 承载测试。
        precondition(Bundle.main.bundleURL.pathExtension == "app", "Run tools/test_bundle_names.sh instead of a bare test executable")
        let arguments = CommandLine.arguments
        precondition(arguments.count >= 3, "Usage: BundleNameTests <app-path> <expected-name> -AppleLanguages '(en)'")
        let path = arguments[1]
        let expectedName = arguments[2]
        guard let bundle = Bundle(path: path) else { fatalError("Cannot load built app: \(path)") }
        precondition(bundle.bundleURL.deletingPathExtension().lastPathComponent == "Halfbeat", "Finder requires the canonical bundle filename")
        precondition(bundle.infoDictionary?["CFBundleDisplayName"] as? String == "Halfbeat", "Default name must match bundle filename")
        precondition(Set(bundle.localizations).isSuperset(of: ["en", "zh-Hans"]), "Both name localizations must be packaged")
        let name = AppIdentity.displayName(in: bundle)
        precondition(name == expectedName, "Expected \(expectedName), got \(name); selected \(bundle.preferredLocalizations)")
        precondition(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == expectedName, "Short name and display name must agree")
        print("PASS: \(bundle.preferredLocalizations) -> \(name), localized short name, packaged resources and canonical filename.")
    }
}
