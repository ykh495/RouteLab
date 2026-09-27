import SwiftUI
import MapKit

struct SpeedSegment: Identifiable {
    let id: Int
    var bucket: Int
    var coordinates: [CLLocationCoordinate2D]
    var color: Color {
        guard bucket >= 0 else { return .gray }
        let t = Double(bucket) / 10
        return Color(red: 1 - t, green: 0.15 + 0.20 * t, blue: t)
    }
    static func build(_ points: [TrackPoint]) -> [SpeedSegment] {
        var result: [SpeedSegment] = []
        guard points.count > 1 else { return result }
        var continuous = false
        for i in 1..<points.count {
            let a = points[i-1], b = points[i], dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= TripMath.maxGap, TripMath.distance(a.coordinate, b.coordinate) / dt <= 60 else { continuous = false; continue }
            let speed = a.speed < 0 || b.speed < 0 ? -1 : (a.speed + b.speed) / 2
            let bucket = speed < 0 ? -1 : Int(min(10, max(0, (speed / (80 / 3.6) * 10).rounded())))
            if continuous, result.last?.bucket == bucket { result[result.count - 1].coordinates.append(b.coordinate.cl) }
            else { result.append(SpeedSegment(id: result.count, bucket: bucket, coordinates: [a.coordinate.cl, b.coordinate.cl])) }
            continuous = true
        }
        return result
    }
}

