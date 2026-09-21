import Darwin
import FocusStudioCapture
import FocusStudioCore
import Foundation
import ScreenCaptureKit

private var failures: [String] = []
failures.append(contentsOf: typingActivityCaptureFailures())
failures.append(contentsOf: zoomMotionFailures())
failures.append(contentsOf: chapterFailures())
failures.append(contentsOf: MainActor.assumeIsolated { accessibilityActivityTraceFailures() })

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
    }
}

let defaultCaptureOptions = CaptureOptions()
expect(
    !defaultCaptureOptions.capturesSystemAudio,
    "default capture must not trigger the optional System Audio permission"
)

let normalWindowFrame = CaptureRect(x: 100, y: 80, width: 1_280, height: 720)
expect(
    CaptureStartupPolicy.isRecordableWindow(
        isOnScreen: true,
        frame: normalWindowFrame
    ),
    "a visible, usable window must remain available as a capture source"
)
expect(
    !CaptureStartupPolicy.isRecordableWindow(
        isOnScreen: false,
        frame: normalWindowFrame
    ),
    "an off-screen or minimized window must not be offered for recording"
)
expect(
    !CaptureStartupPolicy.isRecordableWindow(
        isOnScreen: true,
        frame: CaptureRect(x: 0, y: 0, width: 20, height: 20)
    ),
    "a tiny non-content window must not be offered for recording"
)

let windowStartupRecovery = CaptureStartupPolicy.noCompleteFrameMessage(
    targetName: "Finlyze — Google Chrome",
    targetKind: .window
)
expect(
    windowStartupRecovery.contains("visible desktop")
        && windowStartupRecovery.contains("refresh the source list"),
    "a first-frame timeout must tell the user how to make the window recordable"
)
let startupFailure = CaptureEngineError.captureDidNotStart(windowStartupRecovery)
expect(
    startupFailure.localizedDescription.contains("Recording did not start")
        && !startupFailure.isScreenRecordingPermissionFailure,
    "a suspended source must be actionable and must not masquerade as a permission failure"
)

let displayFrame = CaptureRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
let localSelection = CaptureRect(x: 120, y: 80, width: 1_200, height: 700)
let globalSelection = AreaCaptureGeometry.globalFrame(
    forLocalSelection: localSelection,
    onDisplay: displayFrame
)
expect(
    globalSelection == CaptureRect(x: 1_560, y: 300, width: 1_200, height: 700),
    "AppKit area selections must be flipped into the Quartz global coordinate space"
)
if let globalSelection {
    let sourceRect = AreaCaptureGeometry.sourceRect(
        forGlobalFrame: globalSelection,
        onDisplay: displayFrame
    )
    expect(
        sourceRect == CGRect(x: 120, y: 300, width: 1_200, height: 700),
        "ScreenCaptureKit sourceRect must be display-local and keep the top-left origin"
    )
}

let partiallyOutsideArea = CaptureRect(x: 1_200, y: -100, width: 500, height: 400)
expect(
    AreaCaptureGeometry.clippedGlobalFrame(partiallyOutsideArea, toDisplay: displayFrame)
        == CaptureRect(x: 1_440, y: 0, width: 260, height: 300),
    "area targets must be clipped to their selected display before event normalization"
)

// A secondary display may sit left of and above the primary display. Exercise
// both negative axes so the picker cannot accidentally mix AppKit and Quartz
// origins or assume that the selected display begins at (0, 0).
let negativeDisplayFrame = CaptureRect(x: -1_920, y: -180, width: 1_920, height: 1_080)
let negativeDisplaySelection = AreaCaptureGeometry.globalFrame(
    forLocalSelection: CaptureRect(x: 200, y: 100, width: 800, height: 600),
    onDisplay: negativeDisplayFrame
)
expect(
    negativeDisplaySelection == CaptureRect(x: -1_720, y: 200, width: 800, height: 600),
    "area selection conversion must preserve negative multi-display coordinates"
)
if let negativeDisplaySelection {
    expect(
        AreaCaptureGeometry.sourceRect(
            forGlobalFrame: negativeDisplaySelection,
            onDisplay: negativeDisplayFrame
        ) == CGRect(x: 200, y: 380, width: 800, height: 600),
        "an area sourceRect must remain display-local on an offset secondary display"
    )
}

let retinaAreaOutput = CaptureOutputGeometry.pixelSize(
    sourcePointSize: CGSize(width: 1_200, height: 700),
    targetScaleFactor: 2,
    outputScale: nil,
    maximumOutputDimension: 4_096
)
expect(
    retinaAreaOutput == CapturePixelSize(width: 2_400, height: 1_400),
    "area output dimensions must be derived from the selected area, not its full display"
)
let explicitlyScaledAreaOutput = CaptureOutputGeometry.pixelSize(
    sourcePointSize: CGSize(width: 1_201, height: 701),
    targetScaleFactor: 2,
    outputScale: 0.75,
    maximumOutputDimension: 4_096
)
expect(
    explicitlyScaledAreaOutput == CapturePixelSize(width: 900, height: 526),
    "area output must honor explicit scaling and produce encoder-safe even dimensions"
)
let cappedAreaOutput = CaptureOutputGeometry.pixelSize(
    sourcePointSize: CGSize(width: 2_500, height: 1_001),
    targetScaleFactor: 2,
    outputScale: nil,
    maximumOutputDimension: 1_920
)
expect(
    cappedAreaOutput == CapturePixelSize(width: 1_920, height: 768),
    "large area output must preserve aspect ratio while respecting the encoder size cap"
)

