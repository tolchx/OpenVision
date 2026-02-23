import AVFoundation
import Foundation

enum TranslationDirection {
    /// Audio plays through the iPhone's bottom speaker for the other person to hear
    case toLoudspeaker
    /// Audio plays through the connected Bluetooth glasses for the wearer to hear privately
    case toGlasses
}

class AudioRoutingManager {
    static let shared = AudioRoutingManager()
    
    private let session = AVAudioSession.sharedInstance()
    
    /// Forces the audio output to a specific port during the translation flow
    /// - Parameter direction: Whether the audio is intended for the external person or the glasses wearer
    func setRoute(for direction: TranslationDirection) {
        do {
            // Ensure the category allows playback and recording with Bluetooth
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            
            switch direction {
            case .toLoudspeaker:
                // Force audio out the bottom speaker of the iPhone
                print("[AudioRoutingManager] Routing audio to iPhone Loudspeaker")
                try session.overrideOutputAudioPort(.speaker)
                
            case .toGlasses:
                // Remove the speaker override; iOS will fall back to the connected Bluetooth glasses (if available)
                print("[AudioRoutingManager] Routing audio back to default (Bluetooth Glasses)")
                try session.overrideOutputAudioPort(.none)
            }
            
            try session.setActive(true)
            
        } catch {
            print("[AudioRoutingManager] Failed to change audio route: \(error.localizedDescription)")
        }
    }
}
