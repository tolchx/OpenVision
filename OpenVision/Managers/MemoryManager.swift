import Foundation
import CoreLocation

struct MemoryItem: Codable, Identifiable {
    let id: UUID
    let text: String
    let latitude: Double          
    let longitude: Double
    let altitude: Double?
    let timestamp: Date
    let photoPath: String? // Optional local path if we save images
}

@MainActor
class MemoryManager: ObservableObject {
    static let shared = MemoryManager()
    
    @Published var memories: [MemoryItem] = []
    
    private let saveURL: URL
    
    init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.saveURL = documentsDirectory.appendingPathComponent("spatial_memories.json")
        loadMemories()
    }
    
    // MARK: - Core Functions
    
    func storeMemory(text: String, location: CLLocation, photoData: Data? = nil) {
        // TBD: Saving photo logic if needed. For now just storing text and GPS.
        let item = MemoryItem(
            id: UUID(),
            text: text,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            timestamp: Date(),
            photoPath: nil
        )
        
        memories.append(item)
        saveMemories()
        print("[MemoryManager] Stored new memory: \(text) at \(location.coordinate)")
    }
    
    func searchMemories(query: String) -> [MemoryItem] {
        let lowerQuery = query.lowercased()
        
        // Basic semantic/keyword matching (very naive fallback)
        // A true implementation would use embeddings, but this works for "car", "keys", etc.
        let results = memories.filter { $0.text.lowercased().contains(lowerQuery) }
        
        // Return most recent 5
        return Array(results.sorted(by: { $0.timestamp > $1.timestamp }).prefix(5))
    }
    
    // Get proactive memory context if the user is near an old memory
    func getNearbyMemoriesSystemPrompt(currentLocation: CLLocation, radiusMeters: Double = 200.0) -> String? {
        let nearby = memories.filter { memory in
            let memLoc = CLLocation(latitude: memory.latitude, longitude: memory.longitude)
            return currentLocation.distance(from: memLoc) <= radiusMeters
        }
        
        guard !nearby.isEmpty else { return nil }
        
        var prompt = "The user has past spatial memories near their current location:\n"
        let recentNearby = Array(nearby.sorted(by: { $0.timestamp > $1.timestamp }).prefix(5))
        
        for mem in recentNearby {
            let df = DateFormatter()
            df.dateStyle = .short
            prompt += "- On \(df.string(from: mem.timestamp)): \"\(mem.text)\"\n"
        }
        
        return prompt
    }
    
    // MARK: - Persistence
    
    private func saveMemories() {
        do {
            let data = try JSONEncoder().encode(memories)
            try data.write(to: saveURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("[MemoryManager] Failed to save memories: \(error)")
        }
    }
    
    private func loadMemories() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        do {
            memories = try JSONDecoder().decode([MemoryItem].self, from: data)
            print("[MemoryManager] Loaded \(memories.count) memories.")
        } catch {
            print("[MemoryManager] Failed to load memories: \(error)")
        }
    }
}
