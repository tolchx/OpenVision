// OpenVision - SoundService.swift
// Service for playing UI sound effects

import AVFoundation

/// Service for playing UI sound effects
@MainActor
final class SoundService: ObservableObject {
    // MARK: - Singleton

    static let shared = SoundService()

    // MARK: - Audio Players

    private var wakeWordPlayer: AVAudioPlayer?
    private var thinkingPlayer: AVAudioPlayer?

    // MARK: - State

    @Published var isPlayingThinkingSound: Bool = false
    private var thinkingTimer: Timer?

    // MARK: - Settings

    private var soundEnabled: Bool {
        SettingsManager.shared.settings.playActivationSound
    }

    // MARK: - Initialization

    private init() {
        setupAudioPlayers()
    }

    // MARK: - Setup

    private func setupAudioPlayers() {
        // Wake word ding sound
        if let url = Bundle.main.url(forResource: "wake_word_ding", withExtension: "mp3") {
            do {
                wakeWordPlayer = try AVAudioPlayer(contentsOf: url)
                wakeWordPlayer?.prepareToPlay()
                wakeWordPlayer?.volume = 0.7
            } catch {
                print("[SoundService] Failed to load wake_word_ding.mp3: \(error)")
            }
        } else {
            print("[SoundService] wake_word_ding.mp3 not found in bundle")
        }

        // Thinking loop sound
        if let url = Bundle.main.url(forResource: "thinking_loop", withExtension: "mp3") {
            do {
                thinkingPlayer = try AVAudioPlayer(contentsOf: url)
                thinkingPlayer?.prepareToPlay()
                thinkingPlayer?.volume = 0.3
            } catch {
                print("[SoundService] Failed to load thinking_loop.mp3: \(error)")
            }
        } else {
            print("[SoundService] thinking_loop.mp3 not found in bundle")
        }
    }

    // MARK: - Wake Word Sound

    /// Play the wake word activation sound (ding)
    func playWakeWordSound() {
        guard soundEnabled else { return }

        wakeWordPlayer?.currentTime = 0
        wakeWordPlayer?.play()
    }

    // MARK: - Thinking Sound

    /// Start playing the thinking/processing sound on loop
    func startThinkingSound() {
        guard soundEnabled else { return }
        guard !isPlayingThinkingSound else { return }

        isPlayingThinkingSound = true

        // Play immediately
        playThinkingSoundOnce()

        // Set up timer to repeat every 3 seconds (slow enough to not be annoying)
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.playThinkingSoundOnce()
            }
        }
    }

    /// Stop the thinking sound
    func stopThinkingSound() {
        isPlayingThinkingSound = false
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        thinkingPlayer?.stop()
    }

    private func playThinkingSoundOnce() {
        guard isPlayingThinkingSound else { return }
        thinkingPlayer?.currentTime = 0
        thinkingPlayer?.play()
    }
}
