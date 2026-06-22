import SwiftUI
import UniformTypeIdentifiers

struct PercentageBar: View {
    let percentage: Double
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.15))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percentage))))
            }
        }
    }
}

public struct ContentView: View {
    @State private var viewModel = DiskInventoryViewModel()
    
    // Track expanded nodes in Outline (UUID/Paths)
    @State private var expandedPaths: Set<String> = []
    @State private var selectedExtensionGroup: FileExtensionGroup? = nil
    
    public init() {}
    
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    public var body: some View {
        NavigationStack {
            HSplitView {
                // Main split: Left Side (Directory list + Treemap or Centered Hub)
                Group {
                    if let root = viewModel.rootItem {
                        VSplitView {
                            // Top: Directory list outline
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Folder Structure")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Root: \(root.path)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(NSColor.windowBackgroundColor))
                                
                                Divider()
                                
                            // Custom Tree outline list view with programmatic selection expansion and scroll-to-center
                            ScrollViewReader { proxy in
                                List {
                                    OutlineRow(item: root, selectedItem: $viewModel.selectedItem, expandedPaths: $expandedPaths) { targetFolder in
                                        viewModel.deepScanFolder(at: targetFolder)
                                    }
                                }
                                .listStyle(.sidebar)
                                .onChange(of: viewModel.selectedItem) { oldVal, newValue in
                                    if let selected = newValue {
                                        // 1. Programmatically expand all parent directories recursively
                                        var cursor = selected.parent
                                        while let p = cursor {
                                            expandedPaths.insert(p.path)
                                            cursor = p.parent
                                        }
                                        
                                        // 2. Smoothly scroll the list outline to reveal and center the selected item
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                            withAnimation(.easeInOut(duration: 0.25)) {
                                                proxy.scrollTo(selected.path, anchor: .center)
                                            }
                                        }
                                    }
                                }
                            }
                            }
                            .frame(minHeight: 150)
                            
                            // Bottom: Treemap View
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text("Interactive Treemap Layout (Top Files)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    if let focused = viewModel.treemapRoot {
                                        Text("Focusing: \(focused.name)")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(NSColor.windowBackgroundColor))
                                
                                Divider()
                                
                                TreemapView(rootItem: viewModel.treemapRoot, selectedItem: $viewModel.selectedItem)
                            }
                            .frame(minHeight: 150)
                        }
                    } else if viewModel.isScanning {
                        // Beautiful, completely centered loading / scanning view
                        VStack(spacing: 20) {
                            ProgressView()
                                .controlSize(.large)
                            
                            Text("Analyzing Volume Storage...")
                                .font(.system(size: 16, weight: .bold))
                            
                            if let progress = viewModel.scanProgress {
                                Text(progress.currentItemPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: 440)
                                
                                Text("\(progress.fileCount) files scanned · \(formattedSize(progress.totalSize))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Button(action: viewModel.cancelActiveScan) {
                                Label("Cancel Scan", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .padding(.top, 12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.underPageBackgroundColor))
                    } else {
                        // Completely Centered Welcome selection Hub
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                VStack(spacing: 24) {
                                    VStack(spacing: 8) {
                                        Image(systemName: "circle.grid.hex")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.blue.gradient)
                                        Text("DiskInventoryY")
                                            .font(.system(size: 24, weight: .bold))
                                        Text("Select a volume or folder to begin scanning")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    // List of available disks
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("MOUNTED DISKS")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                        
                                        ScrollView {
                                            VStack(spacing: 8) {
                                                ForEach(viewModel.mountedVolumes) { vol in
                                                    VolumeRow(vol: vol) {
                                                        viewModel.startScan(at: vol.url)
                                                    }
                                                }
                                            }
                                        }
                                        .frame(height: 180)
                                    }
                                    .frame(width: 440)
                                    .padding(12)
                                    .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                                    .cornerRadius(8)
                                    
                                    HStack(spacing: 12) {
                                        Text("Or scan a specific folder:")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                        
                                        Button(action: selectFolderToScan) {
                                            Label("Choose Folder...", systemImage: "folder.badge.plus")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.regular)
                                    }
                                }
                                .padding(32)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(16)
                                .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
                                Spacer()
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.underPageBackgroundColor))
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity)
                
                // Right Side: File Extension Legend
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("File Types & Legend")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    if viewModel.extensionGroups.isEmpty {
                        VStack {
                            Spacer()
                            Text("No file extensions")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                            Spacer()
                        }
                    } else {
                        List {
                            ForEach(viewModel.extensionGroups) { group in
                                Button {
                                    selectedExtensionGroup = group
                                } label: {
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(group.color)
                                            .frame(width: 12, height: 12)
                                            .shadow(radius: 0.5)
                                        
                                        Text(".\(group.fileExtension)")
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        
                                        Spacer()
                                        
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(formattedSize(group.totalSize))
                                                .font(.system(size: 11, design: .monospaced))
                                            Text("\(group.fileCount) files")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .frame(minWidth: 180, maxWidth: 280)
            }
            .navigationTitle("DiskInventoryY")
            .toolbar {
                // Main scan triggers
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: selectFolderToScan) {
                        Label("Scan Folder...", systemImage: "magnifyingglass")
                    }
                    .help("Scan a folder or drive")
                    .disabled(viewModel.isScanning)
                    
                    Menu {
                        ForEach(viewModel.mountedVolumes) { vol in
                            Button {
                                viewModel.startScan(at: vol.url)
                            } label: {
                                Label {
                                    Text("\(vol.name) (\(formattedSize(vol.totalCapacity)))")
                                } icon: {
                                    Image(systemName: vol.isInternal ? "internaldrive" : "externaldrive")
                                }
                            }
                        }
                    } label: {
                        Label("Scan Disk", systemImage: "internaldrive")
                    }
                    .help("Perform a full scan on one of the mounted disks")
                    .disabled(viewModel.isScanning)
                    
                    Button(action: triggerIncrementalScan) {
                        Label("Rescan Folder", systemImage: "arrow.clockwise")
                    }
                    .help("Perform APFS-optimized incremental rescan of current directory")
                    .disabled(viewModel.isScanning || viewModel.currentScanURL == nil)
                    
                    if viewModel.isScanning {
                        Button(action: viewModel.cancelActiveScan) {
                            Label("Cancel Scan", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .help("Cancel running scan")
                    }
                }
                
                // Session saving & loading
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: saveSession) {
                        Label("Save Session", systemImage: "square.and.arrow.down")
                    }
                    .help("Save current scanned tree to diskinvy file")
                    .disabled(viewModel.rootItem == nil || viewModel.isScanning)
                    
                    Button(action: loadSession) {
                        Label("Load Session", systemImage: "square.and.arrow.up")
                    }
                    .help("Load a saved diskinvy session")
                    .disabled(viewModel.isScanning)
                }
            }
            // Glassmorphic real-time scanning overlay at bottom
            .safeAreaInset(edge: .bottom) {
                if viewModel.isScanning, let progress = viewModel.scanProgress {
                    VStack(spacing: 8) {
                        Divider()
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Scanning files...")
                                    .font(.system(size: 11, weight: .bold))
                                Text(progress.currentItemPath)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            
                            Spacer()
                            
                            HStack(spacing: 16) {
                                Text("\(progress.fileCount) files")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                
                                Text(formattedSize(progress.totalSize))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                    }
                }
            }
            .onAppear {
                // Start a high-speed parallelised scan on the user's home folder on startup first!
                let homeURL = FileManager.default.homeDirectoryForCurrentUser
                viewModel.startScan(at: homeURL)
            }
            .sheet(item: $selectedExtensionGroup) { group in
                let files = collectFiles(withExtension: group.fileExtension, under: viewModel.rootItem)
                ExtensionFilesView(group: group, files: files) { targetFile in
                    viewModel.selectedItem = targetFile
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func selectFolderToScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Select Folder to Scan"
        panel.prompt = "Choose"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.startScan(at: url)
            }
        }
    }
    
    private func triggerIncrementalScan() {
        viewModel.startIncrementalScan()
    }
    
    private func saveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "diskinvy") ?? .json]
        panel.nameFieldStringValue = "DiskInventory_Scan"
        panel.title = "Save Scan Session"
        panel.prompt = "Save"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try SessionManager.shared.save(viewModel.rootItem, to: url, scanURL: viewModel.currentScanURL)
                } catch {
                    showError(title: "Save Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    private func loadSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "diskinvy") ?? .json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Load Scan Session"
        panel.prompt = "Load"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    let session = try SessionManager.shared.load(from: url)
                    viewModel.rootItem = session.rootItem
                    viewModel.currentScanURL = session.scanURL
                    viewModel.selectedItem = nil
                    viewModel.updateExtensionGroups(for: session.rootItem)
                } catch {
                    showError(title: "Load Failed", message: error.localizedDescription)
                }
            }
        }
    }
    
    private func collectFiles(withExtension ext: String, under root: DiskItem?) -> [DiskItem] {
        guard let root = root else { return [] }
        var results: [DiskItem] = []
        let targetExt = ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        func traverse(_ node: DiskItem) {
            if node.type == .file {
                let fileExt = node.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
                if fileExt == targetExt || (targetExt == "no extension" && fileExt.isEmpty) {
                    results.append(node)
                }
            } else if let children = node.children {
                for child in children {
                    traverse(child)
                }
            }
        }
        
        traverse(root)
        return results.sorted { $0.size > $1.size }
    }
    
    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct VolumeRow: View {
    let vol: MountedVolume
    let onScan: () -> Void
    
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vol.isInternal ? "internaldrive" : "externaldrive")
                .font(.system(size: 20))
                .foregroundStyle(.blue)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(vol.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(formattedSize(vol.totalCapacity)) capacity · \(formattedSize(vol.availableCapacity)) available")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("Scan Disk") {
                onScan()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct OutlineRow: View {
    let item: DiskItem
    @Binding var selectedItem: DiskItem?
    @Binding var expandedPaths: Set<String>
    let onDeepScan: (DiskItem) -> Void
    
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    var body: some View {
        if item.type == .directory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedPaths.contains(item.path) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedPaths.insert(item.path)
                        } else {
                            expandedPaths.remove(item.path)
                        }
                    }
                )
            ) {
                if let children = item.children {
                    ForEach(children) { child in
                        OutlineRow(item: child, selectedItem: $selectedItem, expandedPaths: $expandedPaths, onDeepScan: onDeepScan)
                    }
                }
            } label: {
                rowContent
            }
        } else {
            rowContent
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: item.type == .directory ? "folder.fill" : "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(item.type == .directory ? .blue : .secondary)
                .frame(width: 14)
            
            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
            
            Spacer()
            
            if item.type == .directory {
                Text("\(item.childCount) items")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            
            Text(formattedSize(item.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .trailing)
            
            PercentageBar(percentage: item.percentageOfParent)
                .frame(width: 50, height: 6)
                .padding(.leading, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItem = item
        }
        .onTapGesture(count: 2) {
            if item.type == .directory {
                onDeepScan(item)
            }
        }
        .id(item.path) // Critical for ScrollViewReader matching!
        .tag(item)
        .contextMenu {
            if item.type == .directory {
                Button("Deep Scan Folder") {
                    onDeepScan(item)
                }
                Divider()
            }
            
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(selectedItem?.path == item.path ? Color(NSColor.selectedControlColor).opacity(0.18) : Color.clear)
        .cornerRadius(4)
    }
}

struct ExtensionFilesView: View {
    let group: FileExtensionGroup
    let files: [DiskItem]
    let onLocate: (DiskItem) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText = ""
    
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    var filteredFiles: [DiskItem] {
        if searchText.isEmpty {
            return files
        } else {
            return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.path.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(group.color)
                    .frame(width: 16, height: 16)
                
                Text("Files with Extension .\(group.fileExtension)")
                    .font(.headline)
                
                Spacer()
                
                Text("\(group.fileCount) files · \(formattedSize(group.totalSize))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            
            Divider()
            
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files by name or path...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                if !searchText.isEmpty {
                    Button("Clear") {
                        searchText = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // List of Files
            List {
                ForEach(filteredFiles) { file in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(file.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        
                        Spacer()
                        
                        Text(formattedSize(file.size))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onLocate(file)
                        dismiss()
                    }
                    .contextMenu {
                        Button("Locate in Folder Structure") {
                            onLocate(file)
                            dismiss()
                        }
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            
            Divider()
            
            // Bottom bar
            HStack {
                Text("Click any file to locate it in the directory tree")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 600, height: 450)
    }
}
