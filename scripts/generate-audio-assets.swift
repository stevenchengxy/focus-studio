#!/usr/bin/swift

import Darwin
import Foundation

// Focus Studio's bundled audio is generated from synthesis code so every build
// is reproducible and no third-party samples or recordings are required.

private let sampleRate = 48_000
private let tau = Double.pi * 2

private struct StereoBuffer {
    var left: [Float]
    var right: [Float]

    init(duration: Double) {
        let count = max(1, Int((duration * Double(sampleRate)).rounded(.up)))
        left = Array(repeating: 0, count: count)
        right = Array(repeating: 0, count: count)
    }

    var duration: Double { Double(left.count) / Double(sampleRate) }

    mutating func add(_ sample: Double, at index: Int, pan: Double = 0) {
        guard left.indices.contains(index) else { return }
        let safePan = min(1, max(-1, pan))
        let angle = (safePan + 1) * Double.pi / 4
        left[index] += Float(sample * cos(angle))
        right[index] += Float(sample * sin(angle))
    }

    mutating func normalize(peak target: Double) {
        var maximum = 0.0
        for index in left.indices {
            maximum = max(maximum, abs(Double(left[index])), abs(Double(right[index])))
        }
        guard maximum > 0 else { return }
        let gain = target / maximum
        for index in left.indices {
            left[index] = Float(tanh(Double(left[index]) * gain))
            right[index] = Float(tanh(Double(right[index]) * gain))
        }
    }
}

private struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xF0C05A7D10 : seed
    }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = Double((state >> 40) & 0xFFFFFF) / Double(0xFFFFFF)
        return value * 2 - 1
    }
}

private func midi(_ note: Int) -> Double {
    440 * pow(2, Double(note - 69) / 12)
}

private func smoothstep(_ value: Double) -> Double {
    let x = min(1, max(0, value))
    return x * x * (3 - 2 * x)
}

private func envelope(time: Double, duration: Double, attack: Double, release: Double) -> Double {
    let onset = smoothstep(time / max(attack, 0.0001))
    let offset = smoothstep((duration - time) / max(release, 0.0001))
    return min(onset, offset)
}

private func addPad(
    to buffer: inout StereoBuffer,
    start: Double,
    duration: Double,
    frequency: Double,
    amplitude: Double,
    pan: Double,
    phaseOffset: Double
) {
    let first = Int(start * Double(sampleRate))
    let count = Int(duration * Double(sampleRate))
    for offset in 0..<count {
        let time = Double(offset) / Double(sampleRate)
        let env = envelope(time: time, duration: duration, attack: 0.7, release: 0.9)
        let phase = tau * frequency * time + phaseOffset
        let slowMotion = 1 + 0.012 * sin(tau * 0.19 * (start + time) + phaseOffset)
        let value = (
            sin(phase * slowMotion) * 0.72
            + sin(phase * 2.003 + 0.4) * 0.19
            + sin(phase * 0.501 + 1.1) * 0.09
        ) * amplitude * env
        buffer.add(value, at: first + offset, pan: pan)
    }
}

private func addPluck(
    to buffer: inout StereoBuffer,
    start: Double,
    frequency: Double,
    amplitude: Double,
    pan: Double
) {
    let duration = 0.42
    let first = Int(start * Double(sampleRate))
    let count = Int(duration * Double(sampleRate))
    for offset in 0..<count {
        let time = Double(offset) / Double(sampleRate)
        let decay = exp(-time * 8.2) * smoothstep(time / 0.008)
        let phase = tau * frequency * time
        let value = (
            sin(phase) * 0.62
            + sin(phase * 2.01 + 0.3) * 0.26
            + sin(phase * 3.99 + 0.7) * 0.12
        ) * amplitude * decay
        buffer.add(value, at: first + offset, pan: pan)
    }
}

private func addBass(
    to buffer: inout StereoBuffer,
    start: Double,
    frequency: Double,
    amplitude: Double
) {
    let duration = 0.44
    let first = Int(start * Double(sampleRate))
    let count = Int(duration * Double(sampleRate))
    for offset in 0..<count {
        let time = Double(offset) / Double(sampleRate)
        let env = envelope(time: time, duration: duration, attack: 0.015, release: 0.22)
        let value = (sin(tau * frequency * time) + 0.18 * sin(tau * frequency * 2 * time)) * amplitude * env
        buffer.add(value, at: first + offset)
    }
}

