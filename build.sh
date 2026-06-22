#!/bin/bash
set -e

echo "=== Building DiskInventoryY in Release Mode ==="
swift build -c release

echo "=== Packaging DiskInventoryY.app ==="
# Remove old app bundle if exists
rm -rf DiskInventoryY.app

# Create folder structure
mkdir -p DiskInventoryY.app/Contents/MacOS
mkdir -p DiskInventoryY.app/Contents/Resources

# Copy the compiled binary
cp .build/release/DiskInventoryY DiskInventoryY.app/Contents/MacOS/

# Copy the Info.plist
cp Resources/Info.plist DiskInventoryY.app/Contents/Info.plist

# Copy the AppIcon.icns
cp Resources/AppIcon.icns DiskInventoryY.app/Contents/Resources/AppIcon.icns

# Make sure executable is runnable
chmod +x DiskInventoryY.app/Contents/MacOS/DiskInventoryY

echo "=== Packaging Complete! ==="
echo "DiskInventoryY.app has been created in the workspace root."
echo "You can double-click it in Finder, or run it via: open DiskInventoryY.app"
