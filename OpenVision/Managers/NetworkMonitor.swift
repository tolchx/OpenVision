import Foundation
import Network

/// Monitors the device's internet connectivity to automatically trigger Offline SLM mode
@MainActor
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var isConnected: Bool = true
    private let monitor = NWPathMonitor()
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
                if path.status == .satisfied {
                    print("[NetworkMonitor] Connected to Internet: \(path.availableInterfaces.map { $0.type })")
                } else {
                    print("[NetworkMonitor] No Internet Connection. Entering Offline Mode.")
                }
            }
        }
        
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)
    }
}
