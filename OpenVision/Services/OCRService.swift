// OpenVision - OCRService.swift
// Extracts text from screenshots/images using Apple's local Vision framework

import Foundation
import UIKit
import Vision

class OCRService {
    static let shared = OCRService()
    
    private init() {}
    
    /// Extracts all recognized text from a UIImage using Vision.
    func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw OCRError.invalidImage
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                let extractedText = observations.compactMap { observation in
                    // Grab the top candidate
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")
                
                continuation.resume(returning: extractedText)
            }
            
            // Configure for accuracy over speed, since we're analyzing a static screenshot
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum OCRError: LocalizedError {
    case invalidImage
    
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "The image data is invalid or could not be converted to a CGImage."
        }
    }
}
