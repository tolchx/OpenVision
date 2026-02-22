// OpenVision - ChatMessageBubble.swift
// Futuristic glassmorphic chat bubbles for individual turns

import SwiftUI

/// Renders a single saved message from the Conversation history
struct ChatMessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if message.role == .user {
                Spacer(minLength: 40)
            } else {
                // AI Avatar
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(
                            colors: [.purple.opacity(0.8), .blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .shadow(color: .purple.opacity(0.5), radius: 4)
            }
            
            // Bubble Content
            Text(message.content)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    GlassCard(
                        cornerRadius: 20,
                        opacity: message.role == .user ? 0.2 : 0.1
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            message.role == .user
                                ? Color.blue.opacity(0.3)
                                : Color.purple.opacity(0.3),
                            lineWidth: 1
                        )
                )

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

/// Renders the currently streaming live turn at the bottom of the chat
struct ActiveTurnBubble: View {
    let userText: String
    let aiText: String
    let isAIStreaming: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            // Live User Input
            if !userText.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    Text(userText)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(GlassCard(cornerRadius: 20, opacity: 0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                        )
                }
            }
            
            // Live AI Output
            if !aiText.isEmpty || isAIStreaming {
                HStack(alignment: .bottom, spacing: 12) {
                    // AI Avatar (pulsing)
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            LinearGradient(
                                colors: [.purple.opacity(0.8), .blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: .purple.opacity(0.5), radius: 4)
                        .scaleEffect(isAIStreaming ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAIStreaming)
                    
                    if !aiText.isEmpty {
                        Text(aiText)
                            .font(.body)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(GlassCard(cornerRadius: 20, opacity: 0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.purple.opacity(0.6), lineWidth: 1)
                            )
                    } else if isAIStreaming {
                        // Thinking indicator
                        HStack(spacing: 4) {
                            Circle().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                            Circle().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                            Circle().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(GlassCard(cornerRadius: 20, opacity: 0.1))
                    }
                    
                    Spacer(minLength: 40)
                }
            }
        }
    }
}