private func addKick(to buffer: inout StereoBuffer, start: Double, amplitude: Double) {
    let duration = 0.2
    let first = Int(start * Double(sampleRate))
    let count = Int(duration * Double(sampleRate))
    var phase = 0.0
    for offset in 0..<count {
        let time = Double(offset) / Double(sampleRate)
        let frequency = 78 * exp(-time * 8.5) + 42
        phase += tau * frequency / Double(sampleRate)
        let env = exp(-time * 18) * smoothstep(time / 0.003)
        buffer.add(sin(phase) * amplitude * env, at: first + offset)
    }
}

private func addHat(
    to buffer: inout StereoBuffer,
    start: Double,
    amplitude: Double,
    pan: Double,
    noise: inout SeededNoise
) {
    let duration = 0.075
    let first = Int(start * Double(sampleRate))
    let count = Int(duration * Double(sampleRate))
    var previous = 0.0
    for offset in 0..<count {
        let time = Double(offset) / Double(sampleRate)
        let white = noise.next()
        let bright = white - previous * 0.88
        previous = white
        let env = exp(-time * 44) * smoothstep(time / 0.0015)
        buffer.add(bright * amplitude * env, at: first + offset, pan: pan)
    }
}

private func makeBackgroundMusic() -> StereoBuffer {
    let bpm = 104.0
    let beat = 60 / bpm
    let bars = 24
    let duration = Double(bars * 4) * beat
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0xF1A2_2026)

    // Bm9 · Gmaj7 · Dadd9 · Asus2, two bars per chord.
    let padChords = [
        [47, 54, 59, 61, 66],
        [43, 50, 54, 59, 64],
        [50, 57, 62, 64, 69],
        [45, 52, 57, 59, 66]
    ]
    let arpeggios = [
        [59, 61, 66, 69, 66, 61, 59, 54],
        [59, 64, 66, 71, 66, 64, 59, 54],
        [62, 64, 69, 74, 69, 64, 62, 57],
        [57, 59, 64, 69, 66, 64, 59, 52]
    ]
    let bassRoots = [35, 31, 38, 33]

    for section in 0..<3 {
        for chordIndex in 0..<4 {
            let chordStartBar = section * 8 + chordIndex * 2
            let chordStart = Double(chordStartBar * 4) * beat
            let chordDuration = beat * 8
            let sectionGain = [0.78, 1.0, 0.9][section]

            for (voice, note) in padChords[chordIndex].enumerated() {
                addPad(
                    to: &buffer,
                    start: chordStart,
                    duration: chordDuration,
                    frequency: midi(note),
                    amplitude: 0.038 * sectionGain,
                    pan: Double(voice - 2) * 0.22,
                    phaseOffset: Double(voice) * 0.61
                )
            }

            for eighth in 0..<16 {
                let start = chordStart + Double(eighth) * beat / 2
                let note = arpeggios[chordIndex][eighth % arpeggios[chordIndex].count]
                let accent = eighth % 4 == 0 ? 1.0 : 0.72
                addPluck(
                    to: &buffer,
                    start: start,
                    frequency: midi(note),
                    amplitude: 0.057 * sectionGain * accent,
                    pan: eighth.isMultiple(of: 2) ? -0.23 : 0.23
                )
            }

            for beatIndex in 0..<8 {
                let start = chordStart + Double(beatIndex) * beat
                let rhythmicGain = section == 0 ? 0.56 : 0.9
                addBass(
                    to: &buffer,
                    start: start,
                    frequency: midi(bassRoots[chordIndex]),
                    amplitude: 0.055 * rhythmicGain
                )
                if beatIndex.isMultiple(of: 2) {
                    addKick(to: &buffer, start: start, amplitude: 0.14 * rhythmicGain)
                }
                addHat(
                    to: &buffer,
                    start: start + beat / 2,
                    amplitude: 0.026 * rhythmicGain,
                    pan: beatIndex.isMultiple(of: 2) ? -0.34 : 0.34,
                    noise: &noise
                )
            }
        }
    }

    // A restrained four-note motif marks each eight-bar section without
    // competing with narration.
    let motif = [71, 74, 69, 66]
    for section in 0..<3 {
        let sectionStart = Double(section * 8 * 4) * beat
        for (index, note) in motif.enumerated() {
            addPluck(
                to: &buffer,
                start: sectionStart + beat * Double(24 + index * 2),
                frequency: midi(note),
                amplitude: 0.04,
                pan: Double(index) * 0.12 - 0.18
            )
        }
    }

    buffer.normalize(peak: 0.64)
    return buffer
}

