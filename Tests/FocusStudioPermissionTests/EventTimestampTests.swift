import FocusStudioCapture
import FocusStudioCore
import Foundation

func eventTimestampFailures() -> [String] {
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) {
        if !value { failures.append("event timestamps: " + message) }
    }
    func resolved(_ native: Double, _ receipt: Double) -> Double? {
        CaptureEventTimestamp.resolve(nativeUptime: native, receiptUptime: receipt)
    }

    expect(resolved(100.1, 100.8) == 100.1, "a delayed callback retains the physical event time")
    expect(resolved(100.1, 500) == 100.1, "an old event must not be revived at its late receipt time")
    for invalid in [Double.nan, .infinity, -.infinity, -1, 0, 1_700_000_000] {
        expect(resolved(invalid, 100.8) == 100.8, "invalid or incompatible native clock falls back to receipt")
    }
    expect(resolved(100.8005, 100.8) == 100.8, "rounding cannot place an event after its receipt")
    expect(resolved(100, .nan) == nil && resolved(100, -.infinity) == nil && resolved(100, -1) == nil,
           "an invalid receipt cannot produce a usable recording timestamp")

    #if DEBUG
    MainActor.assumeIsolated {
        let monitor = EventMonitor()
        do {
            try monitor.prepare(captureRect: .init(x: 0, y: 0, width: 100, height: 100), targetProcessID: 42)
            defer { monitor.stop() }
            monitor.minimumSampleInterval = 0
            monitor.injectNativeEventForTesting(nativeUptime: 99, receiptUptime: 100.2,
                                                x: 20, y: 20, button: .left)
            expect(monitor.clickEvents.isEmpty, "unanchored queued input is discarded")
            monitor.anchor(at: 100)
            let seededCount = monitor.cursorSamples.count
            monitor.injectNativeEventForTesting(nativeUptime: 99.9, receiptUptime: 100.8,
                                                x: 20, y: 20, button: .left)
            expect(monitor.cursorSamples.count == seededCount && monitor.clickEvents.isEmpty,
                   "input from before the first frame cannot become a late click")

            // All three callbacks arrive in one batch. Their native spacing must
            // survive instead of becoming one timestamp and a jumped pointer.
            for (index, native) in [100.1, 100.11, 100.12].enumerated() {
                monitor.injectNativeEventForTesting(nativeUptime: native, receiptUptime: 100.8,
                                                    x: 20 + Double(index) * 10, y: 30,
                                                    button: index == 0 ? .left : nil)
            }
            let batch = Array(monitor.cursorSamples.suffix(3))
            expect(batch.count == 3 && zip(batch.map(\.time), [0.1, 0.11, 0.12]).allSatisfy { pair in abs(pair.0 - pair.1) < 1e-9 },
                   "queued movement retains its timing and order")
            expect(monitor.clickEvents.count == 1 && abs(monitor.clickEvents[0].time - 0.1) < 1e-9,
                   "the click ring uses the same native time as the pointer")

            monitor.pause(at: 101)
            monitor.reconcilePausedDuration(segmentDuration: 0.98)
            monitor.injectNativeEventForTesting(nativeUptime: 101.1, receiptUptime: 101.2,
                                                x: 40, y: 30, button: .left)
            monitor.resume(at: 200)
            let resumedCount = monitor.cursorSamples.count
            for native in [100.99, 150, 199.99] {
                monitor.injectNativeEventForTesting(nativeUptime: native, receiptUptime: 200.5,
                                                    x: 40, y: 30, button: .left)
            }
            expect(monitor.cursorSamples.count == resumedCount && monitor.clickEvents.count == 1,
                   "previous-segment, paused and pre-resume queued events stay rejected")
            monitor.injectNativeEventForTesting(nativeUptime: 200.1, receiptUptime: 200.5,
                                                x: 50, y: 30, button: .left)
            expect(monitor.clickEvents.count == 2 && abs((monitor.clickEvents.last?.time ?? -1) - 1.08) < 1e-9,
                   "resumed input maps to the reconciled video boundary, without callback latency")
            monitor.injectNativeEventForTesting(nativeUptime: .nan, receiptUptime: 200.6,
                                                x: 60, y: 30, button: .left)
            expect(monitor.clickEvents.count == 3 && abs((monitor.clickEvents.last?.time ?? -1) - 1.58) < 1e-9,
                   "receipt fallback still passes through the recording pause clock")

            monitor.pause(at: 201)
            monitor.resume(at: 500)
            monitor.injectNativeEventForTesting(nativeUptime: 250, receiptUptime: 500.2,
                                                x: 70, y: 30, button: .left)
            expect(monitor.clickEvents.count == 3, "a long pause cannot revive stale events through an age cutoff")
            monitor.stop()
            monitor.injectNativeEventForTesting(nativeUptime: 500.5, receiptUptime: 500.6,
                                                x: 70, y: 30, button: .left)
            expect(monitor.clickEvents.count == 3, "input delivered after stop cannot extend the trace")
        } catch {
            failures.append("event timestamps: monitor fixture failed: \(error)")
        }
    }
    #endif
    return failures
}
