import Foundation
import Combine

/// Manages the background downloading of large AI models (e.g., GGUF files) from URLs directly into the iOS filesystem.
@MainActor
class ModelDownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloadManager()
    
    @Published var isDownloading = false
    @Published var progress: Double = 0.0
    @Published var downloadError: String? = nil
    @Published var downloadedFileName: String? = nil
    
    private var downloadSession: URLSession!
    private var downloadTask: URLSessionDownloadTask?
    
    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.openvision.modeldownloader")
        // High timeout since these files are 1-3GB
        configuration.timeoutIntervalForResource = 60 * 60 * 2 // 2 hours
        // Store session for delegate callbacks
        self.downloadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    
    /// Starts downloading a model from a given URL to the app's Documents directory.
    func downloadModel(from urlString: String) {
        guard let url = URL(string: urlString) else {
            self.downloadError = "Invalid URL."
            return
        }
        
        self.isDownloading = true
        self.progress = 0.0
        self.downloadError = nil
        
        // Cancel any existing task
        downloadTask?.cancel()
        
        downloadTask = downloadSession.downloadTask(with: url)
        downloadTask?.resume()
        print("[ModelDownloadManager] Started downloading from: \(urlString)")
    }
    
    /// Cancels the current download
    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        progress = 0.0
        print("[ModelDownloadManager] Download cancelled by user.")
    }
    
    /// The local folder where models are stored
    var modelsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let currentProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor in
                self.progress = currentProgress
                // To avoid spamming print, we won't print every tiny progress chunk here
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url else { return }
        
        // Use the remote filename (e.g., Llama-3.2-1B-Instruct-Q4_K_M.gguf)
        let suggestedFilename = downloadTask.response?.suggestedFilename ?? url.lastPathComponent
        let safeFilename = suggestedFilename.isEmpty ? "model.gguf" : suggestedFilename
        
        Task { @MainActor in
            let destinationURL = self.modelsDirectory.appendingPathComponent(safeFilename)
            
            do {
                // Delete if a file with the same name already exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                
                // Move from temporary download location to Documents
                try FileManager.default.moveItem(at: location, to: destinationURL)
                
                print("[ModelDownloadManager] Download complete. File saved to: \(destinationURL.path)")
                self.downloadedFileName = safeFilename
                self.isDownloading = false
                self.progress = 1.0
                
                // Automatically activate this model
                SettingsManager.shared.settings.localModelFileName = safeFilename
                
            } catch {
                print("[ModelDownloadManager] Failed to move downloaded file: \(error)")
                self.downloadError = "Failed to save file: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.code != NSURLErrorCancelled {
                print("[ModelDownloadManager] Download failed with error: \(error)")
                Task { @MainActor in
                    self.downloadError = error.localizedDescription
                    self.isDownloading = false
                }
            }
        }
    }
}
