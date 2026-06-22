# DiskInventoryY 💾🔍

**DiskInventoryY** is a modern, ultra-fast disk scanning and storage visualization application for macOS, built from scratch using **Swift 6** and **SwiftUI**. 

Inspired by the legendary **Disk Inventory X**, DiskInventoryY updates the classic disk-mapping concept for the modern era. It introduces high-performance parallel scanning, real-time GUI updates, APFS-optimized incremental rescans, and Metal-accelerated interactive visualizations.

---

## 🌟 Inspiration & Improvements over Disk Inventory X

While **Disk Inventory X** remains a beloved utility for macOS power users, it was built in the Objective-C/Carbon era. Over time, macOS hardware and filesystems have undergone dramatic transformations. 

**DiskInventoryY** is a complete, modern reimagining designed to address the limits of its predecessor:

| Feature | Disk Inventory X (Classic) | DiskInventoryY (Modern) |
| :--- | :--- | :--- |
| **Language & SDK** | Objective-C, Carbon/Cocoa | Swift 6, SwiftUI, modern Apple SDKs |
| **Scan Mechanics** | Single-threaded sequential scan | Multi-threaded parallel scanning using Swift Concurrency (`TaskGroup`) |
| **Progress Reporting** | "Big scan & dump" — wait for completion to see any results | **Live updating GUI** — see file trees and sizes grow dynamically as they are discovered |
| **Rescan Capabilities** | Rescans entire directories from scratch | **APFS mtime-optimized incremental rescans** — skips untouched folders, completing in milliseconds |
| **Visual Rendering** | Legacy CPU-bound Quartz/QuickDraw | **Metal-accelerated SwiftUI Canvas** rendering at a buttery-smooth 120 FPS |
| **Session Saving** | Not supported | **Save & Load sessions** to compact `.diskinvy` files and resume/rescan them later |
| **Modern Filesystem Fit** | Designed for HFS+ | Prefetches APFS-specific directory resource keys to bypass slow system `stat` calls |

---

## ⚡ Key Core Features

### 1. APFS-Optimized mtime-Based Incremental Rescan
In Apple's APFS (Apple File System), any file modification, addition, deletion, or rename changes the modification date (`mtime`) of its parent folder. DiskInventoryY tracks these precise timestamps. 
If a subdirectory's mtime matches our cached scan, the scanner **skips traversing its entire subtree**, instantly re-using the cached nodes. This turns Subsequent scans from a multi-minute crawl into a fractional-second update.

### 2. Live-Updating GUI Throttling
Unlike classic tools, DiskInventoryY streams scan progress into the active UI. To ensure the interface remains fluid and responsive during high-speed scans of millions of files, progress updates are thread-safely buffered and dispatched to the main thread every **100 milliseconds**.

### 3. Interactive Squarified Treemap Layout
Utilizing the **Bruls-Huizing-van Wijk algorithm**, DiskInventoryY partitions your screen space into rectangular tiles where the area of each tile represents its file size. Aspect ratios are kept close to 1:1, preventing unreadable, thin strips. 
* Hovering over a tile displays a floating tooltip with the file's path, size, and category.
* Clicking a tile highlights and scrolls to the file in the outline list, and vice versa.
* It automatically aggregates the top 600 largest files under the selected directory and rolls any remaining small files into a single "Other Small Files" category—accounting for 100% of storage with 0% UI lag.

### 4. Fully Native Split Layout
Featuring native macOS `HSplitView` and `VSplitView` splitters, you can adjust the size of the sidebar file outline, bottom treemap, and right file-extension legend by dragging dividers.

---

## 🛠️ Build & Package Instructions

DiskInventoryY uses the modern **Swift Package Manager (SPM)** as its native format. This means the project acts as an Xcode project out-of-the-box!

### Prerequisites
* macOS 14.0 or later
* Xcode 15.0+ (or Swift 5.9+ toolchain)

### Open and Edit in Xcode
1. Open the project directory in Finder.
2. **Double-click `Package.swift`**.
3. Xcode will automatically open, index the files, and configure the scheme. Press **`Cmd + R`** to build and run natively!

### Build and Package Standalone App via Terminal
A helper script is provided to compile the codebase in release mode (with full `-O` compiler optimizations enabled) and package it into a standalone `.app` bundle:

```bash
# 1. Compile and package the standalone application bundle
./build.sh

# 2. Launch DiskInventoryY immediately
open DiskInventoryY.app
```
This will output `DiskInventoryY.app` directly into your workspace root. You can double-click it in Finder, drag it to `/Applications`, or pin it to your Dock.

---

## 🧪 Headless Diagnostics & Integration Tests

DiskInventoryY includes a fully automated command-line verification suite that validates core scanning performance, session serialization, and incremental APFS speeds on a mock file system—without launching the macOS GUI.

To run the automated test:
```bash
.build/release/DiskInventoryY --test-scanner
```

---

## 📦 File Type Associations
DiskInventoryY registers custom `.diskinvy` documents with macOS. This allows you to double-click saved session files to open them in DiskInventoryY directly.

---

## 📄 License
Created by Pandelis Zografos. Inspired by Disk Inventory X.
