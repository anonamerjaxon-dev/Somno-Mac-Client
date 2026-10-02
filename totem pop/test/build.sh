#!/bin/bash
# Build the Motion Sensor app from the command line.
# Usage: chmod +x build.sh && ./build.sh
#
# Produces two binaries:
#   ./build/MotionSensor        — the SwiftUI app (run with sudo)
#   ./build/MotionSensorSelfTest — hardware-free unit tests (run without sudo)
#
# Building requires NO root. `sudo` is runtime-only: IOHIDDeviceOpen needs
# privileges to actually open the accelerometer, but compiling does not.
#
# NOTE: The app binary must be run with sudo to access the HID device:
#   sudo ./build/MotionSensor

set -o pipefail

cd "$(dirname "$0")"

APP_NAME="MotionSensor"
SELFTEST_NAME="MotionSensorSelfTest"
BUILD_DIR="./build"

echo "🔨 Building $APP_NAME..."

mkdir -p "$BUILD_DIR"

# The app binary: SwiftUI + IOKit.
swiftc \
    -framework SwiftUI \
    -framework Foundation \
    -framework IOKit \
    -framework CoreFoundation \
    -o "$BUILD_DIR/$APP_NAME" \
    MotionSensorApp.swift \
    MotionSensorManager.swift \
    AxisBarGeometry.swift \
    ContentView.swift

APP_STATUS=$?

if [ $APP_STATUS -ne 0 ]; then
    echo "❌ Build failed ($APP_NAME)"
    exit 1
fi

echo "✅ Built $BUILD_DIR/$APP_NAME"
echo ""

# The self-test binary: no SwiftUI, no window, no hardware. It links the REAL
# MotionSensorManager.swift and AxisBarGeometry.swift so the tested code is the
# shipped code, not a copy.
echo "🔨 Building $SELFTEST_NAME..."
swiftc \
    -framework Foundation \
    -framework IOKit \
    -framework CoreFoundation \
    -o "$BUILD_DIR/$SELFTEST_NAME" \
    SelfTest.swift \
    MotionSensorManager.swift \
    AxisBarGeometry.swift

SELFTEST_BUILD_STATUS=$?

if [ $SELFTEST_BUILD_STATUS -ne 0 ]; then
    echo "❌ Build failed ($SELFTEST_NAME)"
    exit 1
fi

echo "✅ Built $BUILD_DIR/$SELFTEST_NAME"
echo ""

# Run the self-tests. Exits nonzero if any assertion fails, failing the script.
echo "🧪 Running self-tests (no hardware needed)..."
"$BUILD_DIR/$SELFTEST_NAME"
SELFTEST_STATUS=$?

if [ $SELFTEST_STATUS -ne 0 ]; then
    echo ""
    echo "❌ Self-tests FAILED (exit $SELFTEST_STATUS) — build considered broken."
    exit $SELFTEST_STATUS
fi

echo ""
echo "✅ All checks passed."
echo ""
echo "⚠️  Run the app with sudo (IOHIDDeviceOpen requires root):"
echo "   sudo $BUILD_DIR/$APP_NAME"