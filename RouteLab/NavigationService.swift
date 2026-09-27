import Foundation
import MapKit
import UIKit

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    init(_ cl: CLLocationCoordinate2D) { latitude = cl.latitude; longitude = cl.longitude }
}

struct RouteOption: Identifiable {
    var id = UUID()
    var name: String
    var seconds: Double
    var meters: Double
    var coordinates: [Coordinate]
    var capturedAt: Date
}

enum NavigationService {
    static func search(_ query: String, near coordinate: Coordinate?) async throws -> [Place] {
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        if let coordinate { request.region = MKCoordinateRegion(center: coordinate.cl, latitudinalMeters: 30_000, longitudinalMeters: 30_000) }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).map(place)
    }

    static func routes(from: Coordinate, to: Place) async throws -> [RouteOption] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.cl))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate.cl))
        request.transportType = .automobile
        request.departureDate = Date(); request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        let captured = request.departureDate ?? Date()
        return response.routes.map { route in
            var points = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
            return RouteOption(name: route.name, seconds: route.expectedTravelTime, meters: route.distance,
                               coordinates: points.map(Coordinate.init), capturedAt: captured)
        }
    }

    @MainActor
    static func open(_ navigator: Navigator, destination: Place) async -> Bool {
        switch navigator {
        case .manual: return true
        case .apple:
            let item = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate.cl)); item.name = destination.name
            return item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        case .google:
            var parts = URLComponents(string: "https://www.google.com/maps/dir/")!
            parts.queryItems = [URLQueryItem(name: "api", value: "1"),
                                URLQueryItem(name: "destination", value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"),
                                URLQueryItem(name: "travelmode", value: "driving"), URLQueryItem(name: "dir_action", value: "navigate")]
            guard let url = parts.url else { return false }
            return await UIApplication.shared.open(url)
        }
    }
}

extension NavigationService {
    static func place(_ item: MKMapItem) -> Place {
        Place(name: item.name ?? L("地图位置", "Map location"), coordinate: Coordinate(item.placemark.coordinate), address: item.placemark.title)
    }
    static func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place? {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response.mapItems.first.map(place)
    }
}
