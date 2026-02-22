// OpenVision - HamburgerMenuView.swift
// Futuristic slide-out side menu

import SwiftUI

struct HamburgerMenuView: View {
    @Binding var isOpen: Bool
    @Binding var currentSheet: SheetType?

    enum SheetType {
        case history
        case settings
        case debug
        case newChat
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Dim background overlay
            if isOpen {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isOpen = false
                        }
                    }
            }

            // Menu Drawer
            HStack {
                VStack(alignment: .leading, spacing: 32) {
                    // Header
                    HStack {
                        Image(systemName: "visionpro")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        Text("OpenVision")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                    }
                    .padding(.top, 60)
                    .padding(.horizontal, 24)

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // Navigation Links
                    VStack(alignment: .leading, spacing: 20) {
                        MenuButton(icon: "plus.bubble.fill", title: "New Chat", color: .green) {
                            withAnimation { isOpen = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                currentSheet = .newChat
                            }
                        }

                        MenuButton(icon: "clock.fill", title: "History") {
                            withAnimation { isOpen = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                currentSheet = .history
                            }
                        }

                        MenuButton(icon: "gearshape.fill", title: "Settings") {
                            withAnimation { isOpen = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                currentSheet = .settings
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // Tools
                    VStack(alignment: .leading, spacing: 20) {
                        Text("TOOLS")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 24)

                        MenuButton(icon: "ladybug.fill", title: "Debug Log", color: .orange) {
                            withAnimation { isOpen = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                currentSheet = .debug
                            }
                        }
                    }
                    
                    Spacer()
                    
                    // Footer
                    Text("v1.0.0")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.3))
                        .padding(24)
                }
                .frame(width: 280)
                .background(
                    ZStack {
                        Color(white: 0.05, opacity: 0.95)
                        VisualEffectBlur(blurStyle: .systemThinMaterialDark)
                    }
                    .ignoresSafeArea()
                )
                .overlay(
                    Rectangle()
                        .frame(width: 1)
                        .foregroundColor(Color.white.opacity(0.1)),
                    alignment: .trailing
                )
                .offset(x: isOpen ? 0 : -280)
                
                Spacer()
            }
        }
        .zIndex(100)
    }
}

// Helper generic menu button
private struct MenuButton: View {
    let icon: String
    let title: String
    var color: Color = .blue
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                    .frame(width: 24)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 10)
        }
    }
}

// Helper to use UIKit's UIBlurEffect for that frosted glass look
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
    }
}
