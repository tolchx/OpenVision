// OpenVision - SessionSummarizer.swift
// Generates summary of completed conversations

import Foundation

class SessionSummarizer {
    static let shared = SessionSummarizer()
    
    private init() {}
    
    func summarize(conversation: Conversation) async -> String? {
        let apiKey = SettingsManager.shared.settings.geminiAPIKey
        guard !apiKey.isEmpty else { return nil }
        
        // Limit to reasonable length to avoid huge payload, but keep enough context
        let messages = conversation.messages
        guard messages.count > 2 else { return nil } // Don't summarize tiny chats
        
        let textToSummarize = messages.suffix(50).map { "\($0.role.rawValue.uppercased()): \($0.content)" }.joined(separator: "\n")
        guard textToSummarize.count > 20 else { return nil }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }
        
        let payload: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": textToSummarize]]
                ]
            ],
            "systemInstruction": [
                "parts": [["text": "You are summarizing a conversation between a user wearing smart glasses and an AI assistant. Provide a very brief, single-paragraph summary of what was discussed or done (max 2 sentences). Write in the language of the conversation."]]
            ],
            "generationConfig": [
                "temperature": 0.3
            ]
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[SessionSummarizer] HTTP Error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            print("[SessionSummarizer] Request failed: \(error)")
            return nil
        }
    }
}