// Spacious, narration-friendly ambient bed. This intentionally omits drums so
// onboarding, accessibility, and long-form product walkthroughs stay calm.
private func makeCalmGradientMusic() -> StereoBuffer {
    let bpm = 72.0
    let beat = 60 / bpm
    let bars = 16
    let duration = Double(bars * 4) * beat
    var buffer = StereoBuffer(duration: duration)

    // Cmaj9 · Am9 · Fmaj9 · G6, one bar per chord.
    let chords = [
        [48, 55, 59, 62, 64],
        [45, 52, 55, 59, 60],
        [41, 48, 52, 55, 60],
        [43, 50, 55, 57, 64]
    ]
    let highlights = [76, 71, 72, 74]

    for bar in 0..<bars {
        let chordIndex = bar % chords.count
        let start = Double(bar * 4) * beat
        let gain = bar < 2 ? 0.72 : (bar >= bars - 2 ? 0.78 : 1.0)

        for (voice, note) in chords[chordIndex].enumerated() {
            addPad(
                to: &buffer,
                start: start,
                duration: beat * 4.08,
                frequency: midi(note),
                amplitude: 0.034 * gain,
                pan: Double(voice - 2) * 0.2,
                phaseOffset: Double(voice) * 0.49 + Double(bar) * 0.07
            )
        }

        // A single soft high note every bar gives motion without sounding busy.
        addPluck(
            to: &buffer,
            start: start + beat * 2.5,
            frequency: midi(highlights[chordIndex]),
            amplitude: 0.027 * gain,
            pan: bar.isMultiple(of: 2) ? -0.32 : 0.32
        )
    }

    buffer.normalize(peak: 0.56)
    return buffer
}

// Crisp, optimistic launch music for feature announcements and faster demos.
private func makeBrightLaunchMusic() -> StereoBuffer {
    let bpm = 124.0
    let beat = 60 / bpm
    let bars = 16
    let duration = Double(bars * 4) * beat
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0xB817_2026)

    // D · A · Bm · G, one bar per chord.
    let chords = [
        [50, 57, 62, 66],
        [45, 52, 57, 61],
        [47, 54, 59, 62],
        [43, 50, 55, 59]
    ]
    let arpeggios = [
        [62, 66, 69, 74, 69, 66, 62, 69],
        [61, 64, 69, 73, 69, 64, 61, 69],
        [59, 62, 66, 71, 66, 62, 59, 66],
        [59, 62, 67, 71, 67, 62, 59, 67]
    ]
    let bassRoots = [38, 33, 35, 31]

    for bar in 0..<bars {
        let chordIndex = bar % chords.count
        let start = Double(bar * 4) * beat
        let sectionGain = bar < 2 ? 0.7 : (bar >= 12 ? 1.0 : 0.88)

        for (voice, note) in chords[chordIndex].enumerated() {
            addPad(
                to: &buffer,
                start: start,
                duration: beat * 4.05,
                frequency: midi(note),
                amplitude: 0.023 * sectionGain,
                pan: Double(voice) * 0.18 - 0.27,
                phaseOffset: Double(voice) * 0.72
            )
        }

        for eighth in 0..<8 {
            addPluck(
                to: &buffer,
                start: start + Double(eighth) * beat / 2,
                frequency: midi(arpeggios[chordIndex][eighth]),
                amplitude: (eighth.isMultiple(of: 4) ? 0.068 : 0.048) * sectionGain,
                pan: eighth.isMultiple(of: 2) ? -0.25 : 0.25
            )
        }

        for pulse in 0..<4 {
            let pulseStart = start + Double(pulse) * beat
            addBass(
                to: &buffer,
                start: pulseStart,
                frequency: midi(bassRoots[chordIndex]),
                amplitude: 0.058 * sectionGain
            )
            addKick(to: &buffer, start: pulseStart, amplitude: 0.13 * sectionGain)
            addHat(
                to: &buffer,
                start: pulseStart + beat / 2,
                amplitude: 0.032 * sectionGain,
                pan: pulse.isMultiple(of: 2) ? -0.38 : 0.38,
                noise: &noise
            )
        }
    }

    buffer.normalize(peak: 0.63)
    return buffer
}

