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
                                
                                List(selection: $viewModel.selectedItem) {
                                    OutlineGroup(root, children: \.children) { item in
                                        HStack(spacing: 8) {
                                            Image(systemName: item.type == .directory ? "folder.fill" : "doc.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(item.type == .directory ? .blue : .secondary)
                                                .frame(width: 14)
                                            
                                            Text(item.name)
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                            
                                            Spacer()
                                            
                                            // Count of immediate children if directory
                                            if item.type == .directory {
                                                Text("\(item.childCount) items")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            
                                            // Human readable size
                                            Text(formattedSize(item.size))
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.primary)
                                                .frame(width: 80, alignment: .trailing)
                                            
                                            // Visual space ratio bar
                                            PercentageBar(percentage: item.percentageOfParent)
                                                .frame(width: 50, height: 6)
                                                .padding(.leading, 4)
                                        }
                                        .tag(item)
                                        .contextMenu {
                                            Button("Reveal in Finder") {
                                                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                                            }
                                            Button("Copy Path") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(item.path, forType: .string)
                                            }
                                        }
                                    }
                                }
                                .listStyle(.sidebar)
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
