// OpenVision - ConversationListView.swift
// List of past conversations with search and delete

import SwiftUI

struct ConversationListView: View {
    // MARK: - Environment

    @EnvironmentObject var conversationManager: ConversationManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var searchText: String = ""
    @State private var showDeleteAlert = false
    @State private var conversationToDelete: Conversation?

    // MARK: - Body

    var body: some View {
        Group {
            if conversationManager.conversations.isEmpty {
                emptyState
            } else if filteredConversations.isEmpty {
                noResultsState
            } else {
                conversationList
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search conversations")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if !conversationManager.conversations.isEmpty {
                    EditButton()
                }
            }
        }
        .alert("Delete Conversation?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let conversation = conversationToDelete {
                    withAnimation {
                        conversationManager.deleteConversation(conversation)
                    }
                }
                conversationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No conversations yet")
                .font(.headline)

            Text("Start talking to the AI assistant to see your history here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - No Results State

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No results for \"\(searchText)\"")
                .font(.headline)
        }
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink {
                    ConversationDetailView(conversation: conversation)
                } label: {
                    ConversationRow(conversation: conversation)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        conversationToDelete = conversation
                        showDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deleteConversations)
        }
        .listStyle(.plain)
    }

    // MARK: - Filtered Conversations

    private var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversationManager.conversations
        }
        return conversationManager.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(searchText) ||
            conversation.messages.contains { message in
                message.content.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    // MARK: - Methods

    private func deleteConversations(at offsets: IndexSet) {
        let convos = filteredConversations
        for index in offsets {
            conversationManager.deleteConversation(convos[index])
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(conversation.lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let lastMessage = conversation.messages.last {
                Text(lastMessage.content)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Label("\(conversation.messages.count)", systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if conversation.hasPhotos {
                    Label("", systemImage: "photo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Conversation Detail View

struct ConversationDetailView: View {
    let conversation: Conversation

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(conversation.messages) { message in
                    MessageBubble(message: message)
                }
            }
            .padding()
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.blue : Color(.systemGray5))
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .cornerRadius(16)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
    }
}

#Preview {
    NavigationView {
        ConversationListView()
            .environmentObject(ConversationManager.shared)
    }
}