// A darker, minimal pulse that works behind analytics and developer-tool demos.
private func makeMidnightFocusMusic() -> StereoBuffer {
    let bpm = 88.0
    let beat = 60 / bpm
    let bars = 16
    let duration = Double(bars * 4) * beat
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0xD4A7_2026)

    // Em9 · Cmaj7 · G6 · Dsus2, two bars per chord.
    let chords = [
        [40, 47, 52, 54, 59],
        [36, 43, 48, 52, 59],
        [43, 50, 55, 59, 64],
        [38, 45, 50, 52, 57]
    ]
    let pulses = [52, 48, 55, 50]
    let bassRoots = [28, 24, 31, 26]

    for section in 0..<8 {
        let chordIndex = section % chords.count
        let start = Double(section * 8) * beat
        let sectionGain = section == 0 ? 0.7 : (section == 7 ? 0.82 : 1.0)

        for (voice, note) in chords[chordIndex].enumerated() {
            addPad(
                to: &buffer,
                start: start,
                duration: beat * 8.05,
                frequency: midi(note),
                amplitude: 0.029 * sectionGain,
                pan: Double(voice - 2) * 0.23,
                phaseOffset: Double(voice) * 0.83
            )
        }

        for pulse in 0..<16 {
            let pulseStart = start + Double(pulse) * beat / 2
            addPluck(
                to: &buffer,
                start: pulseStart,
                frequency: midi(pulses[chordIndex] + (pulse % 8 == 6 ? 7 : 0)),
                amplitude: (pulse.isMultiple(of: 4) ? 0.047 : 0.026) * sectionGain,
                pan: pulse.isMultiple(of: 2) ? -0.18 : 0.18
            )
            if pulse.isMultiple(of: 4) {
                addBass(
                    to: &buffer,
                    start: pulseStart,
                    frequency: midi(bassRoots[chordIndex]),
                    amplitude: 0.062 * sectionGain
                )
                addKick(to: &buffer, start: pulseStart, amplitude: 0.085 * sectionGain)
            } else if pulse % 4 == 2 {
                addHat(
                    to: &buffer,
                    start: pulseStart,
                    amplitude: 0.015 * sectionGain,
                    pan: pulse.isMultiple(of: 8) ? -0.24 : 0.24,
                    noise: &noise
                )
            }
        }
    }

    buffer.normalize(peak: 0.58)
    return buffer
}

private func makeUIClick() -> StereoBuffer {
    let duration = 0.105
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0xC11C_2026)
    var phase = 0.0
    for index in buffer.left.indices {
        let time = Double(index) / Double(sampleRate)
        let progress = time / duration
        let frequency = 1_760 - 620 * smoothstep(progress)
        phase += tau * frequency / Double(sampleRate)
        let env = exp(-time * 39) * smoothstep(time / 0.0018)
        let transient = noise.next() * exp(-time * 95) * 0.19
        let tone = (sin(phase) + 0.21 * sin(phase * 1.997 + 0.2)) * env
        buffer.add((tone * 0.66 + transient) * 0.45, at: index)
    }
    buffer.normalize(peak: 0.56)
    return buffer
}

