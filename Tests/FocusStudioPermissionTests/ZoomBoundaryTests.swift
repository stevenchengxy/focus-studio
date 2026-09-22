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
    return failures
}
