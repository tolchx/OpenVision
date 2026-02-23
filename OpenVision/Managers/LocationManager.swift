import Foundation
import CoreLocation

@MainActor
class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    
    @Published var location: CLLocation?
    @Published var placemark: CLPlacemark?
    @Published var error: Error?

    override init() {
        super.init()
        manager.delegate = self
        // Balance battery life vs. accuracy: HundredMeters is good for neighborhood/city context
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters 
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        // Wait for authorization before requesting
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    
    // Start continuous tracking if needed (for proactive nearby memories)
    func startTracking() {
        manager.requestWhenInUseAuthorization()
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func stopTracking() {
        manager.stopUpdatingLocation()
    }

    // MARK: - CoreLocation Delegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        Task { @MainActor in
            self.location = location
            
            // Reverse geocode to get city name
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                self.placemark = placemarks.first
                self.error = nil // Clear any previous errors
            } catch {
                print("[LocationManager] Reverse geocode failed: \(error)")
                self.error = error
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.error = error
            print("[LocationManager] Location update failed: \(error)")
        }
    }
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    // MARK: - Context Helpers

    var contextString: String? {
        guard let loc = location else { return nil }
        
        var str = "Latitude \(loc.coordinate.latitude), Longitude \(loc.coordinate.longitude)."
        
        if let place = placemark {
            let city = place.locality ?? ""
            let neighborhood = place.subLocality ?? ""
            let country = place.country ?? ""
            
            str += " "
            if !neighborhood.isEmpty { str += "Neighborhood: \(neighborhood). " }
            if !city.isEmpty { str += "City: \(city), \(country)." }
        }
        
        return str
    }
}
