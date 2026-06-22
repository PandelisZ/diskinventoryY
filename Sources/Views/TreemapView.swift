import Foundation
import SwiftUI
import CoreGraphics

public struct TreemapNode: Identifiable, Sendable {
    public var id: String { item.path }
    public let item: DiskItem
    public let rect: CGRect
    public let color: Color
}

public final class TreemapLayout {
    /// Compute squarified layout for items in the given size rect
    public static func layout(items: [DiskItem], in rect: CGRect) -> [TreemapNode] {
        guard rect.width > 20 && rect.height > 20 && !items.isEmpty else { return [] }
        
        let totalSize = items.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }
        
        // Convert items to area-based structures
        let areaScale = (Double(rect.width) * Double(rect.height)) / Double(totalSize)
        let elementAreas = items.map { Double($0.size) * areaScale }
        
        var nodes: [TreemapNode] = []
        squarify(
            items: items,
            areas: elementAreas,
            currentIndex: 0,
            currentGroup: [],
            currentGroupArea: 0,
            rect: rect,
            nodes: &nodes
        )
        return nodes
    }
    
    private static func squarify(
        items: [DiskItem],
        areas: [Double],
        currentIndex: Int,
        currentGroup: [Int],
        currentGroupArea: Double,
        rect: CGRect,
        nodes: inout [TreemapNode]
    ) {
        if currentIndex >= items.count {
            if !currentGroup.isEmpty {
                layoutRow(items: items, areas: areas, indices: currentGroup, groupArea: currentGroupArea, rect: rect, nodes: &nodes)
            }
            return
        }
        
        let nextArea = areas[currentIndex]
        let shortestSide = Double(min(rect.width, rect.height))
        
        if shortestSide <= 0 { return }
        
        let newGroup = currentGroup + [currentIndex]
        let newGroupArea = currentGroupArea + nextArea
        
        let oldRatio = worstRatio(areas: areas, indices: currentGroup, groupArea: currentGroupArea, shortestSide: shortestSide)
        let newRatio = worstRatio(areas: areas, indices: newGroup, groupArea: newGroupArea, shortestSide: shortestSide)
        
        if currentGroup.isEmpty || newRatio <= oldRatio {
            // Keep adding to row
            squarify(
                items: items,
                areas: areas,
                currentIndex: currentIndex + 1,
                currentGroup: newGroup,
                currentGroupArea: newGroupArea,
                rect: rect,
                nodes: &nodes
            )
        } else {
            // Layout current row, then start a new row with remaining space
            let remainingRect = layoutRow(items: items, areas: areas, indices: currentGroup, groupArea: currentGroupArea, rect: rect, nodes: &nodes)
            squarify(
                items: items,
                areas: areas,
                currentIndex: currentIndex,
                currentGroup: [],
                currentGroupArea: 0,
                rect: remainingRect,
                nodes: &nodes
            )
        }
    }
    
    private static func worstRatio(areas: [Double], indices: [Int], groupArea: Double, shortestSide: Double) -> Double {
        guard !indices.isEmpty && groupArea > 0 else { return Double.greatestFiniteMagnitude }
        
        let minArea = indices.map { areas[$0] }.min() ?? 0
        let maxArea = indices.map { areas[$0] }.max() ?? 0
        
        let sideSquared = shortestSide * shortestSide
        let groupAreaSquared = groupArea * groupArea
        
        let r1 = (sideSquared * maxArea) / groupAreaSquared
        let r2 = groupAreaSquared / (sideSquared * minArea)
        
        return max(r1, r2)
    }
    
    @discardableResult
    private static func layoutRow(
        items: [DiskItem],
        areas: [Double],
        indices: [Int],
        groupArea: Double,
        rect: CGRect,
        nodes: inout [TreemapNode]
    ) -> CGRect {
        let isHorizontal = rect.width >= rect.height
        let shortestSide = Double(isHorizontal ? rect.height : rect.width)
        let thickness = groupArea / shortestSide
        
        var offset: Double = 0
        for idx in indices {
            let itemArea = areas[idx]
            let itemLength = itemArea / thickness
            
            let itemRect: CGRect
            if isHorizontal {
                // Layout as a vertical column on the left of the bounding box.
                // Items stack vertically (along the y-axis).
                itemRect = CGRect(
                    x: Double(rect.origin.x),
                    y: Double(rect.origin.y) + offset,
                    width: thickness,
                    height: itemLength
                )
            } else {
                // Layout as a horizontal row at the top of the bounding box.
                // Items stack horizontally (along the x-axis).
                itemRect = CGRect(
                    x: Double(rect.origin.x) + offset,
                    y: Double(rect.origin.y),
                    width: itemLength,
                    height: thickness
                )
            }
            
            let item = items[idx]
            let color = ExtensionColorManager.shared.color(for: item.fileExtension)
            nodes.append(TreemapNode(item: item, rect: itemRect, color: color))
            
            offset += itemLength
        }
        
        if isHorizontal {
            // Cut off the vertical column from the left side of the remaining area.
            return CGRect(
                x: Double(rect.origin.x) + thickness,
                y: Double(rect.origin.y),
                width: max(0, Double(rect.width) - thickness),
                height: Double(rect.height)
            )
        } else {
            // Cut off the horizontal row from the top of the remaining area.
            return CGRect(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y) + thickness,
                width: Double(rect.width),
                height: max(0, Double(rect.height) - thickness)
            )
        }
    }
}

