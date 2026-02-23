import Foundation
import UserNotifications

/// Handles proactive notifications that are read aloud by the smart glasses
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    @Published var isAuthorized: Bool = false
    
    // To prevent TTS from playing when the user isn't actually using the glasses/app
    var isSessionActive: Bool = false
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    /// Requests iOS permission to show/play notifications
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.isAuthorized = granted
                if let error = error {
                    print("[NotificationManager] Authorization Error: \(error.localizedDescription)")
                } else {
                    print("[NotificationManager] Authorization Granted: \(granted)")
                }
            }
        }
    }
    
    /// Schedules a local mock notification for testing purposes
    func scheduleTestNotification(in seconds: TimeInterval, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationManager] Error scheduling notification: \(error)")
            } else {
                print("[NotificationManager] Scheduled '\(title)' for \(seconds)s from now.")
            }
        }
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// Called when the app is in the foreground (or active in background via audio session)
    /// This is where we catch the notification and read it aloud through the glasses
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        
        let title = notification.request.content.title
        let body = notification.request.content.body
        
        print("[NotificationManager] Received active notification: \(title) - \(body)")
        
        Task { @MainActor in
            // Only speak if the user has an active AI session (wearing glasses)
            if self.isSessionActive {
                let speechText = "Proactive Alert. \(title). \(body)"
                print("[NotificationManager] Reading alert out loud via TTSService.")
                
                // Play a brief attention chime (if available) then speak
                SoundService.shared.playStartListeningSound()
                try? await Task.sleep(nanoseconds: 500_000_000)
                TTSService.shared.speak(speechText)
            }
        }
        
        // Still show the visual banner on the iPhone screen
        completionHandler([.banner, .sound])
    }
    
    /// Called when the user physically taps the notification banner
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        print("[NotificationManager] User tapped notification: \(response.notification.request.content.title)")
        completionHandler()
    }
}
