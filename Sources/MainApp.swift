import SwiftUI

@main
struct MainApp: App {
    init() {
        // If run with command-line arguments, handle them and exit
        let args = CommandLine.arguments
        if args.contains("--test-scanner") {
            Task {
                await runHeadlessScannerTest()
                exit(0)
            }
            dispatchMain()
        }
    }
    
    var body: some Scene {
        Window("DiskInventoryY - Interactive Disk Scan Utility", id: "disk_inventory_main") {
            ContentView()
                .frame(minWidth: 850, minHeight: 650)
        }
    }
}
