import Foundation
import SwiftUI
import Observation

public struct FileExtensionGroup: Identifiable, Sendable {
    public var id: String { fileExtension }
    public let fileExtension: String
    public let totalSize: Int64
    public let fileCount: Int
    public let color: Color
}

public struct MountedVolume: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let name: String
    public let url: URL
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    public let isInternal: Bool
}

@Observable
public final class DiskInventoryViewModel {
    public var rootItem: DiskItem? = nil
    public var selectedItem: DiskItem? = nil
    
    // Scanner state
    public var isScanning = false
    public var scanProgress: ScanProgress? = nil
    public var currentScanURL: URL? = nil
    
    // UI aggregates
    public var extensionGroups: [FileExtensionGroup] = []
    
    private var activeScanner: DiskScanner? = nil
    private var scanTask: Task<Void, Never>? = nil
    
    public init() {}
    
    /// Detects all currently mounted volumes (internal/external SSDs, DMGs, etc.)
    public var mountedVolumes: [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        
        var volumes: [MountedVolume] = []
        for url in urls {
            // Resolve file reference URL to normal standardized path URL using its POSIX path (essential for directory traversal)
            let resolvedURL = URL(fileURLWithPath: url.path)
            guard let values = try? resolvedURL.resourceValues(forKeys: Set(keys)) else { continue }
            
            let name = values.volumeName ?? resolvedURL.lastPathComponent
            let isInternal = values.volumeIsInternal ?? true
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacity ?? 0)
            
            // Skip folders with 0 capacity
            guard total > 0 else { continue }
            
            volumes.append(MountedVolume(
                name: name,
                url: resolvedURL,
                totalCapacity: total,
                availableCapacity: available,
                isInternal: isInternal
            ))
        }
        
        // Sort so internal boot disk is first, then external drives
        return volumes.sorted { $0.isInternal && !$1.isInternal }
    }
    
    public var formattedTotalSize: String {
        guard let root = rootItem else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: root.size, countStyle: .file)
    }
    
    public var formattedProgressSize: String {
        guard let progress = scanProgress else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: progress.totalSize, countStyle: .file)
    }
    
    /// Starts a fresh scan of the given directory.
    public func startScan(at url: URL) {
        cancelActiveScan()
        
        self.isScanning = true
        self.currentScanURL = url
        self.rootItem = nil
        self.selectedItem = nil
        self.scanProgress = nil
        self.extensionGroups = []
        
        let scanner = DiskScanner()
        self.activeScanner = scanner
        
        self.scanTask = Task.detached(priority: .userInitiated) {
            let root = await scanner.scan(url: url) { [weak self] progress, rootItemState in
                guard let self = self else { return }
                Task { @MainActor in
                    self.scanProgress = progress
                    self.rootItem = rootItemState
                    self.updateExtensionGroups(for: rootItemState)
                }
            }
            
            guard !Task.isCancelled else { return }
            
            Task { @MainActor in
                self.isScanning = false
                if let root = root {
                    self.rootItem = root
                    self.updateExtensionGroups(for: root)
                }
            }
        }
    }
    
    /// Starts an APFS mtime-optimized incremental rescan of the current directory, if we have a root.
    public func startIncrementalScan() {
        guard let url = currentScanURL, let previous = rootItem else { return }
        
        self.isScanning = true
        self.selectedItem = nil
        self.scanProgress = nil
        
        let scanner = DiskScanner()
        self.activeScanner = scanner
        
        self.scanTask = Task.detached(priority: .userInitiated) {
            let root = await scanner.scan(url: url, previousRoot: previous) { [weak self] progress, rootItemState in
                guard let self = self else { return }
                Task { @MainActor in
                    self.scanProgress = progress
                    self.rootItem = rootItemState
                    self.updateExtensionGroups(for: rootItemState)
                }
            }
            
            guard !Task.isCancelled else { return }
            
            Task { @MainActor in
                self.isScanning = false
                if let root = root {
                    self.rootItem = root
                    self.updateExtensionGroups(for: root)
                }
            }
        }
    }
    
    public func cancelActiveScan() {
        scanTask?.cancel()
        scanTask = nil
        
        Task {
            await activeScanner?.cancel()
            await MainActor.run {
                self.isScanning = false
            }
        }
    }
    
    /// Aggregate file types dynamically on the tree
    public func updateExtensionGroups(for root: DiskItem?) {
        guard let root = root else {
            self.extensionGroups = []
            return
        }
        
        // Run aggregation on a background thread if tree is huge, but let's make it highly optimized
        var counts: [String: (size: Int64, count: Int)] = [:]
        
        func traverse(_ item: DiskItem) {
            if item.type == .file {
                let ext = item.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                let extKey = ext.isEmpty ? "no extension" : ext
                let current = counts[extKey] ?? (0, 0)
                counts[extKey] = (current.size + item.size, current.count + 1)
            } else if let children = item.children {
                for child in children {
                    traverse(child)
                }
            }
        }
        
        traverse(root)
        
        let groups = counts.map { (ext, stats) in
            FileExtensionGroup(
                fileExtension: ext,
                totalSize: stats.size,
                fileCount: stats.count,
                color: ExtensionColorManager.shared.color(for: ext)
            )
        }.sorted { $0.totalSize > $1.totalSize }
        
        self.extensionGroups = groups
    }
    
    /// Return the focus subtree based on selection
    public var treemapRoot: DiskItem? {
        guard let selected = selectedItem else { return rootItem }
        
        if selected.type == .directory {
            return selected
        } else {
            // It's a file, show its parent folder in the treemap so we can see the file's context
            return selected.parent ?? rootItem
        }
    }
}