private var authorizedRequestCount = 0
let authorizedResolution = ScreenRecordingAccessPolicy.resolve(
    intent: .explicitUserRequest,
    preflight: { true },
    request: {
        authorizedRequestCount += 1
        return false
    }
)
expect(authorizedResolution, "an existing Screen Recording grant must be accepted")
expect(
    authorizedRequestCount == 0,
    "an existing grant must never call CGRequestScreenCaptureAccess"
)

private var passiveRequestCount = 0
let passiveResolution = ScreenRecordingAccessPolicy.resolve(
    intent: .inspectOnly,
    preflight: { false },
    request: {
        passiveRequestCount += 1
        return true
    }
)
expect(!passiveResolution, "a passive permission inspection must report a missing grant")
expect(
    passiveRequestCount == 0,
    "normal recording entry must never request access or open System Settings"
)

private var explicitRequestCount = 0
let explicitResolution = ScreenRecordingAccessPolicy.resolve(
    intent: .explicitUserRequest,
    preflight: { false },
    request: {
        explicitRequestCount += 1
        return true
    }
)
expect(explicitResolution, "an explicit user request may activate Screen Recording access")
expect(
    explicitRequestCount == 1,
    "an explicit user request must call the system request exactly once"
)

private let declined = NSError(
    domain: SCStreamErrorDomain,
    code: SCStreamError.Code.userDeclined.rawValue,
    userInfo: [NSLocalizedDescriptionKey: "The user declined capture."]
)
let declinedResult = CaptureEngineError.classifyCaptureFailure(
    declined,
    hasScreenRecordingAccess: true
)
expect(declinedResult.isScreenRecordingPermissionFailure, "userDeclined must be a permission failure")
expect(
    declinedResult.localizedDescription.contains("\(SCStreamError.Code.userDeclined.rawValue)"),
    "permission diagnostics must retain the ScreenCaptureKit error code"
)

private let verifierMismatch = NSError(
    domain: "FocusStudio.PermissionProbe",
    code: 71,
    userInfo: [NSLocalizedDescriptionKey: "The current process has no active Screen Recording grant."]
)
let mismatchResult = CaptureEngineError.classifyCaptureFailure(
    verifierMismatch,
    hasScreenRecordingAccess: false
)
expect(mismatchResult.isScreenRecordingPermissionFailure, "failed preflight must be a permission failure")
expect(
    mismatchResult.localizedDescription.contains("[FocusStudio.PermissionProbe 71]"),
    "preflight failure must retain NSError domain and code"
)

private let missingEntitlement = NSError(
    domain: SCStreamErrorDomain,
    code: SCStreamError.Code.missingEntitlements.rawValue,
    userInfo: [NSLocalizedDescriptionKey: "Missing entitlement."]
)
let entitlementResult = CaptureEngineError.classifyCaptureFailure(
    missingEntitlement,
    hasScreenRecordingAccess: false
)
if case .missingCaptureEntitlements = entitlementResult {
    // Expected.
} else {
    failures.append("missingEntitlements must not be misreported as a user permission denial")
}

private let underlying = NSError(
    domain: "FocusStudio.Transport",
    code: 9,
    userInfo: [NSLocalizedDescriptionKey: "Connection interrupted."]
)
private let generalFailure = NSError(
    domain: "FocusStudio.Capture",
    code: 23,
    userInfo: [
        NSLocalizedDescriptionKey: "Unable to enumerate capture sources.",
        NSUnderlyingErrorKey: underlying,
    ]
)
let generalResult = CaptureEngineError.classifyCaptureFailure(
    generalFailure,
    hasScreenRecordingAccess: true
)
if case let .recordingFailed(details) = generalResult {
    expect(details.contains("[FocusStudio.Capture 23]"), "general failure must retain its domain and code")
    expect(details.contains("[FocusStudio.Transport 9]"), "general failure must retain its underlying error")
} else {
    failures.append("authorized non-permission errors must remain general recording failures")
}

private let existing = CaptureEngineError.invalidOptions("Frame rate")
let existingResult = CaptureEngineError.classifyCaptureFailure(
    existing,
    hasScreenRecordingAccess: false
)
if case .invalidOptions = existingResult {
    // Expected: local validation errors must not be overwritten by TCC state.
} else {
    failures.append("existing CaptureEngineError values must survive classification")
}

if failures.isEmpty {
    print("FocusStudioPermissionTests: PASS (permission, startup, and area-geometry scenarios)")
} else {
    for failure in failures {
        fputs("FAIL: \(failure)\n", stderr)
    }
    exit(1)
}
