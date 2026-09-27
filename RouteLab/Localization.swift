import Foundation

enum AppLanguage {
    static var choice: String { UserDefaults.standard.string(forKey: "appLanguage") ?? "system" }
    static var isChinese: Bool { choice == "zh" || (choice == "system" && (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")) }
    static var locale: Locale { Locale(identifier: isChinese ? "zh-Hans" : "en-US") }
}
func L(_ chinese: String, _ english: String) -> String { AppLanguage.isChinese ? chinese : english }
enum LockPolicy: String, CaseIterable, Identifiable {
    case grace, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grace: return L("离开 15 分钟后验证", "Lock after 15 minutes away")
        case .always: return L("每次打开时验证", "Authenticate on every open")
        case .never: return L("不要求 App 内验证", "No in-app authentication")
        }
    }
}
