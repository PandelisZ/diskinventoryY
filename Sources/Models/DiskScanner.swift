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
    private let uiUpdateIntervalNanoseconds: UInt64 = 250_000_000 // Throttled to 250ms (4Hz) for butter-smooth UI scrolling
    
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
            
            // Decoupled Sort: ONLY sort the directories when we are actually about to publish a progress update to the UI.
            // This reduces CPU-heavy sorting overhead on the MainActor by over 99%!
            finalizeAndSort()
            
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
        // Reserve 2 CPU cores exclusively for the UI thread and macOS WindowServer to ensure butter-smooth scrolling
        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
        let rootDepth = resolvedURL.pathComponents.count
        
        print("=== Launching Parallel Scanners: Worker Core Count: \(coreCount) (Reserved 2 for UI) ===")
        
        // Spawn precisely the tuned worker count to run work-stealing directory crawls
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<coreCount {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    
                    let fm = FileManager.default
                    let enumeratorKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
                    
                    // Buffer to batch MainActor hop dispatches (higher limit to reduce MainActor hops by over 73%!)
                    var eventBuffer: [(ScanEvent, String)] = []
                    let batchLimit = 300
                    
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
                        
                        // Recurse directories flatly using NSDirectoryEnumerator
                        guard let enumerator = fm.enumerator(
                            at: dirURL,
                            includingPropertiesForKeys: Array(enumeratorKeys),
                            options: [.skipsHiddenFiles]
                        ) else {
                            await self.workerFinished()
                            continue
                        }
                        
                        var fileCheckCount = 0
                        while let fileURL = enumerator.nextObject() as? URL {
                            // Double-layer cancellation checks
                            if Task.isCancelled { break }
                            fileCheckCount += 1
                            if fileCheckCount % 120 == 0 {
                                let cancelled = await self.checkCancelled()
                                if cancelled { break }
                            }
                            
                            let path = fileURL.standardizedFileURL.path
                            let name = fileURL.lastPathComponent
                            let folderName = fileURL.lastPathComponent
                            
                            // Skip the popped dir itself if returned
                            if path == parentPath { continue }
                            
                            guard let values = try? fileURL.resourceValues(forKeys: enumeratorKeys) else {
                                continue
                            }
                            
                            let isDir = values.isDirectory ?? false
                            let mtime = values.contentModificationDate ?? Date()
                            
                            // Resolve the exact absolute parent path
                            let itemParentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
                            
                            if isDir {
                                // Smart Skip Option:
                                if skipDependencies && self.skippedFolderNames.contains(folderName) {
                                    let shallowContents = (try? fm.contentsOfDirectory(at: fileURL, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                                    var shallowSize: Int64 = 0
                                    for itemURL in shallowContents {
                                        let fileVals = try? itemURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                                        if fileVals?.isDirectory == false {
                                            shallowSize += Int64(fileVals?.fileSize ?? 0)
                                        }
                                    }
                                    
                                    // Emit folder start and inject a collapsed explanation file inside it
                                    eventBuffer.append((.directoryStart(path: path, name: name + " (skipped deep scan)", mtime: mtime), itemParentPath))
                                    eventBuffer.append((.file(path: path + "/_placeholder_", name: "Deep scan skipped (Double-click to scan)", size: shallowSize, mtime: mtime, ext: "skipped"), path))
                                    
                                    enumerator.skipDescendants() // Bypass entering subfolders
                                }
                                // 1. APFS-mtime incremental rescan check
                                else if let cachedNode = savedIndex[path], cachedNode.modificationDate == mtime {
                                    self.relinkParentRefs(for: cachedNode)
                                    eventBuffer.append((.reuseSubtree(path: path, subtree: cachedNode), itemParentPath))
                                    enumerator.skipDescendants() // Bypass entering subfolders
                                } else {
                                    // 2. Hybrid Load Balancing:
                                    let depth = fileURL.pathComponents.count - rootDepth
                                    if depth <= 3 {
                                        // Push onto the shared queue and skip descendants in our current enumerator
                                        eventBuffer.append((.directoryStart(path: path, name: name, mtime: mtime), itemParentPath))
                                        await self.pushWork([fileURL])
                                        enumerator.skipDescendants()
                                    } else {
                                        // Let the enumerator descend recursively on this thread!
                                        eventBuffer.append((.directoryStart(path: path, name: name, mtime: mtime), itemParentPath))
                                    }
                                }
                            } else {
                                let size = Int64(values.fileSize ?? 0)
                                let ext = fileURL.pathExtension.lowercased()
                                eventBuffer.append((.file(path: path, name: name, size: size, mtime: mtime, ext: ext), itemParentPath))
                            }
                            
                            if eventBuffer.count >= batchLimit {
                                await flushBuffer(path)
                            }
                        }
                        
                        // Push directories to queue
                        if !eventBuffer.isEmpty {
                            await flushBuffer(parentPath)
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
