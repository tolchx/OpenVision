// OpenVision - GeminiLiveService.swift
// WebSocket client for Google Gemini Live API with native audio
// Architecture based on VisionClaw's proven working implementation

import Foundation
import AVFoundation

/// Gemini Live WebSocket Service
///
/// Connects to Gemini Live API for real-time voice + vision AI.
/// Handles bidirectional audio streaming and video frame transmission.
@MainActor
final class GeminiLiveService: ObservableObject {
    // MARK: - Singleton

    static let shared = GeminiLiveService()

    // MARK: - Published State

    @Published var connectionState: AIConnectionState = .disconnected
    @Published var isProcessing: Bool = false
    @Published var isModelSpeaking: Bool = false
    @Published var lastError: String?

    // MARK: - Debug Logging

    private let log = DebugLogManager.shared

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

    // MARK: - Audio send tracking

    private var audioSendCount = 0

    // MARK: - Initialization

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Connection

    /// Connect to Gemini Live API
    func connect() async throws {
        guard !apiKey.isEmpty else {
            log.log("API key is empty", source: "GeminiLive", level: .error)
            throw AIBackendError.notConfigured
        }

        guard !connectionState.isUsable else {
            log.log("Already connected, skipping", source: "GeminiLive", level: .warning)
            return
        }
        guard !connectionState.isAttempting else {
            log.log("Connection already in progress", source: "GeminiLive", level: .warning)
            return
        }

        connectionState = .connecting
        onConnectionStateChanged?(connectionState)
        audioSendCount = 0

        guard let url = buildWebSocketURL() else {
            log.log("Failed to build WebSocket URL", source: "GeminiLive", level: .error)
            throw AIBackendError.notConfigured
        }

        log.log("Connecting to \(url.host ?? "unknown")...", source: "GeminiLive", level: .network)
        log.log("Model: \(Constants.GeminiLive.modelName)", source: "GeminiLive", level: .info)
        log.log("API key: \(String(apiKey.prefix(8)))...", source: "GeminiLive", level: .debug)

        // Use CheckedContinuation resolved by delegate callbacks (VisionClaw pattern)
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            // Wire delegate callbacks
            self.delegate.onOpen = { [weak self] protocol_ in
                guard let self else { return }
                Task { @MainActor in
                    self.log.log("WebSocket OPEN (protocol: \(protocol_ ?? "none"))", source: "WebSocket", level: .success)
                    self.sendSetupMessage()
                    self.startReceiving()
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                Task { @MainActor in
                    self.log.log("WebSocket CLOSED: code=\(code.rawValue), reason=\(reasonStr)", source: "WebSocket", level: .warning)
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
                Task { @MainActor in
                    self.log.log("WebSocket ERROR: \(msg)", source: "WebSocket", level: .error)
                    if let nsErr = error as NSError? {
                        self.log.log("  domain=\(nsErr.domain) code=\(nsErr.code)", source: "WebSocket", level: .error)
                    }
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
            self.log.log("WebSocket task created and resumed", source: "WebSocket", level: .debug)

            // Timeout after 15 seconds
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    if self.connectionState == .connecting {
                        self.log.log("Connection TIMEOUT (15s)", source: "GeminiLive", level: .error)
                        self.resolveConnect(success: false)
                        self.connectionState = .failed("Connection timed out")
                        self.onConnectionStateChanged?(self.connectionState)
                    }
                }
            }
        }

        guard success else {
            let msg = lastError ?? "Failed to connect"
            log.log("Connect failed: \(msg)", source: "GeminiLive", level: .error)
            closeWebSocket()
            throw AIBackendError.connectionFailed(msg)
        }

        connectionState = .connected
        onConnectionStateChanged?(connectionState)
        log.log("✅ Connected and ready!", source: "GeminiLive", level: .success)
    }

    /// Disconnect from Gemini Live
    func disconnect() async {
        guard connectionState != .disconnected else { return }

        log.log("Disconnecting (sent \(audioSendCount) audio chunks)", source: "GeminiLive", level: .info)
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

        delegate.onOpen = nil
        delegate.onClose = nil
        delegate.onError = nil

        isModelSpeaking = false
        resolveConnect(success: false)
    }

    // MARK: - Setup

    /// Send setup message to configure the session (called from onOpen callback)
    private func sendSetupMessage() {
        log.log("Sending setup message...", source: "GeminiLive", level: .network)

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
        log.log("Setup message sent", source: "GeminiLive", level: .debug)
    }

    /// Build system prompt
    private func buildSystemPrompt() -> String {
        var prompt = """
        You are a helpful AI assistant integrated with smart glasses. You can see what the user sees through their glasses camera.

        Keep responses concise and conversational - the user is wearing glasses and expects quick, natural interactions.

        If the user asks you to do something beyond your capabilities, explain what you can help with instead.
        """

        let userPrompt = SettingsManager.shared.settings.userPrompt
        if !userPrompt.isEmpty {
            prompt += "\n\nAdditional instructions from user:\n\(userPrompt)"
        }

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

        audioSendCount += 1
        if audioSendCount <= 3 || audioSendCount % 50 == 0 {
            log.log("Sending audio chunk #\(audioSendCount): \(data.count) bytes", source: "Audio", level: .audio)
        }

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

        log.log("Sending text: \(text.prefix(50))...", source: "GeminiLive", level: .info)

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
        guard isModelSpeaking else { return }

        isModelSpeaking = false
        isProcessing = false
        log.log("Interrupted model", source: "GeminiLive", level: .info)
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
            Task { @MainActor in
                self.log.log("Failed to serialize JSON", source: "GeminiLive", level: .error)
            }
            return
        }
        webSocketTask?.send(.string(string)) { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.log.log("Send error: \(error.localizedDescription)", source: "WebSocket", level: .error)
                }
            }
        }
    }

    // MARK: - Receive Loop

    /// Start receiving messages
    private func startReceiving() {
        log.log("Starting receive loop", source: "WebSocket", level: .debug)

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
                        await MainActor.run {
                            self.log.log("Receive loop error: \(error.localizedDescription)", source: "WebSocket", level: .error)
                            if let nsErr = error as NSError? {
                                self.log.log("  domain=\(nsErr.domain) code=\(nsErr.code)", source: "WebSocket", level: .error)
                            }
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

    /// Handle incoming message (string-based)
    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.log("Failed to parse JSON message", source: "GeminiLive", level: .error)
            return
        }

        // Setup complete
        if json["setupComplete"] != nil {
            log.log("✅ Setup complete — session ready", source: "GeminiLive", level: .success)
            resolveConnect(success: true)
            return
        }

        // Go away (server closing)
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            let seconds = timeLeft?["seconds"] as? Int ?? 0
            log.log("Server GoAway (time left: \(seconds)s)", source: "GeminiLive", level: .warning)
            connectionState = .disconnected
            isModelSpeaking = false
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }

        // Tool call
        if let toolCall = json["toolCall"] as? [String: Any] {
            log.log("Tool call received", source: "GeminiLive", level: .info)
            handleToolCall(toolCall)
            return
        }

        // Error from server
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "unknown"
            let status = error["status"] as? String ?? "unknown"
            log.log("Server ERROR: code=\(code) status=\(status) msg=\(message)", source: "GeminiLive", level: .error)
            connectionState = .disconnected
            isModelSpeaking = false
            onConnectionStateChanged?(connectionState)
            onDisconnected?()
            return
        }

        // Server content
        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
            return
        }

        // Unknown message — log it for debugging
        let keys = Array(json.keys).joined(separator: ", ")
        log.log("Unknown message keys: \(keys)", source: "GeminiLive", level: .debug)
    }

    /// Handle server content
    private func handleServerContent(_ content: [String: Any]) {
        // Interrupted
        if content["interrupted"] as? Bool == true {
            log.log("Model interrupted by user", source: "GeminiLive", level: .info)
            isModelSpeaking = false
            isProcessing = false
            return
        }

        // Model turn (audio + text)
        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {

            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.hasPrefix("audio/pcm"),
                   let base64 = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: base64) {

                    if !isModelSpeaking {
                        isModelSpeaking = true
                        log.log("Model started speaking (\(audioData.count) bytes)", source: "GeminiLive", level: .audio)
                        if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
                            let latency = Date().timeIntervalSince(speechEnd) * 1000
                            log.log("Response latency: \(Int(latency))ms", source: "GeminiLive", level: .info)
                            responseLatencyLogged = true
                        }
                    }

                    isProcessing = true
                    onAudioReceived?(audioData)
                }

                if let text = part["text"] as? String {
                    onOutputTranscription?(text)
                }
            }
        }

        // Turn complete
        if content["turnComplete"] as? Bool == true {
            log.log("Turn complete", source: "GeminiLive", level: .info)
            isModelSpeaking = false
            isProcessing = false
            responseLatencyLogged = false
            onTurnComplete?()
        }

        // Input transcription
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String, !text.isEmpty {
            log.log("User: \(text)", source: "GeminiLive", level: .info)
            lastUserSpeechEnd = Date()
            responseLatencyLogged = false
            onInputTranscription?(text)
        }

        // Output transcription
        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String, !text.isEmpty {
            log.log("AI: \(text)", source: "GeminiLive", level: .info)
            onOutputTranscription?(text)
        }
    }

    /// Handle tool call
    private func handleToolCall(_ toolCall: [String: Any]) {
        log.log("Tool call: \(toolCall)", source: "GeminiLive", level: .info)
    }
}

// MARK: - WebSocket Delegate

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
