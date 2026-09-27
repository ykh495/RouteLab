import SwiftUI
import UIKit

@MainActor
struct HomeView: View {
    @EnvironmentObject var recorder: LocationRecorder
    @EnvironmentObject var store: TripStore
    @StateObject private var planner = TripPlanner()
    @State private var choosing = false
    @State private var favoritePlace: Place?
    @State private var editingFavorite: Favorite?
    @State private var navigator = Navigator.apple
    @State private var starting = false
    @State private var autoArrival = false
    @State private var finishedID: UUID?
    @State private var showFinished = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let trip = recorder.active { recordingCard(trip) }
                else { destinationCard; estimateCard; startCard }
                if let message = recorder.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }.padding()
        }.background(Color(.systemGroupedBackground)).navigationTitle(L("准备出发", "Ready to go"))
            .task { recorder.requestPermission(); planner.observe(recorder.latest) }
            .onChange(of: recorder.latest?.timestamp) { _, _ in if recorder.active == nil { planner.observe(recorder.latest) } }
            .onChange(of: recorder.lastSavedID) { _, id in finishedID = id; showFinished = id != nil }
            .sheet(isPresented: $choosing) { DestinationPicker { planner.choose($0, fix: recorder.latest) } }
            .sheet(item: $favoritePlace) { FavoriteEditor(place: $0) }
            .sheet(item: $editingFavorite) { FavoriteEditor(place: $0.place, existing: $0) }
            .sheet(isPresented: $showFinished) {
                if let id = finishedID, let trip = store.trips.first(where: { $0.id == id }) {
                    NavigationStack { TripDetailView(trip: trip).toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成", "Done")) { showFinished = false } } } }
                }
            }
    }
    private var destinationCard: some View {
        Card {
            Text(L("这次去哪里？", "Where to?")).font(.title2.bold())
            Button { choosing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(planner.destination?.name ?? L("搜索地址或在地图选点", "Search an address or drop a pin"))
                            .foregroundStyle(.primary)
                        if let address = planner.destination?.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                }.padding(14).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }.disabled(starting)
            if let destination = planner.destination {
                Button { favoritePlace = destination } label: { Label(L("保存为常用目的地", "Save as favorite"), systemImage: "star") }
                    .font(.subheadline)
            }
            Text(L("常用目的地", "Favorites")).font(.headline)
            if store.favorites.isEmpty {
                Text(L("选好地点后保存住址、学校、图书馆或其他常去地点。", "Choose a destination and save your home, school, library, or any place you visit often."))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(store.favorites) { favorite in
                            Button { planner.choose(favorite.place, fix: recorder.latest) } label: {
                                Label(favorite.displayTitle, systemImage: favorite.icon).padding(10).background(.teal.opacity(0.10), in: Capsule())
                            }.disabled(starting)
                                .contextMenu { Button(L("编辑常用目的地", "Edit favorite")) { editingFavorite = favorite } }
                        }
                    }
                }
            }
            Label(recorder.freshFix ? L("当前位置已就绪 · 自动更新", "Location ready · updates automatically") : L("正在获取当前位置…", "Getting your location…"), systemImage: "location.fill")
                .font(.caption).foregroundStyle(recorder.freshFix ? .teal : .secondary)
            if !recorder.allowed {
                Button(L("允许定位 / 打开设置", "Allow location / open Settings")) {
                    if recorder.authorization == .notDetermined { recorder.requestPermission() }
                    else { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
            } else if !recorder.precise {
                Button(L("开启精确定位", "Enable Precise Location")) { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
        }
    }
    private var estimateCard: some View {
        Card {
            Text(L("出发前估时", "Before you leave")).font(.headline)
            if planner.busy { ProgressView(L("自动获取参考路线…", "Getting reference routes…")) }
            if planner.destination == nil {
                Text(L("选择目的地后，自动显示路线与预计时间。", "Choose a destination to see routes and travel times automatically.")).foregroundStyle(.secondary)
            }
            ForEach(planner.options) { option in
                Button { planner.selectedID = option.id } label: {
                    HStack {
                        Image(systemName: planner.selected?.id == option.id ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(option.name).foregroundStyle(.primary)
                            Text(kilometersText(option.meters)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Text(minutesText(option.seconds)).font(.headline)
                    }
                }.disabled(starting)
            }
            if let option = planner.selected {
                RouteMap(points: [], planned: option.coordinates, destination: planner.destination).frame(height: 225)
                Text(L("绿色是 MapKit 出发前参考路线。打开地图后，导航软件可能重新选路和估时。", "Green shows the MapKit reference route. Your navigation app may recalculate its route and ETA.")).font(.caption).foregroundStyle(.secondary)
            }
            if let message = planner.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button(L("重试估时", "Retry estimate")) { if let fix = recorder.latest { Task { await planner.refresh(fix) } } }.disabled(planner.busy || starting)
            }
        }
    }
    private var startCard: some View {
        Card {
            Picker(L("导航软件", "Navigation app"), selection: $navigator) {
                Text("Apple Maps").tag(Navigator.apple); Text("Google Maps").tag(Navigator.google)
            }.pickerStyle(.segmented)
            Toggle(L("自动检测可能到达", "Detect possible arrival"), isOn: $autoArrival).font(.subheadline)
            if autoArrival { Text(L("目的地附近持续静止 2 分钟后保存，并请你确认到达时间。", "Saves after 2 minutes stopped near your destination, then asks you to confirm arrival.")).font(.caption).foregroundStyle(.secondary) }
            Button { Task { await start() } } label: {
                Label(starting ? L("准备定位与估时…", "Preparing location and estimate…") : L("开始记录并打开地图", "Record and open Maps"), systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).disabled(planner.destination == nil || starting)
        }
    }
    @ViewBuilder private func recordingCard(_ trip: Trip) -> some View {
        Card {
            Label(recorder.isRecording ? L("行程记录中", "Recording your trip") : L("恢复未结束行程", "Recovered trip"), systemImage: "record.circle").font(.title2.bold())
            Text(trip.destination?.name ?? L("未设置目的地", "No destination"))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(minutesText(max(0, context.date.timeIntervalSince(trip.startedAt)))).font(.largeTitle.monospacedDigit())
            }
            RouteMap(points: trip.usablePoints, planned: trip.plannedRoute, destination: trip.destination).frame(height: 290)
            if recorder.isRecording {
                Button { recorder.finish() } label: { Label(L("已到达，结束记录", "Arrived · finish trip"), systemImage: "stop.circle.fill").frame(maxWidth: .infinity).padding(7) }.buttonStyle(.borderedProminent)
                if let destination = trip.destination {
                    Button(L("返回导航", "Return to navigation")) { Task { _ = await NavigationService.open(trip.navigator, destination: destination) } }
                }
            } else {
                Button(L("恢复记录", "Resume recording")) { recorder.resume() }.buttonStyle(.borderedProminent)
                Button(L("保存已记录部分", "Save recorded portion")) { recorder.saveRecoveredPart() }
            }
            Text(L("切到地图或锁屏后仍继续记录。不要上滑强制退出正在记录的 App。", "Recording continues in Maps and with the screen locked. Keep the recording app running.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func start() async {
        guard !starting, let destination = planner.destination else { return }
        starting = true; defer { starting = false }
        guard await recorder.ensureFreshFix(), let fix = recorder.latest else { return }
        if planner.needsRefresh(fix) { await planner.refresh(fix) }
        // A route request can outlast a GPS fix. Recheck before writing the departure snapshot.
        guard await recorder.ensureFreshFix(), UIApplication.shared.applicationState == .active else { return }
        let option = planner.selected.flatMap { Date().timeIntervalSince($0.capturedAt) <= 120 ? $0 : nil }
        if recorder.begin(destination: destination, label: "", navigator: navigator, option: option,
                          externalMinutes: nil, externalCapturedAt: nil, roadFeatures: [], contextStatus: "pending", autoArrival: autoArrival) {
            if !(await NavigationService.open(navigator, destination: destination)) {
                recorder.message = L("记录已开始，但未能打开地图。可手动打开导航。", "Recording started, but Maps could not open. Open your navigation app manually.")
            }
        }
    }
}
