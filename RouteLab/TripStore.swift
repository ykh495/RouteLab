import Foundation
import Combine

@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var trips: [Trip] = []
    @Published var errorMessage: String?
    @Published private(set) var favorites: [Favorite] = []
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var damagedCheckpointBlocked = false
    private var unreadableFavorites = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("RouteLab", isDirectory: true)
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedFromBackup = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excludedFromBackup.setResourceValues(values)
            load()
            loadFavorites()
            clearExports()
        } catch { errorMessage = L("无法创建行程目录：", "Could not create trip storage: ") + error.localizedDescription }
    }

    private func write(_ trip: Trip, to url: URL) throws {
        try encoder.encode(trip).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func load() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var loaded: [Trip] = []
            for url in files where url.lastPathComponent.hasPrefix("trip-") && url.pathExtension == "json" {
                do { loaded.append(try decoder.decode(Trip.self, from: Data(contentsOf: url))) }
                catch { errorMessage = L("有记录无法读取，原文件已保留：", "Unreadable record preserved: ") + url.lastPathComponent }
            }
            trips = loaded.sorted { $0.startedAt > $1.startedAt }
        } catch { errorMessage = error.localizedDescription }
    }

    func checkpoint(_ trip: Trip) -> Bool {
        guard !damagedCheckpointBlocked else { errorMessage = L("无法保留损坏的恢复文件，暂不开始新记录。", "Cannot preserve a damaged recovery file; new recording is blocked."); return false }
        do { try write(trip, to: directory.appendingPathComponent("active.json")); return true }
        catch { errorMessage = L("记录暂未写入磁盘：", "Record has not been written to disk: ") + error.localizedDescription; return false }
    }

    func recoveredTrip() -> Trip? {
        let url = directory.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let trip = try decoder.decode(Trip.self, from: Data(contentsOf: url))
            if trips.contains(where: { $0.id == trip.id }) { clearCheckpoint(); return nil }
            return trip
        } catch {
            let preserved = directory.appendingPathComponent("unreadable-active-\(UUID().uuidString).json")
            do { try FileManager.default.moveItem(at: url, to: preserved) }
            catch { damagedCheckpointBlocked = true }
            errorMessage = L("上次行程无法读取，损坏文件已保留。", "Unreadable recovery file preserved.")
            return nil
        }
    }

    @discardableResult
    func save(_ value: Trip) -> Bool {
        var trip = value
        assignRoute(&trip)
        do {
            try write(trip, to: directory.appendingPathComponent("trip-\(trip.id.uuidString).json"))
            trips.removeAll { $0.id == trip.id }; trips.append(trip)
            trips.sort { $0.startedAt > $1.startedAt }
            return true
        } catch { errorMessage = L("保存失败：", "Could not save: ") + error.localizedDescription; return false }
    }

    func clearCheckpoint() {
        let url = directory.appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { errorMessage = L("未能清理行程恢复文件。", "Could not clear the recovery checkpoint.") }
    }

    func delete(_ trip: Trip) {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("trip-\(trip.id.uuidString).json"))
            trips.removeAll { $0.id == trip.id }
        } catch { errorMessage = L("删除失败：", "Could not delete: ") + error.localizedDescription }
    }

    func export() throws -> URL {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("RouteLab-Export", isDirectory: true)
        if FileManager.default.fileExists(atPath: exportDir.path) { try FileManager.default.removeItem(at: exportDir) }
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let url = exportDir.appendingPathComponent("RouteLab-trips.json")
        try encoder.encode(ExportBundle(trips: trips, favorites: favorites)).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }


    private func loadFavorites() {
        let url = directory.appendingPathComponent("favorites.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { favorites = try decoder.decode([Favorite].self, from: Data(contentsOf: url)) }
        catch { unreadableFavorites = true; errorMessage = L("常用目的地暂时无法读取，原文件已保留。", "Unable to read favorites; the original file is preserved.") }
    }
    func saveFavorite(_ favorite: Favorite) {
        var next = favorites.filter { $0.id != favorite.id }; next.append(favorite)
        writeFavorites(next)
    }
    func deleteFavorite(_ favorite: Favorite) { writeFavorites(favorites.filter { $0.id != favorite.id }) }
    private func writeFavorites(_ next: [Favorite]) {
        guard !unreadableFavorites else { errorMessage = L("常用目的地文件无法读取，暂不覆盖原数据。", "Favorites could not be read; the original file will not be overwritten."); return }
        do {
            try encoder.encode(next).write(to: directory.appendingPathComponent("favorites.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            favorites = next
        } catch { errorMessage = L("常用目的地保存失败：", "Could not save favorites: ") + error.localizedDescription }
    }
    func assignRoute(_ trip: inout Trip) {
        guard !trip.interrupted, trip.endedAt != nil, trip.autoRouteKey == nil, trip.usablePoints.count >= 3 else { return }
        let m = TripMath.metrics(trip)
        guard trip.elapsed >= 60, m.observedSeconds / max(1, trip.elapsed) >= 0.8 else { return }
        let comparable = trips.filter { !$0.interrupted && $0.id != trip.id && $0.autoRouteKey != nil && RouteGeometry.sameJourney($0.usablePoints, trip.usablePoints) }
        var seen: Set<String> = []
        let representatives = comparable.sorted { $0.startedAt < $1.startedAt }.filter { seen.insert($0.autoRouteKey!).inserted }
        if let match = representatives.first(where: { RouteGeometry.sameRoute($0.usablePoints, trip.usablePoints) }) {
            trip.autoRouteKey = match.autoRouteKey; trip.autoRouteNumber = match.autoRouteNumber
        } else {
            trip.autoRouteKey = trip.id.uuidString
            trip.autoRouteNumber = (comparable.compactMap(\.autoRouteNumber).max() ?? 0) + 1
        }
    }
    func migrateRouteGroups() {
        for trip in trips.sorted(by: { $0.startedAt < $1.startedAt }) where trip.autoRouteKey == nil { _ = save(trip) }
    }

    func clearExports() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RouteLab-Export", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }
}
