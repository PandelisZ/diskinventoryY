import Foundation

public struct ScanProgress: Sendable {
    public let totalSize: Int64
    public let fileCount: Int
    public let currentItemPath: String
    public let isCompleted: Bool
}

/// Lightweight events emitted by the parallel background scanners
public enum ScanEvent: Sendable {
    case directoryStart(path: String, name: String, mtime: Date)
    case file(path: String, name: String, size: Int64, mtime: Date, ext: String)
    case reuseSubtree(path: String, subtree: DiskItem)
}

/// Thread-safe, reference-type parser that builds the tree and dispatches updates exclusively on the MainActor.
@MainActor
final class TreeBuilder {
    var currentActiveDirectory: DiskItem
    let rootItem: DiskItem
    let rootPath: String
    let progressHandler: @Sendable (ScanProgress, DiskItem) -> Void
    
    var totalSize: Int64 = 0
    var totalFileCount = 0
    
    // Quick cache for O(1) folder parent resolution
    private var pathIndex: [String: DiskItem] = [:]
    
    private var lastUIUpdateTime = DispatchTime.now()
    private let uiUpdateIntervalNanoseconds: UInt64 = 100_000_000 // 100ms
    
    init(rootItem: DiskItem, rootPath: String, progressHandler: @escaping @Sendable (ScanProgress, DiskItem) -> Void) {
        self.currentActiveDirectory = rootItem
        self.rootItem = rootItem
        self.rootPath = rootPath
        self.progressHandler = progressHandler
        self.pathIndex[rootPath] = rootItem
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
    
    /// Inserts any scanning event into the tree, matching parents by absolute path.
    func process(event: ScanEvent, parentPath: String) {
        // Resolve parent folder
        guard let parentFolder = pathIndex[parentPath] else {
            // Fallback to root if parent is missing
            linkItemToFolder(event: event, parent: rootItem)
            return
        }
        linkItemToFolder(event: event, parent: parentFolder)
    }
    
    private func linkItemToFolder(event: ScanEvent, parent: DiskItem) {
        switch event {
        case .directoryStart(let path, let name, let mtime):
            if pathIndex[path] != nil { return } // Already processed
            
            let newFolder = DiskItem(path: path, name: name, type: .directory, size: 0, modificationDate: mtime, children: [])
            newFolder.parent = parent
            parent.children = (parent.children ?? []) + [newFolder]
            pathIndex[path] = newFolder
            
        case .file(let path, let name, let size, let mtime, let ext):
            let newFile = DiskItem(path: path, name: name, type: .file, size: size, modificationDate: mtime, fileExtension: ext)
            newFile.parent = parent
            parent.children = (parent.children ?? []) + [newFile]
            
            // Propagate size upwards through parent chain
            totalSize += size
            totalFileCount += 1
            var cursor: DiskItem? = parent
            while let p = cursor {
                p.size += size
                cursor = p.parent
            }
            
        case .reuseSubtree(_, let cachedSubtree):
            cachedSubtree.parent = parent
            parent.children = (parent.children ?? []) + [cachedSubtree]
            
            // Index the entire cached subtree so any future deep additions find parent folders
            indexSubtreeRecursively(cachedSubtree)
            
            // Recalculate sizes
            let subtreeSize = cachedSubtree.size
            let subtreeFileCount = countFiles(in: cachedSubtree)
            
            totalSize += subtreeSize
            totalFileCount += subtreeFileCount
            
            var cursor: DiskItem? = parent
            while let p = cursor {
                p.size += subtreeSize
                cursor = p.parent
            }
        }
    }
    
    private func indexSubtreeRecursively(_ item: DiskItem) {
        pathIndex[item.path] = item
        if let children = item.children {
            for child in children {
                indexSubtreeRecursively(child)
            }
        }
    }
    
    func finalizeAndSort() {
        for (_, item) in pathIndex {
            item.children?.sort { $0.size > $1.size }
        }
    }
    
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
    // Work queue and worker tracking
    private var queue: [URL] = []
    private var activeWorkersCount = 0
    private var isCancelled = false
    private var pendingContinuations: [CheckedContinuation<URL?, Never>] = []
    
    // Set of standard massive folders to skip deep recursive scanning by default
    private let skippedFolderNames: Set<String> = [
        "node_modules",
        "venv",
        ".venv",
        "env",
        "__pycache__",
        ".git",
        "Pods",
        "Carthage",
        "target",
        ".build",
        ".swiftpm",
        "Caches",
        ".gradle",
        "bower_components"
    ]
    
    public init() {}
    
    public func cancel() {
        isCancelled = true
        for cont in pendingContinuations {
            cont.resume(returning: nil)
        }
        pendingContinuations.removeAll()
    }
    
    private func checkCancelled() -> Bool {
        return isCancelled
    }
    
    /// Push a list of subdirectory URLs onto the parallel work queue
    public func pushWork(_ urls: [URL]) {
        if isCancelled { return }
        
        for url in urls {
            if !pendingContinuations.isEmpty {
                let cont = pendingContinuations.removeFirst()
                cont.resume(returning: url)
            } else {
                queue.append(url)
            }
        }
    }
    
    /// Pop a directory URL to scan. Suspends if queue is empty but other workers are active.
    /// Returns nil if the scan is completely finished or cancelled.
    public func popWork() async -> URL? {
        if isCancelled { return nil }
        
        if !queue.isEmpty {
            activeWorkersCount += 1
            return queue.removeFirst()
        }
        
        if activeWorkersCount == 0 {
            // All workers are idle and queue is empty, scan completed!
            for cont in pendingContinuations {
                cont.resume(returning: nil)
            }
            pendingContinuations.removeAll()
            return nil
        }
        
        // Wait for work
        return await withCheckedContinuation { cont in
            if isCancelled {
                cont.resume(returning: nil)
            } else {
                pendingContinuations.append(cont)
            }
        }
    }
    
    /// Report that a worker has finished scanning its popped directory
    public func workerFinished() {
        activeWorkersCount = max(0, activeWorkersCount - 1)
        if activeWorkersCount == 0 && queue.isEmpty {
            for cont in pendingContinuations {
                cont.resume(returning: nil)
            }
            pendingContinuations.removeAll()
        }
    }
    
    /// Parallelised Scan using 1 worker Task per CPU core
    public func scan(
        url: URL,
        previousRoot: DiskItem? = nil,
        skipDependencies: Bool = true,
        progressHandler: @escaping @Sendable (ScanProgress, DiskItem) -> Void
    ) async -> DiskItem? {
        self.isCancelled = false
        self.queue.removeAll()
        self.activeWorkersCount = 0
        self.pendingContinuations.removeAll()
        
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
        
        // Initialize the tree-building parser state on the MainActor
        let builder = await MainActor.run {
            TreeBuilder(rootItem: rootItem, rootPath: rootPath, progressHandler: progressHandler)
        }
        
        // Seed the work queue with the root directory
        self.queue.append(resolvedURL)
        
        // Determine physical CPU core counts to scale traversal agents
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let rootDepth = resolvedURL.pathComponents.count
        
        print("=== Launching Parallel Scanners: Core Count: \(coreCount) ===")
        
        // Spawn precisely 1 worker per CPU core to run work-stealing directory crawls
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<coreCount {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    
                    let fm = FileManager.default
                    let enumeratorKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
                    
                    // Buffer to batch MainActor hop dispatches
                    var eventBuffer: [(ScanEvent, String)] = []
                    let batchLimit = 60
                    
                    let flushBuffer = { (currentPath: String) async in
                        if eventBuffer.isEmpty { return }
                        let batch = eventBuffer
                        eventBuffer.removeAll()
                        
                        await MainActor.run {
                            for (ev, parentPath) in batch {
                                builder.process(event: ev, parentPath: parentPath)
                            }
                            builder.sendProgress(currentPath: currentPath, force: false, completed: false)
                        }
                    }
                    
                    // Worker loop
                    while let dirURL = await self.popWork() {
                        if await self.checkCancelled() { break }
                        
                        let parentPath = dirURL.standardizedFileURL.path
                        
                        // List immediate contents of this popped directory (extremely fast, non-recursive)
                        guard let contents = try? fm.contentsOfDirectory(
                            at: dirURL,
                            includingPropertiesForKeys: Array(enumeratorKeys),
                            options: [.skipsHiddenFiles]
                        ) else {
                            // If unreadable, complete and pop next
                            await self.workerFinished()
                            continue
                        }
                        
                        var foldersToQueue: [URL] = []
                        
                        for childURL in contents {
                            if await self.checkCancelled() { break }
                            
                            let path = childURL.standardizedFileURL.path
                            let name = childURL.lastPathComponent
                            let folderName = childURL.lastPathComponent
                            
                            guard let values = try? childURL.resourceValues(forKeys: enumeratorKeys) else {
                                continue
                            }
                            
                            let isDir = values.isDirectory ?? false
                            let mtime = values.contentModificationDate ?? Date()
                            
                            if isDir {
                                // Smart Skip Option:
                                // If skipDependencies is enabled and the directory matches our skiplist:
                                if skipDependencies && self.skippedFolderNames.contains(folderName) {
                                    // Calculate immediate size quickly without descending recursively
                                    let shallowContents = (try? fm.contentsOfDirectory(at: childURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                                    var shallowSize: Int64 = 0
                                    for itemURL in shallowContents {
                                        let fileVals = try? itemURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                                        if fileVals?.isDirectory == false {
                                            shallowSize += Int64(fileVals?.fileSize ?? 0)
                                        }
                                    }
                                    
                                    // Emit folder start and inject a collapsed explanation file inside it
                                    eventBuffer.append((.directoryStart(path: path, name: name + " (skipped deep scan)", mtime: mtime), parentPath))
                                    eventBuffer.append((.file(path: path + "/_placeholder_", name: "Deep scan skipped (Double-click to scan)", size: shallowSize, mtime: mtime, ext: "skipped"), path))
                                }
                                // 1. APFS-mtime incremental rescan check
                                else if let cachedNode = savedIndex[path], cachedNode.modificationDate == mtime {
                                    self.relinkParentRefs(for: cachedNode)
                                    eventBuffer.append((.reuseSubtree(path: path, subtree: cachedNode), parentPath))
                                } else {
                                    // 2. Hybrid Load Balancing:
                                    // If depth is shallow (<= 3 levels from root), push onto the centralized queue
                                    // so other idle CPU cores can steal it. Otherwise, scan recursively right now!
                                    let depth = childURL.pathComponents.count - rootDepth
                                    if depth <= 3 {
                                        eventBuffer.append((.directoryStart(path: path, name: name, mtime: mtime), parentPath))
                                        foldersToQueue.append(childURL)
                                    } else {
                                        // Scan sequentially on this worker thread to keep queueing overhead minimal
                                        await self.scanSequentially(
                                            url: childURL,
                                            parentPath: parentPath,
                                            savedIndex: savedIndex,
                                            rootDepth: rootDepth,
                                            skipDependencies: skipDependencies,
                                            eventBuffer: &eventBuffer,
                                            batchLimit: batchLimit,
                                            flushHandler: flushBuffer
                                        )
                                    }
                                }
                            } else {
                                let size = Int64(values.fileSize ?? 0)
                                let ext = childURL.pathExtension.lowercased()
                                eventBuffer.append((.file(path: path, name: name, size: size, mtime: mtime, ext: ext), parentPath))
                            }
                            
                            if eventBuffer.count >= batchLimit {
                                await flushBuffer(path)
                            }
                        }
                        
                        // Push directories to queue
                        if !eventBuffer.isEmpty {
                            await flushBuffer(parentPath)
                        }
                        
                        if !foldersToQueue.isEmpty {
                            // Push folders onto the shared work queue so other cores can scan them
                            await self.pushWork(foldersToQueue)
                        }
                        
                        // Notify coordinator that we finished scanning this specific directory
                        await self.workerFinished()
                    }
                    
                    // Final flush
                    await flushBuffer(rootPath)
                }
            }
        }
        
        // Finalize sorting and notify final layout
        await MainActor.run {
            builder.finalizeAndSort()
            builder.sendProgress(currentPath: rootPath, force: true, completed: true)
        }
        
        return rootItem
    }
    
    /// Recursively scan a deep subdirectory sequentially on a single thread to avoid queue contention
    private func scanSequentially(
        url: URL,
        parentPath: String,
        savedIndex: [String: DiskItem],
        rootDepth: Int,
        skipDependencies: Bool,
        eventBuffer: inout [(ScanEvent, String)],
        batchLimit: Int,
        flushHandler: (String) async -> Void
    ) async {
        if Task.isCancelled { return }
        let cancelled = self.checkCancelled()
        if cancelled { return }
        
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        let folderName = url.lastPathComponent
        
        let fm = FileManager.default
        let enumeratorKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        
        guard let values = try? url.resourceValues(forKeys: enumeratorKeys) else { return }
        let isDir = values.isDirectory ?? false
        let mtime = values.contentModificationDate ?? Date()
        
        if !isDir {
            let size = Int64(values.fileSize ?? 0)
            let ext = url.pathExtension.lowercased()
            eventBuffer.append((.file(path: path, name: name, size: size, mtime: mtime, ext: ext), parentPath))
            return
        }
        
        // Check Smart Skip for nested sequential files
        if skipDependencies && self.skippedFolderNames.contains(folderName) {
            let shallowContents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            var shallowSize: Int64 = 0
            for itemURL in shallowContents {
                let fileVals = try? itemURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if fileVals?.isDirectory == false {
                    shallowSize += Int64(fileVals?.fileSize ?? 0)
                }
            }
            
            eventBuffer.append((.directoryStart(path: path, name: name + " (skipped deep scan)", mtime: mtime), parentPath))
            eventBuffer.append((.file(path: path + "/_placeholder_", name: "Deep scan skipped (Double-click to scan)", size: shallowSize, mtime: mtime, ext: "skipped"), path))
            return
        }
        
        // Check mtime match
        if let cachedNode = savedIndex[path], cachedNode.modificationDate == mtime {
            relinkParentRefs(for: cachedNode)
            eventBuffer.append((.reuseSubtree(path: path, subtree: cachedNode), parentPath))
            return
        }
        
        // Enter directory
        eventBuffer.append((.directoryStart(path: path, name: name, mtime: mtime), parentPath))
        
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(enumeratorKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        for childURL in contents {
            if eventBuffer.count >= batchLimit {
                await flushHandler(childURL.path)
            }
            
            await scanSequentially(
                url: childURL,
                parentPath: path,
                savedIndex: savedIndex,
                rootDepth: rootDepth,
                skipDependencies: skipDependencies,
                eventBuffer: &eventBuffer,
                batchLimit: batchLimit,
                flushHandler: flushHandler
            )
        }
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
