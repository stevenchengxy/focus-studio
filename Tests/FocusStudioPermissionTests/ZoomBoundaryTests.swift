import FocusStudioCore
import Foundation

/// Manual control over when a zoom-in completes and a zoom-out begins.
func zoomBoundaryFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    var settings = ProjectSettings()
    settings.zoomEaseIn = 0.4
    settings.zoomEaseOut = 0.5
    let segment = ZoomSegment(start: 2, end: 6, targetX: 0.5, targetY: 0.5, scale: 1.75)
    let base = ZoomTiming.resolve(segment, settings: settings)
    expect(abs(base.fullZoomStart - 2.4) < 1e-9 && abs(base.zoomOutStart - 5.5) < 1e-9,
           "resolved timing exposes the inner boundaries")

    let laterArrival = ZoomTiming.applying(.fullZoomAt(3.0), to: segment, projectDuration: 10, settings: settings)
    let laterTiming = ZoomTiming.resolve(laterArrival, settings: settings)
    expect(abs(laterTiming.fullZoomStart - 3.0) < 1e-9 && abs(laterTiming.start - 2) < 1e-9 && abs(laterTiming.end - 6) < 1e-9,
           "moving the zoom-in end keeps the block edges (\(laterTiming))")
    expect(abs(laterTiming.easeOut - 0.5) < 1e-9 && laterArrival.kind == .manual,
           "the zoom-out length is preserved and the edit is manual")
    let scale = TimelineMath.zoomState(at: 2.7, segments: [laterArrival], settings: settings).scale
    expect(scale < 1.75 - 1e-6, "the camera is still arriving before the new boundary (\(scale))")

    let earlierDeparture = ZoomTiming.applying(.zoomOutAt(4.0), to: segment, projectDuration: 10, settings: settings)
    let departTiming = ZoomTiming.resolve(earlierDeparture, settings: settings)
    expect(abs(departTiming.zoomOutStart - 4.0) < 1e-9 && abs(departTiming.easeIn - 0.4) < 1e-9 && abs(departTiming.end - 6) < 1e-9,
           "moving the zoom-out start keeps the block edges and the zoom-in (\(departTiming))")

    let overshoot = ZoomTiming.applying(.fullZoomAt(9.0), to: segment, projectDuration: 10, settings: settings)
    let overshootTiming = ZoomTiming.resolve(overshoot, settings: settings)
    expect(abs(overshootTiming.fullZoomStart - overshootTiming.zoomOutStart) < 1e-9 && overshootTiming.hold == 0,
           "the zoom-in end cannot pass the zoom-out start")
    let negative = ZoomTiming.applying(.zoomOutAt(1.0), to: segment, projectDuration: 10, settings: settings)
    expect(ZoomTiming.resolve(negative, settings: settings).easeOut <= 4 - 0.4 + 1e-9,
           "the zoom-out start cannot pass the zoom-in end")
    let unchanged = ZoomTiming.applying(.fullZoomAt(.nan), to: segment, projectDuration: 10, settings: settings)
    expect(unchanged == segment, "a non-finite boundary edit is ignored")

    // Speed controls differ from absolute boundary controls: slowing the camera
    // keeps its readable hold rather than consuming it inside a fixed block.
    let short = ZoomSegment(start: 1, end: 2.52, targetX: 0.5, targetY: 0.5, scale: 1.75,
                            zoomEaseIn: 0.42, zoomEaseOut: 0.52)
    let relaxed = ZoomTiming.applying(.pacing(easeIn: 0.8, hold: nil, easeOut: 1.0),
                                     to: short, projectDuration: 10, settings: settings)
    let relaxedTiming = ZoomTiming.resolve(relaxed, settings: settings)
    expect(abs(relaxedTiming.hold - 0.58) < 1e-9 && abs(relaxedTiming.end - 3.38) < 1e-9,
           "Gentle preserves the old hold and extends the block instead of eliminating the hold")
    let slower = ZoomTiming.applying(.easeIn(0.9), to: short, projectDuration: 10, settings: settings)
    expect(abs(ZoomTiming.resolve(slower, settings: settings).hold - 0.58) < 1e-9
           && abs(slower.end - 3.0) < 1e-9,
           "changing incoming duration preserves hold and the outgoing duration")
    let tail = ZoomTiming.applying(.pacing(easeIn: 0.7, hold: 1.4, easeOut: 0.8),
                                  to: short, projectDuration: 1.5, settings: settings)
    let tailTiming = ZoomTiming.resolve(tail, settings: settings)
    expect(abs(tail.end - 1.5) < 1e-9 && tailTiming.easeIn > 0 && tailTiming.easeOut > 0
           && abs(tailTiming.hold - 0.5 * 1.4 / 2.9) < 1e-9,
           "a short remainder fits all three phases proportionally, including readable hold")
    let invalidPacing = ZoomTiming.applying(.pacing(easeIn: .nan, hold: 1, easeOut: 0.8),
                                           to: short, projectDuration: 10, settings: settings)
    expect(invalidPacing == short, "a non-finite pacing preset changes nothing")
    return failures
}
