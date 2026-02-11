// OpenVision - TTSService.swift
// Text-to-speech service using AVSpeechSynthesizer

import AVFoundation
import Foundation

/// Text-to-speech service for OpenClaw mode
@MainActor
final class TTSService: NSObject, ObservableObject {
    // MARK: - Singleton

    static let shared = TTSService()

    // MARK: - Published State

    @Published var isSpeaking: Bool = false

    // MARK: - Callbacks

    /// Called when speech starts
    var onSpeechStarted: (() -> Void)?

    /// Called when speech ends
    var onSpeechEnded: (() -> Void)?

    // MARK: - Speech Synthesizer

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Voice Selection

    private var selectedVoice: AVSpeechSynthesisVoice? {
        // Check if user has selected a specific voice
        if let identifier = SettingsManager.shared.settings.selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }

        // Fall back to default English voice
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Get all available voices for a language
    static func availableVoices(for languageCode: String = "en") -> [AVSpeechSynthesisVoice] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
            .sorted { v1, v2 in
                // Sort by quality (premium first), then by name
                if v1.quality != v2.quality {
                    return v1.quality.rawValue > v2.quality.rawValue
                }
                return v1.name < v2.name
            }
    }

    /// Get display name for a voice quality
    static func qualityDisplayName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Initialization

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speak

    /// Speak text
    func speak(_ text: String) {
        // Stop any current speech
        if isSpeaking {
            stop()
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        synthesizer.speak(utterance)
    }

    /// Stop speaking
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Pause speaking
    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    /// Continue speaking
    func continueSpeaking() {
        synthesizer.continueSpeaking()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = true
            self.onSpeechStarted?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeechEnded?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeechEnded?()
        }
    }
}
