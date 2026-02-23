import SwiftUI

struct ModelDownloaderSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var downloadManager = ModelDownloadManager.shared
    
    // Default 1.3B parameter model quantized to 4-bit (approx ~850MB) 
    @State private var modelURLString: String = "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
    
    var body: some View {
        Form {
            Section(header: Text("Offline Inference Engine")) {
                Text("Smart glasses need a local Small Language Model (SLM) to function in subway tunnels, elevators, and remote areas without Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("HuggingFace Model URL (GGUF or MLX)")
                        .bold()
                    TextField("https://huggingface.co/...", text: $modelURLString)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(.vertical, 4)
                
                if downloadManager.isDownloading {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView(value: downloadManager.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        
                        HStack {
                            Text("\(Int(downloadManager.progress * 100))% Downloaded")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button("Cancel") {
                                downloadManager.cancelDownload()
                            }
                            .foregroundColor(.red)
                            .font(.caption)
                            .bold()
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(action: {
                        downloadManager.downloadModel(from: modelURLString)
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download Model")
                        }
                    }
                }
                
                if let error = downloadManager.downloadError {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            
            Section(header: Text("Active Local Model")) {
                if let fileName = settingsManager.settings.localModelFileName {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        Button(role: .destructive) {
                            deleteActiveModel(fileName)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                } else {
                    Text("No local model downloaded yet.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Offline AI Model")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func deleteActiveModel(_ fileName: String) {
        let destinationURL = downloadManager.modelsDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            settingsManager.settings.localModelFileName = nil
        } catch {
            print("Failed to delete model: \(error)")
        }
    }
}

#Preview {
    NavigationView {
        ModelDownloaderSettingsView()
            .environmentObject(SettingsManager.shared)
    }
}
