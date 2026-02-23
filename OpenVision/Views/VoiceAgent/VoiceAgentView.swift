// OpenVision - VoiceAgentView.swift
// Beautiful main voice conversation UI with glassmorphism design

import SwiftUI
import Speech
import PhotosUI
import NaturalLanguage

struct VoiceAgentView: View {
    // MARK: - Environment

    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var glassesManager: GlassesManager
    @EnvironmentObject var conversationManager: ConversationManager

    // MARK: - App State

    @Binding var isMenuOpen: Bool

    // MARK: - Services

    @StateObject private var voiceCommandService = VoiceCommandService.shared
    @StateObject private var geminiVision = GeminiVisionService.shared
    @StateObject private var geminiLive = GeminiLiveService.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var soundService = SoundService.shared
    @StateObject private var audioCapture = AudioCaptureService()
    @StateObject private var audioPlayback = AudioPlaybackService()
    @StateObject private var notificationManager = NotificationManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    // MARK: - State

    @State private var isSessionActive = false
    @State private var agentState: AgentState = .idle
    @State private var userTranscript = ""
    @State private var aiTranscript = ""
    @State private var currentToolName: String?
    @State private var errorMessage: String?
    @State private var audioLevel: CGFloat = 0
    @State private var hasRequestedSpeechAuth = false

    /// Live Video Mode - uses Gemini Live for real-time audio + video
    @State private var isLiveVideoMode = false

    /// Describe Scene timer — periodically asks Gemini to describe what the glasses see
    @State private var describeSceneTimer: Timer?
    /// Tracks when the last user interaction happened (to detect silence)
    @State private var lastInteractionTime = Date()

    /// True when voice recognition is ready (audio engine running)
    @State private var isVoiceReady = false


    /// Text input for manual chatting
    @State private var inputText = ""
    
    /// Photo attachment
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?

    // MARK: - Agent State
    
    /// Context from a recently taken screenshot, ready to be injected to the next command
    @State private var ocrContext: String? = nil
    
    /// Haptic feedback state
    @State private var hasPlayedResponseHaptic = false

    enum AgentState: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case toolRunning
        case liveVideo  // Live video mode - Gemini handles audio + video

        var displayText: String {
            switch self {
            case .idle: return "Tap to start"
            case .connecting: return "Connecting..."
            case .listening: return "Listening..."
            case .thinking: return "Thinking..."
            case .speaking: return "Speaking..."
            case .toolRunning: return "Running tool..."
            case .liveVideo: return "Live Video"
            }
        }

        var accentColor: Color {
            switch self {
            case .idle: return .gray
            case .connecting: return .orange
            case .listening: return .blue
            case .thinking: return .purple
            case .speaking: return .green
            case .toolRunning: return .orange
            case .liveVideo: return .red  // Red for live video recording indicator
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar
                .padding(.top, 8)
                .padding(.bottom, 8)

            // Chat history takes up the entire center
            chatHistory
                
            // Text Input Box & Compact Mic
            textInputBox
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
        .background(
            ZStack {
                // Beautiful animated background
                AnimatedBackground()

                // Particle effects
                ParticleEffect(particleCount: 30)
                    .opacity(0.5)
            }
            .ignoresSafeArea()
        )
        .overlay(
            Group {
                // Error overlay
                if let error = errorMessage {
                    errorOverlay(error)
                }
            }
        )
        .animation(.spring(response: 0.4), value: agentState)
        .animation(.spring(response: 0.4), value: userTranscript)
        .animation(.spring(response: 0.4), value: aiTranscript)

        .onAppear {
            setupVoiceCommandService()
            setupGlassesCallbacks()
            
            // Start listening for CoreLocation updates
            LocationManager.shared.requestLocation()
            LocationManager.shared.startTracking()
            
            // Request Notification Permissions
            notificationManager.requestAuthorization()
        }
        .onDisappear {
            voiceCommandService.stopListening()
        }
        .task {
            await requestSpeechAuthorization()
        }
        // Observe screenshot notifications
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            handleScreenshotTaken()
        }
        // Observe TTS state changes
        .onChange(of: ttsService.isSpeaking) { isSpeaking in
            if isSpeaking {
                agentState = .speaking
                // Pause barge-in detection while TTS is playing
                // (prevents microphone picking up TTS and triggering interruption)
                voiceCommandService.isBargeInPaused = true
            } else {
                // Resume barge-in detection
                voiceCommandService.isBargeInPaused = false

                if isSessionActive {
                    agentState = .listening
                    voiceCommandService.enterConversationMode()
                } else {
                    agentState = .idle
                }
            }
        }
        // Control thinking sound based on agent state
        .onChange(of: agentState) { newState in
            if newState == .thinking || newState == .toolRunning {
                soundService.startThinkingSound()
            } else {
                soundService.stopThinkingSound()
            }
        }
        // Observe VoiceCommandService state changes
        .onChange(of: voiceCommandService.state) { newState in
            print("[VoiceAgentView] VoiceCommandService state changed to: \(newState)")
            switch newState {
            case .idle:
                // In Gemini Live mode, pauseForGeminiLive() sets state to .idle
                // — do NOT disconnect! The session is still active.
                if isLiveVideoMode || voiceCommandService.isPausedForGemini {
                    print("[VoiceAgentView] Voice idle but in Gemini Live mode, keeping session")
                    return
                }
                // Conversation ended, return to idle (OpenClaw mode)
                if isSessionActive {
                    print("[VoiceAgentView] Voice service idle, stopping session")
                    isSessionActive = false
                    agentState = .idle
                    // Disconnect AI backend
                    Task {
                        switch settingsManager.settings.aiBackend {
                        case .openClaw:
                            await OpenClawService.shared.disconnect()
                        case .geminiLive:
                            await GeminiLiveService.shared.disconnect()
                        }
                    }
                }
            case .listening:
                if isSessionActive {
                    agentState = .listening
                }
            case .conversationMode:
                if isSessionActive {
                    agentState = .listening
                }
            case .processing:
                agentState = .thinking
            }
        }
        // Observe Network changes to fallback gracefully during active sessions
        .onChange(of: networkMonitor.isConnected) { isConnected in
            if !isConnected && isSessionActive {
                print("[VoiceAgentView] Network lost during active session. Switching to offline mode.")
                if isLiveVideoMode {
                    Task { await stopLiveVideoMode() }
                }
                ttsService.speak("Network connection lost. I am now operating in offline mode.")
            } else if isConnected && isSessionActive {
                print("[VoiceAgentView] Network restored. Returning to cloud mode.")
                ttsService.speak("Network connection restored. Cloud mode active.")
                OfflineLMService.shared.unloadToFreeMemory()
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Hamburger Menu Button
            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isMenuOpen.toggle()
                }
            }) {
                Image(systemName: "line.3.horizontal")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }

