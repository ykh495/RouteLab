import SwiftUI

@main
@MainActor
struct RouteLabApp: App {
    @StateObject private var store: TripStore
    @StateObject private var recorder: LocationRecorder
    @StateObject private var analyzer: JourneyAnalyzer
    @StateObject private var account = LocalAccount()
    @AppStorage("appLanguage") private var language = "system"
    @Environment(\.scenePhase) private var phase
    init() {
        let store = TripStore()
        _store = StateObject(wrappedValue: store)
        _recorder = StateObject(wrappedValue: LocationRecorder(store: store))
        _analyzer = StateObject(wrappedValue: JourneyAnalyzer(store: store))
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if account.unlocked { MainTabs() }
                else { LoginView() }
            }.id(language)
            .environment(\.locale, AppLanguage.locale)
            .environmentObject(store).environmentObject(recorder).environmentObject(account).environmentObject(analyzer)
            .tint(.teal)
            .overlay {
                if phase == .background {
                    Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "location.north.circle.fill").font(.system(size: 64)).foregroundStyle(.teal))
                }
            }
            .task {
                store.migrateRouteGroups()
                await account.autoSignInIfNeeded()
                recorder.setForeground(account.unlocked && phase == .active)
                if account.unlocked { await analyzer.runPending() }
            }
            .onChange(of: account.unlocked) { _, unlocked in
                recorder.setForeground(unlocked && phase == .active)
                if unlocked { Task { await analyzer.runPending() } }
            }
            .onChange(of: recorder.lastSavedID) { _, _ in Task { await analyzer.runPending() } }
            .onChange(of: phase) { _, newPhase in
                if newPhase == .background {
                    recorder.checkpoint(); recorder.setForeground(false); account.didBackground()
                } else if newPhase == .active {
                    Task {
                        await account.didBecomeActive()
                        recorder.setForeground(account.unlocked)
                        if account.unlocked { await analyzer.runPending() }
                    }
                }
            }
        }
    }
}

@MainActor
struct MainTabs: View {
    @EnvironmentObject var store: TripStore
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label(L("出发", "Go"), systemImage: "location.north.circle") }
            NavigationStack { HistoryView() }.tabItem { Label(L("行程", "Trips"), systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            NavigationStack { InsightsView() }.tabItem { Label(L("比较", "Compare"), systemImage: "chart.bar.xaxis") }
            NavigationStack { SettingsView() }.tabItem { Label(L("设置", "Settings"), systemImage: "person.crop.circle") }
        }
        .alert(L("数据保存提示", "Storage notice"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L("知道了", "OK")) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

@MainActor
struct LoginView: View {
    @EnvironmentObject var account: LocalAccount
    @AppStorage("appLanguage") private var language = "system"
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Image(systemName: "location.north.circle.fill").font(.system(size: 72)).foregroundStyle(.teal).padding(.top, 64)
                VStack(alignment: .leading, spacing: 10) {
                    Text("RouteLab").font(.largeTitle.bold())
                    Text(L("找到适合你的通勤路线", "Find your better commute")).font(.title2.weight(.medium))
                    Text(L("记录真实行驶，用自己的数据比较路线。", "Record real journeys. Compare routes with your own data.")).foregroundStyle(.secondary)
                }
                Card {
                    LanguagePicker(selection: $language)
                    Text(account.name.isEmpty ? L("创建本机账户", "Create a local profile") : L("欢迎回来", "Welcome back")).font(.headline)
                    TextField(L("你的称呼", "Your name"), text: $name).textContentType(.nickname).textFieldStyle(.roundedBorder)
                    Text(L("通过 Face ID、Touch ID 或设备密码验证。默认 15 分钟内重新打开无需验证，可在设置修改。", "Use Face ID, Touch ID, or your device passcode. By default, reopening within 15 minutes needs no authentication. Change this in Settings.")).font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await account.signIn(name: name) } } label: {
                        Label(account.working ? L("验证中…", "Authenticating…") : L("继续", "Continue"), systemImage: "faceid").frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).disabled(account.working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let message = account.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                Text(L("账户与行程保存在这部 iPhone。打开后自动获取当前位置；只有开始记录的行程会在后台持续定位。", "Your profile and trips stay on this iPhone. Location updates while the app is open; background recording runs only during an active trip.")).font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }.background(Color(.systemGroupedBackground)).onAppear { name = account.name }
    }
}

struct LanguagePicker: View {
    @Binding var selection: String
    var body: some View {
        Picker(L("语言 / Language", "Language / 语言"), selection: $selection) {
            Text(L("跟随系统", "System default")).tag("system")
            Text("中文").tag("zh")
            Text("English").tag("en")
        }
    }
}
struct Card<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
func minutesText(_ seconds: Double) -> String { String(format: L("%.1f 分钟", "%.1f min"), seconds / 60) }
func kilometersText(_ meters: Double) -> String { String(format: "%.2f km", meters / 1000) }
