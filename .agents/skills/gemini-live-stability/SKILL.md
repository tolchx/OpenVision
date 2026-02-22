---
name: Gemini Live Stability & GlassesManager Auto-Healing
description: Instructions for restoring stability to Gemini Live, fixing the MWDATCamera Error 2 dropping connection issue, preventing keyboard UI overlapping, and injecting visual context into text chats safely.
---

# Gemini Live & OpenVision Stability Fixes

If the project is rewritten or refactored and loses the stability patches applied for Gemini Live and Meta Glasses streaming, apply the following adjustments exactly as described here.

## 1. GlassesManager `deviceNotConnected` (MWDATCamera Error 2) Fix
When using the `MWDATCamera` SDK to stream from Meta Ray-Ban glasses, rapidly stopping and starting the microphone stream causes a race condition. The SDK crashes with `Error 2` because the hardware socket has not fully closed, and the application locks out the user from streaming until rebooted.

**How to fix `GlassesManager.swift`:**
1. **Add a safe teardown delay**: Inside `func stopStreaming() async`, right after calling `await session.stop()`, add an await sleep for 500ms to give the hardware socket time to close:
   ```swift
   await session.stop()
   // Give the Meta SDK 500ms to safely tear down the hardware socket.
   try? await Task.sleep(nanoseconds: 500_000_000)
   ```
2. **Add an Auto-Healer to the error listener**: Inside `setupStreamListeners(...)`, replace the basic print statement of the `errorPublisher` with a self-healing retry block:
   ```swift
   errorListenerToken = session.errorPublisher.listen { [weak self] error in
       Task { @MainActor in
           self?.errorMessage = error.localizedDescription
           print("[GlassesManager] Stream error: \\(error)")

           // Auto-healing for MWDATCamera Error 2 (deviceNotConnected)
           if let isStreaming = self?.isStreaming, isStreaming {
               print("[GlassesManager] Attempting auto-reconnect due to error...")
               Task {
                   await self?.stopStreaming()
                   try? await Task.sleep(nanoseconds: 2_000_000_000)
                   print("[GlassesManager] Auto-reconnecting stream...")
                   await self?.startStreaming()
               }
           }
       }
   }
   ```

## 2. Preventing Keyboard UI Overlap in `VoiceAgentView`
When adding a text input box to `VoiceAgentView`, the iOS keyboard might overlap the text box. Using `.ignoresSafeArea(.keyboard)` disables the OS from pushing the view up.

**How to fix the layout in `VoiceAgentView.swift`:**
1. **Never use a `ZStack` as the root element** containing both the UI and the animated background.
2. The root element must be a `VStack`.
3. Move `AnimatedBackground()` and `ParticleEffect()` into a `.background(ZStack {...}.ignoresSafeArea())` modifier applied directly to the root `VStack`.
4. Ensure no `.ignoresSafeArea(.keyboard)` is attached anywhere, allowing the base `VStack` to naturally be compressed by the system keyboard, sliding the text box upward perfectly.

## 3. Gemini Live Text vs Silence Timers Disconnect Loop
If users are placed in `isLiveVideoMode` and they decide to type instead of using their voice, `VoiceCommandService.shared` will eventually hit its `silenceTimer` or `onConversationTimeout` due to lack of speaking. This erroneously calls `stopSession()` and kills Gemini Live while typing.

**How to fix:**
In `VoiceAgentView`, navigate to where `voiceCommandService.onConversationTimeout` is configured and wrap the `stopSession` trigger in an `isLiveVideoMode` check:
```swift
voiceCommandService.onConversationTimeout = {
    // Do not stop the entire session explicitly if we are in live video mode,
    // because the user might just be typing text or looking around.
    if !self.isLiveVideoMode {
        self.stopSession()
    }
}
```

## 4. Text-Based Visual Context Injection
If the user is streaming to Gemini Live but types a question like "What do you see?" in text, the `geminiLive.sendText(command)` gets passed over the websocket immediately. If it's the very first command and `sendVideoFrame` hasn't naturally ticked yet, the AI responds without any visual context.

**How to fix:**
In `sendCommand(_ command: String) async` inside `VoiceAgentView.swift`, force an immediate frame injection exclusively when routing text to Gemini:
```swift
if isLiveVideoMode {
    do {
        // If they ask what we see in text, explicitly feed the most recent camera frame
        // in real time so the text question isn't blind and gets the immediate context
        if let lastFrame = glassesManager.lastFrame, let jpegData = lastFrame.jpegData(compressionQuality: 0.6) {
            geminiLive.sendVideoFrame(imageData: jpegData)
        }
        try await geminiLive.sendText(command)
    } catch {
        // error handling
    }
    return
}
```
