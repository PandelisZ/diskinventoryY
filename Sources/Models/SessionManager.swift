import Foundation

public struct DiskSession: Codable {
    public let scanURL: URL?
    public let rootItem: DiskItem
    public let date: Date
}

public final class SessionManager {
    public static let shared = SessionManager()
    
    private init() {}
    
    /// Save a disk inventory scan tree to a custom .diskinvy file
    public func save(_ rootItem: DiskItem?, to url: URL, scanURL: URL?) throws {
        guard let rootItem = rootItem else {
            throw NSError(domain: "SessionManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "No scan data to save."])
        }
        
        let session = DiskSession(scanURL: scanURL, rootItem: rootItem, date: Date())
        
        let encoder = JSONEncoder()
        // Do NOT pretty-print to keep the file size extremely small and fast to parse
        encoder.outputFormatting = []
        
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }
    
    /// Load a disk inventory scan tree from a custom .diskinvy file
    public func load(from url: URL) throws -> DiskSession {
        let data = try Data(contentsOf: url)
        
        let decoder = JSONDecoder()
        let session = try decoder.decode(DiskSession.self, from: data)
        
        // Custom link parent pointers after decoding
        relinkParentRefs(for: session.rootItem)
        
        return session
    }
    
    private func relinkParentRefs(for item: DiskItem) {
        guard let children = item.children else { return }
        for child in children {
            child.parent = item
            relinkParentRefs(for: child)
        }
    }
}