public struct TreemapView: View {
    let rootItem: DiskItem?
    @Binding var selectedItem: DiskItem?
    
    @State private var hoveredNode: TreemapNode?
    @State private var mouseLocation: CGPoint = .zero
    
    private let maxNodes = 600
    
    public init(rootItem: DiskItem?, selectedItem: Binding<DiskItem?>) {
        self.rootItem = rootItem
        self._selectedItem = selectedItem
    }
    
    /// Collect largest leaf files recursively under standard item
    private func collectFiles(from item: DiskItem) -> [DiskItem] {
        var files: [DiskItem] = []
        
        func traverse(_ node: DiskItem) {
            if node.type == .file {
                files.append(node)
            } else if let children = node.children {
                for child in children {
                    traverse(child)
                }
            }
        }
        
        traverse(item)
        files.sort { $0.size > $1.size }
        
        if files.count > maxNodes {
            let topFiles = Array(files.prefix(maxNodes - 1))
            let remainingSize = files.suffix(from: maxNodes - 1).reduce(0) { $0 + $1.size }
            if remainingSize > 0 {
                let otherItem = DiskItem(
                    path: item.path + "/_other_small_files_",
                    name: "Other Small Files",
                    type: .file,
                    size: remainingSize,
                    fileExtension: "tmp"
                )
                return topFiles + [otherItem]
            }
            return topFiles
        }
        return files
    }
    
    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    public var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let files = rootItem.map { collectFiles(from: $0) } ?? []
            let nodes = TreemapLayout.layout(items: files, in: rect)
            
            ZStack(alignment: .topLeading) {
                // Background
                Color(NSColor.underPageBackgroundColor)
                
                if nodes.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "circle.grid.hex")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text(rootItem == nil ? "No Disk Scanned" : "Scanning/No Files Found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                } else {
                    // Modern Fast Metal-backed Canvas
                    Canvas { context, size in
                        for node in nodes {
                            let rect = node.rect
                            
                            // Bevel / border effects
                            let path = Path(rect)
                            context.fill(path, with: .color(node.color))
                            
                            // Highlight hovered/selected
                            if let selected = selectedItem, selected.path == node.item.path {
                                context.stroke(path, with: .color(.white), lineWidth: 2.0)
                            } else if let hovered = hoveredNode, hovered.item.path == node.item.path {
                                context.stroke(path, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                            } else {
                                // Default nice thin borders
                                context.stroke(path, with: .color(.black.opacity(0.15)), lineWidth: 0.5)
                            }
                        }
                    }
                    // Capture hover and clicks via combined gesture and mouse movement tracker
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { val in
                                mouseLocation = val.location
                                if let node = nodes.first(where: { $0.rect.contains(val.location) }) {
                                    hoveredNode = node
                                } else {
                                    hoveredNode = nil
                                }
                            }
                            .onEnded { val in
                                if let node = nodes.first(where: { $0.rect.contains(val.location) }) {
                                    // Set selected
                                    selectedItem = node.item
                                }
                                hoveredNode = nil
                            }
                    )
                    // On macOS, track mouse movement for hover tooltip without clicking
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            mouseLocation = location
                            if let node = nodes.first(where: { $0.rect.contains(location) }) {
                                hoveredNode = node
                            } else {
                                hoveredNode = nil
                            }
                        case .ended:
                            hoveredNode = nil
                        }
                    }
                    
                    // Hover Tooltip overlay
                    if let hover = hoveredNode {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hover.item.name)
                                .font(.system(size: 11, weight: .bold))
                            Text(formattedSize(hover.item.size))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(hover.item.path)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(6)
                        .shadow(radius: 4)
                        .frame(maxWidth: 320)
                        .position(x: tooltipPositionX(for: mouseLocation, viewWidth: geo.size.width),
                                  y: tooltipPositionY(for: mouseLocation, viewHeight: geo.size.height))
                    }
                }
            }
        }
    }
    
    // Help avoid tooltips overflowing from screen bounds
    private func tooltipPositionX(for loc: CGPoint, viewWidth: Double) -> Double {
        if loc.x + 170 > viewWidth {
            return loc.x - 170
        }
        return loc.x + 170
    }
    
    private func tooltipPositionY(for loc: CGPoint, viewHeight: Double) -> Double {
        if loc.y - 45 < 0 {
            return loc.y + 45
        }
        return loc.y - 45
    }
}
