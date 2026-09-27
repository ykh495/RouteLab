import Foundation

enum RouteGeometry {
    static func speedLimit(_ text: String?) -> Double? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let mph = raw.hasSuffix("mph")
        let number = raw.replacingOccurrences(of: "mph", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(number), v > 0, v <= 200 else { return nil }
        return mph ? v * 0.44704 : v / 3.6
    }
    static func pointToSegment(_ p: Coordinate, _ a: Coordinate, _ b: Coordinate) -> Double {
        let scale = cos(p.latitude * .pi / 180)
        func xy(_ c: Coordinate) -> (Double, Double) { ((c.longitude - p.longitude) * 111_320 * scale, (c.latitude - p.latitude) * 111_320) }
        let av = xy(a), bv = xy(b), dx = bv.0 - av.0, dy = bv.1 - av.1
        let length2 = dx * dx + dy * dy
        let t = length2 == 0 ? 0 : min(1, max(0, -(av.0 * dx + av.1 * dy) / length2))
        return hypot(av.0 + t * dx, av.1 + t * dy)
    }
    static func bearing(_ a: Coordinate, _ b: Coordinate) -> Double {
        atan2((b.longitude - a.longitude) * cos(a.latitude * .pi / 180), b.latitude - a.latitude)
    }
    static func angleDifference(_ a: Double, _ b: Double) -> Double { abs(atan2(sin(a-b), cos(a-b))) }
    private struct Cell: Hashable { var lat: Int; var lon: Int }
    private struct Segment { var road: Int; var a: Coordinate; var b: Coordinate }
    static func match(_ points: [TrackPoint], roads: [Road]) -> [RoadMatch] {
        // A small spatial grid avoids comparing every GPS point with every street segment.
        let step = 0.002
        func cell(_ c: Coordinate) -> Cell { Cell(lat: Int(floor(c.latitude / step)), lon: Int(floor(c.longitude / step))) }
        var segments: [Segment] = [], grid: [Cell: [Int]] = [:], longSegments: [Int] = []
        for (r, road) in roads.enumerated() where road.coordinates.count > 1 {
            for j in 1..<road.coordinates.count {
                let a = road.coordinates[j-1], b = road.coordinates[j], ca = cell(a), cb = cell(b)
                let index = segments.count; segments.append(Segment(road: r, a: a, b: b))
                if (abs(ca.lat-cb.lat)+1) * (abs(ca.lon-cb.lon)+1) > 200 { longSegments.append(index); continue }
                for lat in min(ca.lat,cb.lat)...max(ca.lat,cb.lat) {
                    for lon in min(ca.lon,cb.lon)...max(ca.lon,cb.lon) { grid[Cell(lat: lat, lon: lon), default: []].append(index) }
                }
            }
        }
        var result: [RoadMatch] = []
        for (i, p) in points.enumerated() {
            var heading: Double?
            if i > 0, p.speed > 1.5, p.timestamp.timeIntervalSince(points[i-1].timestamp) <= TripMath.maxGap,
               TripMath.distance(points[i-1].coordinate, p.coordinate) > 5 { heading = bearing(points[i-1].coordinate, p.coordinate) }
            let deltaLon = 0.0004 / max(0.01, cos(p.coordinate.latitude * .pi / 180))
            let lo = cell(Coordinate(latitude: p.coordinate.latitude - 0.0004, longitude: p.coordinate.longitude - deltaLon))
            let hi = cell(Coordinate(latitude: p.coordinate.latitude + 0.0004, longitude: p.coordinate.longitude + deltaLon))
            var candidates = Set(longSegments)
            for lat in lo.lat...hi.lat {
                for lon in lo.lon...hi.lon { candidates.formUnion(grid[Cell(lat: lat, lon: lon)] ?? []) }
            }
            var byRoad: [Int: (score: Double, distance: Double)] = [:]
            for index in candidates {
                let s = segments[index], road = roads[s.road]
                let d = pointToSegment(p.coordinate, s.a, s.b)
                guard d <= 35 else { continue }
                var angle = 0.0
                if let heading {
                    let course = bearing(s.a, s.b)
                    if road.oneWay == 1 { angle = angleDifference(heading, course) }
                    else if road.oneWay == -1 { angle = angleDifference(heading, course + .pi) }
                    else { angle = min(angleDifference(heading, course), angleDifference(heading, course + .pi)) }
                    if angle > .pi / 3 { continue }
                }
                let score = d + angle * 15
                if score < (byRoad[s.road]?.score ?? .infinity) { byRoad[s.road] = (score, d) }
            }
            let ranked = byRoad.sorted { $0.value.score < $1.value.score }
            guard let best = ranked.first else { continue }
            let road = roads[best.key]
            // Ambiguous parallel roads remain unmatched, including roads sharing a name.
            if ranked.count > 1, ranked[1].value.score - best.value.score < 5 { continue }
            result.append(RoadMatch(pointID: p.id, roadID: road.id, roadName: road.name, distanceMeters: best.value.distance, speedLimitMPS: road.speedLimitMPS))
        }
        return result
    }
    static func names(_ matches: [RoadMatch]) -> [String] {
        var names: [String] = [], current = "", count = 0
        func flush() { if count >= 3 && !current.isEmpty && names.last != current { names.append(current) } }
        for match in matches {
            if match.roadName != current { flush(); current = match.roadName; count = 1 } else { count += 1 }
        }
        flush(); return names
    }
    static func sampled(_ points: [TrackPoint], spacing: Double = 65) -> [Coordinate] {
        guard let first = points.first else { return [] }
        var output = [first.coordinate], cumulative = 0.0
        for i in 1..<points.count {
            cumulative += TripMath.distance(points[i-1].coordinate, points[i].coordinate)
            if cumulative >= spacing { output.append(points[i].coordinate); cumulative = 0 }
        }
        if let last = points.last, output.last != last.coordinate { output.append(last.coordinate) }
        if output.count > 160 {
            return (0..<160).map { output[Int(Double($0) * Double(output.count - 1) / 159)] }
        }
        return output
    }
    static func sameJourney(_ a: [TrackPoint], _ b: [TrackPoint]) -> Bool {
        guard let af = a.first, let al = a.last, let bf = b.first, let bl = b.last else { return false }
        return TripMath.distance(af.coordinate, bf.coordinate) <= 250 && TripMath.distance(al.coordinate, bl.coordinate) <= 250
    }
    static func sameRoute(_ a: [TrackPoint], _ b: [TrackPoint]) -> Bool {
        guard sameJourney(a,b) else { return false }
        let xs = sampled(a), ys = sampled(b)
        guard xs.count >= 3 && ys.count >= 3 else { return false }
        func length(_ ps: [Coordinate]) -> Double { zip(ps, ps.dropFirst()).reduce(0) { $0 + TripMath.distance($1.0,$1.1) } }
        let la = length(xs), lb = length(ys)
        guard min(la,lb) > 100, abs(la-lb) / max(la,lb) <= 0.18 else { return false }
        // Discrete Frechet distance preserves traversal order and distinguishes reversed/detoured traces.
        var previous = [Double](repeating: .infinity, count: ys.count)
        for i in xs.indices {
            var row = [Double](repeating: .infinity, count: ys.count)
            for j in ys.indices {
                let d = TripMath.distance(xs[i], ys[j])
                if i == 0 && j == 0 { row[j] = d }
                else {
                    let left = j > 0 ? row[j-1] : .infinity
                    let diag = (i > 0 && j > 0) ? previous[j-1] : .infinity
                    row[j] = max(d, min(previous[j], min(left, diag)))
                }
            }
            previous = row
        }
        return (previous.last ?? .infinity) <= 90
    }
}
