import Foundation

struct Coordinate: Codable, Sendable, Hashable {
    var latitude: Double
    var longitude: Double
}

struct TrackPoint: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var coordinate: Coordinate
    var speed: Double // m/s; negative means unavailable
    var horizontalAccuracy: Double
}

struct Place: Codable, Sendable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var coordinate: Coordinate
    var address: String?
}

struct Favorite: Codable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var category: String
    var place: Place
    var displayTitle: String {
        if !title.isEmpty { return title }
        switch category {
        case "home": return L("住址", "Home")
        case "library": return L("图书馆", "Library")
        case "school": return L("学校", "School")
        case "parking": return L("停车库", "Parking")
        default: return place.name
        }
    }
    var icon: String {
        switch category { case "home": return "house.fill"; case "library": return "books.vertical.fill"; case "school": return "graduationcap.fill"; case "parking": return "parkingsign.circle.fill"; default: return "star.fill" }
    }
}

enum Navigator: String, Codable, Sendable, CaseIterable, Identifiable {
    case apple, google, manual
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: return "Apple Maps"; case .google: return "Google Maps"; case .manual: return L("旧版手动行程", "Legacy manual trip") }
    }
}

struct Estimate: Codable, Sendable {
    var seconds: Double
    var capturedAt: Date
    var source: String // mapkit_reference, apple_user_entered, google_user_entered
    var routeDescription: String
}

enum RoadFeatureKind: String, Codable, Sendable { case signal, rail, junction }
struct RoadFeature: Codable, Sendable, Identifiable {
    var id: String
    var kind: RoadFeatureKind
    var coordinate: Coordinate
}

enum DelayReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case unknown, signal, rail, congestion, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return L("原因未知", "Unknown cause")
        case .signal: return L("红灯 / 路口等待", "Signal / intersection wait")
        case .rail: return L("铁路等待", "Rail crossing wait")
        case .congestion: return L("拥堵", "Congestion")
        case .other: return L("其他停车 / 等待", "Other stop / wait")
        }
    }
}

enum MotionKind: String, Codable, Sendable { case stopped, slow }
struct DelayEvent: Identifiable {
    var id: String
    var start: Date
    var end: Date
    var coordinate: Coordinate
    var kind: MotionKind
    var suggestedReason: DelayReason
    var evidence: String = "unknown"
    var duration: Double { max(0, end.timeIntervalSince(start)) }
}

struct Trip: Codable, Sendable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
    var timezoneID: String
    var navigator: Navigator
    var destination: Place?
    var routeLabel: String
    var referenceEstimate: Estimate?
    var externalEstimate: Estimate?
    var plannedDistanceMeters: Double?
    var plannedRoute: [Coordinate] = []
    var points: [TrackPoint] = []
    var roadFeatures: [RoadFeature] = []
    var roadContextStatus: String = "未加载道路设施"
    var confirmedReasons: [String: DelayReason] = [:]
    var notes: String = ""
    var endMethod: String = "manual"
    var autoArrivalEnabled: Bool = false
    var reviewed: Bool = false
    var interrupted: Bool = false
    var excluded: Bool = false
    var rejectionCount: Int = 0
    // Optional additions preserve automatic decoding of every v0.1 trip/checkpoint.
    var autoRouteKey: String?
    var autoRouteNumber: Int?
    var roadNames: [String]?
    var roadMatches: [RoadMatch]?
    var roadMatchCoverage: Double?
    var analysisStatus: String?
    var constructionReported: Bool?
    var stopRuleVersion: Int?

    var displayTitle: String {
        if let n = autoRouteNumber { return L("路线 ", "Route ") + String(n) }
        return routeLabel.isEmpty ? L("路线待识别", "Route pending") : routeLabel
    }

    var elapsed: Double { max(0, (endedAt ?? Date()).timeIntervalSince(startedAt)) }
    var usablePoints: [TrackPoint] {
        points.filter { $0.timestamp >= startedAt && $0.timestamp <= (endedAt ?? .distantFuture) }
    }
}

struct ExportBundle: Codable {
    var schemaVersion = 1
    var appVersion = "0.2.0"
    var exportedAt = Date()
    var distanceMethod = "filtered_gps_haversine_v1"
    var trips: [Trip]
    var favorites: [Favorite]?
}

struct TripMetrics {
    var distanceMeters: Double = 0
    var observedSeconds: Double = 0
    var gapSeconds: Double = 0
    var events: [DelayEvent] = []
    var stoppedSeconds: Double { events.filter { $0.kind == .stopped }.reduce(0) { $0 + $1.duration } }
    var slowSeconds: Double { events.filter { $0.kind == .slow }.reduce(0) { $0 + $1.duration } }
}

struct RouteSummary: Identifiable {
    var id: String
    var odNumber: Int
    var routeLabel: String
    var dayType: String
    var timeBucket: String
    var timezoneID: String
    var count: Int
    var meanMinutes: Double
    var medianMinutes: Double
    var standardDeviationMinutes: Double? // sample standard deviation
    var p90Minutes: Double? // hidden when n < 20
}

struct Road: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var coordinates: [Coordinate]
    var nodeIDs: [Int64]
    var speedLimitMPS: Double?
    var oneWay: Int
}
struct RoadMatch: Codable, Sendable {
    var pointID: UUID
    var roadID: String
    var roadName: String
    var distanceMeters: Double
    var speedLimitMPS: Double?
}
struct RoadSnapshot: Sendable {
    var features: [RoadFeature]
    var roads: [Road]
}
