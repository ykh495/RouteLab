import Foundation

enum TripMath {
    static let maxGap = 30.0
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let p = Double.pi / 180
        let dlat = (b.latitude - a.latitude) * p
        let dlon = (b.longitude - a.longitude) * p
        let h = pow(sin(dlat / 2), 2) + cos(a.latitude * p) * cos(b.latitude * p) * pow(sin(dlon / 2), 2)
        return 6_371_000 * 2 * asin(min(1, sqrt(max(0, h))))
    }

    static func valid(_ point: TrackPoint, after last: TrackPoint?, now: Date) -> Bool {
        guard point.coordinate.latitude.isFinite, point.coordinate.longitude.isFinite,
              abs(point.coordinate.latitude) <= 90, abs(point.coordinate.longitude) <= 180,
              point.horizontalAccuracy >= 0, point.horizontalAccuracy <= 35,
              point.timestamp <= now.addingTimeInterval(5),
              point.speed.isFinite, point.speed <= 60 else { return false }
        if let last {
            let dt = point.timestamp.timeIntervalSince(last.timestamp)
            guard dt > 0 else { return false }
            // Reject physically implausible short-interval jumps. After a gap, do not bridge distance.
            if dt <= maxGap && distance(last.coordinate, point.coordinate) / dt > 60 { return false }
        }
        return true
    }

    static func metrics(_ trip: Trip) -> TripMetrics {
        let points = trip.usablePoints
        var result = TripMetrics()
        guard points.count >= 2 else { result.gapSeconds = trip.elapsed; return result }
        let limits = Dictionary((trip.roadMatches ?? []).compactMap { match in match.speedLimitMPS.map { (match.pointID, $0) } }, uniquingKeysWith: { a, _ in a })
        var run: DelayEvent?
        func flush() {
            if var e = run {
                let modern = (trip.stopRuleVersion ?? 1) >= 2
                if e.duration >= (e.kind == .stopped ? (modern ? 4 : 15) : 30) {
                    if modern {
                        let nearby = trip.roadFeatures.filter { distance($0.coordinate, e.coordinate) <= 40 }
                        if e.kind == .stopped {
                            if e.duration >= 15 && nearby.contains(where: { $0.kind == .rail }) { e.suggestedReason = .rail; e.evidence = "mapped_crossing" }
                            else if nearby.contains(where: { $0.kind == .signal }) { e.suggestedReason = .signal; e.evidence = "mapped_signal" }
                            else if nearby.contains(where: { $0.kind == .junction }) { e.suggestedReason = .signal; e.evidence = "intersection_only" }
                            else { e.suggestedReason = .unknown; e.evidence = "no_context" }
                        } else { e.suggestedReason = .congestion }
                    }
                    result.events.append(e)
                }
            }
            run = nil
        }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let dt = b.timestamp.timeIntervalSince(a.timestamp)
            guard dt > 0, dt <= maxGap else { flush(); continue }
            let meters = distance(a.coordinate, b.coordinate)
            guard meters / dt <= 60 else { flush(); continue }
            result.observedSeconds += dt
            // Use reported Doppler speed where available; stationary jitter should not add distance.
            let speed = b.speed >= 0 ? b.speed : meters / dt
            if speed >= 1.2 && meters >= 2 { result.distanceMeters += meters }
            // If GPS speed is unknown, do not invent a stop classification.
            let modern = (trip.stopRuleVersion ?? 1) >= 2
            let slowThreshold = modern ? min(8.33, (limits[b.id] ?? (3 / 0.35)) * 0.35) : 3
            let classified: MotionKind? = b.speed < 0 ? nil : (speed < 0.8 ? .stopped : (speed < slowThreshold ? .slow : nil))
            let kind: MotionKind? = modern && (a.speed < 0 || (classified == .stopped && a.speed >= 0.8) || (classified == .slow && (a.speed < 0.8 || a.speed >= slowThreshold))) ? nil : classified
            guard let kind else { flush(); continue }
            if run?.kind != kind {
                flush()
                let candidate = trip.roadFeatures.filter { distance($0.coordinate, b.coordinate) <= 45 }
                    .min { distance($0.coordinate, b.coordinate) < distance($1.coordinate, b.coordinate) }
                let reason: DelayReason = kind == .slow ? .unknown :
                    (candidate?.kind == .rail ? .rail : (candidate?.kind == .signal ? .signal : .unknown))
                run = DelayEvent(id: "\(kind.rawValue)-\(Int(a.timestamp.timeIntervalSince1970))",
                                 start: a.timestamp, end: b.timestamp, coordinate: b.coordinate,
                                 kind: kind, suggestedReason: reason, evidence: kind == .slow ? (limits[b.id] == nil ? "low_speed" : "relative_to_limit") : "unknown")
            } else { run?.end = b.timestamp }
        }
        flush()
        result.gapSeconds = max(0, trip.elapsed - result.observedSeconds)
        return result
    }

    static func exclusionReason(_ trip: Trip) -> String? {
        if trip.endedAt == nil { return L("行程未结束", "Trip is still active") }
        if trip.excluded { return L("用户排除", "Excluded by user") }
        if trip.interrupted { return L("记录中断", "Recording interrupted") }
        if !trip.reviewed { return L("尚未确认实际路线和到达时间", "Arrival needs confirmation") }
        if trip.autoRouteKey == nil && trip.routeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("等待路线识别", "Waiting for route identification") }
        if trip.elapsed < 60 { return L("行程不足 1 分钟", "Trip shorter than 1 minute") }
        if trip.usablePoints.count < 3 { return L("定位点不足", "Too few location samples") }
        let m = metrics(trip)
        if m.observedSeconds / max(1, trip.elapsed) < 0.8 { return L("有效定位覆盖不足 80%", "Location coverage below 80%") }
        return nil
    }

    static func quantile(_ values: [Double], _ p: Double) -> Double {
        let v = values.sorted()
        guard !v.isEmpty else { return 0 }
        let x = Double(v.count - 1) * p
        let i = Int(x), j = min(v.count - 1, Int(x) + 1)
        return v[i] + (v[j] - v[i]) * (x - Double(i))
    }

    static func summaries(_ trips: [Trip]) -> [RouteSummary] {
        struct OD { var start: Coordinate; var end: Coordinate }
        var anchors: [OD] = []
        var groups: [String: (Int, String, String, String, String, [Double])] = [:]
        // Fixed anchor per cluster; do not chain adjacent journeys into progressively larger regions.
        for t in trips.sorted(by: { $0.startedAt < $1.startedAt }) where exclusionReason(t) == nil {
            guard let first = t.usablePoints.first, let last = t.usablePoints.last else { continue }
            var index = anchors.firstIndex { distance($0.start, first.coordinate) <= 250 && distance($0.end, last.coordinate) <= 250 }
            if index == nil { anchors.append(OD(start: first.coordinate, end: last.coordinate)); index = anchors.count - 1 }
            let od = (index ?? 0) + 1
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: t.timezoneID) ?? TimeZone(secondsFromGMT: 0)!
            let hour = calendar.component(.hour, from: t.startedAt)
            let minute = calendar.component(.minute, from: t.startedAt) < 30 ? 0 : 30
            let bucket = String(format: "%02d:%02d", hour, minute)
            let weekday = calendar.component(.weekday, from: t.startedAt)
            let dayType = (weekday == 1 || weekday == 7) ? L("周末", "Weekend") : L("工作日", "Weekday")
            let label = t.displayTitle
            let routeKey = t.autoRouteKey ?? t.routeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(od)|\(t.timezoneID)|\(dayType)|\(bucket)|\(routeKey)"
            if groups[key] == nil { groups[key] = (od, label, dayType, bucket, t.timezoneID, []) }
            groups[key]?.5.append(t.elapsed / 60)
        }
        return groups.map { key, g in
            let xs = g.5, mean = xs.reduce(0, +) / Double(xs.count)
            let sd = xs.count > 1 ? sqrt(xs.reduce(0) { $0 + pow($1 - mean, 2) } / Double(xs.count - 1)) : nil
            return RouteSummary(id: key, odNumber: g.0, routeLabel: g.1, dayType: g.2,
                                timeBucket: g.3, timezoneID: g.4, count: xs.count,
                                meanMinutes: mean, medianMinutes: quantile(xs, 0.5),
                                standardDeviationMinutes: sd,
                                p90Minutes: xs.count >= 20 ? quantile(xs, 0.9) : nil)
        }.sorted { ($0.odNumber, $0.dayType, $0.timeBucket, $0.meanMinutes) < ($1.odNumber, $1.dayType, $1.timeBucket, $1.meanMinutes) }
    }
}
