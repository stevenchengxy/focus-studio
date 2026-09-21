import AppKit
import SceneKit
import SwiftUI

/// What the character is doing. The panel derives this from session events;
/// the scene turns it into eased motion.
enum AvatarState: String, Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking
    case happy
    case error
}

// MARK: - SwiftUI view

/// A small SceneKit character rendered on a transparent background. Rendering
/// pauses while the view is hidden, off-window or covered, and the whole
/// animation collapses to a static pose with crossfades under Reduce Motion.
struct AssistantAvatarView: NSViewRepresentable {
    var state: AvatarState
    /// 0…1: microphone or synthesizer activity that scales the speaking and
    /// listening motion. Ignored in other states.
    var audioLevel: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AssistantAvatarSceneView {
        let view = AssistantAvatarSceneView(frame: .zero, options: nil)
        let avatar = context.coordinator.avatar
        view.scene = avatar.scene
        view.pointOfView = avatar.cameraNode
        view.delegate = avatar
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = false
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: AssistantAvatarSceneView, context: Context) {
        view.animationsEnabled = !reduceMotion
        context.coordinator.avatar.set(state: state, audioLevel: audioLevel, animated: !reduceMotion)
    }

    final class Coordinator {
        let avatar = AssistantAvatarScene()
    }
}

/// SCNView that only renders while it can actually be seen.
final class AssistantAvatarSceneView: SCNView {
    var animationsEnabled = true {
        didSet { updatePlayback() }
    }

    private var occlusionObserver: NSObjectProtocol?

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
        }
        updatePlayback()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updatePlayback()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updatePlayback()
    }

    private func updatePlayback() {
        let visible = window.map { $0.occlusionState.contains(.visible) } ?? false
        let shouldRender = visible && !isHiddenOrHasHiddenAncestor
        // Continuous frames only while animating; a static pose re-renders on
        // demand when a SCNTransaction changes something.
        rendersContinuously = shouldRender && animationsEnabled
        isPlaying = shouldRender
    }
}

// MARK: - Scene

