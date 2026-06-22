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
    
    // Deletion Queue
    public var markedForDeletion: Set<String> = []
    
    private var activeScanner: DiskScanner? = nil
    private var scanTask: Task<Void, Never>? = nil
    private var currentScanID: UUID? = nil
    
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
    public func startScan(at url: URL, skipDependencies: Bool = true) {
        cancelActiveScan()
        
        let scanID = UUID()
        self.currentScanID = scanID
        
        self.currentScanURL = url
        self.selectedItem = nil
        self.scanProgress = nil
        
        let cacheFile = cacheURL(for: url)
        
        // 1. Auto-Load Cache Check:
        if FileManager.default.fileExists(atPath: cacheFile.path),
           let cachedSession = try? SessionManager.shared.load(from: cacheFile) {
            print("=== Loaded Cached Scan Session for \(url.path) Instantly! ===")
            self.rootItem = cachedSession.rootItem
            self.updateExtensionGroups(for: cachedSession.rootItem)
            
            // Automatically launch a silent, APFS-mtime optimized background incremental rescan
            startIncrementalScan(skipDependencies: skipDependencies, isAutoBackgroundRescan: true)
            return
        }
        
        // 2. Fresh Scan (when no cache exists):
        self.isScanning = true
        self.rootItem = nil
        self.extensionGroups = []
        
        let scanner = DiskScanner()
        self.activeScanner = scanner
        
        self.scanTask = Task.detached(priority: .userInitiated) { [weak self, scanID] in
            defer {
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    self.isScanning = false
                }
            }
            
            let root = await scanner.scan(url: url, skipDependencies: skipDependencies) { [weak self] progress, _ in
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    // ONLY update progress counters to keep the loading card lag-free!
                    self.scanProgress = progress
                }
            }
            
            // On completion OR cancellation, commit the partially or fully scanned tree!
            Task { @MainActor in
                guard let self = self, self.currentScanURL == url else { return }
                if let root = root {
                    self.rootItem = root
                    self.updateExtensionGroups(for: root)
                    self.autoSaveCache(for: url, root: root) // Auto-save the partial or completed snapshot
                }
            }
        }
    }
    
    /// Starts an APFS mtime-optimized incremental rescan of the current directory, if we have a root.
    public func startIncrementalScan(skipDependencies: Bool = true, isAutoBackgroundRescan: Bool = false) {
        guard let url = currentScanURL, let previous = rootItem else { return }
        
        // If it's a manual rescan (not auto-background), cancel previous runs first.
        // For auto-background, we keep the loaded tree active on screen!
        if !isAutoBackgroundRescan {
            cancelActiveScan()
        }
        
        let scanID = UUID()
        self.currentScanID = scanID
        
        self.isScanning = true
        self.selectedItem = nil
        self.scanProgress = nil
        
        let scanner = DiskScanner()
        self.activeScanner = scanner
        
        self.scanTask = Task.detached(priority: .userInitiated) { [weak self, scanID] in
            defer {
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    self.isScanning = false
                }
            }
            
            let root = await scanner.scan(url: url, previousRoot: previous, skipDependencies: skipDependencies) { [weak self] progress, rootItemState in
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    self.scanProgress = progress
                    
                    // Only update the tree structure live if this is NOT a silent background rescan.
                    if !isAutoBackgroundRescan {
                        self.rootItem = rootItemState
                        self.updateExtensionGroups(for: rootItemState)
                    }
                }
            }
            
            // On completion or cancellation, commit and cache the updated tree!
            Task { @MainActor in
                guard let self = self, self.currentScanURL == url else { return }
                if let root = root {
                    self.rootItem = root
                    self.updateExtensionGroups(for: root)
                    self.autoSaveCache(for: url, root: root) // Auto-save completed incremental scan
                }
            }
        }
    }
    
    /// Starts a targeted, in-place deep scan of a specific skipped directory, merging its findings back into our main tree.
    public func deepScanFolder(at item: DiskItem) {
        let url = URL(fileURLWithPath: item.path)
        
        cancelActiveScan()
        
        let scanID = UUID()
        self.currentScanID = scanID
        
        self.isScanning = true
        self.selectedItem = nil
        self.scanProgress = nil
        
        let scanner = DiskScanner()
        self.activeScanner = scanner
        
        self.scanTask = Task.detached(priority: .userInitiated) { [weak self, scanID] in
            defer {
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    self.isScanning = false
                }
            }
            
            // Force skipDependencies = false to perform a targeted full deep scan
            let subtree = await scanner.scan(url: url, previousRoot: nil, skipDependencies: false) { [weak self] progress, _ in
                Task { @MainActor in
                    guard let self = self, self.currentScanID == scanID else { return }
                    self.scanProgress = progress
                }
            }
            
            guard !Task.isCancelled else { return }
            
            Task { @MainActor in
                guard let self = self, self.currentScanID == scanID else { return }
                if let subtree = subtree {
                    self.mergeDeepSubtree(subtree, atPath: item.path)
                }
            }
        }
    }
    
    /// Merge a newly-deep-scanned subtree into our active root tree in-place, updating size differences up the chain.
    @MainActor
    private func mergeDeepSubtree(_ subtree: DiskItem, atPath path: String) {
        guard let root = rootItem else { return }
        
        // Find the node in our active tree
        guard let oldNode = root.findNode(byPath: path) else { return }
        
        let oldSize = oldNode.size
        let newSize = subtree.size
        let sizeDiff = newSize - oldSize
        
        // Update the old node's children, size, and rename to clean skipped suffix
        oldNode.children = subtree.children
        oldNode.size = newSize
        
        // Update parent links for the newly appended subtrees
        if let children = oldNode.children {
            for child in children {
                child.parent = oldNode
            }
        }
        
        // Propagate size difference upwards through parent chains up to root
        var cursor = oldNode.parent
        while let p = cursor {
            p.size += sizeDiff
            cursor = p.parent
        }
        
        // Re-sort parent directories to reflect the expanded storage weight
        var sortCursor: DiskItem? = oldNode
        while let p = sortCursor {
            p.children?.sort { $0.size > $1.size }
            sortCursor = p.parent
        }
        
        // Recalculate file extension legend aggregates on the updated tree
        updateExtensionGroups(for: root)
        
        // Update selection to focus on the deep-scanned node
        self.selectedItem = oldNode
        
        // Force state binding refresh in SwiftUI
        let tempRoot = root
        self.rootItem = nil
        self.rootItem = tempRoot
        
        // Auto-save the merged tree state back to our persistent cache
        if let currentURL = currentScanURL {
            autoSaveCache(for: currentURL, root: tempRoot)
        }
    }
    
    public func cancelActiveScan() {
        self.currentScanID = nil
        self.isScanning = false
        
        scanTask?.cancel()
        scanTask = nil
        
        let scanner = activeScanner
        Task {
            await scanner?.cancel()
        }
    }
    
    // MARK: - Auto-Caching Helpers
    
    private var cacheDirectory: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("com.pandelis.DiskInventoryY")
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }
    
    private func cacheURL(for scanURL: URL) -> URL {
        let path = scanURL.standardizedFileURL.path
        // Generate a stable string hash value (DJB2) that persists across different app launches
        var hash: UInt64 = 5381
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return cacheDirectory.appendingPathComponent("cache_\(hash).diskinvy")
    }
    
    private func autoSaveCache(for url: URL, root: DiskItem) {
        let file = cacheURL(for: url)
        Task.detached(priority: .background) {
            try? SessionManager.shared.save(root, to: file, scanURL: url)
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
    
    // MARK: - Space Clearing & Deletion Operations
    
    public func isMarkedForDeletion(_ item: DiskItem) -> Bool {
        return markedForDeletion.contains(item.path)
    }
    
    /// Recursively marks or unmarks an item and all of its descendants for bulk deletion
    public func toggleDeletionMark(for item: DiskItem) {
        let isMarked = markedForDeletion.contains(item.path)
        
        func toggleRecursive(_ node: DiskItem, mark: Bool) {
            if mark {
                markedForDeletion.insert(node.path)
            } else {
                markedForDeletion.remove(node.path)
            }
            if let children = node.children {
                for child in children {
                    toggleRecursive(child, mark: mark)
                }
            }
        }
        
        toggleRecursive(item, mark: !isMarked)
    }
    
    /// Resolves and returns only the top-level directories and files that have been marked,
    /// completely bypassing redundant child nodes to prevent double-counting.
    public var topLevelMarkedItems: [DiskItem] {
        guard let root = rootItem else { return [] }
        var results: [DiskItem] = []
        
        func findTopMarked(_ node: DiskItem) {
            if markedForDeletion.contains(node.path) {
                results.append(node)
            } else if let children = node.children {
                for child in children {
                    findTopMarked(child)
                }
            }
        }
        
        findTopMarked(root)
        return results
    }
    
    public var totalMarkedSize: Int64 {
        return topLevelMarkedItems.reduce(0) { $0 + $1.size }
    }
    
    /// Delete a single item (move to Trash) and update the in-memory tree in-place
    @MainActor
    public func deleteItem(_ item: DiskItem) throws {
        let fm = FileManager.default
        let itemURL = URL(fileURLWithPath: item.path)
        
        // Move to Trash natively (recycles the item)
        try fm.trashItem(at: itemURL, resultingItemURL: nil)
        
        // Subtract size up the parent chain
        let deletedSize = item.size
        var cursor = item.parent
        while let p = cursor {
            p.size = max(0, p.size - deletedSize)
            cursor = p.parent
        }
        
        // Remove item from its parent's children array
        if let parent = item.parent {
            parent.children?.removeAll { $0.path == item.path }
            parent.children?.sort { $0.size > $1.size }
        }
        
        // Clear from selection and deletion register
        if selectedItem?.path == item.path {
            selectedItem = nil
        }
        markedForDeletion.remove(item.path)
        
        // Refresh aggregates
        if let root = rootItem {
            updateExtensionGroups(for: root)
            
            // Force state binding refresh
            let tempRoot = root
            self.rootItem = nil
            self.rootItem = tempRoot
            
            // Auto-save updated tree state
            if let currentURL = currentScanURL {
                autoSaveCache(for: currentURL, root: tempRoot)
            }
        }
    }
    
    /// Delete all checked items in bulk (move to Trash) and update the tree in-place
    @MainActor
    public func deleteMarkedItems() throws {
        let itemsToDelete = topLevelMarkedItems
        guard !itemsToDelete.isEmpty else { return }
        
        let fm = FileManager.default
        var lastError: Error? = nil
        
        for item in itemsToDelete {
            let itemURL = URL(fileURLWithPath: item.path)
            do {
                try fm.trashItem(at: itemURL, resultingItemURL: nil)
                
                // Subtract size up parent chain
                let deletedSize = item.size
                var cursor = item.parent
                while let p = cursor {
                    p.size = max(0, p.size - deletedSize)
                    cursor = p.parent
                }
                
                // Remove from parent children list
                if let parent = item.parent {
                    parent.children?.removeAll { $0.path == item.path }
                    parent.children?.sort { $0.size > $1.size }
                }
                
                markedForDeletion.remove(item.path)
            } catch {
                print("Failed to recycle \(item.path): \(error.localizedDescription)")
                lastError = error
            }
        }
        
        // Clear selections
        selectedItem = nil
        markedForDeletion.removeAll()
        
        // Refresh aggregates
        if let root = rootItem {
            updateExtensionGroups(for: root)
            
            // Force state binding refresh
            let tempRoot = root
            self.rootItem = nil
            self.rootItem = tempRoot
            
            if let currentURL = currentScanURL {
                autoSaveCache(for: currentURL, root: tempRoot)
            }
        }
        
        if let error = lastError {
            throw error
        }
    }
}
