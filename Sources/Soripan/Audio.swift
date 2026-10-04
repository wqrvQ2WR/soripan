import Foundation
import AVFoundation

let SR: Double = 44100
let peakBlock = 256
let paletteCount = 6

// MARK: - 프로젝트 모델 (값 타입이라 통째로 undo 스냅샷이 됨)

struct Clip: Identifiable, Equatable, Codable {
    var id = UUID()
    var sourceID: UUID
    var name: String
    var start: Double      // 타임라인 위치 (초)
    var offset: Double     // 원본 파일 안에서 시작 지점 (초)
    var length: Double
    var gain: Float = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var pitch: Double = 0     // 반음 단위
    var speed: Double = 1     // 배속. 타임라인 길이 = 원본 구간 / speed
    var end: Double { start + length }
    var isProcessed: Bool { pitch != 0 || speed != 1 }
    var variantKey: String { AudioSource.key(pitch: pitch, speed: speed) }
}

struct Track: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var clips: [Clip] = []
    var volume: Float = 1
    var pan: Float = 0
    var mute = false
    var solo = false
}

struct ProjectState: Equatable {
    var tracks: [Track] = []
    var end: Double { tracks.flatMap(\.clips).map(\.end).max() ?? 0 }
}

// MARK: - 프로젝트 파일 (.soripan, JSON)

struct ProjectFile: Codable {
    struct SourceRef: Codable {
        var id: UUID
        var path: String          // 절대 경로
        var relative: String?     // 프로젝트 파일 기준 상대 경로 (폴더째 옮겼을 때용)
    }
    var version = 1
    var pxPerSec: Double
    var sources: [SourceRef]
    var tracks: [Track]

    static let ext = "soripan"

    static func relativePath(of file: URL, from dir: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }

    /// 절대 경로 → 상대 경로 → 프로젝트 폴더 안 같은 이름 순서로 찾음
    func resolve(_ ref: SourceRef, projectDir: URL) -> URL? {
        let fm = FileManager.default
        var tries = [URL(fileURLWithPath: ref.path)]
        if let r = ref.relative { tries.append(projectDir.appendingPathComponent(r).standardizedFileURL) }
        tries.append(projectDir.appendingPathComponent(URL(fileURLWithPath: ref.path).lastPathComponent))
        return tries.first { fm.fileExists(atPath: $0.path) }
    }
}

// MARK: - 원본 오디오 (44.1kHz 스테레오 float로 디코딩해 메모리에 보관)

struct DecodedAudio: Sendable {
    var left: [Float]
    var right: [Float]
    var peaks: [Float]
}

final class AudioSource: @unchecked Sendable {
    let id: UUID
    let url: URL
    let left: [Float]
    let right: [Float]
    let peaks: [Float]
    var duration: Double { Double(left.count) / SR }

    init(id: UUID = UUID(), url: URL, decoded: DecodedAudio) {
        self.id = id
        self.url = url
        left = decoded.left
        right = decoded.right
        peaks = decoded.peaks
    }

    // 피치/배속 처리된 버전 캐시 (키: 피치_배속)
    private var variants: [String: Mix] = [:]
    private let lock = NSLock()

    static func key(pitch: Double, speed: Double) -> String { "\(Int((pitch * 100).rounded()))_\(Int((speed * 1000).rounded()))" }

    func variant(_ key: String) -> Mix? {
        lock.lock(); defer { lock.unlock() }
        return variants[key]
    }

    func setVariant(_ key: String, _ m: Mix) {
        lock.lock(); variants[key] = m; lock.unlock()
    }

    func peak(from: Double, length: Double) -> Float {
        let a = max(0, Int(from * SR)), b = min(left.count, Int((from + length) * SR))
        var m: Float = 0
        if a < b { for i in a..<b { m = max(m, abs(left[i]), abs(right[i])) } }
        return m
    }
}

struct Mix: Sendable {
    var left: [Float]
    var right: [Float]
}

enum AudioError: LocalizedError {
    case unreadable, convert
    var errorDescription: String? { self == .unreadable ? "파일을 읽을 수 없음" : "변환 실패" }
}

enum AudioIO {
    static let format = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!

    static func decode(_ url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        guard file.length > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioError.unreadable }
        try file.read(into: inBuf)

