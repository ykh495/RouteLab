import SwiftUI
import MapKit
import Combine

@MainActor
final class AddressSuggestions: NSObject, ObservableObject {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var error: String?
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init(); completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }
    func update(_ query: String, near: Coordinate?) {
        if let near { completer.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 25_000, longitudinalMeters: 25_000) }
        error = nil; completer.queryFragment = query
        if query.trimmingCharacters(in: .whitespaces).isEmpty { results = [] }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = completer.results }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        self.error = L("搜索暂不可用，可以在地图上选点。", "Search is unavailable. You can choose a point on the map.")
    }
}
#if compiler(>=6.2)
extension AddressSuggestions: @MainActor MKLocalSearchCompleterDelegate {}
#else
extension AddressSuggestions: MKLocalSearchCompleterDelegate {}
#endif

@MainActor
struct DestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorder: LocationRecorder
    @EnvironmentObject var store: TripStore
    @StateObject private var suggestions = AddressSuggestions()
    @State private var query = ""
    @State private var mode = 0
    @State private var busy = false
    @State private var message: String?
    @State private var searchResults: [Place] = []
    var onSelect: (Place) -> Void
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("选择方式", "Choose using"), selection: $mode) {
                    Text(L("地址搜索", "Search")).tag(0)
                    Text(L("地图选点", "Drop pin")).tag(1)
                }.pickerStyle(.segmented).padding()
                if mode == 0 { searchBody }
                else { PinPicker(initial: recorder.latest?.coordinate) { select($0) } }
            }
            .navigationTitle(L("这次去哪里？", "Where to?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } } }
        }
    }
    private var searchBody: some View {
        List {
            Section {
                TextField(L("输入地址、门牌号或地点名称", "Address, street number, or place"), text: $query)
                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { fullSearch() }
                    .onChange(of: query) { _, value in
                        searchResults = []; suggestions.update(value, near: recorder.latest?.coordinate)
                    }
                if busy { ProgressView(L("查找中…", "Searching…")) }
                if let message = message ?? suggestions.error { Text(message).font(.footnote).foregroundStyle(.secondary) }
                ForEach(Array(suggestions.results.enumerated()), id: \.offset) { _, result in
                    Button {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                if let place = try await NavigationService.resolve(result) { select(place) }
                                else { message = L("未找到此地点，请补充地址。", "Place not found. Try a more complete address.") }
                            } catch { message = L("无法加载地点，请重试。", "Unable to load this place. Please try again.") }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).foregroundStyle(.primary)
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(busy)
                }
                ForEach(searchResults) { place in
                    Button { select(place) } label: {
                        VStack(alignment: .leading) { Text(place.name); Text(place.address ?? "").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !query.isEmpty { Button(L("搜索完整地址", "Search this address")) { fullSearch() }.disabled(busy) }
            } footer: {
                Text(L("输入一部分地址即可联想；只有门牌号时，补充街道名通常更准确。", "Suggestions appear as you type. Adding a street name improves results for a street number."))
            }
            if query.isEmpty && !store.favorites.isEmpty {
                Section(L("常用目的地", "Favorites")) {
                    ForEach(store.favorites) { favorite in
                        Button { select(favorite.place) } label: { Label(favorite.displayTitle, systemImage: favorite.icon) }
                    }
                }
            }
        }.listStyle(.insetGrouped)
    }
    private func select(_ place: Place) { onSelect(place); dismiss() }
    private func fullSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true; let text = query
        Task {
            defer { busy = false }
            do {
                let results = try await NavigationService.search(text, near: recorder.latest?.coordinate)
                guard query == text else { return }
                searchResults = results
                if results.isEmpty { message = L("没有找到结果，请补充城市或街道。", "No results. Add a city or street name.") }
            } catch { message = L("搜索失败，请重试或地图选点。", "Search failed. Retry or choose a point on the map.") }
        }
    }
}

@MainActor
struct PinPicker: View {
    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var pin: CLLocationCoordinate2D?
    @State private var name = ""
    var onSelect: (Place) -> Void
    init(initial: Coordinate?, onSelect: @escaping (Place) -> Void) {
        // Until a location fix arrives, show a broad map instead of assuming the user's home.
        let center = initial?.cl ?? CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35)
        _center = State(initialValue: center)
        _position = State(initialValue: .region(MKCoordinateRegion(center: center, latitudinalMeters: initial == nil ? 5_000_000 : 3_000, longitudinalMeters: initial == nil ? 5_000_000 : 3_000)))
        self.onSelect = onSelect
    }
    var body: some View {
        VStack(spacing: 12) {
            Text(L("轻点地图放置图钉，或移动地图后选择中心。", "Tap to drop a pin, or move the map and choose its center."))
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()
                    if let pin { Marker(L("目的地", "Destination"), coordinate: pin).tint(.orange) }
                }
                .mapControls { MapCompass(); MapUserLocationButton(); MapScaleView() }
                .onMapCameraChange(frequency: .onEnd) { center = $0.region.center }
                .onTapGesture { point in pin = proxy.convert(point, from: .local) }
            }
            Button(L("将图钉放在地图中心", "Drop pin at map center")) { pin = center }
            TextField(L("地点名称（可选）", "Place name (optional)"), text: $name).textFieldStyle(.roundedBorder).padding(.horizontal)
            if let pin { Text(String(format: "%.6f, %.6f", pin.latitude, pin.longitude)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button {
                guard let pin else { return }
                let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onSelect(Place(name: label.isEmpty ? L("地图选点", "Dropped pin") : label, coordinate: Coordinate(pin)))
            } label: { Text(L("使用这个位置", "Use this location")).frame(maxWidth: .infinity).padding(7) }
                .buttonStyle(.borderedProminent).disabled(pin == nil).padding([.horizontal, .bottom])
        }
    }
}

@MainActor
struct FavoriteEditor: View {
    @EnvironmentObject var store: TripStore
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var category: String
    let place: Place
    let existing: Favorite?
    init(place: Place, existing: Favorite? = nil) {
        self.place = place; self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _category = State(initialValue: existing?.category ?? "custom")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(place.name); Text(place.address ?? L("已保存坐标", "Coordinates saved")).font(.caption).foregroundStyle(.secondary) }
                Section {
                    Picker(L("类型", "Category"), selection: $category) {
                        Text(L("住址", "Home")).tag("home")
                        Text(L("图书馆", "Library")).tag("library")
                        Text(L("学校", "School")).tag("school")
                        Text(L("停车库", "Parking")).tag("parking")
                        Text(L("自定义", "Custom")).tag("custom")
                    }
                    TextField(L("自定义名称（可选）", "Custom name (optional)"), text: $title)
                }
                if let existing {
                    Button(L("删除常用目的地", "Delete favorite"), role: .destructive) { store.deleteFavorite(existing); dismiss() }
                }
            }.navigationTitle(L("常用目的地", "Favorite"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("保存", "Save")) {
                            var favorite = Favorite(title: title.trimmingCharacters(in: .whitespacesAndNewlines), category: category, place: place)
                            if let existing { favorite.id = existing.id }
                            store.saveFavorite(favorite); dismiss()
                        }
                    }
                }
        }
    }
}
