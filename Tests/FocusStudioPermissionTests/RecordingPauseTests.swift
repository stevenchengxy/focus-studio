import FocusStudioCapture
import FocusStudioCore
import Foundation

func recordingPauseClockFailures() -> [String] {
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
    var clock = RecordingPauseClock()
    expect(clock.elapsed(at: 500) == 0 && clock.mediaTime(at: 500) == nil, "unstarted recording must not count startup waiting time")
    expect(!clock.anchor(at: .nan) && !clock.anchor(at: -1), "invalid first-frame clocks must be rejected")
    expect(clock.anchor(at: 100) && !clock.anchor(at: 101), "the first active frame must anchor once")
    expect(clock.mediaTime(at: 99.9) == nil && clock.mediaTime(at: 101.5) == 1.5, "event timestamps must be relative to the active frame")
    expect(clock.pause(at: 102) == 2 && clock.pause(at: 130) == nil, "repeated pause must not add paused time")
    expect(clock.elapsed(at: 200) == 2 && clock.mediaTime(at: 150) == nil, "pause must freeze the media clock and reject events")
    clock.reconcileLastSegment(duration: 1.95)
    expect(abs(clock.completedDuration - 1.95) < 1e-9, "video duration must calibrate the next interval boundary")
    expect(!clock.anchor(at: 101) && clock.anchor(at: 150), "stale pre-pause frames must not resume recording")
    expect(abs((clock.mediaTime(at: 150.5) ?? -1) - 2.45) < 1e-9, "resume must remove pause and writer restart latency from event time")
    expect(clock.mediaTime(at: 140) == nil, "a queued paused event delivered after resume must remain rejected")
    clock.pause(at: 150.75)
    clock.reconcileLastSegment(duration: 0.75)
    expect(abs(clock.elapsed(at: 500) - 2.7) < 1e-9, "stop while paused must retain only active intervals")
    var many = RecordingPauseClock()
    for index in 0..<100 {
        let uptime = Double(index) * 50 + 10
        expect(many.anchor(at: uptime), "each new active interval must resume")
        many.pause(at: uptime + 0.125)
        many.reconcileLastSegment(duration: 0.1)
    }
    expect(abs(many.completedDuration - 10) < 1e-8, "many short pauses must not accumulate wall-clock or frame drift")
    var instant = RecordingPauseClock()
    instant.anchor(at: 10)
    instant.pause(at: 10)
    instant.reconcileLastSegment(duration: 0)
    expect(instant.completedDuration == 0 && instant.anchor(at: 20), "zero-length intervals must safely allow resume")
    return failures
}

@MainActor
func recordingPauseInteractionFailures() -> [String] {
    #if DEBUG
    var failures: [String] = []
    func expect(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
    let monitor = EventMonitor()
    let context = TypingFocusContext(processID: 42, windowID: 7, semantics: .editable(.init(x: 10, y: 10, width: 50, height: 30)))
    do {
        try monitor.prepare(captureRect: .init(x: 0, y: 0, width: 100, height: 100), targetProcessID: 42, targetWindowID: 7)
        monitor.anchor(at: 100)
        monitor.injectEventForTesting(uptime: 100.5, x: 30, y: 30, button: .left)
        monitor.injectTypingActivityForTesting(uptime: 100.6, context: context)
        monitor.pause(at: 101)
        monitor.injectEventForTesting(uptime: 110, x: 30, y: 30, button: .left)
        monitor.injectTypingActivityForTesting(uptime: 110, context: context)
        monitor.injectAccessibilityActivityForTesting(uptime: 111, context: context)
        expect(monitor.clickEvents.count == 1 && monitor.typingActivity.count == 1, "paused mouse, keyboard and AX activity must all be discarded")
        monitor.reconcilePausedDuration(segmentDuration: 0.8)
        monitor.resume(at: 120)
        monitor.injectEventForTesting(uptime: 119, x: 30, y: 30, button: .left)
        monitor.injectTypingActivityForTesting(uptime: 119, context: context)
        monitor.injectEventForTesting(uptime: 120.25, x: 30, y: 30, button: .left)
        monitor.injectTypingActivityForTesting(uptime: 120.5, context: context)
        expect(monitor.clickEvents.count == 2 && abs((monitor.clickEvents.last?.time ?? -1) - 1.05) < 1e-8,
               "resumed clicks must share the trimmed video's timeline and discard queued paused clicks")
        expect(monitor.typingActivity.count == 2 && abs((monitor.typingActivity.last?.time ?? -1) - 1.3) < 1e-8,
               "resumed typing must share the same compressed clock as video and clicks")
        monitor.pause(at: 121)
        monitor.reconcilePausedDuration(segmentDuration: 0.3)
        expect(monitor.typingActivity.count == 1, "metadata beyond a truncated segment must not spill into the next segment")
        monitor.updatePausedCaptureRect(.init(x: 200, y: 100, width: 100, height: 100), targetProcessID: 42, targetWindowID: 7)
        monitor.resume(at: 130)
        monitor.injectEventForTesting(uptime: 130.25, x: 225, y: 150, button: .left)
        expect(monitor.clickEvents.last?.x == 0.25 && monitor.clickEvents.last?.y == 0.5,
               "moving the selected window while paused must refresh resumed coordinate normalization")
        monitor.stop()
    } catch { failures.append("pause trace fixture setup failed: \(error)") }
    return failures
    #else
    return []
    #endif
}