@MainActor
struct RouteMap: View {
    var points: [TrackPoint]
    var planned: [Coordinate] = []
    var destination: Place?
    @State private var position: MapCameraPosition = .automatic
    @State private var showReference = false
    private var reference: Bool { points.isEmpty || showReference }
    var body: some View {
        VStack(spacing: 8) {
            if !points.isEmpty && !planned.isEmpty {
                Picker(L("显示路线", "Show route"), selection: $showReference) {
                    Text(L("实际路线 · 速度", "Actual · speed")).tag(false)
                    Text(L("出发前参考", "Reference")).tag(true)
                }.pickerStyle(.segmented).onChange(of: showReference) { _, _ in position = .automatic }
            }
            Map(position: $position) {
                if reference {
                    if planned.count > 1 { MapPolyline(coordinates: planned.map(\.cl)).stroke(.green, lineWidth: 6) }
                } else {
                    ForEach(SpeedSegment.build(points)) { segment in
                        MapPolyline(coordinates: segment.coordinates).stroke(segment.color, lineWidth: 6)
                    }
                }
                if let first = points.first { Marker(L("出发", "Start"), systemImage: "circle.fill", coordinate: first.coordinate.cl).tint(.green) }
                if let last = points.last, !reference { Marker(L("最后定位", "Last location"), systemImage: "location.fill", coordinate: last.coordinate.cl).tint(.blue) }
                if let destination { Marker(destination.name, coordinate: destination.coordinate.cl).tint(.orange) }
            }.mapStyle(.standard(elevation: .flat)).mapControls { MapCompass() }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if !reference {
                HStack(spacing: 8) {
                    Text(L("慢 0", "Slow 0"))
                    LinearGradient(colors: [.red, Color(red: 0.5, green: 0.25, blue: 0.5), .blue], startPoint: .leading, endPoint: .trailing).frame(height: 7).clipShape(Capsule())
                    Text(L("80+ km/h 快", "50+ mph Fast"))
                }.font(.caption2)
                Text(L("灰色：速度未知 · 定位缺失处断线", "Gray: unknown speed · gaps stay disconnected")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct HistoryView: View {
    @EnvironmentObject var store: TripStore
    var body: some View {
        List {
            if store.trips.isEmpty {
                ContentUnavailableView(L("还没有行程", "No trips yet"), systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text(L("下次出发前开始记录，结束后会保存在这里。", "Start recording before your next trip. Completed trips appear here.")))
            }
            ForEach(store.trips) { trip in
                NavigationLink { TripDetailView(trip: trip) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(trip.destination?.name ?? trip.displayTitle).font(.headline)
                        Text(trip.displayTitle + " · " + trip.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                        if let names = trip.roadNames, !names.isEmpty { Text(names.joined(separator: " → ")).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                        HStack {
                            Text(minutesText(trip.elapsed)); Spacer()
                            Text(trip.reviewed ? L("已保存", "Saved") : L("请确认到达", "Confirm arrival")).font(.caption).foregroundStyle(trip.reviewed ? .teal : .orange)
                        }
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle(L("我的行程", "My trips"))
    }
}

@MainActor
struct TripDetailView: View {
    @EnvironmentObject var store: TripStore
    @EnvironmentObject var analyzer: JourneyAnalyzer
    @Environment(\.dismiss) private var dismiss
    let tripID: UUID
    @State private var fallback: Trip
    @State private var deleteConfirmation = false
    @State private var editingArrival = false
    @State private var arrival: Date
    init(trip: Trip) {
        tripID = trip.id; _fallback = State(initialValue: trip)
        _arrival = State(initialValue: trip.endedAt ?? trip.startedAt)
    }
    private var trip: Trip { store.trips.first { $0.id == tripID } ?? fallback }
    private var metrics: TripMetrics { TripMath.metrics(trip) }
    var body: some View {
        Form {
            Section {
                RouteMap(points: trip.usablePoints, planned: trip.plannedRoute, destination: trip.destination).frame(height: 310)
                LabeledContent(L("实际总时间", "Actual duration"), value: minutesText(trip.elapsed))
                LabeledContent(L("GPS 估算距离", "GPS distance"), value: kilometersText(metrics.distanceMeters))
                LabeledContent(L("静止时间", "Stopped time"), value: minutesText(metrics.stoppedSeconds))
                LabeledContent(L("缓行时间", "Slow travel"), value: minutesText(metrics.slowSeconds))
                LabeledContent(L("定位覆盖", "Location coverage"), value: String(format: "%.0f%%", 100 * metrics.observedSeconds / max(1, trip.elapsed)))
            } header: { Text(L("实际记录", "Recorded journey")) }
            routeSection
            Section(L("最初估时", "Initial estimate")) {
                if let estimate = trip.referenceEstimate { estimateRow(estimate, title: L("MapKit 独立参考", "MapKit reference")) }
                if let estimate = trip.externalEstimate { estimateRow(estimate, title: L("外部导航 · 用户录入", "Navigation ETA · manually entered")) }
                if trip.referenceEstimate == nil && trip.externalEstimate == nil { Text(L("未保存初始 ETA", "No initial ETA saved")).foregroundStyle(.secondary) }
                Text(L("这是出发前快照，不会在途中更新；不同路线的估时差不等于实际节省时间。", "This departure snapshot stays unchanged. Estimates for different routes do not establish actual time savings.")).font(.caption).foregroundStyle(.secondary)
            }
            arrivalSection
            delaySection
            Section {
                Toggle(L("排除本次行程的统计", "Exclude from comparisons"), isOn: Binding(get: { trip.excluded }, set: { value in update { $0.excluded = value } }))
                if let reason = TripMath.exclusionReason(trip) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                Button(L("删除这次行程", "Delete trip"), role: .destructive) { deleteConfirmation = true }
            }
        }.navigationTitle(trip.displayTitle).navigationBarTitleDisplayMode(.inline)
            .alert(L("删除这次行程？", "Delete this trip?"), isPresented: $deleteConfirmation) {
                Button(L("取消", "Cancel"), role: .cancel) {}
                Button(L("删除", "Delete"), role: .destructive) { store.delete(trip); if !store.trips.contains(where: { $0.id == tripID }) { dismiss() } }
            } message: { Text(L("手机上的记录将删除；已导出的副本会保留。", "The record on this phone will be deleted. Exported copies remain.")) }
    }
    private var routeSection: some View {
        Section(L("自动识别路线", "Automatic route identification")) {
            Text(trip.displayTitle).font(.headline)
            if let names = trip.roadNames, !names.isEmpty { Text(names.joined(separator: " → ")) }
            else { Text(L("暂无可确认的道路名称，实际轨迹仍已保存。", "No reliable street names yet. Your recorded track is saved.")).foregroundStyle(.secondary) }
            if let coverage = trip.roadMatchCoverage {
                Text(String(format: L("道路匹配覆盖 %.0f%% · 近似识别", "Road match coverage %.0f%% · approximate"), coverage * 100)).font(.caption).foregroundStyle(.secondary)
            }
            if trip.analysisStatus == "queued" { Label(L("等待联网分析道路", "Waiting for road analysis"), systemImage: "clock").font(.caption) }
            if trip.analysisStatus != "complete" {
                Button(analyzer.running ? L("识别中…", "Analyzing…") : L("重试识别道路", "Retry street identification")) { Task { await analyzer.retry(tripID) } }.disabled(analyzer.running || !analyzer.enabled)
            }
            Text(L("相近起终点和相似实际轨迹自动归入同一路线。道路名称来自 OpenStreetMap，平行道路与立交处可能无法区分。", "Trips with nearby endpoints and similar tracks are grouped automatically. Street names come from OpenStreetMap; parallel roads and interchanges can be ambiguous.")).font(.caption).foregroundStyle(.secondary)
            Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!).font(.caption)
        }
    }
    private var arrivalSection: some View {
        Section(L("到达与行程补充", "Arrival and trip notes")) {
            Text(L("出发：", "Started: ") + trip.startedAt.formatted(date: .abbreviated, time: .standard)).font(.subheadline)
            Text(L("到达：", "Arrived: ") + (trip.endedAt ?? trip.startedAt).formatted(date: .abbreviated, time: .standard)).font(.subheadline)
            if !trip.reviewed {
                Text(L("请核对自动到达或恢复行程的结束时间。", "Please check the arrival time for this detected or recovered trip.")).font(.caption).foregroundStyle(.orange)
                Button(L("到达时间正确", "Confirm arrival time")) { update { $0.reviewed = true } }.buttonStyle(.bordered)
            }
            DisclosureGroup(L("修改到达时间", "Edit arrival time"), isExpanded: $editingArrival) {
                DatePicker(L("到达时间", "Arrival"), selection: $arrival, in: trip.startedAt...max(Date(), trip.startedAt), displayedComponents: [.date, .hourAndMinute])
                Button(L("保存到达时间", "Save arrival time")) {
                    update { t in
                        t.endedAt = arrival; t.endMethod = "user_corrected"; t.reviewed = true
                        t.autoRouteKey = nil; t.autoRouteNumber = nil
                        t.roadNames = nil; t.roadMatches = nil; t.roadMatchCoverage = nil; t.analysisStatus = "queued"
                    }
                    editingArrival = false; Task { await analyzer.runPending() }
                }
            }
            Picker(L("途中有道路施工吗？", "Any road construction?"), selection: Binding(get: { trip.constructionReported.map { $0 ? 1 : 0 } ?? -1 }, set: { value in update { $0.constructionReported = value == -1 ? nil : value == 1 } })) {
                Text(L("未填写", "Not answered")).tag(-1); Text(L("没有", "No")).tag(0); Text(L("有", "Yes")).tag(1)
            }
            TextField(L("备注（可选）", "Notes (optional)"), text: Binding(get: { trip.notes }, set: { value in update { $0.notes = value } }), axis: .vertical)
            if trip.interrupted { Text(L("本次记录曾中断，不参与路线排名。", "Recording was interrupted. This trip is excluded from comparisons.")).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var delaySection: some View {
        Section(L("停车与缓行 · 自动推测", "Stops and slow travel · inferred")) {
            Text(L("路口静止超过 3 秒推测为路口等待；已知道口附近等待至少 15 秒推测为铁路等待。没有实时信号灯或列车信息，可能包含 STOP、接人或其他停车。", "Stops over 3 seconds near mapped junctions suggest intersection waits; stops of at least 15 seconds near mapped level crossings suggest rail waits. No live signals or train data are available; STOP signs, pickups, and other stops can look similar.")).font(.caption).foregroundStyle(.secondary)
            if metrics.events.isEmpty { Text(L("未检测到符合条件的片段。", "No qualifying stops or slow sections detected.")) }
            ForEach(metrics.events) { event in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(event.kind == .stopped ? L("静止", "Stopped") : L("缓行", "Slow travel")).font(.headline); Spacer(); Text(minutesText(event.duration)) }
                    Text(event.start.formatted(date: .omitted, time: .standard) + " – " + event.end.formatted(date: .omitted, time: .standard)).font(.caption)
                    if let reason = trip.confirmedReasons[event.id] { Text(L("你的标注：", "Your correction: ") + reason.title) }
                    else { Text((event.suggestedReason == .unknown ? "" : L("推测：", "Inferred: ")) + event.suggestedReason.title).foregroundStyle(.secondary) }
                    Text(evidenceText(event.evidence)).font(.caption).foregroundStyle(.secondary)
                    Menu(L("修改原因（可选）", "Correct cause (optional)")) {
                        ForEach(DelayReason.allCases) { reason in Button(reason.title) { update { $0.confirmedReasons[event.id] = reason } } }
                        Button(L("恢复自动推测", "Use automatic inference")) { update { $0.confirmedReasons.removeValue(forKey: event.id) } }
                    }
                }.padding(.vertical, 4)
            }
        }
    }
    private func evidenceText(_ value: String) -> String {
        switch value {
        case "mapped_crossing": return L("附近有已登记铁路道口。", "Near a mapped level crossing.")
        case "mapped_signal": return L("附近有已登记信号灯。", "Near a mapped traffic signal.")
        case "intersection_only": return L("仅有路口位置依据，无法确认有红绿灯。", "Junction location only; a traffic signal is not confirmed.")
        case "relative_to_limit": return L("持续低于已知道路限速的 35%，仍可能是转弯或停车场行驶。", "Sustained travel below 35% of a mapped speed limit; turns or parking can also cause this.")
        case "low_speed": return L("仅依据持续低速，未获得可靠限速。", "Based on sustained low speed; no reliable speed limit available.")
        default: return L("没有足够信息确定原因。", "Insufficient context to determine the cause.")
        }
    }
    private func update(_ change: (inout Trip) -> Void) {
        var current = trip; change(&current); if store.save(current) { fallback = current }
    }
    @ViewBuilder private func estimateRow(_ estimate: Estimate, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(minutesText(estimate.seconds) + L(" · 预计到达 ", " · ETA ") + estimate.capturedAt.addingTimeInterval(estimate.seconds).formatted(date: .omitted, time: .standard))
            Text(estimate.routeDescription).font(.caption).foregroundStyle(.secondary)
            if let end = trip.endedAt {
                Text(String(format: L("实际到达相对 ETA：%+.1f 分钟", "Arrival vs ETA: %+.1f min"), end.timeIntervalSince(estimate.capturedAt.addingTimeInterval(estimate.seconds)) / 60)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
