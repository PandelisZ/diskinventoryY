import Foundation
import SwiftUI

public enum DiskItemType: String, Codable, Sendable {
    case file
    case directory
}

public final class DiskItem: Identifiable, Codable, @unchecked Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let type: DiskItemType
    public var size: Int64
    public var modificationDate: Date
    public var fileExtension: String
    public var children: [DiskItem]?
    
    // Parent is weak and not serialized to prevent cycles
    public weak var parent: DiskItem?
    
    // Hashable & Equatable conformance
    public static func == (lhs: DiskItem, rhs: DiskItem) -> Bool {
        return lhs.path == rhs.path
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
    
    // Helper property to calculate percentage of parent size
    public var percentageOfParent: Double {
        guard let parentSize = parent?.size, parentSize > 0 else { return 1.0 }
        return Double(size) / Double(parentSize)
    }
    
    enum CodingKeys: String, CodingKey {
        case path
        case name
        case type
        case size
        case modificationDate
        case fileExtension
        case children
    }
    
    public init(path: String, name: String, type: DiskItemType, size: Int64 = 0, modificationDate: Date = Date(), fileExtension: String = "", children: [DiskItem]? = nil) {
        self.path = path
        self.name = name
        self.type = type
        self.size = size
        self.modificationDate = modificationDate
        self.fileExtension = fileExtension.lowercased()
        self.children = children
        
        // Link children
        if let children = children {
            for child in children {
                child.parent = self
            }
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.name = try container.decode(String.self, forKey: .name)
        self.type = try container.decode(DiskItemType.self, forKey: .type)
        self.size = try container.decode(Int64.self, forKey: .size)
        
        // Some systems might store date as Double or String, handle safely
        if let dateDouble = try? container.decode(Double.self, forKey: .modificationDate) {
            self.modificationDate = Date(timeIntervalSince1970: dateDouble)
        } else if let date = try? container.decode(Date.self, forKey: .modificationDate) {
            self.modificationDate = date
        } else {
            self.modificationDate = Date()
        }
        
        self.fileExtension = (try? container.decode(String.self, forKey: .fileExtension))?.lowercased() ?? ""
        self.children = try container.decodeIfPresent([DiskItem].self, forKey: .children)
        
        // Set up parent relationships for decoded tree
        if let children = self.children {
            for child in children {
                child.parent = self
            }
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(size, forKey: .size)
        try container.encode(modificationDate.timeIntervalSince1970, forKey: .modificationDate)
        try container.encode(fileExtension, forKey: .fileExtension)
        try container.encodeIfPresent(children, forKey: .children)
    }
    
    // Check if child counts or size changed
    public var childCount: Int {
        return children?.count ?? 0
    }
}
