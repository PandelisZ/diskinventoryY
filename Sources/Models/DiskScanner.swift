import Foundation
import SwiftUI

public struct ScanProgress: Sendable {
    public let totalSize: Int64
    public let fileCount: Int
    public let currentItemPath: String
    public let isCompleted: Bool
}

public actor DiskScanner {
    private var isCancelled = false
    private var previousRoot: DiskItem?
    
    public init() {}
    
    public func cancel() {
        isCancelled = true
    }
    
    /// Scan a directory, optionally performing an incremental update based on previous scan data.
    /// - Parameters:
    ///   - url: Root URL to scan
    ///   - previousRoot: The previous scan results of the exact same path, if any, to use for incremental speedup.
    ///   - progressHandler: A callback triggered periodically with the current status (total size, file count, etc.) on the Main thread.
    public func scan(
        url: URL,
        previousRoot: DiskItem? = nil,
        progressHandler: @escaping @Sendable (ScanProgress, DiskItem) -> Void
    ) async -> DiskItem? {
        self.isCancelled = false
        self.previousRoot = previousRoot
        
        let resolvedURL = URL(fileURLWithPath: url.path)
        let rootPath = resolvedURL.path
        let rootName = resolvedURL.lastPathComponent
        
        // Retrieve root attributes
        let resourceValues: URLResourceValues
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
            resourceValues = try resolvedURL.resourceValues(forKeys: keys)
        } catch {
            print("Failed to access root URL: \(error.localizedDescription)")
            return nil
        }
        
        guard resourceValues.isDirectory == true else {
            // Root is a file
            let keys: Set<URLResourceKey> = [.fileSizeKey]
            let size = (try? resolvedURL.resourceValues(forKeys: keys).fileSize).map { Int64($0) } ?? 0
            let mtime = resourceValues.contentModificationDate ?? Date()
            let fileExt = url.pathExtension.lowercased()
            let fileItem = DiskItem(path: rootPath, name: rootName, type: .file, size: size, modificationDate: mtime, fileExtension: fileExt)
            progressHandler(ScanProgress(totalSize: size, fileCount: 1, currentItemPath: rootPath, isCompleted: true), fileItem)
            return fileItem
        }
        
        // Root is indeed a directory.
        // We'll create our initial root item
        let rootMtime = resourceValues.contentModificationDate ?? Date()
        let rootItem = DiskItem(path: rootPath, name: rootName, type: .directory, size: 0, modificationDate: rootMtime, children: [])
        
        // If we have previous root, index it by path for easy mtime-based lookups during incremental scan
        let savedIndex = buildPathIndex(for: previousRoot)
        
        // We will perform a multi-threaded parallel scan of the root's immediate contents
        // This is highly optimal because top-level directories (e.g. /Users/name/Documents, Downloads, Library)
        // are processed concurrently in separate threads, while inner sub-trees are scanned sequentially
        // on those threads to avoid excessive thread context switching.
        
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .nameKey]
        
        guard let topContents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            print("Cannot read top contents of \(url.path)")
            return rootItem
        }
        
        // Progress tracking state (thread-safe actor state, but we can also accumulate locally and update)
        var totalSize: Int64 = 0
        var totalFileCount = 0
        
        // We'll throttle UI updates to every 100ms
        var lastUIUpdateTime = DispatchTime.now()
        let uiUpdateIntervalNanoseconds: UInt64 = 100_000_000 // 100ms
        
        let progressCallback = progressHandler
        
        // Helper to trigger main thread progress update
        func sendProgress(path: String, force: Bool, completed: Bool) {
            let size = totalSize
            let count = totalFileCount
            let rootCopy = rootItem // It's reference type, but progress updates will read its dynamic sizes
            
            let now = DispatchTime.now()
            if force || completed || (now.uptimeNanoseconds - lastUIUpdateTime.uptimeNanoseconds) >= uiUpdateIntervalNanoseconds {
                lastUIUpdateTime = now
                Task { @MainActor in
                    progressCallback(
                        ScanProgress(totalSize: size, fileCount: count, currentItemPath: path, isCompleted: completed),
                        rootCopy
                    )
                }
            }
        }
        
        // We will execute top-level nodes in a TaskGroup for maximum concurrent I/O performance
        await withTaskGroup(of: DiskItem?.self) { group in
            for childURL in topContents {
                if self.isCancelled { break }
                
                // Spawn parallel scan for each top-level child
                group.addTask {
                    return await self.scanSubtree(
                        url: childURL,
                        savedIndex: savedIndex,
                        depth: 1
                    )
                }
            }
            
            // Collect subtrees
            var rootChildren: [DiskItem] = []
            for await subtree in group {
                if let child = subtree {
                    child.parent = rootItem
                    rootChildren.append(child)
                    
                    // Update running counters
                    totalSize += child.size
                    totalFileCount += self.countFiles(in: child)
                    rootItem.size = totalSize
                    rootItem.children = rootChildren
                    
                    sendProgress(path: child.path, force: false, completed: false)
                }
            }
        }
        
        // Final size calculation & sorting
        rootItem.size = totalSize
        rootItem.children?.sort { $0.size > $1.size }
        
        // Force a final completed progress update
        sendProgress(path: rootPath, force: true, completed: true)
        
        return rootItem
    }
    
    /// Recursive function to scan a subtree. Runs on background task threads.
    private func scanSubtree(
        url: URL,
        savedIndex: [String: DiskItem],
        depth: Int
    ) async -> DiskItem? {
        if isCancelled { return nil }
        
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        
        // Try to read resource keys
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            // Skip unreadable files/folders
            return nil
        }
        
        let isDirectory = values.isDirectory ?? false
        let diskMtime = values.contentModificationDate ?? Date()
        
        // 1. APFS-Optimized Incremental Rescan Check
        // If we have a saved item at this exact path, check its mtime
        if let savedItem = savedIndex[path] {
            // Check if modification dates match
            // APFS keeps accurate, microsecond-resolution modification dates on folders.
            // If the folder mtime matches exactly, nothing inside was added, removed, or modified.
            // We can fully reuse the cached subtree!
            if savedItem.modificationDate == diskMtime {
                // Return a deep copy or reuse the subtree (after verifying structure and fixing parent refs)
                // Reconstructing the parent links on reuse:
                relinkParentRefs(for: savedItem)
                return savedItem
            }
        }
        
        // 2. If it's a file (or package we decide not to enter, but let's scan packages)
        if !isDirectory {
            let size = Int64(values.fileSize ?? 0)
            let fileExt = url.pathExtension.lowercased()
            return DiskItem(
                path: path,
                name: name,
                type: .file,
                size: size,
                modificationDate: diskMtime,
                fileExtension: fileExt
            )
        }
        
        // 3. It's a directory (or package we do enter). We must scan its children.
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            // Skip unreadable directories but return an empty directory item
            return DiskItem(
                path: path,
                name: name,
                type: .directory,
                size: 0,
                modificationDate: diskMtime,
                children: []
            )
        }
        
        var children: [DiskItem] = []
        var folderSize: Int64 = 0
        
        // To prevent massive stack nesting and thread creation, we scan sequentially
        // for deeper folders (depth > 1) on the same thread pool.
        for childURL in contents {
            if isCancelled { return nil }
            
            if let childItem = await scanSubtree(
                url: childURL,
                savedIndex: savedIndex,
                depth: depth + 1
            ) {
                folderSize += childItem.size
                children.append(childItem)
            }
        }
        
        // Sort children by size descending, like Disk Inventory X does
        children.sort { $0.size > $1.size }
        
        let folderItem = DiskItem(
            path: path,
            name: name,
            type: .directory,
            size: folderSize,
            modificationDate: diskMtime,
            children: children
        )
        
        // Link parent
        for child in children {
            child.parent = folderItem
        }
        
        return folderItem
    }
    
    /// Re-links parent references in a reused cached subtree
    private func relinkParentRefs(for item: DiskItem) {
        guard let children = item.children else { return }
        for child in children {
            child.parent = item
            relinkParentRefs(for: child)
        }
    }
    
    /// Helper to count files in a subtree for progress reports
    private func countFiles(in item: DiskItem) -> Int {
        if item.type == .file { return 1 }
        var count = 0
        if let children = item.children {
            for child in children {
                count += countFiles(in: child)
            }
        }
        return count
    }
    
    /// Flatten a tree into a lookup dictionary of path -> DiskItem
    private func buildPathIndex(for root: DiskItem?) -> [String: DiskItem] {
        guard let root = root else { return [:] }
        var index: [String: DiskItem] = [:]
        
        var queue: [DiskItem] = [root]
        while !queue.isEmpty {
            let item = queue.removeFirst()
            index[item.path] = item
            if let children = item.children {
                queue.append(contentsOf: children)
            }
        }
        
        return index
    }
}
