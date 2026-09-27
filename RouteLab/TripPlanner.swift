import Foundation
import Combine

@MainActor
final class TripPlanner: ObservableObject {
    @Published private(set) var destination: Place?
    @Published private(set) var options: [RouteOption] = []
    @Published var selectedID: UUID?
    @Published private(set) var busy = false
    @Published var message: String?
    private var origin: Coordinate?
    private var generation = UUID()
    private var attemptedAt = Date.distantPast
    private var work: Task<Void, Never>?
    var selected: RouteOption? { options.first { $0.id == selectedID } ?? options.first }
    func choose(_ place: Place, fix: TrackPoint?) {
        destination = place; options = []; selectedID = nil; origin = nil; message = nil
        generation = UUID(); work?.cancel(); busy = false; attemptedAt = .distantPast
        observe(fix)
    }
    func needsRefresh(_ fix: TrackPoint) -> Bool {
        guard let origin, let selected else { return true }
        return TripMath.distance(origin, fix.coordinate) > 150 || Date().timeIntervalSince(selected.capturedAt) > 90
    }
    func observe(_ fix: TrackPoint?) {
        guard let fix, destination != nil, !busy, Date().timeIntervalSince(fix.timestamp) < 45,
              Date().timeIntervalSince(attemptedAt) > 30, needsRefresh(fix) else { return }
        work = Task { await refresh(fix) }
    }
    func refresh(_ fix: TrackPoint) async {
        guard let destination else { return }
        let token = UUID(); generation = token; busy = true; attemptedAt = Date()
        defer { if generation == token { busy = false } }
        do {
            let routes = try await NavigationService.routes(from: fix.coordinate, to: destination)
            guard generation == token, !Task.isCancelled else { return }
            options = routes; selectedID = routes.first?.id; origin = fix.coordinate
            message = routes.isEmpty ? L("暂无参考路线，仍可开始记录。", "No reference routes available. You can still record your trip.") : nil
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            options = []; selectedID = nil
            message = L("暂时无法估时，仍可记录行程。", "An estimate is unavailable. You can still record your trip.")
        }
    }
}
