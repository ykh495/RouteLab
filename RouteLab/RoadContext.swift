import Foundation

actor RoadContext {
    static let shared = RoadContext()
    private struct Response: Decodable { var elements: [Element] }
    private struct Element: Decodable {
        var type: String; var id: Int64; var lat: Double?; var lon: Double?
        var tags: [String: String]?; var nodes: [Int64]?; var geometry: [Geo]?
    }
    private struct Geo: Decodable { var lat: Double; var lon: Double }
    private var cache: [String: (Date, RoadSnapshot)] = [:]
    func fetch(around coordinates: [Coordinate]) async throws -> RoadSnapshot {
        guard !coordinates.isEmpty else { return RoadSnapshot(features: [], roads: []) }
        let south = floor(((coordinates.map(\.latitude).min() ?? 0) - 0.001) * 100) / 100
        let north = ceil(((coordinates.map(\.latitude).max() ?? 0) + 0.001) * 100) / 100
        let west = floor(((coordinates.map(\.longitude).min() ?? 0) - 0.001) * 100) / 100
        let east = ceil(((coordinates.map(\.longitude).max() ?? 0) + 0.001) * 100) / 100
        guard north-south <= 0.25, east-west <= 0.25 else { throw serviceError("查询区域过大", "Area too large for the local-road lookup") }
        let box = "\(south),\(west),\(north),\(east)"
        if let saved = cache[box], Date().timeIntervalSince(saved.0) < 86400 { return saved.1 }
        let types = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
        let query = "[out:json][timeout:20];(node[highway=traffic_signals](\(box));node[railway=level_crossing](\(box));way[highway~\"^(\(types))$\"](\(box)););out body geom;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"; request.timeoutInterval = 28
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("RouteLab-iOS/0.2 personal-research", forHTTPHeaderField: "User-Agent")
        var form = URLComponents(); form.queryItems = [URLQueryItem(name: "data", value: query)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data,response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 12_000_000 else { throw serviceError("道路数据暂不可用", "Road data is temporarily unavailable") }
        let responseData = try JSONDecoder().decode(Response.self, from: data)
        var features: [RoadFeature] = [], roads: [Road] = []
        var neighbors: [Int64: Set<Int64>] = [:], locations: [Int64: Coordinate] = [:]
        for element in responseData.elements {
            let tags = element.tags ?? [:]
            if element.type == "node", let lat = element.lat, let lon = element.lon {
                features.append(RoadFeature(id: "osm-node-\(element.id)", kind: tags["railway"] == "level_crossing" ? .rail : .signal, coordinate: Coordinate(latitude: lat, longitude: lon)))
            } else if element.type == "way", let geometry = element.geometry, geometry.count > 1 {
                let coordinates = geometry.map { Coordinate(latitude: $0.lat, longitude: $0.lon) }
                let nodes = element.nodes ?? []
                let oneWay = tags["oneway"] == "-1" ? -1 : ((tags["oneway"] == "yes" || tags["oneway"] == "1" || (tags["junction"] == "roundabout" && tags["oneway"] != "no")) ? 1 : 0)
                // Conditional/directional limits are not guessed into a single authoritative limit.
                let hasDirectional = tags["maxspeed:forward"] != nil || tags["maxspeed:backward"] != nil || tags["maxspeed:conditional"] != nil
                roads.append(Road(id: "osm-way-\(element.id)", name: tags["name"] ?? tags["ref"] ?? "", coordinates: coordinates, nodeIDs: nodes, speedLimitMPS: hasDirectional ? nil : RouteGeometry.speedLimit(tags["maxspeed"]), oneWay: oneWay))
                if nodes.count == coordinates.count {
                    for i in nodes.indices {
                        locations[nodes[i]] = coordinates[i]
                        if i > 0 { neighbors[nodes[i], default: []].insert(nodes[i-1]) }
                        if i+1 < nodes.count { neighbors[nodes[i], default: []].insert(nodes[i+1]) }
                    }
                }
            }
        }
        // Shared topology prevents an overpass crossing from being mistaken for a junction.
        for (id, adjacent) in neighbors where adjacent.count >= 3 {
            if let coordinate = locations[id] { features.append(RoadFeature(id: "osm-junction-\(id)", kind: .junction, coordinate: coordinate)) }
        }
        let result = RoadSnapshot(features: features, roads: roads)
        if cache.count > 12 { cache.removeAll() }
        cache[box] = (Date(), result); return result
    }
    private func serviceError(_ zh: String, _ en: String) -> NSError {
        NSError(domain: "RouteLab", code: 1, userInfo: [NSLocalizedDescriptionKey: L(zh,en)])
    }
}
