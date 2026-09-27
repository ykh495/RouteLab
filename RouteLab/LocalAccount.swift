import Foundation
import Combine
import LocalAuthentication

@MainActor
final class LocalAccount: ObservableObject {
    @Published var unlocked = false
    @Published var working = false
    @Published var message: String?
    @Published var name: String
    @Published var policy: LockPolicy {
        didSet { UserDefaults.standard.set(policy.rawValue, forKey: "lockPolicy") }
    }
    private var autoAttempted = false
    private var explicitlyLocked = false
    init() {
        name = UserDefaults.standard.string(forKey: "profileName") ?? ""
        policy = LockPolicy(rawValue: UserDefaults.standard.string(forKey: "lockPolicy") ?? "grace") ?? .grace
        let stamp = UserDefaults.standard.double(forKey: "lastUnlockedExit")
        let age = Date().timeIntervalSince1970 - stamp
        explicitlyLocked = UserDefaults.standard.bool(forKey: "explicitlyLocked")
        unlocked = !name.isEmpty && !explicitlyLocked && (policy == .never || (policy == .grace && stamp > 0 && age >= 0 && age < 900))
    }
    func autoSignInIfNeeded() async {
        guard !unlocked, !name.isEmpty, !working, !autoAttempted, !explicitlyLocked else { return }
        autoAttempted = true
        await signIn(name: name)
    }
    func signIn(name input: String) async {
        guard !working else { return }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { message = L("请输入你的称呼。", "Enter your name."); return }
        if policy == .never && !name.isEmpty && !explicitlyLocked { unlock(value); return }
        working = true; defer { working = false }
        let context = LAContext(); context.localizedCancelTitle = L("取消", "Cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = L("请先为 iPhone 设置设备密码，再使用 Face ID、Touch ID 或设备密码验证。", "Set an iPhone passcode to use Face ID, Touch ID or passcode authentication."); return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("解锁你的行程记录", "Unlock your trip records")) { unlock(value) }
        } catch { message = L("验证已取消，点击按钮可重试。", "Authentication cancelled. Tap below to retry.") }
    }
    private func unlock(_ value: String) {
        name = value; unlocked = true; explicitlyLocked = false; message = nil
        UserDefaults.standard.set(value, forKey: "profileName")
        UserDefaults.standard.set(false, forKey: "explicitlyLocked")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUnlockedExit")
    }
    func didBackground() {
        if unlocked { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUnlockedExit") }
        if policy == .always { unlocked = false }
        autoAttempted = false
    }
    func didBecomeActive() async {
        let age = Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: "lastUnlockedExit")
        if policy == .grace && (age >= 900 || age < 0) { unlocked = false }
        await autoSignInIfNeeded()
    }
    func signOut() {
        explicitlyLocked = true; unlocked = false; autoAttempted = true
        UserDefaults.standard.set(true, forKey: "explicitlyLocked")
    }
}
