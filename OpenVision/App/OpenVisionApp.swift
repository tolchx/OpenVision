// OpenVision - OpenVisionApp.swift
// App entry point with URL scheme handling for Meta AI registration

import SwiftUI
import MWDATCore

@main
struct OpenVisionApp: App {
    // MARK: - State Objects

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var glassesManager: GlassesManager
    @StateObject private var conversationManager: ConversationManager

    // MARK: - App Storage

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    // MARK: - Initialization

    init() {
        // 1. Initialize Meta Wearables SDK FIRST
        do {
            try Wearables.configure()
            print("[OpenVisionApp] Wearables SDK configured")
        } catch {
            print("[OpenVisionApp] Failed to configure Wearables SDK: \(error)")
        }

        // 2. Initialize Managers SECONELY (guarantees SDK is ready)
        self._settingsManager = StateObject(wrappedValue: SettingsManager.shared)
        self._glassesManager = StateObject(wrappedValue: GlassesManager.shared)
        self._conversationManager = StateObject(wrappedValue: ConversationManager.shared)
        
        print("[OpenVisionApp] Initialized and Managers ready")
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    MainTabView()
                        .environmentObject(settingsManager)
                        .environmentObject(glassesManager)
                        .environmentObject(conversationManager)
                } else {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                handleURL(url)
            }
        }
    }

    // MARK: - URL Handling

    /// Handle URL callback from Meta AI app for glasses registration
    private func handleURL(_ url: URL) {
        print("[OpenVisionApp] Received URL: \(url)")

        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
                print("[OpenVisionApp] URL handled successfully")
            } catch {
                print("[OpenVisionApp] Error handling URL: \(error)")
            }
        }
    }
}
