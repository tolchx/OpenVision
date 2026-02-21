// OpenVision - GeminiLiveService.swift
// WebSocket client for Google Gemini Live API with native audio
// Architecture based on VisionClaw's proven working implementation

import Foundation
import AVFoundation

/// Gemini Live WebSocket Service
///
/// Connects to Gemini Live API for real-time voice + vision AI.
/// Handles bidirectional audio streaming and video frame transmission.
///
/// Key architectural decisions (matching VisionClaw):
/// - Uses URLSessionWebSocketDelegate for proper connection lifecycle
/// - Sends setup inside onOpen callback (not via polling)
/// - Uses dedicated sendQueue for thread-safe message sending
/// - Sends JSON as .string (not .data)
@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Configuration

    private var apiKey: String {
        SettingsManager.shared.settings.geminiAPIKey
    }

    private var videoFPS: Int {
        SettingsManager.shared.settings.geminiVideoFPS
    }

    // MARK: - Callbacks

    var onTextReceived: ((String) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - WebSocket

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let delegate = WebSocketDelegate()
    private var receiveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?

    /// Dedicated queue for sending messages (thread safety)
    private let sendQueue = DispatchQueue(label: "openvision.gemini.send", qos: .userInitiated)

    // MARK: - Video Throttling

    private var lastFrameTime: Date = .distantPast
    private var frameInterval: TimeInterval {
        1.0 / Double(videoFPS)
    }

    // MARK: - Latency Tracking

    private var lastUserSpeechEnd: Date?
    private var responseLatencyLogged = false

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Connection

    /// Connect to Gemini Live API
    /// Returns true if connection + setup succeeded (matches VisionClaw's pattern)
    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw AIBackendError.notConfigured
        }

        guard !connectionState.isUsable else { return }
        guard !connectionState.isAttempting else { return }

        connectionState = .connecting
        onConnectionStateChanged?(connectionState)

        guard let url = buildWebSocketURL() else {
            throw AIBackendError.notConfigured
        }

        // Use CheckedContinuation resolved by delegate callbacks (VisionClaw pattern)
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            // Wire delegate callbacks
            self.delegate.onOpen = { [weak self] protocol_ in
                guard let self else { return }
                Task { @MainActor in
                    print("[GeminiLive] WebSocket opened, sending setup...")
                    // Send setup immediately when WS is truly open
                    self.sendSetupMessage()
                    self.startReceiving()
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                print("[GeminiLive] WebSocket closed: code=\(code.rawValue), reason=\(reasonStr)")
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.connectionState = .disconnected
                    self.isModelSpeaking = false
                    self.onConnectionStateChanged?(self.connectionState)
                    self.onDisconnected?()
                }
            }

            self.delegate.onError = { [weak self] error in
                guard let self else { return }
                let msg = error?.localizedDescription ?? "Unknown error"
                print("[GeminiLive] WebSocket error: \(msg)")
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.lastError = msg
                    self.connectionState = .failed(msg)
                    self.isModelSpeaking = false
                    self.onConnectionStateChanged?(self.connectionState)
                    self.onDisconnected?()
                }
            }

            // Create and resume WebSocket task
            self.webSocketTask = self.urlSession?.webSocketTask(with: url)
            self.webSocketTask?.resume()

            // Timeout after 15 seconds
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    if self.connectionState == .connecting {
                        print("[GeminiLive] Connection timed out")
                        self.resolveConnect(success: false)
                        self.connectionState = .failed("Connection timed out")
                        self.onConnectionStateChanged?(self.connectionState)
                    }
                }
            }
        }

        guard success else {
            let msg = lastError ?? "Failed to connect"
            closeWebSocket()
            throw AIBackendError.connectionFailed(msg)
        }

        connectionState = .connected
        onConnectionStateChanged?(connectionState)
        print("[GeminiLive] Connected and ready")
    }

    /// Disconnect from Gemini Live
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        print("[GeminiLive] Disconnecting")
        connectionState = .disconnected
        onConnectionStateChanged?(connectionState)
        closeWebSocket()
        onDisconnected?()
    }

    /// Build WebSocket URL
    private func buildWebSocketURL() -> URL? {
        var components = URLComponents(string: Constants.GeminiLive.websocketEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey)
        ]
        return components.url
    }

    /// Resolve the connect continuation (only once)
    private func resolveConnect(success: Bool) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: success)
        }
    }

    /// Close WebSocket without changing state
    private func closeWebSocket() {
        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        // Clear delegate callbacks to avoid retain cycles
        delegate.onOpen = nil
        delegate.onClose = nil
        delegate.onError = nil

        isModelSpeaking = false
        resolveConnect(success: false)
    }

    // MARK: - Setup

    /// Send setup message to configure the session (called from onOpen callback)
    private func sendSetupMessage() {
        let setup: [String: Any] = [
            "setup": [
                "model": Constants.GeminiLive.modelName,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "thinkingConfig": [
                        "thinkingBudget": 0
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": buildSystemPrompt()]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "prefixPaddingMs": 40,
                        "silenceDurationMs": 500
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT"
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any]
            ]
        ]

        sendJSON(setup)
    }

    /// Build system prompt
    private func buildSystemPrompt() -> String {
        var prompt = """
        You are a helpful AI assistant integrated with smart glasses. You can see what the user sees through their glasses camera.

        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        If the user asks you to do something beyond your capabilities, explain what you can help with instead.
        """

        // Add user's custom instructions
        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

        // Add memories
        let memories = SettingsManager.shared.settings.memories
        if !memories.isEmpty {
            prompt += "\n\nThings to remember about the user:"
            for (key, value) in memories {
                prompt += "\n- \(key): \(value)"
            }
        }

        return prompt
    }

    // MARK: - Send Audio

    /// Send audio data to Gemini
    func sendAudio(data: Data) {
        guard connectionState.isUsable, !isModelSpeaking else { return }

        sendQueue.async { [weak self] in
            let message: [String: Any] = [
                "realtimeInput": [
                    "audio": [
                        "mimeType": "audio/pcm;rate=\(Constants.GeminiLive.inputSampleRate)",
                        "data": data.base64EncodedString()
                    ]
                ]
            ]
            self?.sendJSON(message)
        }
    }

    /// Notify that user stopped speaking
    func userStoppedSpeaking() {
        lastUserSpeechEnd = Date()
    }

    /// Send text message to Gemini
    func sendText(_ text: String) async throws {
        guard connectionState.isUsable else {
            throw AIBackendError.notConnected
        }

        let message: [String: Any] = [
            "clientContent": [
                "turns": [
                    [
                        "role": "user",
                        "parts": [["text": text]]
                    ]
                ],
                "turnComplete": true
            ]
        ]

        sendJSON(message)
    }

    /// Interrupt the AI (barge-in support)
    func interrupt() async {
        // Send interrupt signal if model is speaking
        guard isModelSpeaking else { return }

        isModelSpeaking = false
        isProcessing = false
        print("[GeminiLive] Interrupted")
    }

    // MARK: - Send Video

    /// Send video frame to Gemini (throttled)
    func sendVideoFrame(imageData: Data) {
        guard connectionState.isUsable else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        sendQueue.async { [weak self] in
            let message: [String: Any] = [
                "realtimeInput": [
                    "video": [
                        "mimeType": "image/jpeg",
                        "data": imageData.base64EncodedString()
                    ]
                ]
            ]
            self?.sendJSON(message)
        }
    }

    // MARK: - Send JSON

    /// Send JSON message as string (matching VisionClaw)
    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask?.send(.string(string)) { error in
            if let error = error {
                print("[GeminiLive] Send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive Loop

    /// Start receiving messages
    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let task = self.webSocketTask else { break }

                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[GeminiLive] Receive error: \(error.localizedDescription)")
                        await MainActor.run {
                            self.resolveConnect(success: false)
                            self.connectionState = .disconnected
                            self.isModelSpeaking = false
                            self.onConnectionStateChanged?(self.connectionState)
                            self.onDisconnected?()
                        }
                    }
                    break
                }
            }
        }
    }

    /// Handle incoming message (string-based, matching VisionClaw)
    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Setup complete
        if json["setupComplete"] != nil {
            print("[GeminiLive] Setup complete")
            resolveConnect(success: true)
            return
        }

        // Go away (server closing connection)
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            let seconds = timeLeft?["seconds"] as? Int ?? 0
            print("[GeminiLive] Server closing (time left: \(seconds)s)")
            connectionState = .disconnected
            isModelSpeaking = false
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any] {
            handleToolCall(toolCall)
            return
        }

        // Error from server
        if let error = json["error"] as? [String: Any] {
            print("[GeminiLive] Server error: \(error)")
            connectionState = .disconnected
            isModelSpeaking = false
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }

        // Server content (audio, text, transcription, etc.)
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
            return
        }
    }

    /// Handle server content
    private func handleServerContent(_ content: [String: Any]) {
        // Check if interrupted
        if content["interrupted"] as? Bool == true {
            isModelSpeaking = false
            isProcessing = false
            return
        }

        // Model turn (audio + text)
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                // Audio data
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.hasPrefix("audio/pcm"),
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {

                    // Track latency for first audio
                    if !isModelSpeaking {
                        isModelSpeaking = true
                        if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                            let latency = Date().timeIntervalSince(speechEnd) * 1000
                            print("[GeminiLive] Latency: \(Int(latency))ms")
                            responseLatencyLogged = true
                        }
                    }

                    isProcessing = true
                    onAudioReceived?(audioData)
                }

                // Text (output transcription in parts)
                if let text = part["text"] as? String {
                    onOutputTranscription?(text)
                }
            }
        }

        // Turn complete
        if content["turnComplete"] as? Bool == true {
            isModelSpeaking = false
            isProcessing = false
            responseLatencyLogged = false
            onTurnComplete?()
        }

        // Input transcription (user's speech)
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            lastUserSpeechEnd = Date()
            responseLatencyLogged = false
            onInputTranscription?(text)
        }

        // Output transcription
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String, !text.isEmpty {
            onOutputTranscription?(text)
        }
    }

    /// Handle tool call
    private func handleToolCall(_ toolCall: [String: Any]) {
        // For future: route tool calls to OpenClaw
        print("[GeminiLive] Tool call received: \(toolCall)")
    }
}

// MARK: - WebSocket Delegate

/// Proper URLSessionWebSocketDelegate for connection lifecycle management
/// (VisionClaw pattern - replaces unreliable .state polling)
private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(`protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onError?(error)
        }
    }
}
