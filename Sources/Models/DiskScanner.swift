import Foundation

public struct ScanProgress: Sendable {
    public let totalSize: Int64
    public let fileCount: Int
    public let currentItemPath: String
    public let isCompleted: Bool
}

/// Lightweight events emitted by the background scanner to build the tree on the main thread
public enum ScanEvent: Sendable {
    case directoryStart(path: String, name: String, mtime: Date)
    case file(path: String, name: String, size: Int64, mtime: Date, ext: String)
    case directoryEnd(path: String)
    case reuseSubtree(path: String, subtree: DiskItem)
}

/// Clean parser that builds the tree and dispatches updates exclusively on the MainActor.
/// This is a final class to allow thread-safe reference-type capturing in concurrent tasks.
@MainActor
final class TreeBuilder {
    var currentActiveDirectory: DiskItem
    let rootItem: DiskItem
    let rootPath: String
    let progressHandler: @Sendable (ScanProgress, DiskItem) -> Void
    
    var totalSize: Int64 = 0
    var totalFileCount = 0
    
    private var lastUIUpdateTime = DispatchTime.now()
    private let uiUpdateIntervalNanoseconds: UInt64 = 100_000_000 // 100ms
    
    init(rootItem: DiskItem, rootPath: String, progressHandler: @escaping @Sendable (ScanProgress, DiskItem) -> Void) {
        self.currentActiveDirectory = rootItem
        self.rootItem = rootItem
        self.rootPath = rootPath
        self.progressHandler = progressHandler
    }
    
    func sendProgress(currentPath: String, force: Bool, completed: Bool) {
        let now = DispatchTime.now()
        if force || completed || (now.uptimeNanoseconds - lastUIUpdateTime.uptimeNanoseconds) >= uiUpdateIntervalNanoseconds {
            lastUIUpdateTime = now
            progressHandler(
                ScanProgress(totalSize: totalSize, fileCount: totalFileCount, currentItemPath: currentPath, isCompleted: completed),
                rootItem
            )
        }
    }
    
    /// Resolve active directories on the fly during depth-first enumeration.
    /// Closes and sorts subdirectories as we step back up the parent chain.
    func resolveActiveDirectory(itemPath: String) {
        while currentActiveDirectory.path != rootPath && !itemPath.hasPrefix(currentActiveDirectory.path + "/") {
            currentActiveDirectory.children?.sort { $0.size > $1.size }
            if let parent = currentActiveDirectory.parent {
                currentActiveDirectory = parent
            } else {
                break
            }
        }
    }
    
