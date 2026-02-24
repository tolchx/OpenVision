// OpenVision - AudioCaptureService.swift
// Captures audio from microphone using AVAudioEngine

@preconcurrency import AVFoundation

/// Captures audio from microphone
/// Captures audio from microphone
final class AudioCaptureService: ObservableObject {
    // MARK: - Published State

    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0

    // MARK: - Callbacks

    /// Called when audio data is captured (PCM Int16, mono)
    var onAudioCaptured: ((Data) -> Void)?

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // MARK: - Threading
    
    /// Dedicated queue for audio processing to avoid blocking MainActor (tap thread)
    private let processingQueue = DispatchQueue(label: "com.openvision.audio.processing", qos: .userInitiated)

    // MARK: - Audio Format

    /// Target sample rate for output
    var targetSampleRate: Double = Double(Constants.GeminiLive.inputSampleRate)

    /// Chunk duration in milliseconds
    var chunkDurationMs: Int = Constants.GeminiLive.audioChunkMs

    // MARK: - Buffering

    private var audioBuffer = Data()
    private var bufferLock = NSLock()

    /// Target buffer size in bytes (for chunking)
    private var targetBufferSize: Int {
        // PCM Int16, mono: 2 bytes per sample
        let samplesPerChunk = Int(targetSampleRate) * chunkDurationMs / 1000
        return samplesPerChunk * 2
    }

    // MARK: - Start/Stop

    /// Start capturing audio
    func startCapture() throws {
        // Use MainActor for Published property checks if needed, but here we can just check local state
        guard !isCapturing else { return }

        let engine = AVAudioEngine()
        audioEngine = engine
        inputNode = engine.inputNode

        guard let inputNode = inputNode else {
            throw AudioCaptureError.inputNodeUnavailable
        }

        // Get native format
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioCapture] Native format: \(nativeFormat)")

        // Install tap in native format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, nativeFormat: nativeFormat)
        }
        
        do {
            try engine.start()
        } catch {
            print("[AudioCapture] ERROR starting engine: \(error.localizedDescription)")
            // Clean up
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            self.inputNode = nil
            throw error
        }
        
        DispatchQueue.main.async {
            self.isCapturing = true
        }
        print("[AudioCapture] Started capturing successfully")
    }

    /// Stop capturing audio
    func stopCapture() {
        guard isCapturing else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil

        // Flush remaining buffer
        flushBuffer()

        DispatchQueue.main.async {
            self.isCapturing = false
        }
        print("[AudioCapture] Stopped capturing")
    }

    // MARK: - External Buffer Processing

    /// Process an audio buffer from an external source (e.g. VoiceCommandService's engine).
    /// This allows reusing an existing AVAudioEngine without creating a new one,
    /// which avoids disrupting the Meta SDK's Wi-Fi Direct camera stream.
    func processExternalBuffer(_ buffer: AVAudioPCMBuffer, nativeFormat: AVAudioFormat) {
        processAudioBuffer(buffer, nativeFormat: nativeFormat)
    }

    // MARK: - Audio Processing

    private var audioConverter: AVAudioConverter?
    private var currentNativeFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Constants.GeminiLive.inputSampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Process audio buffer from tap
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, nativeFormat: AVAudioFormat) {
        // Offload to background queue immediately
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Check if we need to setup/update the converter
            if self.currentNativeFormat != nativeFormat {
                self.currentNativeFormat = nativeFormat
                let needsResample = nativeFormat.sampleRate != self.targetFormat.sampleRate || nativeFormat.channelCount != self.targetFormat.channelCount
                if needsResample {
                    self.audioConverter = AVAudioConverter(from: nativeFormat, to: self.targetFormat)
                } else {
                    self.audioConverter = nil
                }
            }

            // 2. Resample if needed
            let bufferToProcess: AVAudioPCMBuffer
            if let converter = self.audioConverter {
                guard let resampled = self.convertBuffer(buffer, using: converter, targetFormat: self.targetFormat) else {
                    print("[AudioCapture] Resample failed")
                    return
                }
                bufferToProcess = resampled
            } else {
                bufferToProcess = buffer
            }

            // --- NEW SAFETY CHECK ---
            // Ensure we actually have frames to process to avoid downstream math crashes
            guard bufferToProcess.frameLength > 0 else { return }
            
            // 3. Compute Audio Level (RMS)
            let rms = self.computeRMS(bufferToProcess)
            DispatchQueue.main.async {
                self.audioLevel = rms
            }

            // 4. Convert Float32 to Int16 PCM Data
            let pcmData = self.float32BufferToInt16Data(bufferToProcess)

            // 5. Append and Chunk
            self.bufferLock.lock()
            self.audioBuffer.append(pcmData)

            // Send chunks when buffer is full
            while self.audioBuffer.count >= self.targetBufferSize {
                let chunk = self.audioBuffer.prefix(self.targetBufferSize)
                self.audioBuffer.removeFirst(self.targetBufferSize)
                self.bufferLock.unlock()

                let dataChunk = Data(chunk)
                DispatchQueue.main.async {
                    self.onAudioCaptured?(dataChunk)
                }

                self.bufferLock.lock()
            }
            self.bufferLock.unlock()
        }
    }

    /// Flush remaining audio buffer
    private func flushBuffer() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.bufferLock.lock()
            if !self.audioBuffer.isEmpty {
                let remaining = self.audioBuffer
                self.audioBuffer.removeAll()
                self.bufferLock.unlock()

                DispatchQueue.main.async {
                    self.onAudioCaptured?(remaining)
                }
            } else {
                self.bufferLock.unlock()
            }
        }
    }

    // MARK: - Conversion Helpers

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return 0 }
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let s = floatData[0][i]
            sumSquares += s * s
        }
        return sqrt(sumSquares / Float(frameCount))
    }

    private func float32BufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatData = buffer.floatChannelData else { return Data() }
        var int16Array = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let sample = max(-1.0, min(1.0, floatData[0][i]))
            int16Array[i] = Int16(sample * Float(Int16.max))
        }
        return int16Array.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = UInt32(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if error != nil {
            return nil
        }

        return outputBuffer
    }
}

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case engineCreationFailed
    case inputNodeUnavailable

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Failed to create audio engine"
        case .inputNodeUnavailable: return "Audio input node unavailable"
        }
    }
}