/// Builds the procedural character (no external assets) and animates it from
/// the SceneKit render callback. `set(state:audioLevel:animated:)` is the only
/// entry point from the main thread; everything else runs on the render thread.
final class AssistantAvatarScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let cameraNode = SCNNode()

    // Colours shared with StudioTheme.purple and a cyan accent.
    static let purple = NSColor(calibratedRed: 0.50, green: 0.38, blue: 1.0, alpha: 1)
    static let cyan = NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.98, alpha: 1)

    private struct Input {
        var state: AvatarState = .idle
        var audioLevel: Double = 0
        var animated = true
        /// Set when motion is re-enabled so the render thread restarts from rest.
        var resetPose = false
    }

    /// Every animated quantity in one value so states blend into each other.
    struct Pose {
        var offset = SIMD3<Double>(0, 0, 0)
        var scale = SIMD3<Double>(1, 1, 1)
        /// Euler angles: x leans toward the viewer, y turns, z tilts the head.
        var tilt = SIMD3<Double>(0, 0, 0)
        var eyeOpen = 1.0
        var eyeSize = 1.0
        var pupilSize = 1.0
        var gaze = SIMD2<Double>(0, 0)
        var ringOpacity = 0.55
        /// 0 = purple halo, 1 = cyan halo.
        var ringCyan = 0.35
        var ringScale = 1.0
        var tipGlow = 1.0
        var cheekOpacity = 0.8

        static func mix(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
            func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            var pose = Pose()
            pose.offset = a.offset + (b.offset - a.offset) * t
            pose.scale = a.scale + (b.scale - a.scale) * t
            pose.tilt = a.tilt + (b.tilt - a.tilt) * t
            pose.eyeOpen = lerp(a.eyeOpen, b.eyeOpen)
            pose.eyeSize = lerp(a.eyeSize, b.eyeSize)
            pose.pupilSize = lerp(a.pupilSize, b.pupilSize)
            pose.gaze = a.gaze + (b.gaze - a.gaze) * t
            pose.ringOpacity = lerp(a.ringOpacity, b.ringOpacity)
            pose.ringCyan = lerp(a.ringCyan, b.ringCyan)
            pose.ringScale = lerp(a.ringScale, b.ringScale)
            pose.tipGlow = lerp(a.tipGlow, b.tipGlow)
            pose.cheekOpacity = lerp(a.cheekOpacity, b.cheekOpacity)
            return pose
        }
    }

    // Node graph
    private let root = SCNNode()
    private var eyes: [SCNNode] = []
    private var pupils: [SCNNode] = []
    private var pupilRest = SIMD3<Double>(0, 0, 0)
    private var cheeks: [SCNNode] = []
    private let ringAnchor = SCNNode()
    private var ringMaterial = SCNMaterial()
    private var haloMaterial = SCNMaterial()
    private var tipMaterial = SCNMaterial()
    private var tipGlowNode = SCNNode()
    private var keyLight = SCNNode()

    // Main-thread input, render-thread state
    private let lock = NSLock()
    private var input = Input()

    private var startTime: TimeInterval?
    private var currentState: AvatarState = .idle
    private var stateEntered: TimeInterval = 0
    private var transitionStart: TimeInterval = -1
    private var fromPose = Pose()
    private var lastPose = Pose()
    private var smoothedLevel = 0.0
    private var nextBlink: TimeInterval = 0
    private var blinkStart: TimeInterval = -10
    private var gazeFrom = SIMD2<Double>(0, 0)
    private var gazeTo = SIMD2<Double>(0, 0)
    private var gazeDrift = SIMD2<Double>(0, 0)
    private var gazeStart: TimeInterval = 0
    private var nextGazeChange: TimeInterval = 0
    private var appliedRingCyan = -1.0

    static let transitionDuration: TimeInterval = 0.45
    private static let ringHeight = 1.18
    private static let ringTilt = 0.38

    override init() {
        super.init()
        buildScene()
        applyStatic(state: .idle, animated: false)
    }

    // MARK: Input

    func set(state: AvatarState, audioLevel: Double, animated: Bool) {
        let previous: Input = lock.withLock {
            let previous = input
            input.state = state
            input.audioLevel = min(max(audioLevel, 0), 1)
            input.animated = animated
            if animated, !previous.animated { input.resetPose = true }
            return previous
        }
        if !animated, previous.animated || previous.state != state {
            applyStatic(state: state, animated: true)
        }
    }

    // MARK: Render loop

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        advance(to: time)
    }

    /// Advances the animation to `time` (seconds, any origin) and writes the
    /// pose into the node graph. Safe to call from the render thread or, for
    /// off-screen snapshots, from any single thread.
    func advance(to time: TimeInterval) {
        let input: Input = lock.withLock {
            let current = self.input
            self.input.resetPose = false
            return current
        }
        guard input.animated else { return }
        if input.resetPose {
            // Motion was re-enabled after a static pose: continue from rest.
            fromPose = Pose()
            lastPose = Pose()
            transitionStart = -1
            currentState = input.state
            stateEntered = time
        }
        if startTime == nil {
            startTime = time
            stateEntered = time
            nextBlink = time + 1.8
            nextGazeChange = time + 1.2
        }
        if input.state != currentState {
            fromPose = lastPose
            transitionStart = time
            stateEntered = time
            currentState = input.state
        }
        let elapsed = time - (startTime ?? time)
        let local = time - stateEntered
        let attack = input.audioLevel > smoothedLevel ? 0.45 : 0.14
        smoothedLevel += (input.audioLevel - smoothedLevel) * attack

        updateGazeDrift(at: time)
        var target = Self.pose(for: currentState, elapsed: local, level: smoothedLevel, absolute: elapsed)
        target.gaze += gazeDrift * Self.driftAmplitude(for: currentState)

        let progress: Double
        if transitionStart < 0 {
            progress = 1
        } else {
            progress = Self.smoothstep(min(1, (time - transitionStart) / Self.transitionDuration))
        }
        let blended = Pose.mix(fromPose, target, progress)
        lastPose = blended

        var pose = blended
        pose.eyeOpen *= blinkFactor(at: time)
        apply(pose, absolute: elapsed)
    }

    // MARK: Poses

    static func pose(for state: AvatarState, elapsed t: TimeInterval, level: Double, absolute: TimeInterval) -> Pose {
        var pose = Pose()
        let breath = sin(2 * .pi * absolute / 3.4)
        switch state {
        case .idle:
            pose.offset.y = 0.03 * breath
            pose.scale = SIMD3(1 - 0.006 * breath, 1 + 0.014 * breath, 1 - 0.006 * breath)
            pose.ringOpacity = 0.5
            pose.ringCyan = 0.35
            pose.tipGlow = 1.0

        case .listening:
            pose.offset.z = 0.22
            pose.offset.y = 0.02 * sin(2 * .pi * t / 2.2)
            pose.tilt.x = 0.15
            pose.eyeSize = 1.16
            pose.pupilSize = 1.1
            let pulse = 0.5 + 0.5 * sin(2 * .pi * t * 1.3)
            pose.ringCyan = 1
            pose.ringOpacity = 0.6 + 0.35 * pulse
            pose.ringScale = 1 + 0.05 * pulse + 0.18 * level
            pose.tipGlow = 1.3 + 0.8 * level
            pose.cheekOpacity = 0.85

        case .thinking:
            pose.gaze = SIMD2(0.55, 0.6)
            pose.tilt.y = 0.16
            pose.tilt.z = 0.08 + 0.06 * sin(2 * .pi * t / 2.8)
            pose.offset.y = 0.02 * breath
            let pulse = 0.5 + 0.5 * sin(2 * .pi * t * 1.6)
            pose.tipGlow = 1.2 + 2.2 * pulse
            pose.ringCyan = 0.5
            pose.ringOpacity = 0.45
            pose.eyeSize = 1.02

        case .speaking:
            let beat = max(0, sin(2 * .pi * t * 2.4))
            pose.offset.y = 0.045 * beat + 0.07 * level
            pose.scale = SIMD3(1 - 0.02 * beat - 0.03 * level, 1 + 0.045 * beat + 0.06 * level, 1 - 0.02 * beat - 0.03 * level)
            pose.pupilSize = 1.08 + 0.3 * level + 0.06 * beat
            pose.eyeSize = 1.05
            pose.ringCyan = 0.6
            pose.ringOpacity = 0.6 + 0.3 * level
            pose.ringScale = 1 + 0.12 * level
            pose.tipGlow = 1.4 + 1.2 * level

        case .happy:
            let hop = 0.55
            let p = min(max(t / hop, 0), 1)
            pose.offset.y = 4 * 0.26 * p * (1 - p)
            if t < hop {
                let stretch = sin(.pi * p) * 0.12
                pose.scale = SIMD3(1 - stretch / 2, 1 + stretch, 1 - stretch / 2)
            } else if t < hop + 0.32 {
                let squash = sin(.pi * (t - hop) / 0.32) * 0.13
                pose.scale = SIMD3(1 + squash / 2, 1 - squash, 1 + squash / 2)
            } else {
                pose.offset.y = 0.02 * breath
            }
            pose.tilt.z = 0.12 * sin(2 * .pi * t * 2) * max(0, 1 - t / 1.2)
            pose.eyeOpen = 0.3
            pose.eyeSize = 1.06
            pose.ringCyan = 0.8
            pose.ringOpacity = 0.85
            pose.ringScale = 1.1
            pose.tipGlow = 2.2
            pose.cheekOpacity = 1

        case .error:
            pose.tilt.z = -0.2
            pose.tilt.x = -0.05
            pose.offset.x = 0.02 * sin(2 * .pi * 9 * t) * exp(-3 * t)
            pose.eyeOpen = 0.82
            pose.pupilSize = 0.9
            pose.gaze = SIMD2(-0.25, -0.35)
            pose.ringOpacity = 0.16
            pose.ringCyan = 0
            pose.tipGlow = 0.3
            pose.cheekOpacity = 0.35
        }
        return pose
    }

    private static func driftAmplitude(for state: AvatarState) -> Double {
        switch state {
        case .idle: return 1
        case .listening: return 0.35
        case .speaking: return 0.4
        case .thinking: return 0.15
        case .happy, .error: return 0
        }
    }

    private func updateGazeDrift(at time: TimeInterval) {
        if time >= nextGazeChange {
            gazeFrom = gazeDrift
            let angle = Double.random(in: 0..<(2 * .pi))
            let radius = Double.random(in: 0.15...0.7)
            gazeTo = SIMD2(cos(angle) * radius, sin(angle) * radius * 0.7)
            gazeStart = time
            nextGazeChange = time + Double.random(in: 2.5...5)
        }
        let p = Self.smoothstep(min(1, (time - gazeStart) / 0.7))
        gazeDrift = gazeFrom + (gazeTo - gazeFrom) * p
    }

    private func blinkFactor(at time: TimeInterval) -> Double {
        if time >= nextBlink {
            blinkStart = time
            let doubleBlink = Double.random(in: 0..<1) < 0.2
            nextBlink = time + (doubleBlink ? 0.35 : Double.random(in: 3...5))
        }
        let p = (time - blinkStart) / 0.16
        guard p >= 0, p <= 1 else { return 1 }
        return 1 - sin(.pi * p) * 0.95
    }

    static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Applying a pose

    private func apply(_ pose: Pose, absolute: TimeInterval) {
        root.position = SCNVector3(pose.offset.x, pose.offset.y, pose.offset.z)
        root.scale = SCNVector3(pose.scale.x, pose.scale.y, pose.scale.z)
        root.eulerAngles = SCNVector3(pose.tilt.x, pose.tilt.y, pose.tilt.z)
        let open = max(0.06, pose.eyeOpen)
        for eye in eyes {
            eye.scale = SCNVector3(pose.eyeSize, pose.eyeSize * open, pose.eyeSize)
        }
        for pupil in pupils {
            pupil.position = SCNVector3(pupilRest.x + pose.gaze.x * 0.05, pupilRest.y + pose.gaze.y * 0.045, pupilRest.z)
            pupil.scale = SCNVector3(pose.pupilSize, pose.pupilSize, 0.55 * pose.pupilSize)
        }
        for cheek in cheeks { cheek.opacity = CGFloat(pose.cheekOpacity) }
        ringAnchor.position = SCNVector3(0, Self.ringHeight + 0.03 * sin(2 * .pi * absolute / 3.1 + 1.0), 0)
        ringAnchor.scale = SCNVector3(pose.ringScale, pose.ringScale, pose.ringScale)
        ringAnchor.opacity = CGFloat(pose.ringOpacity)
        applyRingColor(pose.ringCyan)
        tipMaterial.emission.intensity = CGFloat(pose.tipGlow)
        tipGlowNode.opacity = CGFloat(min(1, 0.25 + 0.3 * pose.tipGlow))
    }

    private func applyRingColor(_ cyan: Double) {
        guard abs(cyan - appliedRingCyan) > 0.015 else { return }
        appliedRingCyan = cyan
        let color = Self.mix(Self.purple, Self.cyan, cyan)
        ringMaterial.emission.contents = color
        haloMaterial.diffuse.contents = color
    }

    /// Reduce Motion: the rest pose plus crossfaded colours and glow.
    private func applyStatic(state: AvatarState, animated: Bool) {
        let pose = Self.pose(for: state, elapsed: 0.3, level: 0, absolute: 0)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        root.position = SCNVector3(0, 0, 0)
        root.scale = SCNVector3(1, 1, 1)
        root.eulerAngles = SCNVector3(0, 0, 0)
        for eye in eyes { eye.scale = SCNVector3(1, 1, 1) }
        for pupil in pupils {
            pupil.position = SCNVector3(pupilRest.x, pupilRest.y, pupilRest.z)
            pupil.scale = SCNVector3(1, 1, 0.55)
        }
        for cheek in cheeks { cheek.opacity = CGFloat(pose.cheekOpacity) }
        ringAnchor.position = SCNVector3(0, Self.ringHeight, 0)
        ringAnchor.scale = SCNVector3(1, 1, 1)
        ringAnchor.opacity = CGFloat(pose.ringOpacity)
        appliedRingCyan = -1
        applyRingColor(pose.ringCyan)
        tipMaterial.emission.intensity = CGFloat(pose.tipGlow)
        tipGlowNode.opacity = CGFloat(min(1, 0.25 + 0.3 * pose.tipGlow))
        SCNTransaction.commit()
        lastPose = Pose()
        fromPose = Pose()
        transitionStart = -1
    }

    // MARK: Building

    private func buildScene() {
        scene.background.contents = nil
        scene.lightingEnvironment.contents = ProceduralTextures.environment()
        scene.lightingEnvironment.intensity = 1.1

        let camera = SCNCamera()
        camera.fieldOfView = 24
        camera.projectionDirection = .vertical
        camera.zNear = 0.5
        camera.zFar = 40
        camera.wantsHDR = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.55, 6.6)
        let focus = SCNNode()
        focus.position = SCNVector3(0, 0.22, 0)
        scene.rootNode.addChildNode(focus)
        let lookAt = SCNLookAtConstraint(target: focus)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        scene.rootNode.addChildNode(root)
        buildBody()
        buildEyes()
        buildCheeks()
        buildAntenna()
        buildRing()
        buildLights(target: focus)
    }

    private func buildBody() {
        let sphere = SCNSphere(radius: 0.82)
        sphere.segmentCount = 72
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = ProceduralTextures.bodyGradient()
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        sphere.materials = [material]
        let body = SCNNode(geometry: sphere)
        body.scale = SCNVector3(1, 0.93, 0.97)
        body.name = "body"
        root.addChildNode(body)
    }

    private func buildEyes() {
        let white = SCNMaterial()
        white.lightingModel = .physicallyBased
        white.diffuse.contents = NSColor(calibratedRed: 0.98, green: 0.98, blue: 1.0, alpha: 1)
        white.roughness.contents = 0.18
        white.metalness.contents = 0.0

        let dark = SCNMaterial()
        dark.lightingModel = .physicallyBased
        dark.diffuse.contents = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.14, alpha: 1)
        dark.roughness.contents = 0.3
        dark.metalness.contents = 0.0

        let shine = SCNMaterial()
        shine.lightingModel = .constant
        shine.diffuse.contents = NSColor.white
        shine.emission.contents = NSColor.white

        pupilRest = SIMD3(0, 0, 0.145)
        for side in [-1.0, 1.0] {
            let eye = SCNNode()
            eye.position = SCNVector3(0.30 * side, 0.12, 0.70)
            let ball = SCNSphere(radius: 0.17)
            ball.segmentCount = 48
            ball.materials = [white]
            eye.addChildNode(SCNNode(geometry: ball))

            let pupilGeometry = SCNSphere(radius: 0.095)
            pupilGeometry.segmentCount = 36
            pupilGeometry.materials = [dark]
            let pupil = SCNNode(geometry: pupilGeometry)
            pupil.position = SCNVector3(pupilRest.x, pupilRest.y, pupilRest.z)
            pupil.scale = SCNVector3(1, 1, 0.55)
            eye.addChildNode(pupil)

            let highlight = SCNSphere(radius: 0.034)
            highlight.segmentCount = 16
            highlight.materials = [shine]
            let highlightNode = SCNNode(geometry: highlight)
            highlightNode.position = SCNVector3(-0.045, 0.06, 0.19)
            eye.addChildNode(highlightNode)

            let smallHighlight = SCNSphere(radius: 0.016)
            smallHighlight.segmentCount = 12
            smallHighlight.materials = [shine]
            let smallHighlightNode = SCNNode(geometry: smallHighlight)
            smallHighlightNode.position = SCNVector3(0.05, -0.05, 0.195)
            eye.addChildNode(smallHighlightNode)

            root.addChildNode(eye)
            eyes.append(eye)
            pupils.append(pupil)
        }
    }

    private func buildCheeks() {
        let blush = SCNMaterial()
        blush.lightingModel = .physicallyBased
        blush.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.74, alpha: 1)
        blush.emission.contents = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.66, alpha: 1)
        blush.emission.intensity = 0.35
        blush.roughness.contents = 1.0
        blush.metalness.contents = 0.0
        for side in [-1.0, 1.0] {
            let disc = SCNSphere(radius: 0.115)
            disc.segmentCount = 32
            disc.materials = [blush]
            let cheek = SCNNode(geometry: disc)
            cheek.position = SCNVector3(0.49 * side, -0.14, 0.64)
            cheek.scale = SCNVector3(1, 0.72, 0.3)
            cheek.eulerAngles = SCNVector3(0.12, atan2(0.49 * side, 0.64), 0)
            cheek.opacity = 0.8
            root.addChildNode(cheek)
            cheeks.append(cheek)
        }
    }

    private func buildAntenna() {
        let stalkMaterial = SCNMaterial()
        stalkMaterial.lightingModel = .physicallyBased
        stalkMaterial.diffuse.contents = NSColor(calibratedRed: 0.32, green: 0.26, blue: 0.58, alpha: 1)
        stalkMaterial.roughness.contents = 0.7
        stalkMaterial.metalness.contents = 0.0
        let stalk = SCNCylinder(radius: 0.028, height: 0.34)
        stalk.radialSegmentCount = 24
        stalk.materials = [stalkMaterial]
        let stalkNode = SCNNode(geometry: stalk)
        stalkNode.position = SCNVector3(0, 0.88, 0)
        root.addChildNode(stalkNode)

        tipMaterial = SCNMaterial()
        tipMaterial.lightingModel = .constant
        tipMaterial.diffuse.contents = NSColor(calibratedRed: 0.55, green: 0.95, blue: 1.0, alpha: 1)
        tipMaterial.emission.contents = Self.cyan
        tipMaterial.emission.intensity = 1
        let tip = SCNSphere(radius: 0.075)
        tip.segmentCount = 32
        tip.materials = [tipMaterial]
        let tipNode = SCNNode(geometry: tip)
        tipNode.position = SCNVector3(0, 1.08, 0)
        root.addChildNode(tipNode)

        let glowMaterial = SCNMaterial()
        glowMaterial.lightingModel = .constant
        glowMaterial.diffuse.contents = Self.cyan
        glowMaterial.transparent.contents = ProceduralTextures.radialGlow()
        glowMaterial.transparencyMode = .aOne
        glowMaterial.writesToDepthBuffer = false
        glowMaterial.isDoubleSided = true
        let glow = SCNPlane(width: 0.6, height: 0.6)
        glow.materials = [glowMaterial]
        tipGlowNode = SCNNode(geometry: glow)
        tipGlowNode.position = SCNVector3(0, 1.08, 0.02)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        tipGlowNode.constraints = [billboard]
        tipGlowNode.opacity = 0.55
        root.addChildNode(tipGlowNode)
    }

    private func buildRing() {
        ringMaterial = SCNMaterial()
        ringMaterial.lightingModel = .constant
        ringMaterial.diffuse.contents = NSColor.black
        ringMaterial.emission.contents = Self.purple
        ringMaterial.emission.intensity = 1.15
        let torus = SCNTorus(ringRadius: 0.55, pipeRadius: 0.028)
        torus.ringSegmentCount = 96
        torus.pipeSegmentCount = 16
        torus.materials = [ringMaterial]
        let ring = SCNNode(geometry: torus)
        ring.eulerAngles = SCNVector3(Self.ringTilt, 0, 0)
        ringAnchor.addChildNode(ring)

        haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = Self.purple
        haloMaterial.transparent.contents = ProceduralTextures.ringGlow()
        haloMaterial.transparencyMode = .aOne
        haloMaterial.writesToDepthBuffer = false
        haloMaterial.isDoubleSided = true
        let halo = SCNPlane(width: 1.8, height: 1.8)
        halo.materials = [haloMaterial]
        let haloNode = SCNNode(geometry: halo)
        haloNode.eulerAngles = SCNVector3(-Double.pi / 2 + Self.ringTilt, 0, 0)
        haloNode.opacity = 0.9
        ringAnchor.addChildNode(haloNode)

        ringAnchor.position = SCNVector3(0, Self.ringHeight, 0)
        ringAnchor.opacity = 0.55
        scene.rootNode.addChildNode(ringAnchor)
    }

    private func buildLights(target: SCNNode) {
        let key = SCNLight()
        key.type = .directional
        key.color = NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.84, alpha: 1)
        key.intensity = 1100
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 8
        key.shadowSampleCount = 8
        key.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.32)
        key.orthographicScale = 2.6
        keyLight = SCNNode()
        keyLight.light = key
        keyLight.position = SCNVector3(-2.6, 3.2, 4.0)
        keyLight.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(keyLight)

        let rim = SCNLight()
        rim.type = .directional
        rim.color = NSColor(calibratedRed: 0.55, green: 0.88, blue: 1.0, alpha: 1)
        rim.intensity = 900
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(3.0, 1.6, -3.2)
        rimNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(rimNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.color = NSColor(calibratedRed: 0.72, green: 0.62, blue: 1.0, alpha: 1)
        fill.intensity = 300
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(3.2, -0.4, 4.0)
        fillNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(calibratedRed: 0.5, green: 0.46, blue: 0.7, alpha: 1)
        ambient.intensity = 260
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let x = a.usingColorSpace(.deviceRGB) ?? a
        let y = b.usingColorSpace(.deviceRGB) ?? b
        let f = CGFloat(min(max(t, 0), 1))
        return NSColor(
            deviceRed: x.redComponent + (y.redComponent - x.redComponent) * f,
            green: x.greenComponent + (y.greenComponent - x.greenComponent) * f,
            blue: x.blueComponent + (y.blueComponent - x.blueComponent) * f,
            alpha: 1
        )
    }
}

