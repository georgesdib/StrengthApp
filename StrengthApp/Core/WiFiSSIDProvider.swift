import CoreLocation
import Foundation
import NetworkExtension

protocol WiFiSSIDProviding: AnyObject {
    /// Returns the current SSID only when location and Wi-Fi information access are available.
    func currentSSID() async -> String?
}

@MainActor
final class WiFiSSIDProvider: NSObject, CLLocationManagerDelegate, WiFiSSIDProviding {
    private let locationManager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func currentSSID() async -> String? {
        var status = locationManager.authorizationStatus
        if status == .notDetermined {
            status = await requestLocationAuthorization()
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return nil
        }
        // NEHotspotNetwork requires precise location authorization as well as the Access
        // Wi-Fi Information entitlement. Reduced accuracy returns nil rather than a false match.
        guard locationManager.accuracyAuthorization == .fullAccuracy else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    private func requestLocationAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authorizationContinuation?.resume(returning: manager.authorizationStatus)
        authorizationContinuation = nil
    }
}
