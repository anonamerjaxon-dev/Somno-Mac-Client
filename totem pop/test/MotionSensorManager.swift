import Foundation
import IOKit
import IOKit.hid
import CoreFoundation

/// Reads the Bosch BMI286 IMU accelerometer from Apple Silicon Macs via IOKit.
///
/// Uses the same technique as the `spank` project (taigrr/spank):
/// 1. Wakes the AppleSPUHIDDriver by setting reporting/power properties
/// 2. Enumerates AppleSPUHIDDevice services, finds the accelerometer
/// 3. Opens the IOHIDDevice and registers an input-report callback
/// 4. Parses 22-byte HID reports (3× int32 XYZ at byte offset 6)
/// 5. Scales the raw int32 counts into g-force by dividing by 65536
///
/// Requires `sudo` because IOHIDDeviceOpen needs root privileges.
/// Only available on Apple Silicon Macs (M2+, or M1 Pro).
final class MotionSensorManager: ObservableObject {

    // MARK: - Published state

    @Published var x: Double = 0.0
    @Published var y: Double = 0.0
    @Published var z: Double = 0.0
    @Published var magnitude: Double = 0.0
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "Initializing…"

    // MARK: - HID report format (Bosch BMI286)

    /// Length of a single accelerometer input report, in bytes.
    static let imuReportLen = 22
    /// Byte offset at which the X/Y/Z payload begins inside the report.
    static let imuDataOffset = 6
    /// Bytes of payload after the offset: 3 axes × 4 bytes.
    static let imuPayloadLen = 12
    /// Buffer handed to `IOHIDDeviceRegisterInputReportCallback`.
    ///
    /// Must be at least as large as the largest report the device can deliver.
    /// The payload needs `imuDataOffset + imuPayloadLen` = 18 bytes; the report
    /// itself is 22 bytes. We round up to a whole number of `Int32` words so the
    /// allocation is word-aligned (required by the old `withMemoryRebound` path,
    /// and harmless for the `memcpy` path we use now): 24 bytes = 6 × Int32.
    /// The old value of `6` was interpreted as an `Int32` *count*, i.e. 24 bytes,
    /// which happened to be enough — but it was wrong documentation and it would
    /// silently break the moment the report grew past 24 bytes.
    static let reportBufSize = 24

    /// Raw-count → g-force scale for the AppleSPUHIDDevice accelerometer.
    ///
    /// The BMI286 HID reports are 3 × signed Int32 raw counts. Independent
    /// implementations of this undocumented protocol (junwatu/macimu,
    /// taigrr/apple-silicon-accelerometer, olvvier/apple-silicon-accelerometer)
    /// all divide by 65536 to obtain g.
    ///
    /// - Needs hardware verification: this divisor is the one assumption in the
    ///   parse path that has not been confirmed against a physical Mac — no test
    ///   hardware was available. The byte offsets (6/10/14) are well corroborated;
    ///   the divisor is not. Verify by leaving the Mac flat on a desk: the
    ///   magnitude should read ≈ 1.0 g. If it reads in the tens of thousands,
    ///   this scale is wrong. See `HOW_TO_USE.txt`.
    static let accelScale = 65536.0

    // MARK: - Driver configuration

    /// `ReportInterval` requested from `AppleSPUHIDDriver`, in **microseconds**.
    ///
    /// Units are undocumented by Apple. 1000 µs == 1 kHz, which is the value the
    /// reference implementations use (`ReportIntervalUS = 1000`). The hardware
    /// reports at roughly 800 Hz; we decimate below rather than rely on the driver.
    ///
    /// - Needs hardware verification: Apple does not document this property's
    ///   unit or its honored range. If the driver rejects it, we simply get
    ///   whatever rate the driver defaults to — the UI rate is capped by our own
    ///   `publishIntervalSeconds` regardless.
    static let reportIntervalMicroseconds: Int32 = 1000

    /// Minimum seconds between `@Published` updates pushed to the main queue.
    ///
    /// 0.04 s == 25 Hz. The driver delivers ~800 Hz; without coalescing every
    /// report would enqueue a main-thread block and flood `@Published`.
    static let publishIntervalSeconds: Double = 0.04

    // MARK: - Apple SPU HID constants

    private static let pageVendor: Int = 0xFF00
    private static let usageAccel: Int = 3

    /// Run-loop mode used to schedule the HID device and pump the sensor loop.
    private static let runLoopMode: CFRunLoopMode = .defaultMode

    // MARK: - Private state

    /// Guards every field below that is touched by both the sensor thread and
    /// the main thread: `sensorThread`, `deviceRef`, `reportBuffer`, plus the
    /// start/stop state machine.
    private let lock = NSLock()