// MARK: - Textures

/// Small CoreGraphics images that replace shipped assets: a pastel body
/// gradient, soft glow sprites and a gradient environment for reflections.
enum ProceduralTextures {
    static func bodyGradient() -> CGImage? {
        gradientImage(width: 4, height: 256, colors: [
            CGColor(red: 0.66, green: 0.55, blue: 1.0, alpha: 1),
            CGColor(red: 0.58, green: 0.60, blue: 1.0, alpha: 1),
            CGColor(red: 0.46, green: 0.86, blue: 0.97, alpha: 1),
        ], locations: [0, 0.5, 1])
    }

    /// Equirectangular sky: brighter above so the glossy eyes pick up a highlight.
    static func environment() -> CGImage? {
        gradientImage(width: 128, height: 64, colors: [
            CGColor(red: 0.85, green: 0.88, blue: 1.0, alpha: 1),
            CGColor(red: 0.45, green: 0.40, blue: 0.70, alpha: 1),
            CGColor(red: 0.12, green: 0.10, blue: 0.22, alpha: 1),
        ], locations: [0, 0.55, 1])
    }

    static func radialGlow(size: Int = 128) -> CGImage? {
        radialImage(size: size, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.95),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ], locations: [0, 0.35, 1])
    }

    static func ringGlow(size: Int = 256) -> CGImage? {
        radialImage(size: size, colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.8),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ], locations: [0, 0.42, 0.61, 0.82])
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func gradientImage(width: Int, height: Int, colors: [CGColor], locations: [CGFloat]) -> CGImage? {
        guard let context = context(width: width, height: height),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
        else { return nil }
        // CoreGraphics draws bottom-up; start at the top so the first colour is on top.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return context.makeImage()
    }

    private static func radialImage(size: Int, colors: [CGColor], locations: [CGFloat]) -> CGImage? {
        guard let context = context(width: size, height: size),
              let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
        else { return nil }
        let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()
    }
}