        var buf = inBuf
        if inFmt.sampleRate != SR || inFmt.channelCount > 2 {
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: min(inFmt.channelCount, 2))!
            guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw AudioError.convert }
            conv.downmix = true
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * SR / inFmt.sampleRate) + 8192
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { throw AudioError.convert }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true
                st.pointee = .haveData
                return inBuf
            }
            if status == .error { throw err ?? AudioError.convert }
            buf = out
        }

        let n = Int(buf.frameLength)
        guard n > 0, let ch = buf.floatChannelData else { throw AudioError.unreadable }
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = buf.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return DecodedAudio(left: l, right: r, peaks: peaks(l, r))
    }

    static func peaks(_ l: [Float], _ r: [Float]) -> [Float] {
        let n = l.count
        var out = [Float](repeating: 0, count: (n + peakBlock - 1) / peakBlock)
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                for b in 0..<out.count {
                    var m: Float = 0
                    let e = min(n, (b + 1) * peakBlock)
                    for i in (b * peakBlock)..<e { m = max(m, abs(lp[i]), abs(rp[i])) }
                    out[b] = m
                }
            }
        }
        return out
    }

    /// AVAudioUnitTimePitch로 오프라인 렌더. 피치는 반음, 배속은 배수 (서로 독립)
    static func timePitch(_ src: AudioSource, pitch: Double, speed: Double) throws -> Mix {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.pitch = Float(pitch * 100)
        tp.rate = Float(speed)
        tp.overlap = 16
        engine.attach(player)
        engine.attach(tp)
        engine.connect(player, to: tp, format: format)
        engine.connect(tp, to: engine.mainMixerNode, format: format)
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()
        guard let inBuf = buffer(Mix(left: src.left, right: src.right)),
              let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)
        else { throw AudioError.convert }
        player.scheduleBuffer(inBuf, completionHandler: nil)
        player.play()

        let expected = Int(Double(src.left.count) / speed)
        var L: [Float] = [], R: [Float] = []
        L.reserveCapacity(expected); R.reserveCapacity(expected)
        while L.count < expected {
            let n = AVAudioFrameCount(min(Int(maxFrames), expected - L.count))
            let st = try engine.renderOffline(n, to: out)
            guard st == .success, let ch = out.floatChannelData else { break }
            let got = Int(out.frameLength)
            L.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: got))
            R.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: got))
        }
        player.stop()
        engine.stop()
        return Mix(left: L, right: R)
    }

    static func buffer(_ mix: Mix) -> AVAudioPCMBuffer? {
        let n = mix.left.count
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            ch[0][i] = min(1, max(-1, mix.left[i]))
            ch[1][i] = min(1, max(-1, mix.right[i]))
        }
        return buf
    }

    static func write(_ mix: Mix, to url: URL, m4a: Bool) throws {
        let settings: [String: Any] = m4a
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
               AVLinearPCMIsNonInterleaved: false]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65536
        var pos = 0
        while pos < mix.left.count {
            let e = min(mix.left.count, pos + chunk)
            let part = Mix(left: Array(mix.left[pos..<e]), right: Array(mix.right[pos..<e]))
            if let b = buffer(part) { try file.write(from: b) }
            pos = e
        }
    }
}

// MARK: - 믹서: 트랙/클립/페이드/팬을 합쳐서 스테레오 샘플로

enum Mixer {
    static func render(_ s: ProjectState, _ sources: [UUID: AudioSource], from: Double, to: Double) -> Mix {
        let n = max(0, Int((to - from) * SR))
        var L = [Float](repeating: 0, count: n)
        var R = [Float](repeating: 0, count: n)
        let anySolo = s.tracks.contains { $0.solo }

        L.withUnsafeMutableBufferPointer { lp in
            R.withUnsafeMutableBufferPointer { rp in
                for t in s.tracks where !t.mute && (!anySolo || t.solo) {
                    let lg = t.volume * (t.pan > 0 ? 1 - t.pan : 1)
                    let rg = t.volume * (t.pan < 0 ? 1 + t.pan : 1)
                    for c in t.clips {
                        guard let src = sources[c.sourceID] else { continue }
                        let data: Mix
                        if c.isProcessed {
                            guard let v = src.variant(c.variantKey) else { continue }
                            data = v
                        } else {
                            data = Mix(left: src.left, right: src.right)
                        }
                        let cs = Int(((c.start - from) * SR).rounded())
                        let clen = Int(c.length * SR)
                        let off = Int(c.offset / c.speed * SR)
                        let i0 = max(0, cs), i1 = min(n, cs + clen)
                        if i0 >= i1 { continue }
                        let fi = Int(c.fadeIn * SR), fo = Int(c.fadeOut * SR)
                        data.left.withUnsafeBufferPointer { sl in
                            data.right.withUnsafeBufferPointer { sr in
                                for i in i0..<i1 {
                                    let k = i - cs
                                    let si = off + k
                                    if si < 0 { continue }
                                    if si >= sl.count { break }
                                    var g = c.gain
                                    if k < fi { g *= Float(k) / Float(fi) }
                                    let rem = clen - k
                                    if rem < fo { g *= Float(rem) / Float(fo) }
                                    lp[i] += sl[si] * g * lg
                                    rp[i] += sr[si] * g * rg
                                }
                            }
                        }
                    }
                }
            }
        }
        return Mix(left: L, right: R)
    }
}

// MARK: - 재생

final class Playback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var origin: Double = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: AudioIO.format)
    }

    func play(_ buf: AVAudioPCMBuffer, from t: Double) throws {
        node.stop()
        if !engine.isRunning { try engine.start() }
        node.scheduleBuffer(buf, at: nil, options: [])
        origin = t
        node.play()
    }

    var time: Double? {
        guard node.isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return nil }
        return origin + Double(pt.sampleTime) / pt.sampleRate
    }

    func stop() { node.stop() }
}

// MARK: - 녹음 (마이크 → caf 파일)

final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = SR
    private let lock = NSLock()

    var elapsed: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / rate
    }

    func start(_ url: URL) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw AudioError.unreadable }
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        lock.lock(); file = f; frames = 0; rate = fmt.sampleRate; lock.unlock()
        self.url = url
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            try? self.file?.write(from: buf)
            self.frames += AVAudioFramePosition(buf.frameLength)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); file = nil; let n = frames; lock.unlock()
        defer { url = nil }
        return n > 0 ? url : nil
    }
}