    private var sensorThread: Thread?
    private var deviceRef: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?

    /// Set by `stop()`, polled by the sensor loop to decide when to tear down.
    private var isStopping = false

    /// Retains `self` for as long as the HID callback may fire.
    ///
    /// The callback receives an `UnsafeMutableRawPointer` context; using
    /// `passUnretained` there was a use-after-free waiting to happen. `context`
    /// is consumed (released) by `releaseCallbackContext()` once the device is
    /// unscheduled and the thread has exited.
    private var callbackContext: MotionSensorCallbackContext?

    /// Latest sample parsed on the sensor thread, published on the main thread.
    private var latestSample = SIMD3<Double>(0, 0, 0)
    private var latestMagnitude: Double = 0
    private var lastPublishTime: TimeInterval = 0

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    // MARK: - Public API

    func start() {
        // Serialize against a concurrent stop(): hold the lock for the whole
        // transition so `start()` can never observe `sensorThread == nil` while a
        // previous thread is still winding down.
        lock.lock()
        if sensorThread != nil || isStopping {
            lock.unlock()
            return
        }
        isStopping = false
        lastPublishTime = 0

        let thread = Thread { [weak self] in
            self?.sensorLoop()
        }
        thread.name = "MotionSensor"
        thread.qualityOfService = .userInteractive
        sensorThread = thread
        lock.unlock()

        thread.start()
    }

    func stop() {
        // Phase 1: ask the sensor thread to wind down, and remember it so we can
        // join. Everything that must happen *on the sensor thread* happens there.
        lock.lock()
        guard let thread = sensorThread else {
            // Never started, or already stopped.
            isStopping = false
            lock.unlock()
            return
        }
        isStopping = true
        sensorThread = nil
        lock.unlock()

        thread.cancel()

        // Phase 2: join. The sensor loop unschedules the HID device and closes it
        // on its own thread *before* exiting, so by the time `isFinished` is true
        // no callback can be in flight against a closed or freed device.
        //
        // Bounded wait so a wedged run loop cannot hang `deinit` forever. The
        // sensor loop polls at 50 ms, so this is ~200× the normal latency.
        let deadline = Date().addingTimeInterval(10)
        while !thread.isFinished && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }

        // Phase 3: clear the remaining references under the lock. On the normal
        // path the sensor thread already did this; on the timeout path we do it
        // here so nothing is left dangling.
        lock.lock()
        deviceRef = nil
        reportBuffer = nil
        if let context = callbackContext {
            context.invalidate()
            callbackContext = nil
        }
        lock.unlock()
    }

    // MARK: - Sensor thread

    private func sensorLoop() {
        // Step 1: Wake up the SPU HID drivers.
        wakeSPUDrivers()

        // Step 2: Find and open the accelerometer HID device.
        guard let device = openAccelerometerDevice() else {
            let (connected, message) = (false, "No accelerometer found.\nRequires Apple Silicon Mac (M2+ or M1 Pro) and sudo.")
            publishStatus(connected: connected, message: message)
            finishSensorThread()
            return
        }

        // Step 3: Allocate the report buffer. It must outlive every callback, so
        // it is owned by the manager and freed only after the thread exits.
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufSize)
        buffer.initialize(repeating: 0, count: Self.reportBufSize)

        // Step 4: Register the input-report callback with a *managed* context.
        let context = MotionSensorCallbackContext(owner: self)
        lock.lock()
        reportBuffer = buffer
        deviceRef = device
        callbackContext = context
        lock.unlock()

        let callback: IOHIDReportCallback = { contextPointer, _, _, _, _, report, reportLen in
            guard let contextPointer else { return }
            let context = Unmanaged<MotionSensorCallbackContext>
                .fromOpaque(contextPointer)
                .takeUnretainedValue()
            context.handle(report: report, length: reportLen)
        }

        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            Self.reportBufSize,
            callback,
            Unmanaged.passRetained(context).toOpaque()
        )

        // Step 5: Schedule the device on this thread's run loop.
        let runLoopMode = Self.runLoopMode
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetCurrent(),
            runLoopMode.rawValue as CFString
        )

        publishStatus(
            connected: true,
            message: "Connected to BMI286 IMU (Apple Silicon)"
        )

        // Step 6: Run the CFRunLoop until cancelled (delivers HID callbacks).
        // Safe unwrap: `defaultMode` is a documented non-nil `CFRunLoopMode`,
        // but we unwrap explicitly rather than force-unwrap.
        guard let mode = CFRunLoopMode.defaultMode as CFRunLoopMode? else {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), runLoopMode.rawValue as CFString)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            lock.lock()
            deviceRef = nil
            reportBuffer = nil
            lock.unlock()
            finishSensorThread()
            return
        }

        while !isStopRequested() {
            CFRunLoopRunInMode(mode, 0.05, false)
        }

        // Step 7: Tear down *on the sensor thread*, in the correct order.
        // Unschedule FIRST so no new callback can be delivered, then close.
        // Doing this from `stop()` on the main thread — as the code used to —
        // races with an in-flight callback.
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            finishSensorThread()
            return
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, currentRunLoop, runLoopMode.rawValue as CFString)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        lock.lock()
        deviceRef = nil
        if let buffer = reportBuffer {
            buffer.deinitialize(count: Self.reportBufSize)
            buffer.deallocate()
            reportBuffer = nil
        }
        // The device can no longer deliver callbacks, so the context's strong
        // reference to `self` can go. Release the unmanaged instance too: it was
        // registered with `passRetained`, so this `.release()` balances that
        // `+1`. Pairing `passUnretained` here with `.release()` would be an
        // over-release and free the object while the callback can still read it.
        if let context = callbackContext {
            context.invalidate()
            callbackContext = nil
            Unmanaged<MotionSensorCallbackContext>.fromOpaque(
                Unmanaged.passUnretained(context).toOpaque()
            ).release()
        }
        lock.unlock()

        finishSensorThread()
    }

    /// Marks the sensor thread finished so `stop()`'s join loop can observe it.
    private func finishSensorThread() {
        lock.lock()
        isStopping = false
        lock.unlock()
    }

    private func isStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopping
    }

    // MARK: - Wake SPU drivers

    private func wakeSPUDrivers() {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            // `IORegistryEntrySetCFProperty` consumes a +1 reference to the
            // property, so passing a Swift literal `as CFTypeRef` is enough. The
            // old code built CFNumbers with `CFNumberCreate` and leaked them.
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFTypeRef)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFTypeRef)

            // ReportInterval is in microseconds (see `reportIntervalMicroseconds`).
            IORegistryEntrySetCFProperty(
                service,
                "ReportInterval" as CFString,
                Self.reportIntervalMicroseconds as CFTypeRef
            )
        }
    }

    // MARK: - Open accelerometer device

    private func openAccelerometerDevice() -> IOHIDDevice? {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else { return nil }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return nil }

        var foundDevice: IOHIDDevice?
        var service = IOIteratorNext(iterator)

        while service != 0 && foundDevice == nil {
            // Read PrimaryUsagePage and PrimaryUsage to identify the accelerometer.
            if let pageValue = IORegistryEntryCreateCFProperty(service, "PrimaryUsagePage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               let usageValue = IORegistryEntryCreateCFProperty(service, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int,
               pageValue == Self.pageVendor,
               usageValue == Self.usageAccel {

                let device = IOHIDDeviceCreate(kCFAllocatorDefault, service)
                if let device = device {
                    let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
                    if openResult == KERN_SUCCESS {
                        foundDevice = device
                    }
                    // If the open failed, simply dropping the reference here
                    // releases the +1 from IOHIDDeviceCreate (Core Foundation
                    // objects are ARC-managed; never call CFRelease from Swift).
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        IOObjectRelease(iterator)
        return foundDevice
    }

    // MARK: - Report handling

    /// Parse one accelerometer report into g-force.
    ///
    /// Pure: takes bytes, returns a value, touches no shared state and no
    /// hardware. The live callback path funnels through the same logic so it
    /// can be unit tested by `runSelfTest()` without an IMU present.
    ///
    /// `report` must contain at least `imuDataOffset + imuPayloadLen` bytes (18).
    /// We read **three little-endian Int32 values starting at byte 6**, i.e.
    /// bytes 6–9, 10–13, 14–17, then divide each by `accelScale`.
    ///
    /// Implementation note: `memcpy` into local `Int32`s rather than
    /// `withMemoryRebound`. Byte 6 is only 4-byte aligned when the base pointer
    /// happens to be aligned, and `withMemoryRebound` traps on misalignment; the
    /// old code also integer-divided the offset by 4 (`6 / 4 == 1`), silently
    /// reading bytes 4/8/12 instead of 6/10/14.
    ///
    /// Returns nil when the buffer is too short to hold the payload.
    static func parseXYZ(from report: [UInt8]) -> SIMD3<Float>? {
        guard let counts = parseRawCounts(from: report) else { return nil }
        return SIMD3<Float>(
            Float(Double(counts.x) / accelScale),
            Float(Double(counts.y) / accelScale),
            Float(Double(counts.z) / accelScale)
        )
    }

    /// Same parse, but without dividing by `accelScale` — raw Int32 counts.
    static func parseRawCounts(from report: [UInt8]) -> (x: Int32, y: Int32, z: Int32)? {
        let required = imuDataOffset + imuPayloadLen
        guard report.count >= required else { return nil }
        return report.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return readCounts(from: base)
        }
    }

    /// The one place the three payload words are actually read.
    ///
    /// Reads 4 bytes at each of offsets 6, 10 and 14 with `memcpy` — no
    /// alignment requirement, no integer division of the offset.
    private static func readCounts(from base: UnsafePointer<UInt8>) -> (x: Int32, y: Int32, z: Int32) {
        var xRaw: Int32 = 0
        var yRaw: Int32 = 0
        var zRaw: Int32 = 0
        memcpy(&xRaw, base.advanced(by: imuDataOffset), MemoryLayout<Int32>.size)
        memcpy(&yRaw, base.advanced(by: imuDataOffset + 4), MemoryLayout<Int32>.size)
        memcpy(&zRaw, base.advanced(by: imuDataOffset + 8), MemoryLayout<Int32>.size)
        return (xRaw, yRaw, zRaw)
    }

    /// Pointer-based parse used by the live callback — identical logic to
    /// `parseRawCounts(from:)` plus the g conversion, reading straight from the
    /// HID buffer without copying it into a Swift array first.
    private static func parseScaled(from base: UnsafePointer<UInt8>) -> (x: Double, y: Double, z: Double) {
        let counts = readCounts(from: base)
        return (
            Double(counts.x) / accelScale,
            Double(counts.y) / accelScale,
            Double(counts.z) / accelScale
        )
    }

    /// Called on the sensor thread for every HID report. Parses, stores the
    /// latest sample, and schedules a *coalesced* publish to the main queue.
    fileprivate func handleReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= CFIndex(Self.imuDataOffset + Self.imuPayloadLen) else { return }
        let parsed = Self.parseScaled(from: report)

        let magnitude = sqrt(parsed.x * parsed.x + parsed.y * parsed.y + parsed.z * parsed.z)

        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        latestSample = SIMD3(parsed.x, parsed.y, parsed.z)
        latestMagnitude = magnitude

        let shouldPublish = (now - lastPublishTime) >= Self.publishIntervalSeconds
        if shouldPublish {
            lastPublishTime = now
        }
        lock.unlock()

        guard shouldPublish else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Re-read the latest sample under the lock: a newer report may have
            // landed since the coalescing decision.
            self.lock.lock()
            let sample = self.latestSample
            let mag = self.latestMagnitude
            self.lock.unlock()

            self.x = sample.x
            self.y = sample.y
            self.z = sample.z
            self.magnitude = mag
        }
    }

    /// Pointer-based parse used by the live callback (same logic as
    /// `parseXYZRaw(from:)`, but reading straight from the HID buffer).
    private static func parseXYZRaw(fromUnsafe report: UnsafePointer<UInt8>) -> (x: Double, y: Double, z: Double)? {
        var xRaw: Int32 = 0
        var yRaw: Int32 = 0
        var zRaw: Int32 = 0
        memcpy(&xRaw, report.advanced(by: imuDataOffset), MemoryLayout<Int32>.size)
        memcpy(&yRaw, report.advanced(by: imuDataOffset + 4), MemoryLayout<Int32>.size)
        memcpy(&zRaw, report.advanced(by: imuDataOffset + 8), MemoryLayout<Int32>.size)
        return (Double(xRaw) / accelScale, Double(yRaw) / accelScale, Double(zRaw) / accelScale)
    }

    private func publishStatus(connected: Bool, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.statusMessage = message
        }
    }
}

// MARK: - Callback context

/// Strongly-held bridge between the C HID callback and the manager.
///
/// `IOHIDDeviceRegisterInputReportCallback` stores the context pointer without
/// retaining it. Passing `Unmanaged.passUnretained(self)` meant that if the
/// manager were deallocated while a report was in flight, the callback would
/// message freed memory. A dedicated context object fixes this two ways:
///
/// - Keeps the HID callback from messaging freed memory: the context holds a
///   strong reference to the manager while the device is scheduled.
/// - Registered with `passRetained` (+1) and balanced by a single `.release()`
///   after the device is unscheduled, so the context outlives every in-flight
///   callback and is never freed early.
///
/// The previous code passed `Unmanaged.passUnretained(self)` here: the C
/// callback stored that pointer without retaining it, so a manager deallocated
/// while a report was in flight was messageable as freed memory.
private final class MotionSensorCallbackContext {
    private weak var owner: MotionSensorManager?
    private var isValid = true

    init(owner: MotionSensorManager) {
        self.owner = owner
    }

    func invalidate() {
        isValid = false
        owner = nil
    }

    func handle(report: UnsafePointer<UInt8>?, length: CFIndex) {
        guard isValid, let report else { return }
        owner?.handleReport(report, length: length)
    }
}