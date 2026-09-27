import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationRecorder: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var precise = false
    @Published private(set) var latest: TrackPoint?
    @Published private(set) var active: Trip?
    @Published private(set) var isRecording = false
    @Published var message: String?
    @Published var lastSavedID: UUID?
    private let manager = CLLocationManager()
    private let store: TripStore
    private var checkpointAt = Date.distantPast
    private var arrivalSince: Date?
    private var movedMeters: Double = 0
    private var foreground = false
    private var requestedPrecise = false

    init(store: TripStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
        precise = manager.accuracyAuthorization == .fullAccuracy
        if let recovered = store.recoveredTrip() {
            active = recovered
            message = L("发现未结束的行程，可恢复记录或保存已有部分。", "An unfinished trip was recovered. Resume it or save the recorded portion.")
        }
    }

    var allowed: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var freshFix: Bool {
        guard let latest else { return false }
        return Date().timeIntervalSince(latest.timestamp) < 45 && latest.horizontalAccuracy <= 35
    }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if allowed { refreshLocation() }
        else { message = L("请到 iPhone 设置中允许 RouteLab 使用位置。", "Allow location access for RouteLab in iPhone Settings.") }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        guard !isRecording else { return }
        manager.allowsBackgroundLocationUpdates = false
        if value && allowed { manager.startUpdatingLocation() }
        else { manager.stopUpdatingLocation() }
    }

    func refreshLocation() {
        guard allowed else { return }
        if manager.accuracyAuthorization != .fullAccuracy && !requestedPrecise {
            requestedPrecise = true
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: AppLanguage.isChinese ? "TripRecordingZH" : "TripRecordingEN")
        }
        if foreground || isRecording { manager.startUpdatingLocation() }
        else { manager.requestLocation() }
    }

    func ensureFreshFix() async -> Bool {
        requestPermission(); refreshLocation()
        for _ in 0..<40 {
            if freshFix && precise { return true }
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return false }
        }
        message = L("仍在等待精确位置。请检查定位权限，或到室外再试。", "Waiting for an accurate location. Check location access or try outdoors.")
        return false
    }

    func begin(destination: Place?, label: String, navigator: Navigator, option: RouteOption?,
               externalMinutes: Double?, externalCapturedAt: Date?, roadFeatures: [RoadFeature],
               contextStatus: String, autoArrival: Bool) -> Bool {
        guard active == nil else { message = L("请先结束或恢复上一段行程。", "Finish or resume your previous trip first."); return false }
        guard allowed && precise && freshFix else {
            message = L("正在等待精确位置，请稍后再试。", "Waiting for an accurate location. Please try again shortly."); refreshLocation(); return false
        }
        let now = Date()
        var trip = Trip(startedAt: now, timezoneID: TimeZone.current.identifier, navigator: navigator,
                        destination: destination, routeLabel: label)
        if let option {
            trip.referenceEstimate = Estimate(seconds: option.seconds, capturedAt: option.capturedAt,
                                               source: "mapkit_reference", routeDescription: option.name)
            trip.plannedRoute = option.coordinates; trip.plannedDistanceMeters = option.meters
        }
        if let minutes = externalMinutes, minutes > 0, let captured = externalCapturedAt, navigator != .manual {
            trip.externalEstimate = Estimate(seconds: minutes * 60, capturedAt: captured,
                                             source: navigator == .apple ? "apple_user_entered" : "google_user_entered",
                                             routeDescription: "用户录入外部导航的最初剩余分钟数")
        }
        trip.stopRuleVersion = 2
        trip.roadFeatures = roadFeatures; trip.roadContextStatus = contextStatus
        trip.autoArrivalEnabled = autoArrival && destination != nil
        guard store.checkpoint(trip) else { return false }
        active = trip; movedMeters = 0; arrivalSince = nil; isRecording = true; message = nil
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        return true
    }

    func resume() {
        guard var trip = active, allowed, precise else { requestPermission(); return }
        trip.interrupted = true; active = trip
        arrivalSince = nil; isRecording = true
        manager.allowsBackgroundLocationUpdates = true; manager.startUpdatingLocation()
        checkpoint()
    }

    func finish(at date: Date = Date(), method: String = "manual") {
        guard var trip = active else { return }
        trip.endedAt = max(trip.startedAt, date)
        trip.endMethod = method; trip.reviewed = method == "manual"
        trip.analysisStatus = "queued"
        if !isRecording { trip.interrupted = true }
        guard store.save(trip) else {
            message = L("保存未完成，请保持 App 打开并重试到达。", "Saving failed. Keep the app open and try finishing again."); return
        }
        manager.stopUpdatingLocation(); manager.allowsBackgroundLocationUpdates = false
        isRecording = false; active = nil; store.clearCheckpoint()
        setForeground(foreground)
        lastSavedID = trip.id
        message = method == "automatic_candidate" ? L("已保存可能到达的行程，请确认到达时间。", "Possible arrival saved. Please confirm your arrival time.") : L("行程已保存，正在自动整理路线。", "Trip saved. Your route is being organized automatically.")
    }

    func saveRecoveredPart() {
        guard let trip = active else { return }
        finish(at: trip.points.last?.timestamp ?? trip.startedAt, method: "recovered_partial")
    }

    func checkpoint() { if let active { _ = store.checkpoint(active) } }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        precise = manager.accuracyAuthorization == .fullAccuracy
        if allowed && (foreground || isRecording) { refreshLocation() }
        if !allowed && isRecording {
            active?.interrupted = true; checkpoint(); isRecording = false
            manager.stopUpdatingLocation()
            message = L("位置权限被关闭，记录已中断；已有数据仍保留。", "Location access was revoked. Recording stopped; saved samples are preserved.")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = TrackPoint(timestamp: Date(timeIntervalSince1970: floor(location.timestamp.timeIntervalSince1970)), coordinate: Coordinate(location.coordinate),
                                   speed: location.speed, horizontalAccuracy: location.horizontalAccuracy)
            guard TripMath.valid(point, after: nil, now: Date()) else {
                if isRecording { active?.rejectionCount += 1 }; continue
            }
            if latest == nil || point.timestamp > latest!.timestamp { latest = point }
            guard isRecording, var trip = active, point.timestamp >= trip.startedAt else { continue }
            guard TripMath.valid(point, after: trip.points.last, now: Date()) else { active?.rejectionCount += 1; continue }
            if let previous = trip.points.last {
                let dt = point.timestamp.timeIntervalSince(previous.timestamp)
                if dt <= TripMath.maxGap && point.speed >= 1.2 {
                    movedMeters += TripMath.distance(previous.coordinate, point.coordinate)
                }
                if dt > TripMath.maxGap { arrivalSince = nil }
            }
            trip.points.append(point); active = trip
            if Date().timeIntervalSince(checkpointAt) >= 5 { checkpoint(); checkpointAt = Date() }
            if trip.autoArrivalEnabled, let destination = trip.destination, movedMeters > 300,
               TripMath.distance(point.coordinate, destination.coordinate) < 60,
               point.speed >= 0, point.speed < 0.8 {
                if arrivalSince == nil { arrivalSince = point.timestamp }
                if let since = arrivalSince, point.timestamp.timeIntervalSince(since) >= 120 {
                    finish(at: since, method: "automatic_candidate"); return
                }
            } else { arrivalSince = nil }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = L("暂时无法定位：", "Location temporarily unavailable: ") + error.localizedDescription
        checkpoint()
    }
}

#if compiler(>=6.2)
extension LocationRecorder: @MainActor CLLocationManagerDelegate {}
#else
extension LocationRecorder: CLLocationManagerDelegate {}
#endif
