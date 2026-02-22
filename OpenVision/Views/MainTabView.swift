// OpenVision - MainTabView.swift
// Main root navigation coordinator

import SwiftUI

struct MainTabView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager
    @EnvironmentObject var conversationManager: ConversationManager

    // MARK: - State

    @State private var isMenuOpen: Bool = false
    @State private var currentSheet: HamburgerMenuView.SheetType? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            // Main App View
            VoiceAgentView(isMenuOpen: $isMenuOpen)
                // Slight scale down effect when menu is open for a 3D drawer look
                .scaleEffect(isMenuOpen ? 0.95 : 1.0)
                .blur(radius: isMenuOpen ? 2 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isMenuOpen)
                // Consume taps when menu is open to prevent interacting with the background
                .onTapGesture {
                    if isMenuOpen {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isMenuOpen = false
                        }
                    }
                }
                .disabled(isMenuOpen)

            // Hamburger Menu Overlay
            HamburgerMenuView(isOpen: $isMenuOpen, currentSheet: $currentSheet)
        }
        .sheet(item: Binding<HamburgerMenuView.SheetType?>(
            get: { self.currentSheet },
            set: { self.currentSheet = $0 }
        )) { sheetAction in
            switch sheetAction {
            case .history:
                NavigationView {
                    ConversationListView()
                        .environmentObject(conversationManager)
                }
            case .settings:
                NavigationView {
                    SettingsView()
                }
            case .debug:
                DebugLogView()
            case .newChat:
                // This case is handled below in onChange, not as a sheet
                EmptyView()
            }
        }
        .onChange(of: currentSheet) { newValue in
            if newValue == .newChat {
                // Start a new conversation and dismiss immediately
                conversationManager.startNewConversation()
                currentSheet = nil
            }
        }
    }
}

// Make the enum conform to Identifiable so it can be used with .sheet(item:)
extension HamburgerMenuView.SheetType: Identifiable {
    var id: Self { self }
}

#Preview {
    MainTabView()
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .environmentObject(ConversationManager.shared)
        .preferredColorScheme(.dark)
}
