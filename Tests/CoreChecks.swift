// Run from the project root with bash verify-on-mac.sh.
import Foundation

@main
struct CoreChecks {
    static func makeTrip(minutes: Int = 10, reverse: Bool = false) -> Trip {
        let start = ISO8601DateFormatter().date(from: "2026-09-21T13:05:00Z")!
        var t = Trip(startedAt: start, endedAt: start.addingTimeInterval(Double(minutes * 60)), timezoneID: "America/Chicago", navigator: .manual, routeLabel: "Koenig")
        t.reviewed = true
        for i in 0...(minutes * 6) {
            let f = Double(i) / Double(minutes * 6)
            t.points.append(TrackPoint(timestamp: start.addingTimeInterval(Double(i * 10)),
                                       coordinate: Coordinate(latitude: 30.35 - 0.025 * (reverse ? 1 - f : f), longitude: -97.74),
                                       speed: 6, horizontalAccuracy: 5))
        }
        return t
    }
    static func main() {
        let normal = makeTrip()
        assert(TripMath.exclusionReason(normal) == nil)
        let summary = TripMath.summaries([normal, makeTrip(minutes: 12)])
        assert(summary.count == 1 && summary[0].count == 2)
        assert(summary[0].timeBucket == "08:00")
        assert(abs(summary[0].meanMinutes - 11) < 0.0001)
        assert(abs(summary[0].standardDeviationMinutes! - sqrt(2)) < 0.0001)
        assert(summary[0].p90Minutes == nil)
        assert(TripMath.summaries([normal, makeTrip(reverse: true)]).count == 2)
        var gap = normal
        gap.points = Array(normal.points.prefix(3)) + Array(normal.points.suffix(3))
        assert(TripMath.metrics(gap).gapSeconds > 500)
        assert(TripMath.exclusionReason(gap) != nil)
        var stopped = normal
        for i in 10...16 { stopped.points[i].speed = 0; stopped.points[i].coordinate = normal.points[10].coordinate }
        stopped.roadFeatures = [RoadFeature(id: "signal", kind: .signal, coordinate: normal.points[10].coordinate)]
        let event = TripMath.metrics(stopped).events[0]
        assert(event.suggestedReason == .signal)
        stopped.confirmedReasons[event.id] = .congestion
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reloaded = try! decoder.decode(Trip.self, from: encoder.encode(stopped))
        assert(reloaded.confirmedReasons[TripMath.metrics(reloaded).events[0].id] == .congestion)
        var unreviewed = normal; unreviewed.reviewed = false
        assert(TripMath.summaries([unreviewed]).isEmpty)
        // Decode the original export with none of the v0.2 fields present.
        struct Fixture: Decodable { var trips: [Trip] }
        let fixture = try! decoder.decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: "Examples/synthetic-trips.json")))
        assert(!fixture.trips.isEmpty && fixture.trips.allSatisfy { $0.autoRouteKey == nil })
        let reloadedTrips = try! decoder.decode([Trip].self, from: encoder.encode(fixture.trips))
        assert(reloadedTrips.count == fixture.trips.count)
        var modern = normal
        modern.stopRuleVersion = 2
        modern.routeLabel = ""; modern.autoRouteKey = "route-a"; modern.autoRouteNumber = 1
        assert(TripMath.exclusionReason(modern) == nil)
        var differentKey = modern; differentKey.id = UUID(); differentKey.autoRouteKey = "route-b"
        assert(TripMath.summaries([modern, differentKey]).count == 2)
        modern.points = (0...4).map { TrackPoint(timestamp: normal.startedAt.addingTimeInterval(Double($0)), coordinate: normal.points[0].coordinate, speed: 0, horizontalAccuracy: 5) }
        modern.endedAt = normal.startedAt.addingTimeInterval(4)
        modern.roadFeatures = [RoadFeature(id: "junction", kind: .junction, coordinate: normal.points[0].coordinate)]
        assert(TripMath.metrics(modern).events.first?.evidence == "intersection_only")
        modern.endedAt = normal.startedAt.addingTimeInterval(3)
        assert(TripMath.metrics(modern).events.isEmpty)
        modern.endedAt = normal.startedAt.addingTimeInterval(4); modern.roadFeatures = []
        assert(TripMath.metrics(modern).events.first?.suggestedReason == .unknown)
        assert(RouteGeometry.sameRoute(normal.points, makeTrip(minutes: 12).points))
        assert(!RouteGeometry.sameRoute(normal.points, makeTrip(reverse: true).points))
        var jitter = normal.points
        for i in jitter.indices { jitter[i].coordinate.longitude += 0.00004 }
        assert(RouteGeometry.sameRoute(normal.points, jitter))
        var detour = normal.points
        for i in 15...45 { detour[i].coordinate.longitude += 0.004 }
        assert(!RouteGeometry.sameRoute(normal.points, detour))
        assert(abs(RouteGeometry.speedLimit("35 mph")! - 15.6464) < 0.00001)
        assert(RouteGeometry.speedLimit("signals") == nil)
        let road = Road(id: "r1", name: "Example St", coordinates: [normal.points.first!.coordinate, normal.points.last!.coordinate], nodeIDs: [1,2], speedLimitMPS: 15, oneWay: 0)
        let matches = RouteGeometry.match(normal.points, roads: [road])
        assert(matches.count == normal.points.count && RouteGeometry.names(matches) == ["Example St"])
        var wrongWay = road; wrongWay.oneWay = -1
        assert(RouteGeometry.match(normal.points, roads: [wrongWay]).count <= 1)
        var parallel = road; parallel.id = "parallel"; parallel.name = "Other St"
        parallel.coordinates = parallel.coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude + 0.0001) }
        var between = normal.points
        for i in between.indices { between[i].coordinate.longitude += 0.00005 }
        assert(RouteGeometry.match(between, roads: [road, parallel]).isEmpty)
        print("RouteLab native core checks passed")
    }
}