// MARK: - Off-screen preview

#if DEBUG
extension AssistantAvatarScene {
    /// Renders one state without a window, for previews and the compile-time
    /// sanity check. Returns nil when no Metal device exists (CI runners).
    static func renderPreview(
        state: AvatarState,
        size: CGSize = CGSize(width: 320, height: 320),
        time: TimeInterval = 0.8,
        audioLevel: Double = 0.4
    ) -> NSImage? {
        let avatar = AssistantAvatarScene()
        avatar.set(state: .idle, audioLevel: 0, animated: true)
        avatar.advance(to: 0)
        avatar.set(state: state, audioLevel: audioLevel, animated: true)
        avatar.advance(to: 0.01)
        avatar.advance(to: 0.01 + transitionDuration + time)
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = avatar.scene
        renderer.pointOfView = avatar.cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}

struct AssistantAvatarPreview: View {
    @State private var state: AvatarState = .idle

    var body: some View {
        VStack(spacing: 12) {
            AssistantAvatarView(state: state, audioLevel: 0.3)
                .frame(width: 220, height: 150)
            Picker("State", selection: $state) {
                ForEach([AvatarState.idle, .listening, .thinking, .speaking, .happy, .error], id: \.self) {
                    Text(verbatim: $0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .background(StudioTheme.panel)
    }
}
#endif

// MARK: - Director

/// Turns session events into avatar states: a base state that follows the
/// session (idle, listening, thinking), short reactions layered on top
/// (happy, error, a two-second speaking beat) and a hold while a spoken reply
/// is playing.
@MainActor
final class AssistantAvatarDirector: ObservableObject {
    @Published private(set) var state: AvatarState = .idle

    private var base: AvatarState = .idle
    private var reaction: AvatarState?
    private var reactionTask: Task<Void, Never>?
    private var isSpeakingAloud = false

    func setBase(_ state: AvatarState) {
        base = state
        publish()
    }

    /// Shows `state` for `duration`, then falls back to the base state.
    func react(_ state: AvatarState, for duration: Duration) {
        reactionTask?.cancel()
        reaction = state
        publish()
        reactionTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.reaction = nil
            self.publish()
        }
    }

    func setSpeakingAloud(_ speaking: Bool) {
        isSpeakingAloud = speaking
        if speaking {
            reactionTask?.cancel()
            reaction = nil
        }
        publish()
    }

    private func publish() {
        let next = reaction ?? (isSpeakingAloud ? .speaking : base)
        if next != state { state = next }
    }
}