private func makeZoomWhoosh() -> StereoBuffer {
    let duration = 0.46
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0x200F_2026)
    var lowPass = 0.0
    var slowerLowPass = 0.0
    var phase = 0.0

    for index in buffer.left.indices {
        let time = Double(index) / Double(sampleRate)
        let progress = time / duration
        let shape = pow(sin(Double.pi * progress), 1.7)
        let white = noise.next()
        let alpha = 0.025 + 0.16 * sin(Double.pi * progress)
        lowPass += alpha * (white - lowPass)
        slowerLowPass += 0.012 * (white - slowerLowPass)
        let air = lowPass - slowerLowPass
        let frequency = 185 + 520 * smoothstep(progress)
        phase += tau * frequency / Double(sampleRate)
        let tone = sin(phase) * 0.16 + sin(phase * 2.01 + 0.7) * 0.04
        let pan = -0.52 + 1.04 * smoothstep(progress)
        buffer.add((air * 0.8 + tone) * shape * 0.52, at: index, pan: pan)
    }
    buffer.normalize(peak: 0.58)
    return buffer
}

private func makeSoftTap() -> StereoBuffer {
    let duration = 0.13
    var buffer = StereoBuffer(duration: duration)
    var phase = 0.0
    for index in buffer.left.indices {
        let time = Double(index) / Double(sampleRate)
        let progress = time / duration
        let frequency = 880 - 260 * smoothstep(progress)
        phase += tau * frequency / Double(sampleRate)
        let env = exp(-time * 31) * smoothstep(time / 0.003)
        let value = (sin(phase) * 0.76 + sin(phase * 0.5 + 0.4) * 0.24) * env * 0.34
        buffer.add(value, at: index, pan: 0.08)
    }
    buffer.normalize(peak: 0.46)
    return buffer
}

private func makeTypingKey() -> StereoBuffer {
    let duration = 0.075
    var buffer = StereoBuffer(duration: duration)
    var noise = SeededNoise(seed: 0x7A9E_2026)
    var filtered = 0.0
    for index in buffer.left.indices {
        let time = Double(index) / Double(sampleRate)
        filtered += 0.24 * (noise.next() - filtered)
        let env = exp(-time * 58) * smoothstep(time / 0.0014)
        let body = sin(tau * 540 * time) * exp(-time * 42) * 0.2
        buffer.add((filtered * 0.42 + body) * env, at: index, pan: -0.05)
    }
    buffer.normalize(peak: 0.42)
    return buffer
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private func writeWAV(_ buffer: StereoBuffer, to url: URL) throws {
    precondition(buffer.left.count == buffer.right.count)
    let channels: UInt16 = 2
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = Int(bitsPerSample / 8)
    let dataSize = buffer.left.count * Int(channels) * bytesPerSample
    let byteRate = sampleRate * Int(channels) * bytesPerSample
    let blockAlign = channels * bitsPerSample / 8

    var data = Data(capacity: 44 + dataSize)
    data.append(contentsOf: "RIFF".utf8)
    data.appendLittleEndian(UInt32(36 + dataSize))
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channels)
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(byteRate))
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.append(contentsOf: "data".utf8)
    data.appendLittleEndian(UInt32(dataSize))

    for index in buffer.left.indices {
        for value in [buffer.left[index], buffer.right[index]] {
            let clamped = max(-1, min(1, Double(value)))
            let signed = Int16((clamped * Double(Int16.max)).rounded())
            data.appendLittleEndian(UInt16(bitPattern: signed))
        }
    }
    try data.write(to: url, options: .atomic)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-audio-assets.swift <output-directory>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

private let assets: [(name: String, make: () -> StereoBuffer)] = [
    ("product-demo-bed.wav", makeBackgroundMusic),
    ("calm-gradient-bed.wav", makeCalmGradientMusic),
    ("bright-launch-bed.wav", makeBrightLaunchMusic),
    ("midnight-focus-bed.wav", makeMidnightFocusMusic),
    ("ui-click.wav", makeUIClick),
    ("soft-tap.wav", makeSoftTap),
    ("typing-key.wav", makeTypingKey),
    ("zoom-whoosh.wav", makeZoomWhoosh)
]

for asset in assets {
    let buffer = asset.make()
    let destination = outputDirectory.appendingPathComponent(asset.name)
    try writeWAV(buffer, to: destination)
    print("Generated \(asset.name) (\(String(format: "%.3f", buffer.duration)) seconds, \(sampleRate) Hz stereo PCM)")
}