            Spacer()
            
            // AI Backend status (or Live Video indicator)
            if isLiveVideoMode {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        
                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.red.opacity(0.8)))
            } else {
                StatusPill(
                    status: settingsManager.settings.aiBackend.displayName,
                    color: agentState == .idle ? .gray : .green,
                    isConnected: agentState != .idle && agentState != .connecting
                )
            }

            Spacer()

            // Top bar (glasses status + token counter)
            HStack(spacing: 12) {
                // Translator Toggle
                Button(action: {
                    withAnimation {
                        settingsManager.settings.isTranslationModeActive.toggle()
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    }
                }) {
                    Image(systemName: settingsManager.settings.isTranslationModeActive ? "globe.americas.fill" : "globe")
                        .foregroundColor(settingsManager.settings.isTranslationModeActive ? .blue : .white.opacity(0.8))
                        .font(.system(size: 16, weight: .semibold))
                }
                
                // Debug Notification Test
                Button(action: {
                    notificationManager.scheduleTestNotification(in: 5, title: "Meeting Reminder", body: "Design sync starting in 5 minutes.")
                }) {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.yellow.opacity(0.8))
                        .font(.system(size: 16))
                }
                
                // Tokens
                if conversationManager.approximateTokenCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(conversationManager.approximateTokenCount)")
                            .font(.caption.monospacedDigit())
                    }
                    .foregroundColor(.white.opacity(0.8))
                }
                
                // Glasses
                Image(systemName: "eyeglasses")
                    .foregroundColor(glassesManager.isRegistered ? .green : .white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Chat History

    private var chatHistory: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    // System initialization hints
                    if agentState == .idle && settingsManager.settings.wakeWordEnabled && !isVoiceReady {
                        Text("Initializing voice...")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 40)
                    }

                    // Render existing messages from the conversation manager
                    if let messages = conversationManager.currentConversation?.messages {
                        ForEach(messages) { message in
                            ChatMessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    // Render the current active turn (live transcription)
                    if !userTranscript.isEmpty || !aiTranscript.isEmpty || agentState == .thinking {
                        ActiveTurnBubble(
                            userText: userTranscript,
                            aiText: aiTranscript,
                            isAIStreaming: agentState == .speaking || agentState == .thinking
                        )
                        .id("active_turn")
                    }
                    
                    // Invisible spacer for scrolling
                    Color.clear.frame(height: 1).id("bottomSpacer")
                }
                .padding(.horizontal)
                .padding(.vertical, 20)
            }
            .onChange(of: conversationManager.currentConversation?.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottomSpacer", anchor: .bottom) }
            }
            .onChange(of: userTranscript) { _ in
                withAnimation { proxy.scrollTo("active_turn", anchor: .bottom) }
            }
            .onChange(of: aiTranscript) { _ in
                withAnimation { proxy.scrollTo("active_turn", anchor: .bottom) }
            }
        }
    }
    
    // MARK: - Text Input Box & Compact Mic

    private var textInputBox: some View {
        VStack(spacing: 8) {
            // Selected Photo Preview
            if let photoData = selectedPhotoData, let uiImage = UIImage(data: photoData) {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        
                        Button {
                            selectedPhotoData = nil
                            selectedPhotoItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .offset(x: 5, y: -5)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 12) {
                // Photo Picker
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(selectedPhotoData != nil ? .blue : .white.opacity(0.8))
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                            // Resize image down to reduce payload size (max 800px)
                            if let uiImage = UIImage(data: data) {
                                let maxSize: CGFloat = 800
                                let size = uiImage.size
                                let ratio = min(maxSize/size.width, maxSize/size.height)
                                
                                if ratio < 1.0 {
                                    let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
                                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                                    uiImage.draw(in: CGRect(origin: .zero, size: newSize))
                                    let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
                                    UIGraphicsEndImageContext()
                                    
                                    await MainActor.run {
                                        self.selectedPhotoData = resizedImage?.jpegData(compressionQuality: 0.7)
                                    }
                                } else {
                                    await MainActor.run {
                                        self.selectedPhotoData = uiImage.jpegData(compressionQuality: 0.7)
                                    }
                                }
                            }
                        }
                    }
                }

                // Text Field
            TextField("Message or command...", text: $inputText)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.1))
                .cornerRadius(24)
                .foregroundColor(.white)
                .accentColor(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .onSubmit {
                    submitTextCommand()
                }

            // Text Send Button
            if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: {
                    submitTextCommand()
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .frame(width: 36, height: 36)
                        .foregroundColor(.blue)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                // Compact Microphone Orb
                Button(action: {
                    toggleSession()
                }) {
                    ZStack {
                        Circle()
                            .fill(isSessionActive ? Color.blue.opacity(0.2) : Color.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                        
                        Image(systemName: isSessionActive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(isSessionActive ? .white : .blue)
                            
                        if agentState == .listening || agentState == .thinking {
                            Circle()
                                .stroke(Color.blue.opacity(0.5), lineWidth: 2)
                                .frame(width: 50, height: 50)
                                .scaleEffect(audioLevel > 0.05 ? 1.0 + CGFloat(audioLevel) : 1.0)
                                .animation(.easeOut(duration: 0.1), value: audioLevel)
                        }
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: inputText)
        .animation(.spring(response: 0.3), value: selectedPhotoData)
    }
    
    private func submitTextCommand() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasPhoto = selectedPhotoData != nil
        
        guard !text.isEmpty || hasPhoto else { return }
        
        // Capture data and clear UI
        let commandText = text
        let imageData = selectedPhotoData
        
        inputText = ""
        selectedPhotoItem = nil
        selectedPhotoData = nil
        lastInteractionTime = Date()
        
        // Hide keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        Task {
            // Auto-Start the session if disconnected
            if !isSessionActive {
                print("[VoiceAgentView] Auto-starting session for text input...")
                startSession()
                
                // Wait for the connection to establish (timeout ~10s)
                for _ in 0..<100 {
                    if agentState != .connecting {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
            
            // Wait an extra beat for websocket/engine internals to stabilize
            try? await Task.sleep(nanoseconds: 300_000_000)

            // Process the command as if it was spoken (with optional photo)
            await sendCommand(commandText, imageData: imageData)
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ message: String) -> some View {
        VStack {
            Spacer()

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)

                Spacer()

                Button {
                    errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.red.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 150)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Chat History Persistence

    /// Persist the current live turn (user transcript + AI transcript) into 
    /// ConversationManager so it becomes a permanent chat bubble.
    /// Called when Gemini signals `onTurnComplete`.
    private func persistCompletedTurn() {
        let user = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let ai   = aiTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Save user message if present (voice-captured turns)
        if !user.isEmpty {
            conversationManager.addUserMessage(user)
        }

        // Save AI response if present
        if !ai.isEmpty {
            conversationManager.addAssistantMessage(ai)
        }

        // Clear the live transcripts so the ActiveTurnBubble disappears
        // and the messages now live in the permanent chat history above
        userTranscript = ""
        aiTranscript = ""

        // Reset interaction time (so describe scene timer knows conversation is active)
        lastInteractionTime = Date()
    }

    // MARK: - Describe Scene Timer

    /// How many seconds of silence before triggering a scene description
    private static let describeSceneSilenceThreshold: TimeInterval = 30

    /// Start the periodic describe scene timer (runs every 10s, checks silence threshold)
    private func startDescribeSceneTimer() {
        stopDescribeSceneTimer()
        lastInteractionTime = Date()

        describeSceneTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak geminiLive, weak glassesManager] _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      self.isLiveVideoMode,
                      let geminiLive = geminiLive,
                      geminiLive.connectionState.isUsable,
                      !geminiLive.isModelSpeaking,
                      !geminiLive.isProcessing else { return }

                let silenceDuration = Date().timeIntervalSince(self.lastInteractionTime)
                guard silenceDuration >= Self.describeSceneSilenceThreshold else { return }

                // Send the latest camera frame for context
                if let lastFrame = glassesManager?.lastFrame,
                   let jpegData = lastFrame.jpegData(compressionQuality: 0.6) {
                    geminiLive.sendVideoFrame(imageData: jpegData)
                }

                // Ask Gemini to describe the scene
                try? await geminiLive.sendText("[DESCRIBE_SCENE]")
                self.lastInteractionTime = Date() // Reset so it doesn't spam
                DebugLogManager.shared.log("Describe Scene triggered (silence: \(Int(silenceDuration))s)", source: "DescribeScene", level: .info)
            }
        }
        print("[VoiceAgentView] Describe Scene timer started (threshold: \(Self.describeSceneSilenceThreshold)s)")
    }

    /// Stop the describe scene timer
    private func stopDescribeSceneTimer() {
        describeSceneTimer?.invalidate()
        describeSceneTimer = nil
    }

    // MARK: - Actions

    private func toggleSession() {
        if isSessionActive {
            stopSession()
        } else {
            startSession()
        }
    }

    private func startSession() {
        // Check configuration
        guard settingsManager.settings.isCurrentBackendConfigured else {
            errorMessage = "Please configure \(settingsManager.settings.aiBackend.displayName) in Settings"
            return
        }

        isSessionActive = true
        agentState = .connecting
        notificationManager.isSessionActive = true

        // Configure audio routing for glasses if registered
        configureAudioForGlasses()

        // Connect to AI backend
        Task {
            do {
                switch settingsManager.settings.aiBackend {
                case .openClaw:
                    try await OpenClawService.shared.connect()
                    // Note: Streaming NOT auto-started in OpenClaw mode
                    // User says "start video stream" → startLiveVideoMode()
                    // User says "take a photo" → captureAndSendPhoto() starts streaming on-demand

                case .geminiLive:
                    // Setup audio session for voiceChat mode (iPhone mic)
                    // This mirrors VisionClaw's AudioManager.setupAudioSession()
                    try AudioSessionManager.shared.configure(for: .voiceChat)

                    // Start VoiceCommandService engine if not already running
                    // The engine provides the mic tap that feeds audio to Gemini
                    if !voiceCommandService.isListening {
                        if voiceCommandService.authorizationStatus == .authorized {
                            try voiceCommandService.startListening(with: audioPlayback.playerNodeForInjection)
                        } else {
                            errorMessage = "Speech recognition not authorized"
                            isSessionActive = false
                            agentState = .idle
                            return
                        }
                    }

                    // Connect to Gemini Live WebSocket
                    try await geminiLive.connect()

                    // Setup callbacks for audio/transcription
                    setupGeminiLiveCallbacks()

                    // Setup audio playback for Gemini responses using the shared engine
                    do {
                        try audioPlayback.setup(with: voiceCommandService.activeEngine)
                    } catch {
                        print("[VoiceAgentView] Audio playback setup failed: \(error)")
                    }

                    // Redirect audio engine to Gemini
                    audioCapture.onAudioCaptured = { [weak geminiLive] data in
                        geminiLive?.sendAudio(data: data)
                    }
                    voiceCommandService.pauseForGeminiLive { buffer in
                        self.audioCapture.processExternalBuffer(buffer, nativeFormat: buffer.format)
                    }

                    isLiveVideoMode = true

                    // Start glasses video streaming if available (optional enhancement)
                    if glassesManager.isRegistered {
                        if !glassesManager.isStreaming {
                            await glassesManager.startStreaming()
                        }
                        glassesManager.onVideoFrame = { [weak geminiLive] image in
                            if let jpegData = image.jpegData(compressionQuality: 0.6) {
                                geminiLive?.sendVideoFrame(imageData: jpegData)
                            }
                        }
                    }
                }

                agentState = isLiveVideoMode ? .liveVideo : .listening
                userTranscript = ""
                aiTranscript = ""

                // Start voice command listening for speech capture (OpenClaw mode only)
                if settingsManager.settings.aiBackend == .openClaw {
                    if voiceCommandService.authorizationStatus == .authorized {
                        if !voiceCommandService.isListening {
                            try? voiceCommandService.startListening()
                        }
                        voiceCommandService.enterConversationMode()
                    } else {
                        errorMessage = "Speech recognition not authorized"
                    }
                }

            } catch {
                errorMessage = "Failed to connect: \(error.localizedDescription)"
                isSessionActive = false
                agentState = .idle
            }
        }
    }

    /// Configure audio routing to use glasses mic/speaker if available
    private func configureAudioForGlasses() {
        guard glassesManager.isRegistered else {
            print("[VoiceAgentView] Glasses not registered, using iPhone audio")
            return
        }

        // Stop listening temporarily if already active
        let wasListening = voiceCommandService.isListening
        if wasListening {
            voiceCommandService.stopListening()
        }

        do {
            try AudioSessionManager.shared.configureForGlasses()
            let route = AudioSessionManager.shared.currentRouteDescription
            print("[VoiceAgentView] Audio configured: \(route)")

            if AudioSessionManager.shared.isBluetoothHFPActive {
                print("[VoiceAgentView] ✓ Using glasses audio (Bluetooth HFP)")
            } else {
                print("[VoiceAgentView] ⚠ Bluetooth HFP not active, check glasses connection")
            }
        } catch {
            print("[VoiceAgentView] Failed to configure audio for glasses: \(error)")
            // Continue anyway - will fall back to iPhone audio
        }

        // Restart listening with new audio configuration
        if wasListening {
            do {
                try voiceCommandService.startListening()
                print("[VoiceAgentView] Restarted listening with new audio config")
            } catch {
                print("[VoiceAgentView] Failed to restart listening: \(error)")
            }
        }
    }

    private func stopSession() {
        // If in live video mode, stop it first
        if isLiveVideoMode {
            Task {
                await stopLiveVideoMode()
            }
        }

        Task {
            switch settingsManager.settings.aiBackend {
            case .openClaw:
                await OpenClawService.shared.disconnect()
            case .geminiLive:
                await GeminiLiveService.shared.disconnect()
            }

            // Stop glasses streaming (turns off LED)
            if glassesManager.isStreaming {
                print("[VoiceAgentView] Stopping glasses stream...")
                await glassesManager.stopStreaming()
            }
        }

        // Stop any ongoing TTS
        ttsService.stop()

        // Set session inactive FIRST to prevent callbacks from processing
        isSessionActive = false
        agentState = .idle
        notificationManager.isSessionActive = false

        // Handle voice command service based on wake word setting
        if settingsManager.settings.wakeWordEnabled {
            // Exit conversation mode but keep listening for wake word
            voiceCommandService.exitConversationMode()
        } else {
            // Wake word disabled - stop listening entirely to prevent
            // processing speech after session ends
            voiceCommandService.stopListening()
        }
        userTranscript = ""
        aiTranscript = ""
        currentToolName = nil
        isLiveVideoMode = false
    }

    private func capturePhoto() {
        Task {
            if glassesManager.isStreaming {
                await glassesManager.capturePhoto()
            } else {
                // Use iPhone camera fallback
                // TODO: Implement iPhone camera capture
            }
        }
    }

    // MARK: - Voice Command Setup

    /// Request speech recognition authorization
    private func requestSpeechAuthorization() async {
        guard !hasRequestedSpeechAuth else { return }
        hasRequestedSpeechAuth = true

        let authorized = await voiceCommandService.requestAuthorization()
        if authorized {
            print("[VoiceAgentView] Speech recognition authorized")
            startWakeWordListening()
        } else {
            print("[VoiceAgentView] Speech recognition not authorized")
            errorMessage = "Speech recognition not authorized. Please enable in Settings."
        }
    }

    /// Setup voice command service callbacks
    private func setupVoiceCommandService() {
        print("[VoiceAgentView] Setting up voice command callbacks")

        // Local speech transcription during Gemini Live mode
        // Shows what the user is saying in real-time in the chat
        voiceCommandService.onLocalTranscription = { text in
            Task { @MainActor in
                self.userTranscript = text
                self.lastInteractionTime = Date()
            }
        }

        // Allow wake word to interrupt TTS (for "ok vision stop")
        voiceCommandService.shouldAllowInterrupt = { [weak ttsService] in
            return ttsService?.isSpeaking ?? false
        }

        // Wake word detected
        voiceCommandService.onWakeWordDetected = {
            print("[VoiceAgentView] Wake word detected!")
            HapticFeedback.medium()
            self.soundService.playWakeWordSound()

            // If TTS is speaking, stop it immediately (interrupt)
            if self.ttsService.isSpeaking {
                print("[VoiceAgentView] Stopping TTS due to wake word interrupt")
                self.ttsService.stop()
                self.audioPlayback.stop()
                self.agentState = .listening
            }

            // Auto-start session if not already active (use Task to avoid blocking)
            Task { @MainActor in
                if !self.isSessionActive && self.settingsManager.settings.isCurrentBackendConfigured {
                    print("[VoiceAgentView] Starting session from wake word...")
                    self.startSession()
                }
            }
        }

        // Command captured
        voiceCommandService.onCommandCaptured = { (command: String) in
            print("[VoiceAgentView] Command captured: \(command)")

            // IMPORTANT: Only process commands when session is active
            // This prevents processing stale commands after session ends
            guard self.isSessionActive else {
                print("[VoiceAgentView] Ignoring command - session not active")
                return
            }

            self.userTranscript = command

            // Persist user message to chat history
            self.conversationManager.addUserMessage(command)

            // Send command to AI backend
            Task {
                await self.sendCommand(command)
            }
        }

        // Barge-in (user interrupts AI)
        voiceCommandService.onInterruption = {
            print("[VoiceAgentView] Barge-in detected")

            // Stop TTS immediately
            self.ttsService.stop()

            // Stop current AI response
            Task {
                switch self.settingsManager.settings.aiBackend {
                case .openClaw:
                    await OpenClawService.shared.interrupt()
                case .geminiLive:
                    await GeminiLiveService.shared.interrupt()
                }
            }
        }

        // Conversation timeout (user didn't speak after AI response)
        voiceCommandService.onConversationTimeout = {
            print("[VoiceAgentView] Conversation timeout - returning to idle")
            
            // Do not stop the entire session explicitly if we are in live video mode,
            // because the user might just be typing text or looking around.
            if !self.isLiveVideoMode {
                self.stopSession()
            }
        }

        // Setup AI service callbacks for responses
        setupAIServiceCallbacks()

        print("[VoiceAgentView] Voice command callbacks setup complete")
    }

    /// Play a subtle haptic when AI responds
    private func playResponseHapticIfNeeded() {
        if !hasPlayedResponseHaptic {
            hasPlayedResponseHaptic = true
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    /// Setup AI service callbacks for receiving responses
    private func setupAIServiceCallbacks() {
        // OpenClaw callbacks
        OpenClawService.shared.onAgentMessage = { (message: String) in
            print("[VoiceAgentView] Received AI message: \(message.prefix(50))...")
            
            // Play haptic on first token/chunk
            self.playResponseHapticIfNeeded()

            // IMPORTANT: Only speak responses when session is active
            // This prevents speaking stale responses after session ends
            guard self.isSessionActive else {
                print("[VoiceAgentView] Ignoring AI message - session not active")
                return
            }

            self.aiTranscript = message

            // Persist AI response to chat history
            self.conversationManager.addAssistantMessage(message)

            // Speak the response via TTS
            self.speakResponse(message)
            // Note: agentState will be set to .speaking by TTS callback
            // and back to .listening when TTS ends
        }

        OpenClawService.shared.onProcessingChanged = { (isProcessing: Bool) in
            print("[VoiceAgentView] Processing changed: \(isProcessing)")
            if isProcessing {
                self.agentState = .thinking
            } else if self.agentState == .thinking && !self.ttsService.isSpeaking {
                // Only go to listening if not speaking
                self.agentState = self.isSessionActive ? .listening : .idle
            }
        }

        OpenClawService.shared.onToolStatusChanged = { (toolName: String?, isRunning: Bool) in
            print("[VoiceAgentView] Tool status: \(toolName ?? "none"), running: \(isRunning)")
            self.currentToolName = toolName
            if isRunning {
                self.agentState = .toolRunning
            }
        }

        // Handle tool calls (e.g., take_photo)
        OpenClawService.shared.onToolCall = { (toolName: String, args: [String: Any], completion: @escaping (String) -> Void) in
            print("[VoiceAgentView] Tool call: \(toolName) with args: \(args)")

            switch toolName {
            case "take_photo", "capture_photo", "take_picture":
                // Capture photo from glasses
                Task { @MainActor in
                    await self.handleTakePhotoTool(completion: completion)
                }

            case "describe_scene", "what_do_you_see", "look":
                // Query Gemini Vision for scene description
                Task { @MainActor in
                    await self.handleDescribeSceneTool(args: args, completion: completion)
                }
                
            case "store_memory", "remember_this":
                Task { @MainActor in
                    if let text = args["text"] as? String, let loc = LocationManager.shared.location {
                        MemoryManager.shared.storeMemory(text: text, location: loc)
                        completion("[SYSTEM] Memory stored successfully at your current location.")
                    } else {
                        completion("[SYSTEM] Failed to store memory. Ensure location is available and text is provided.")
                    }
                }
            
            case "search_memory", "retrieve_memory", "recall":
                Task { @MainActor in
                    if let query = args["query"] as? String {
                        let results = MemoryManager.shared.searchMemories(query: query)
                        if results.isEmpty {
                            completion("[SYSTEM] No memories found matching '\(query)'")
                        } else {
                            var response = "[SYSTEM] Found memories matching '\(query)':\n"
                            let df = DateFormatter()
                            df.dateStyle = .short
                            for mem in results {
                                response += "- On \(df.string(from: mem.timestamp)): \(mem.text)\n"
                            }
                            completion(response)
                        }
                    } else {
                        completion("[SYSTEM] Please provide a query string to search.")
                    }
                }

            default:
                print("[VoiceAgentView] Unknown tool: \(toolName)")
                completion("Tool '\(toolName)' is not available on this device.")
            }
        }

        // Gemini Live callbacks (for Gemini Live mode, not hybrid)
        GeminiLiveService.shared.onOutputTranscription = { (text: String) in
            self.playResponseHapticIfNeeded()
            self.aiTranscript += text
        }

        GeminiLiveService.shared.onTurnComplete = {
            self.persistCompletedTurn()
            self.agentState = self.isSessionActive ? .listening : .idle
            self.voiceCommandService.enterConversationMode()
        }
    }

    /// Start listening for wake word
    private func startWakeWordListening() {
        guard settingsManager.settings.wakeWordEnabled else { return }
        guard voiceCommandService.authorizationStatus == .authorized else { return }

        // Configure audio for glasses before starting to listen
        configureAudioForGlasses()

        do {
            try voiceCommandService.startListening(with: audioPlayback.playerNodeForInjection)
            isVoiceReady = true
            print("[VoiceAgentView] Started wake word listening - READY")
        } catch {
            print("[VoiceAgentView] Failed to start listening: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    /// Send command to AI backend
    private func sendCommand(_ command: String, imageData: Data? = nil) async {
        let lowerCommand = command.lowercased()

        // Check for "stop" command - stops TTS and waits for next command...
        let stopKeywords = ["stop", "be quiet", "shut up", "silence", "quiet", "enough", "ok stop", "okay stop"]
        let isStopCommand = stopKeywords.contains { lowerCommand.contains($0) } &&
                           !lowerCommand.contains("video") && !lowerCommand.contains("stream")

        if isStopCommand {
            print("[VoiceAgentView] Stop command detected - stopping TTS")
            ttsService.stop()
            audioPlayback.stop()
            Task {
                switch settingsManager.settings.aiBackend {
                case .openClaw: await OpenClawService.shared.interrupt()
                case .geminiLive: await GeminiLiveService.shared.interrupt()
                }
            }
            agentState = .listening
            aiTranscript = ""
            return
        }

        // Check for live video mode commands...
        let startLiveKeywords = ["start video stream", "start live video", "start video", "start streaming", "enable video", "live mode", "go live", "video mode"]
        let stopLiveKeywords = ["stop video stream", "stop live video", "stop video", "stop streaming", "disable video", "end live mode", "exit video mode", "stop live"]

        if startLiveKeywords.contains(where: { lowerCommand.contains($0) }) {
            print("[VoiceAgentView] Starting live video mode...")
            await startLiveVideoMode()
            return
        }

        if stopLiveKeywords.contains(where: { lowerCommand.contains($0) }) {
            print("[VoiceAgentView] Stopping live video mode...")
            await stopLiveVideoMode()
            return
        }

        // If in live video mode, Gemini handles everything directly.
        if isLiveVideoMode {
            conversationManager.addUserMessage(command, photoData: imageData)
            userTranscript = ""
            
            do {
                // Determine which image to send: user-attached photo OR latest glasses frame
                if let attachedData = imageData {
                    geminiLive.sendVideoFrame(imageData: attachedData)
                } else if let lastFrame = glassesManager.lastFrame, let jpegData = lastFrame.jpegData(compressionQuality: 0.6) {
                    geminiLive.sendVideoFrame(imageData: jpegData)
                }
                
                // If there's a text command, send it too. Often user might just send a photo with no text,
                // but Gemini Live text requires at least some text or it throws.
                var textToSend = command.isEmpty && imageData != nil ? "Look at this photo." : command
                if let context = ocrContext {
                    textToSend = "Context from my recent phone screenshot (do not mention unless relevant): \"\(context)\"\n\nUser command: \(textToSend)"
                    await MainActor.run { self.ocrContext = nil }
                }

                try await geminiLive.sendText(textToSend)
            } catch {
                print("[VoiceAgentView] Failed to send to Gemini Live: \(error)")
            }
            return
        }

        agentState = .thinking

        let photoKeywords = ["take a photo", "take a picture", "take photo", "take picture",
                             "capture a photo", "capture photo", "snap a photo", "snap a picture",
                             "what do you see", "what are you looking at", "look at this",
                             "what's in front of me", "describe what you see", "what is this",
                             "what am i looking at", "can you see"]
        let isPhotoCommand = photoKeywords.contains { lowerCommand.contains($0) }

        // Reset haptic state for the new AI response
        hasPlayedResponseHaptic = false

        do {
            var textToSend = command.isEmpty && imageData != nil ? "Look at this photo." : command
            if let context = ocrContext {
                textToSend = "Context from my recent phone screenshot (do not mention unless relevant): \"\(context)\"\n\nUser command: \(textToSend)"
                await MainActor.run { self.ocrContext = nil }
            }
            
            // --- OFFLINE SLM FALLBACK ---
            if !NetworkMonitor.shared.isConnected {
                print("[VoiceAgentView] Network disconnected. Falling back to OfflineLMService.")
                conversationManager.addUserMessage(command, photoData: imageData)
                
                // Route to local small language model
                let response = try await OfflineLMService.shared.generateResponse(for: textToSend)
                
                self.aiTranscript = response
                conversationManager.addAssistantMessage(response)
                speakResponse(response)
                
                // Restore agent state
                agentState = isSessionActive ? .listening : .idle
                return
            }

            switch settingsManager.settings.aiBackend {
            case .openClaw:
                if isPhotoCommand && imageData == nil {
                    print("[VoiceAgentView] Photo command detected, capturing from glasses...")
                    // Send textToSend so OpenClaw gets the OCR context if attached
                    await captureAndSendPhoto(withPrompt: textToSend)
                } else {
                    // Send text and optional attached image
                    conversationManager.addUserMessage(command, photoData: imageData)
                    try await OpenClawService.shared.sendMessage(textToSend, imageData: imageData)
                }

            case .geminiLive:
                conversationManager.addUserMessage(command, photoData: imageData)
                userTranscript = ""
                
                if let attachedData = imageData {
                    geminiLive.sendVideoFrame(imageData: attachedData)
                }
                try await GeminiLiveService.shared.sendText(textToSend)
            }
        } catch {
            errorMessage = "Failed to send command: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle
        }
    }

    // MARK: - Live Video Mode

    /// Start live video mode via voice command ("start video stream")
    /// This is now only used for enabling video on an already-active Gemini session.
    /// Audio is already flowing from startSession(), this just adds video.
    private func startLiveVideoMode() async {
        let log = DebugLogManager.shared

        guard !settingsManager.settings.geminiAPIKey.isEmpty else {
            log.log("No Gemini API key", source: "LiveMode", level: .error)
            ttsService.speak("Please configure your Gemini API key in settings")
            return
        }

        // If not already in a Gemini Live session, start the full pipeline
        if !isLiveVideoMode {
            log.log("=== Starting Live Video Mode ===", source: "LiveMode", level: .info)

            // Setup audio session
            do {
                try AudioSessionManager.shared.configure(for: .voiceChat)
            } catch {
                log.log("Audio session setup failed: \(error)", source: "LiveMode", level: .error)
            }

            // Stop TTS if speaking
            ttsService.stop()

            // Ensure VoiceCommandService engine is running
            if !voiceCommandService.isListening {
                if voiceCommandService.authorizationStatus == .authorized {
                    do {
                        try voiceCommandService.startListening(with: audioPlayback.playerNodeForInjection)
                    } catch {
                        log.log("Failed to start voice engine: \(error)", source: "LiveMode", level: .error)
                    }
                }
            }

            // Connect to Gemini Live WebSocket
            log.log("Connecting to Gemini Live...", source: "LiveMode", level: .network)
            do {
                try await geminiLive.connect()
                log.log("Gemini Live connected", source: "LiveMode", level: .success)
            } catch {
                log.log("Gemini connect FAILED: \(error.localizedDescription)", source: "LiveMode", level: .error)
                errorMessage = "Failed to connect to Gemini Live: \(error.localizedDescription)"
                return
            }

            // Setup Gemini Live callbacks
            setupGeminiLiveCallbacks()

            // Setup audio playback
            do {
                try audioPlayback.setup(with: voiceCommandService.activeEngine)
                log.log("Audio playback ready", source: "LiveMode", level: .success)
            } catch {
                log.log("Audio playback setup failed: \(error)", source: "LiveMode", level: .error)
            }

            // Redirect audio to Gemini
            audioCapture.onAudioCaptured = { [weak geminiLive] data in
                geminiLive?.sendAudio(data: data)
            }
            voiceCommandService.pauseForGeminiLive { buffer in
                self.audioCapture.processExternalBuffer(buffer, nativeFormat: buffer.format)
            }
            log.log("Audio engine redirected to Gemini", source: "LiveMode", level: .success)

            isLiveVideoMode = true
            agentState = .liveVideo
        }

        // Add video streaming if glasses are connected (optional)
        if glassesManager.isRegistered {
            if !glassesManager.isStreaming {
                log.log("Starting glasses streaming...", source: "LiveMode", level: .info)
                await glassesManager.startStreaming()
            }
            glassesManager.onVideoFrame = { [weak geminiLive] image in
                if let jpegData = image.jpegData(compressionQuality: 0.6) {
                    geminiLive?.sendVideoFrame(imageData: jpegData)
                }
            }
            log.log("Video frame routing configured", source: "LiveMode", level: .success)
        } else {
            log.log("No glasses connected — audio-only mode", source: "LiveMode", level: .info)
        }

        log.log("=== Live Video Mode ACTIVE ===", source: "LiveMode", level: .success)

        // Send welcome greeting to Gemini — it will respond with audio through the glasses
        // so the user immediately knows the system is active
        Task {
            // Small delay to let audio pipeline fully stabilize
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self.isLiveVideoMode, self.geminiLive.connectionState.isUsable {
                // Send a current video frame so Gemini can see the scene for context
                if let lastFrame = self.glassesManager.lastFrame,
                   let jpegData = lastFrame.jpegData(compressionQuality: 0.6) {
                    self.geminiLive.sendVideoFrame(imageData: jpegData)
                }
                try? await self.geminiLive.sendText("You just connected. Greet the user briefly so they know you're active and can hear them. If you can see something through the camera, mention it very briefly.")
                log.log("Welcome greeting sent", source: "LiveMode", level: .info)
            }
        }

        // Start describe scene timer
        startDescribeSceneTimer()
    }

    /// Stop live video mode - return to OpenClaw
    private func stopLiveVideoMode() async {
        guard isLiveVideoMode else {
            print("[VoiceAgentView] Not in live video mode")
            return
        }

        print("[VoiceAgentView] Stopping live video mode...")

        // Stop describe scene timer
        stopDescribeSceneTimer()

        // Stop sending audio to Gemini (but don't touch engine)
        audioCapture.onAudioCaptured = nil

        // Stop audio playback
        audioPlayback.teardown()

        // Disconnect Gemini Live
        await geminiLive.disconnect()

        // Stop glasses streaming
        if glassesManager.isStreaming {
            await glassesManager.stopStreaming()
        }

        // Restore video frame callback to Gemini Vision
        glassesManager.onVideoFrame = { [weak geminiVision] image in
            geminiVision?.sendVideoFrame(image)
        }

        isLiveVideoMode = false
        agentState = isSessionActive ? .listening : .idle

        // Resume VoiceCommandService recognition (engine was never stopped)
        if voiceCommandService.isPausedForGemini {
            voiceCommandService.resumeFromGeminiLive()
            print("[VoiceAgentView] Restored voice command recognition")
        } else {
            // Fallback: restart from scratch if needed
            do {
                try voiceCommandService.startListening(with: audioPlayback.playerNodeForInjection)
            } catch {
                print("[VoiceAgentView] Failed to restart voice commands: \(error)")
            }
        }

        print("[VoiceAgentView] Live video mode stopped - back to OpenClaw")
        ttsService.speak("Live video mode ended")
    }

    /// Setup Gemini Live callbacks for audio/transcription
    private func setupGeminiLiveCallbacks() {
        // Audio from Gemini → playback
        geminiLive.onAudioReceived = { [weak audioPlayback] data in
            audioPlayback?.playAudio(data: data)
        }

        // Transcription updates - also check for stop commands
        geminiLive.onInputTranscription = { text in
            Task { @MainActor in
                self.userTranscript = text

                // Check for stop video commands in what the user said
                let lowerText = text.lowercased()
                let stopKeywords = ["stop video", "stop streaming", "stop live", "end video",
                                   "exit video", "disable video", "stop the video", "end live",
                                   // Hindi fallbacks (Gemini sometimes transcribes English as Hindi)
                                   "स्टॉप", "वीडियो बंद", "बंद करो", "रुको"]

                let isStopCommand = stopKeywords.contains { lowerText.contains($0) }

                if isStopCommand && self.isLiveVideoMode {
                    print("[VoiceAgentView] Stop command detected in Gemini transcription: \(text)")
                    await self.stopLiveVideoMode()
                }
            }
        }

        geminiLive.onOutputTranscription = { text in
            Task { @MainActor in
                self.aiTranscript += text
            }
        }

        // Turn complete — persist the completed turn to chat history
        geminiLive.onTurnComplete = {
            Task { @MainActor in
                self.persistCompletedTurn()
            }
        }

        // Disconnection - handle reconnection or mode exit
        geminiLive.onDisconnected = {
            Task { @MainActor in
                if self.isLiveVideoMode {
                    print("[VoiceAgentView] Gemini Live disconnected unexpectedly")
                    await self.stopLiveVideoMode()
                }
            }
        }
    }

    /// Capture photo and send to OpenClaw with the user's prompt
    private func captureAndSendPhoto(withPrompt prompt: String) async {
        // Try to get an image from various sources
        var imageData: Data?
        var startedStreamingForPhoto = false

        // Start streaming if glasses are registered but not streaming
        if glassesManager.isRegistered && !glassesManager.isStreaming {
            print("[VoiceAgentView] Starting glasses camera stream for photo...")
            await glassesManager.startStreaming()
            startedStreamingForPhoto = true

            // Wait for stream to actually be ready (up to 3 seconds)
            for _ in 0..<30 {
                if glassesManager.isStreaming {
                    print("[VoiceAgentView] Stream is ready!")
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            // Give extra time for first frames to arrive
            if glassesManager.isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }

        if glassesManager.isStreaming {
            // Capture from glasses camera
            print("[VoiceAgentView] Capturing from glasses...")
            imageData = await capturePhotoFromGlasses()
        } else {
            print("[VoiceAgentView] Stream not active, checking for last frame...")
        }

        // Fallback to last frame if we have one
        if imageData == nil, let lastFrame = glassesManager.lastFrame {
            print("[VoiceAgentView] Using last frame...")
            imageData = lastFrame.jpegData(compressionQuality: 0.8)
        }

        // Send with or without image
        do {
            if let imageData = imageData {
                print("[VoiceAgentView] Sending message with photo (\(imageData.count) bytes)")
                try await OpenClawService.shared.sendMessage(prompt, imageData: imageData)

                // Only stop streaming if:
                // 1. We started it just for this photo, AND
                // 2. Not in live video mode
                if startedStreamingForPhoto && !isLiveVideoMode {
                    print("[VoiceAgentView] Stopping camera stream after photo")
                    await glassesManager.stopStreaming()
                } else if isLiveVideoMode {
                    print("[VoiceAgentView] Keeping stream active for live video mode")
                }
            } else {
                print("[VoiceAgentView] No image available, sending text only")
                // Provide more helpful message
                let note = glassesManager.isRegistered
                    ? " (Note: Camera is not available right now. Try starting the camera from Settings > Glasses first.)"
                    : " (Note: Smart glasses not connected. Please register in Settings.)"
                try await OpenClawService.shared.sendMessage(prompt + note)
            }
        } catch {
            print("[VoiceAgentView] Failed to send: \(error)")
            errorMessage = "Failed to send: \(error.localizedDescription)"
            agentState = isSessionActive ? .listening : .idle

            // Stop streaming on error if we started it for this photo
            if startedStreamingForPhoto && glassesManager.isStreaming {
                await glassesManager.stopStreaming()
            }
        }
    }

    /// Capture photo from glasses and return the data
    private func capturePhotoFromGlasses() async -> Data? {
        // Simple approach: just wait for photo via lastPhotoData
        // Request the capture
        await glassesManager.capturePhoto()

        // Wait for photo data to appear (poll for up to 5 seconds)
        for _ in 0..<50 {
            if let photoData = glassesManager.lastPhotoData {
                // Clear it so we don't reuse it
                glassesManager.lastPhotoData = nil
                print("[VoiceAgentView] Photo captured: \(photoData.count) bytes")
                return photoData
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        print("[VoiceAgentView] Photo capture timed out")
        return nil
    }

    // MARK: - Screen OCR Integration

    /// Fetches the latest screenshot from the Photo Library and runs OCR
    private func handleScreenshotTaken() {
        print("[VoiceAgentView] Screenshot detected, starting OCR context capture...")
        
        Task {
            // First time this runs, it will prompt the user for Photos access.
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                print("[VoiceAgentView] Photo library access denied.")
                return
            }
            
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.fetchLimit = 1
            
            let result = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            guard let latestAsset = result.firstObject else { return }
            
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestImage(for: latestAsset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: options) { image, _ in
                guard let image = image else { return }
                
                Task {
                    do {
                        let text = try await OCRService.shared.extractText(from: image)
                        if !text.isEmpty {
                            await MainActor.run {
                                self.ocrContext = text
                                print("[VoiceAgentView] OCR Context captured successfully! (\(text.count) chars)")
                                
                                // Provide distinct haptic to tell user context is loaded
                                let generator = UINotificationFeedbackGenerator()
                                generator.prepare()
                                generator.notificationOccurred(.success)
                            }
                        }
                    } catch {
                        print("[VoiceAgentView] OCR extraction failed: \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Glasses Video Integration

    /// Frame counter for logging
    @State private var videoFrameCount: Int = 0

    /// Setup glasses callbacks to stream video to Gemini Vision
    private func setupGlassesCallbacks() {
        print("[VoiceAgentView] Setting up glasses video callbacks...")

        // Connect video frames from glasses to Gemini Vision (for live feed)
        // Note: GeminiVisionService.sendVideoFrame already throttles to 1fps
        glassesManager.onVideoFrame = { [weak geminiVision] image in
            // Send frame to Gemini Vision for live analysis
            geminiVision?.sendVideoFrame(image)

            // Log periodically (every 30 frames = ~1 second at 30fps)
            Task { @MainActor in
                self.videoFrameCount += 1
                if self.videoFrameCount % 30 == 0 {
                    print("[VoiceAgentView] Video frames processed: \(self.videoFrameCount)")
                }
            }
        }

        // Photo captured callback (for OpenClaw photo analysis)
        glassesManager.onPhotoCaptured = { data in
            print("[VoiceAgentView] Photo captured: \(data.count) bytes")
            // Photos are handled via OpenClaw's attachment system
        }

        print("[VoiceAgentView] Glasses callbacks configured")
    }

    // MARK: - TTS Integration

    /// Speak AI response via TTS
    private func speakResponse(_ text: String) {
        guard !text.isEmpty else { return }
        
        // --- TRANSLATION ROUTING ---
        if settingsManager.settings.isTranslationModeActive {
            if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
                print("[VoiceAgentView] Detected AI response language: \(language.rawValue)")
                // If AI speaks English, it's talking to the external person -> iPhone Speaker
                // If AI speaks Spanish, it's whispering the translation to the wearer -> Glasses
                if language == .english {
                    AudioRoutingManager.shared.setRoute(for: .toLoudspeaker)
                } else {
                    AudioRoutingManager.shared.setRoute(for: .toGlasses)
                }
            }
        } else {
            // Ensure we are in default routing when translation mode is off
            AudioRoutingManager.shared.setRoute(for: .toGlasses)
        }
        
        ttsService.speak(text)
    }

    // MARK: - Tool Handlers

    /// Handle take_photo tool call
    private func handleTakePhotoTool(completion: @escaping (String) -> Void) async {
        print("[VoiceAgentView] Handling take_photo tool")

        if glassesManager.isStreaming {
            // Capture from glasses
            await glassesManager.capturePhoto()

            // Wait for photo to be captured (via callback)
            // Set up one-time handler for the photo
            let originalHandler = glassesManager.onPhotoCaptured
            glassesManager.onPhotoCaptured = { data in
                // Restore original handler
                self.glassesManager.onPhotoCaptured = originalHandler

                // Send photo to OpenClaw as attachment in next message
                Task {
                    do {
                        try await OpenClawService.shared.sendMessage("Here's the photo I just captured.", imageData: data)
                        completion("Photo captured and sent for analysis.")
                    } catch {
                        completion("Photo captured but failed to send: \(error.localizedDescription)")
                    }
                }
            }

            // Timeout after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.glassesManager.onPhotoCaptured != nil {
                    self.glassesManager.onPhotoCaptured = originalHandler
                    completion("Photo capture timed out.")
                }
            }
        } else if let lastFrame = glassesManager.lastFrame,
                  let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            // Use last frame if available
            do {
                try await OpenClawService.shared.sendMessage("Here's what I can see.", imageData: jpegData)
                completion("Captured current view and sent for analysis.")
            } catch {
                completion("Failed to send image: \(error.localizedDescription)")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first.")
        }
    }

    /// Handle describe_scene tool call (uses Gemini Vision)
    private func handleDescribeSceneTool(args: [String: Any], completion: @escaping (String) -> Void) async {
        print("[VoiceAgentView] Handling describe_scene tool")

        let prompt = args["prompt"] as? String ?? "Please describe what you see in this image."

        // Capture photo and send to OpenClaw for analysis
        if let lastFrame = glassesManager.lastFrame,
           let jpegData = lastFrame.jpegData(compressionQuality: 0.8) {
            do {
                try await OpenClawService.shared.sendMessage(prompt, imageData: jpegData)
                completion("Image captured and sent for analysis.")
            } catch {
                completion("Failed to analyze scene: \(error.localizedDescription)")
            }
        } else if glassesManager.isStreaming {
            // Try to capture a photo
            await glassesManager.capturePhoto()
            // Wait briefly for photo
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let photoData = glassesManager.lastPhotoData {
                glassesManager.lastPhotoData = nil
                do {
                    try await OpenClawService.shared.sendMessage(prompt, imageData: photoData)
                    completion("Photo captured and sent for analysis.")
                } catch {
                    completion("Failed to send photo: \(error.localizedDescription)")
                }
            } else {
                completion("Failed to capture photo.")
            }
        } else {
            completion("Camera is not available. Please connect glasses and start streaming first, or say 'start video stream' for live mode.")
        }
    }
}

#Preview {
    VoiceAgentView(isMenuOpen: .constant(false))
        .environmentObject(SettingsManager.shared)
        .environmentObject(GlassesManager.shared)
        .environmentObject(ConversationManager.shared)
        .preferredColorScheme(.dark)
}