    func process(event: ScanEvent) {
        switch event {
        case .directoryStart(let path, let name, let mtime):
            resolveActiveDirectory(itemPath: path)
            let newFolder = DiskItem(path: path, name: name, type: .directory, size: 0, modificationDate: mtime, children: [])
            newFolder.parent = currentActiveDirectory
            currentActiveDirectory.children = (currentActiveDirectory.children ?? []) + [newFolder]
            currentActiveDirectory = newFolder
            
        case .file(let path, let name, let size, let mtime, let ext):
            resolveActiveDirectory(itemPath: path)
            let newFile = DiskItem(path: path, name: name, type: .file, size: size, modificationDate: mtime, fileExtension: ext)
            newFile.parent = currentActiveDirectory
            currentActiveDirectory.children = (currentActiveDirectory.children ?? []) + [newFile]
            
            // Propagate file size upwards through the parent chain
            totalSize += size
            totalFileCount += 1
            var parentCursor: DiskItem? = currentActiveDirectory
            while let p = parentCursor {
                p.size += size
                parentCursor = p.parent
            }
            
        case .directoryEnd(_):
            break
            
        case .reuseSubtree(let path, let cachedSubtree):
            resolveActiveDirectory(itemPath: path)
            // Link cached subtree under current directory
            cachedSubtree.parent = currentActiveDirectory
            currentActiveDirectory.children = (currentActiveDirectory.children ?? []) + [cachedSubtree]
            
            // Recalculate and propagate the cached subtree's size and file counts
            let subtreeSize = cachedSubtree.size
            let subtreeFileCount = countFiles(in: cachedSubtree)
            
            totalSize += subtreeSize
            totalFileCount += subtreeFileCount
            
            var parentCursor: DiskItem? = currentActiveDirectory
            while let p = parentCursor {
                p.size += subtreeSize
                parentCursor = p.parent
            }
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
}

public actor DiskScanner {
    private var isCancelled = false
    
    public init() {}
    
    public func cancel() {
        isCancelled = true
    }
    
    private func checkCancelled() -> Bool {
        return isCancelled
    }
    
    /// Scan a directory, streaming events to build the tree in real-time on the main thread.
    /// - Parameters:
    ///   - url: Root URL to scan
    ///   - previousRoot: The previous scan results of the exact same path, if any, to use for incremental speedup.
    ///   - progressHandler: A callback triggered periodically on the Main thread with the live progress and root tree state.
    public func scan(
        url: URL,
        previousRoot: DiskItem? = nil,
        progressHandler: @escaping @Sendable (ScanProgress, DiskItem) -> Void
    ) async -> DiskItem? {
        self.isCancelled = false
        
        let resolvedURL = URL(fileURLWithPath: url.path)
        let rootPath = resolvedURL.path
        let rootName = resolvedURL.lastPathComponent
        
        // Retrieve root attributes
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let rootValues = try? resolvedURL.resourceValues(forKeys: keys) else {
            print("Failed to access root URL: \(resolvedURL.path)")
            return nil
        }
        
        let isDir = rootValues.isDirectory ?? false
        let rootMtime = rootValues.contentModificationDate ?? Date()
        
        // Handle the simple case where root is a single file
        guard isDir else {
            let keys: Set<URLResourceKey> = [.fileSizeKey]
            let size = (try? resolvedURL.resourceValues(forKeys: keys).fileSize).map { Int64($0) } ?? 0
            let fileExt = resolvedURL.pathExtension.lowercased()
            let fileItem = DiskItem(path: rootPath, name: rootName, type: .file, size: size, modificationDate: rootMtime, fileExtension: fileExt)
            
            progressHandler(ScanProgress(totalSize: size, fileCount: 1, currentItemPath: rootPath, isCompleted: true), fileItem)
            return fileItem
        }
        
        // Root is a directory. Initialize the live-growing tree structure on the MainActor
        let rootItem = DiskItem(path: rootPath, name: rootName, type: .directory, size: 0, modificationDate: rootMtime, children: [])
        
        // Build path index for cached incremental rescan matching
        let savedIndex = buildPathIndex(for: previousRoot)
        
        // Create our stateful MainActor TreeBuilder parser reference
        let builder = await MainActor.run {
            TreeBuilder(rootItem: rootItem, rootPath: rootPath, progressHandler: progressHandler)
        }
        
        // Run the fast sequential directory enumerator on a background thread
        // Emits events in chunks to minimize main-thread actor hop overhead
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let enumeratorKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
            
            guard let enumerator = fm.enumerator(
                at: resolvedURL,
                includingPropertiesForKeys: Array(enumeratorKeys),
                options: [.skipsHiddenFiles]
            ) else {
                return
            }
            
            var eventBuffer: [ScanEvent] = []
            let bufferSize = 80 // Batch events to maximize throughput
            
            // Helper to dispatch buffered events to the MainActor
            let flushEvents = { (currentPath: String, force: Bool) async in
                if eventBuffer.isEmpty { return }
                let batch = eventBuffer
                eventBuffer.removeAll()
                
                await MainActor.run {
                    for ev in batch {
                        builder.process(event: ev)
                    }
                    builder.sendProgress(currentPath: currentPath, force: force, completed: false)
                }
            }
            
            var fileCheckCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                if Task.isCancelled { break }
                
                // Only check actor-isolated cancellation once every 100 files to avoid actor-hop overhead
                fileCheckCount += 1
                if fileCheckCount % 100 == 0 {
                    let cancelled = await self.checkCancelled()
                    if cancelled { break }
                }
                
                let path = fileURL.standardizedFileURL.path
                let name = fileURL.lastPathComponent
                
                // Skip the root folder itself if the enumerator returns it
                if path == rootPath { continue }
                
                guard let values = try? fileURL.resourceValues(forKeys: enumeratorKeys) else {
                    continue
                }
                
                let isDir = values.isDirectory ?? false
                let mtime = values.contentModificationDate ?? Date()
                
                if isDir {
                    // Check if we can perform an APFS-mtime incremental reuse of this subdirectory
                    if let cachedNode = savedIndex[path], cachedNode.modificationDate == mtime {
                        // Re-link parent references inside the cached node
                        self.relinkParentRefs(for: cachedNode)
                        
                        eventBuffer.append(.reuseSubtree(path: path, subtree: cachedNode))
                        enumerator.skipDescendants() // Tell macOS not to scan inside this directory!
                    } else {
                        // Enter the directory
                        eventBuffer.append(.directoryStart(path: path, name: name, mtime: mtime))
                    }
                } else {
                    let size = Int64(values.fileSize ?? 0)
                    let ext = fileURL.pathExtension.lowercased()
                    eventBuffer.append(.file(path: path, name: name, size: size, mtime: mtime, ext: ext))
                }
                
                if eventBuffer.count >= bufferSize {
                    await flushEvents(path, false)
                }
            }
            
            // Flush remaining events
            await flushEvents(rootPath, true)
            
            // Clean up depth in our MainActor builder to ensure all folders are properly sorted
            await MainActor.run {
                var cursor: DiskItem? = builder.currentActiveDirectory
                while let p = cursor {
                    p.children?.sort { $0.size > $1.size }
                    cursor = p.parent
                }
            }
        }.value
        
        // Sort final root children and trigger final completed layout
        await MainActor.run {
            rootItem.children?.sort { $0.size > $1.size }
            builder.sendProgress(currentPath: rootPath, force: true, completed: true)
        }
        
        return rootItem
    }
    
    /// Re-links parent references in a reused cached subtree
    nonisolated private func relinkParentRefs(for item: DiskItem) {
        guard let children = item.children else { return }
        for child in children {
            child.parent = item
            relinkParentRefs(for: child)
        }
    }
    
    /// Flatten a tree into a lookup dictionary of path -> DiskItem
    nonisolated private func buildPathIndex(for root: DiskItem?) -> [String: DiskItem] {
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
