import Foundation

@Sendable
func runHeadlessScannerTest() {
    print("=========================================================")
    print("      DiskInventoryY - AUTOMATED SCANNER VERIFICATION")
    print("=========================================================")
    
    let fm = FileManager.default
    let tempDirURL = fm.temporaryDirectory.appendingPathComponent("DiskInventoryY_Test_\(UUID().uuidString)")
    let sessionFileURL = fm.temporaryDirectory.appendingPathComponent("session_\(UUID().uuidString).diskinvy")
    
    do {
        // 1. Setup mock directory structure
        print("[1/6] Setting up mock file system structure...")
        try fm.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
        
        let subDirURL = tempDirURL.appendingPathComponent("SubFolder")
        try fm.createDirectory(at: subDirURL, withIntermediateDirectories: true)
        
        // Create files of deterministic size
        let file1URL = tempDirURL.appendingPathComponent("root_file.txt")
        let file2URL = tempDirURL.appendingPathComponent("image_file.jpg")
        let file3URL = subDirURL.appendingPathComponent("video_file.mp4")
        let file4URL = subDirURL.appendingPathComponent("archive.zip")
        
        try Data(repeating: 65, count: 10 * 1024).write(to: file1URL) // 10 KB
        try Data(repeating: 66, count: 20 * 1024).write(to: file2URL) // 20 KB
        try Data(repeating: 67, count: 50 * 1024).write(to: file3URL) // 50 KB
        try Data(repeating: 68, count: 100 * 1024).write(to: file4URL) // 100 KB
        
        print("Created mock structure at: \(tempDirURL.path)")
        print("  - root_file.txt (10 KB)")
        print("  - image_file.jpg (20 KB)")
        print("  - SubFolder/video_file.mp4 (50 KB)")
        print("  - SubFolder/archive.zip (100 KB)")
        print("Total expected size: 180 KB (184,320 bytes)")
        
        // 2. Perform fresh scan
        print("\n[2/6] Running fresh parallel disk scan...")
        let scanner = DiskScanner()
        let t1Start = DispatchTime.now()
        
        // We use a semaphore or await directly in Task
        let group = DispatchGroup()
        group.enter()
        
        var scannedRoot: DiskItem? = nil
        
        Task {
            scannedRoot = await scanner.scan(url: tempDirURL) { progress, _ in
                // Progress updates ignored for headless test
            }
            group.leave()
        }
        group.wait()
        
        let t1End = DispatchTime.now()
        let t1Elapsed = Double(t1End.uptimeNanoseconds - t1Start.uptimeNanoseconds) / 1_000_000_000.0
        
        guard let root = scannedRoot else {
            print("❌ ERROR: Fresh scan failed to return root node.")
            exit(1)
        }
        
        print("Fresh scan complete in \(String(format: "%.4f", t1Elapsed)) seconds.")
        print("Scanned root size: \(root.size) bytes (expected: 184,320 bytes)")
        
        if root.size == 184_320 {
            print("✅ Size matches perfectly!")
        } else {
            print("❌ ERROR: Size mismatch! Got \(root.size) bytes.")
            exit(1)
        }
        
        // 3. Save scan session
        print("\n[3/6] Testing session serialization (saving to disk)...")
        try SessionManager.shared.save(root, to: sessionFileURL, scanURL: tempDirURL)
        print("Saved scan session to: \(sessionFileURL.path)")
        
        // 4. Load scan session back
        print("\n[4/6] Testing session deserialization (loading from disk)...")
        let loadedSession = try SessionManager.shared.load(from: sessionFileURL)
        let loadedRoot = loadedSession.rootItem
        print("Loaded session scan URL: \(loadedSession.scanURL?.path ?? "None")")
        print("Loaded root size: \(loadedRoot.size) bytes")
        
        if loadedRoot.size == 184_320 {
            print("✅ Deserialized tree structure and size verified successfully!")
        } else {
            print("❌ ERROR: Deserialized size mismatch!")
            exit(1)
        }
        
        // 5. Modify files and run APFS-Optimized Incremental Rescan
        print("\n[5/6] Simulating disk modifications and running APFS-Optimized Incremental Rescan...")
        
        // Wait 1.1s to guarantee mtime timestamp on APFS shifts forward clearly
        Thread.sleep(forTimeInterval: 1.1)
        
        // Modify root_file.txt size from 10 KB to 30 KB (updates root directory mtime, but SubFolder mtime is UNCHANGED)
        try Data(repeating: 69, count: 30 * 1024).write(to: file1URL) // Now 30 KB
        print("Modified 'root_file.txt' size: 10 KB -> 30 KB. Expected new total: 200 KB (204,800 bytes).")
        
        let t2Start = DispatchTime.now()
        group.enter()
        
        var rescannedRoot: DiskItem? = nil
        Task {
            // Pass loadedRoot as previousRoot to trigger incremental scan speedup
            rescannedRoot = await scanner.scan(url: tempDirURL, previousRoot: loadedRoot) { progress, _ in }
            group.leave()
        }
        group.wait()
        
        let t2End = DispatchTime.now()
        let t2Elapsed = Double(t2End.uptimeNanoseconds - t2Start.uptimeNanoseconds) / 1_000_000_000.0
        
        guard let newRoot = rescannedRoot else {
            print("❌ ERROR: Incremental rescan failed to return root node.")
            exit(1)
        }
        
        print("Incremental rescan complete in \(String(format: "%.4f", t2Elapsed)) seconds.")
        print("Incremental root size: \(newRoot.size) bytes (expected: 204,800 bytes)")
        
        if newRoot.size == 204_800 {
            print("✅ Size updated and verified perfectly after modifications!")
        } else {
            print("❌ ERROR: Incremental size mismatch! Got \(newRoot.size) bytes.")
            exit(1)
        }
        
        // Calculate speedup factor
        let speedup = t1Elapsed / t2Elapsed
        print("Incremental Scan Speedup Factor: \(String(format: "%.2f", speedup))x")
        
        // 6. Clean up temporary files
        print("\n[6/6] Cleaning up temporary test files...")
        try fm.removeItem(at: tempDirURL)
        try fm.removeItem(at: sessionFileURL)
        print("Cleanup complete.")
        
        print("\n=========================================================")
        print("      🎉 DISKINVENTORYY CORE SCANNERS VERIFIED 100% OK!")
        print("=========================================================")
        
    } catch {
        print("❌ INTEGRATION TEST FAILED: \(error.localizedDescription)")
        exit(1)
    }
}
