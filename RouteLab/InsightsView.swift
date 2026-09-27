import SwiftUI
import UIKit

@MainActor
struct InsightsView: View {
    @EnvironmentObject var store: TripStore
    var body: some View {
        let summaries = TripMath.summaries(store.trips)
        let eligible = store.trips.filter { TripMath.exclusionReason($0) == nil }.count
        let groups = Dictionary(grouping: summaries) { "\($0.odNumber)|\($0.timezoneID)|\($0.dayType)|\($0.timeBucket)" }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    Text(L("从真实行程比较", "Compare real journeys")).font(.title2.bold())
                    Text(String(format: L("%d 次可比较 / 共 %d 次记录", "%d comparable / %d recorded trips"), eligible, store.trips.count)).foregroundStyle(.secondary)
                    Text(L("相近起终点各 250m 内、同一当地半小时出发时段、工作日或周末分别比较。实际轨迹自动归类，去程与回程分开。", "Compare nearby endpoints within 250 m, the same local half-hour departure window, and weekdays or weekends separately. Actual tracks are grouped automatically; outbound and return journeys stay separate.")).font(.footnote).foregroundStyle(.secondary)
                    Text(L("这些是历史统计，不代表今天一定更快。样本少于 5 次仅供观察，P90 至少需要 20 次。", "Historical statistics do not guarantee a faster trip today. Fewer than 5 samples is preliminary; P90 requires at least 20.")).font(.footnote).foregroundStyle(.secondary)
                }
                if summaries.isEmpty {
                    ContentUnavailableView(L("继续积累行程", "Collect more trips"), systemImage: "chart.bar.xaxis", description: Text(L("手动结束的完整行程自动纳入统计。自动到达需确认，中断或定位覆盖不足的记录保留供参考。", "Complete, manually finished trips are included automatically. Confirm detected arrivals. Interrupted or poorly covered trips remain available for reference.")))
                }
                ForEach(groups.keys.sorted(), id: \.self) { key in
                    Card {
                        if let first = groups[key]?.first {
                            Text(String(format: L("起终点组 %d", "Endpoint group %d"), first.odNumber) + " · " + first.dayType + " · " + first.timeBucket).font(.headline)
                            Text(L("按平均耗时排序 · ", "Sorted by mean duration · ") + first.timezoneID).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach((groups[key] ?? []).sorted { $0.meanMinutes < $1.meanMinutes }) { summary in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(summary.routeLabel).font(.headline); Spacer()
                                    Text(String(format: L("%d 次", "%d trips"), summary.count)).font(.caption).padding(5).background(.teal.opacity(0.12), in: Capsule())
                                }
                                Text(String(format: L("平均 %.1f 分钟 · 中位数 %.1f 分钟", "Mean %.1f min · Median %.1f min"), summary.meanMinutes, summary.medianMinutes))
                                if let sd = summary.standardDeviationMinutes {
                                    Text(String(format: L("波动（样本标准差）%.1f 分钟", "Variability (sample SD): %.1f min"), sd)).font(.caption).foregroundStyle(.secondary)
                                } else { Text(L("至少 2 次才能估计波动", "At least 2 trips needed for variability")).font(.caption).foregroundStyle(.secondary) }
                                if let p90 = summary.p90Minutes { Text(String(format: L("历史 P90：%.1f 分钟", "Historical P90: %.1f min"), p90)).font(.caption).foregroundStyle(.secondary) }
                                if summary.count < 5 { Text(L("样本较少，继续积累", "Small sample · keep recording")).font(.caption).foregroundStyle(.orange) }
                                Divider()
                            }
                        }
                    }
                }
            }.padding()
        }.background(Color(.systemGroupedBackground)).navigationTitle(L("路线比较", "Route comparison"))
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject var account: LocalAccount
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var recorder: LocationRecorder
    @EnvironmentObject var analyzer: JourneyAnalyzer
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage("roadAnalysisEnabled") private var roadAnalysis = true
    @State private var exportURL: URL?
    @State private var sharing = false
    @State private var error: String?
    @State private var editingFavorite: Favorite?
    @State private var choosing = false
    @State private var newFavoritePlace: Place?
    @State private var showNewFavorite: Place?
    var body: some View {
        Form {
            Section(L("本机账户", "Local profile")) {
                LabeledContent(L("名称", "Name"), value: account.name)
                LanguagePicker(selection: $language)
                Picker(L("重新打开时验证", "Authenticate on reopening"), selection: $account.policy) {
                    ForEach(LockPolicy.allCases) { Text($0.title).tag($0) }
                }
                Text(L("需要验证时自动弹出 Face ID、Touch ID 或设备密码；取消后可点击重试。", "When authentication is needed, Face ID, Touch ID, or passcode starts automatically. If cancelled, tap to retry.")).font(.footnote).foregroundStyle(.secondary)
                Button(L("立即锁定", "Lock now")) { account.signOut() }
                if recorder.isRecording { Text(L("锁定账户不会停止行程记录。", "Locking does not stop an active recording.")).font(.caption) }
            }
            Section(L("常用目的地", "Favorites")) {
                ForEach(store.favorites) { favorite in
                    Button { editingFavorite = favorite } label: {
                        HStack { Label(favorite.displayTitle, systemImage: favorite.icon); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                    }
                }
                Button(L("添加常用目的地", "Add a favorite")) { choosing = true }
            }
            Section(L("路线识别", "Road identification")) {
                Toggle(L("自动查询道路和路口信息", "Look up roads and intersections"), isOn: $roadAnalysis)
                Text(L("行程结束后联网查询 OpenStreetMap / Overpass，道路查询区域会发送至该服务。完整轨迹保存在本机；关闭后仍可记录、按轨迹归类和比较耗时。", "After a trip, look up roads through OpenStreetMap / Overpass. The road query area is sent to that service. Full tracks stay on this phone. Recording, track grouping, and time comparisons also work with this off.")).font(.footnote).foregroundStyle(.secondary)
                Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
            Section(L("导出数据", "Export data")) {
                Button(L("导出全部已保存行程 · JSON", "Export saved trips · JSON")) {
                    do { exportURL = try store.export(); sharing = true } catch { self.error = error.localizedDescription }
                }.disabled(store.trips.isEmpty && store.favorites.isEmpty)
                Text(L("包含精确轨迹、时间、初始参考 ETA、道路匹配和标注。可存到“文件”或 AirDrop 到 Mac，用附带 Python 工具生成 CSV。", "Includes precise tracks, times, initial reference ETA, road matches, and corrections. Save to Files or AirDrop to a Mac, then use the included Python tool for CSV.")).font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            Section(L("定位与存储", "Location and storage")) {
                Text(L("前台自动更新位置；只有主动开始的行程在后台持续定位。无需空闲时一直后台运行。", "Location updates automatically in the foreground. Only an actively started trip uses continuous background location."))
                Button(L("管理定位权限", "Manage location access")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                Text(L("记录存于本机，不提供云同步，也不参与设备云备份。升级请保持相同 Bundle Identifier 并覆盖安装；卸载会丢失本机记录。", "Records stay on this device without cloud sync or device cloud backup. Update using the same Bundle Identifier. Uninstalling deletes local records.")).font(.footnote).foregroundStyle(.secondary)
            }
            Section("RouteLab 0.2") {
                Text(L("地图搜索和参考 ETA 由 Apple MapKit 提供。无法读取 Apple / Google Maps 屏幕中的 ETA，也不能监听它们的导航开始或结束。", "Apple MapKit provides search and reference estimates. RouteLab cannot read the ETA shown in Apple / Google Maps or monitor their navigation start and end events.")).font(.footnote)
                Text(L("停车原因与道路名称是近似识别，不是实时信号灯或列车检测。强制退出或系统终止可能中断记录，可恢复已保存部分。", "Stop causes and street names are approximate inferences, not live signal or train detection. Force-quitting or system termination can interrupt recording; saved samples can be recovered.")).font(.footnote)
            }
        }.navigationTitle(L("设置", "Settings"))
            .sheet(isPresented: $sharing, onDismiss: { exportURL = nil }) { if let exportURL { ExportSheet(items: [exportURL]) } }
            .sheet(item: $editingFavorite) { FavoriteEditor(place: $0.place, existing: $0) }
            .sheet(isPresented: $choosing, onDismiss: {
                showNewFavorite = newFavoritePlace; newFavoritePlace = nil
            }) { DestinationPicker { newFavoritePlace = $0 } }
            .sheet(item: $showNewFavorite) { FavoriteEditor(place: $0) }
    }
}

@MainActor
struct ExportSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
