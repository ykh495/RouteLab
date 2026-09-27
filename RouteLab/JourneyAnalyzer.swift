import Foundation
import Combine
import UIKit

@MainActor
final class JourneyAnalyzer: ObservableObject {
    @Published private(set) var running = false
    private let store: TripStore
    init(store: TripStore) { self.store = store }
    var enabled: Bool { UserDefaults.standard.object(forKey: "roadAnalysisEnabled") == nil || UserDefaults.standard.bool(forKey: "roadAnalysisEnabled") }
    func retry(_ id: UUID) async {
        guard var t = store.trips.first(where: { $0.id == id }) else { return }
        t.analysisStatus = "queued"; store.save(t)
        await runPending()
    }
    func runPending() async {
        guard !running else { return }
        running = true; defer { running = false }
        while let trip = store.trips.first(where: { $0.analysisStatus == "queued" }) {
            guard UIApplication.shared.applicationState == .active else { break }
            if !enabled {
                var disabled = trip; disabled.analysisStatus = "disabled"; if !store.save(disabled) { break }; continue
            }
            do {
                let ps = trip.usablePoints
                guard ps.count >= 3 else {
                    var unavailable = trip; unavailable.analysisStatus = "insufficient"; if !store.save(unavailable) { break }; continue
                }
                let snapshot = try await RoadContext.shared.fetch(around: ps.map(\.coordinate))
                let matches = await Task.detached(priority: .utility) { RouteGeometry.match(ps, roads: snapshot.roads) }.value
                guard var current = store.trips.first(where: { $0.id == trip.id }) else { continue }
                guard current.endedAt == trip.endedAt else { continue }
                current.roadMatches = matches; current.roadNames = RouteGeometry.names(matches)
                current.roadFeatures = snapshot.features
                current.roadContextStatus = "osm_snapshot"
                current.roadMatchCoverage = Double(matches.count) / Double(max(1, ps.count))
                current.analysisStatus = (current.roadMatchCoverage ?? 0) >= 0.5 ? "complete" : "partial"
                if !store.save(current) { break }
            } catch {
                guard var current = store.trips.first(where: { $0.id == trip.id }) else { continue }
                current.analysisStatus = "unavailable"; if !store.save(current) { break }
            }
        }
    }
}
