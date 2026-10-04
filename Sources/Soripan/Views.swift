import SwiftUI

let laneH: CGFloat = 104
let rulerH: CGFloat = 30
let headerW: CGFloat = 232
let spacerH: CGFloat = 56

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Palette {
    static let pink = Color(hex: 0xFF2E93)
    static let orange = Color(hex: 0xFF8A00)
    static let yellow = Color(hex: 0xFFD200)
    static let purple = Color(hex: 0x7B2FF7)
    static let cyan = Color(hex: 0x00C6FF)
    static let ink = Color(hex: 0x2A1250)
    static let red = Color(hex: 0xF0243F)
    static let bg = Color(hex: 0xF7F3FF)
    static let muted = Color(hex: 0x6B5A8A)

    static let tracks: [(Color, Color)] = [
        (pink, orange),
        (purple, cyan),
        (Color(hex: 0x0FBF6B), Color(hex: 0x9BE15D)),
        (orange, yellow),
        (Color(hex: 0x3A7BD5), Color(hex: 0x00D2FF)),
        (Color(hex: 0xF953C6), Color(hex: 0xB91D73)),
    ]
    static func track(_ i: Int) -> (Color, Color) { tracks[i % tracks.count] }
}

func fmtTime(_ t: Double) -> String {
    let t = max(0, t)
    let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 100)
    return String(format: "%02d:%02d.%02d", m, s, cs)
}

func dB(_ g: Float) -> Double { g <= 0.0001 ? -60 : Double(20 * log10(g)) }
func gain(fromDB d: Double) -> Float { Float(pow(10, d / 20)) }

// MARK: - 전체 화면

struct ContentView: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            TimelineArea()
            InspectorBar()
        }
        .background(Palette.bg)
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 72) }
        .background(WindowCloseGuard(title: ed.projectName, dirty: ed.isDirty, url: ed.projectURL))
    }
}

/// 빨간 닫기 버튼/⌘W 때 저장 확인. SwiftUI의 윈도우 delegate는 그대로 두고 앞에 끼워 넣음
/// 제목/편집됨 점/프록시 아이콘도 여기서 네이티브 창에 직접 반영
struct WindowCloseGuard: NSViewRepresentable {
    let title: String
    let dirty: Bool
    let url: URL?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let coord = context.coordinator
        coord.latest = self
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if !(w.delegate is CloseGuardDelegate) {
                let proxy = CloseGuardDelegate(original: w.delegate)
                coord.proxy = proxy
                w.delegate = proxy
            }
            // 비동기로 늦게 실행되므로 그 사이 바뀐 최신 값으로 적용
            coord.latest?.apply(w)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.latest = self
        if let w = nsView.window { apply(w) }
    }
    fileprivate func apply(_ w: NSWindow) {
        w.title = title
        w.subtitle = dirty ? "편집됨" : ""
        w.isDocumentEdited = dirty
        w.representedURL = url
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var proxy: CloseGuardDelegate?
        var latest: WindowCloseGuard?
    }
}

final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    init(original: NSWindowDelegate?) { self.original = original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let ok = MainActor.assumeIsolated { Editor.current?.confirmDiscard() ?? true }
        if ok { MainActor.assumeIsolated { Editor.current?.closing = true } }
        return ok
    }

    override func responds(to sel: Selector!) -> Bool {
        super.responds(to: sel) || (original?.responds(to: sel) ?? false)
    }

    override func forwardingTarget(for sel: Selector!) -> Any? {
        original?.responds(to: sel) == true ? original : nil
    }
}


struct ToastView: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        if let t = ed.toast {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(LinearGradient(colors: [Palette.purple, Palette.cyan], startPoint: .leading, endPoint: .trailing)))
                .shadow(color: Palette.purple.opacity(0.35), radius: 10, y: 4)
                .transition(.opacity)
        }
    }
}

// MARK: - 상단 바

struct TopBar: View {
    @Environment(Editor.self) private var ed

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: -2) {
                Text("SORIPAN")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Palette.purple.opacity(0.55), radius: 0, x: 0, y: 2)
                Text("AUDIO EDITOR")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .fixedSize()

            HStack(spacing: 6) {
                RoundButton(icon: "backward.end.fill", help: "처음으로 (Home)") { ed.seek(0) }
                RoundButton(icon: ed.isPlaying && !ed.isRecording ? "pause.fill" : "play.fill", help: "재생/일시정지 (Space)", big: true) { ed.togglePlay() }
                RoundButton(icon: "stop.fill", help: "정지") { ed.stop() }
                RoundButton(icon: "record.circle", help: "녹음 (R)", tint: Palette.red, active: ed.isRecording) { ed.toggleRecord() }
            }

            TimeDisplay()

            Spacer(minLength: 8)

            if ed.loading > 0 { ProgressView().controlSize(.small) }

            HStack(spacing: 4) {
                ToolButton(icon: "arrow.uturn.backward", help: "실행 취소 (⌘Z)") { ed.undo() }.disabled(!ed.canUndo)
                ToolButton(icon: "arrow.uturn.forward", help: "다시 실행 (⇧⌘Z)") { ed.redo() }.disabled(!ed.canRedo)
                ToolButton(icon: "scissors", help: "재생헤드에서 자르기 (S)") { ed.split() }
            }

            ZoomControl()

            PillButton(title: "가져오기", icon: "square.and.arrow.down") { ed.importDialog() }
            Menu {
                Button("WAV로 내보내기") { ed.export(m4a: false) }
                Button("M4A로 내보내기") { ed.export(m4a: true) }
            } label: {
                Label("내보내기", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(Palette.ink)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(LinearGradient(colors: [Palette.pink, Palette.orange, Palette.yellow], startPoint: .leading, endPoint: .trailing))
    }
}

struct RoundButton: View {
    let icon: String
    let help: String
    var big = false
    var tint: Color = Palette.purple
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 17 : 13, weight: .bold))
                .foregroundStyle(active ? .white : tint)
                .frame(width: big ? 42 : 34, height: big ? 42 : 34)
                .background(Circle().fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(.white)))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ToolButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(enabled ? 0.9 : 0.45)))
                .foregroundStyle(Palette.ink.opacity(enabled ? 1 : 0.4))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white))
                .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

struct TimeDisplay: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        HStack(spacing: 6) {
            if ed.isRecording {
                Circle().fill(Palette.red).frame(width: 8, height: 8)
                Text("REC").font(.system(size: 11, weight: .heavy)).foregroundStyle(Palette.red)
            }
            Text(fmtTime(ed.playhead))
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white))
        .fixedSize()
    }
}

struct ZoomControl: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        HStack(spacing: 4) {
            Button { ed.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain)
            GradientSlider(value: Binding(get: { log(ed.pxPerSec) }, set: { ed.pxPerSec = exp($0) }),
                           range: log(4.0)...log(2000.0), colors: [Palette.purple, Palette.cyan])
                .frame(width: 90)
            Button { ed.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.9)))
        .help("확대/축소 (⌘= / ⌘-)")
    }
}

// MARK: - 타임라인

struct TimelineArea: View {
    @Environment(Editor.self) private var ed

    var body: some View {
        let width = ed.contentWidth
        GeometryReader { geo in
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Text("트랙")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                        .frame(height: rulerH)
                        .overlay(alignment: .bottom) { Divider() }
                    ForEach(ed.state.tracks) { t in TrackHeader(track: t) }
                    Button { ed.addTrack() } label: {
                        Label("트랙 추가", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(LinearGradient(colors: [Palette.purple, Palette.cyan], startPoint: .leading, endPoint: .trailing)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(height: spacerH)
                    .help("새 트랙 (⌘T)")
                    Color.white.frame(maxHeight: .infinity)
                }
                .frame(width: headerW)
                .background(.white)

                Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        RulerView(width: width).frame(height: rulerH)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(Array(ed.state.tracks.enumerated()), id: \.element.id) { i, t in
                                    LaneBackground(index: i, track: t)
                                }
                            }
                            ClipsLayer()
                            RecordingRegion()
                        }
                        .coordinateSpace(name: "lanes")
                        DropSpacer()
                        // 트랙 아래 빈 공간도 끌어서 스크롤
                        Color.clear
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .modifier(PanToScroll())
                    }
                    .frame(width: width, alignment: .leading)
                    .overlay(alignment: .topLeading) { PlayheadLine() }
                    .background(ScrollerAnchor())
                }
            }
            .frame(minHeight: geo.size.height, alignment: .top)
        }
        }
        .background(Palette.bg)
    }
}

struct RulerView: View {
    @Environment(Editor.self) private var ed
    let width: CGFloat

    static func step(_ pps: Double) -> Double {
        for c in [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600] where c * pps >= 80 { return c }
        return 1200
    }

    var body: some View {
        let pps = ed.pxPerSec
        let step = Self.step(pps)
        let tile: CGFloat = 1024
        let n = max(1, Int(ceil(width / tile)))
        LazyHStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                Canvas { ctx, size in
                    let x0 = CGFloat(i) * tile
                    let minor = step / 5
                    // 앞 조각에서 넘어온 라벨도 이어서 그리려고 60px 앞에서 시작
                    var k = max(0, Int(floor(Double(x0 - 60) / pps / minor)))
                    while true {
                        let t = Double(k) * minor
                        let x = CGFloat(t * pps) - x0
                        if x > size.width { break }
                        let major = k % 5 == 0
                        if x >= 0 || major {
                            let h: CGFloat = major ? 12 : 5
                            if x >= 0 { ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                                     with: .color(Palette.ink.opacity(major ? 0.5 : 0.25))) }
                            if major {
                                let m = Int(t) / 60, s = t - Double(m * 60)
                                let label = step < 1 ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s))
                                ctx.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.ink.opacity(0.6)),
                                         at: CGPoint(x: x + 4, y: 9), anchor: .leading)
                            }
                        }
                        k += 1
                    }
                }
                .frame(width: tile, height: rulerH)
            }
        }
        .frame(width: width, height: rulerH, alignment: .leading)
        .clipped()
        .background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1) }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in ed.scrub(v.location.x / pps) }
                .onEnded { v in ed.seek(v.location.x / pps) }
        )
        .help("클릭해서 재생 위치 이동")
    }
}

struct PlayheadLine: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        let x = CGFloat(ed.playhead * ed.pxPerSec)
        ZStack(alignment: .top) {
            Rectangle().fill(Palette.red).frame(width: 2)
            Triangle().fill(Palette.red).frame(width: 14, height: 10)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .offset(x: x - 7)
        .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct LaneBackground: View {
    @Environment(Editor.self) private var ed
    let index: Int
    let track: Track

    var body: some View {
        let selected = ed.selectedTrackID == track.id
        let c = Palette.track(track.colorIndex).0
        Rectangle()
            .fill(selected ? c.opacity(0.07) : (index % 2 == 0 ? Color.white.opacity(0.6) : Color.white.opacity(0.25)))
            .frame(height: laneH)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
            .opacity(track.mute ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture { loc in
                ed.selectTrack(track.id)
                ed.selectedClipID = nil
                ed.seek(loc.x / ed.pxPerSec)
            }
            .modifier(PanToScroll())
            .dropDestination(for: URL.self) { urls, loc in
                ed.importFiles(urls, trackIndex: index, at: loc.x / ed.pxPerSec)
                return true
            }
    }
}

struct DropSpacer: View {
    @Environment(Editor.self) private var ed
    @State private var targeted = false
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Palette.purple.opacity(targeted ? 0.8 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.purple.opacity(targeted ? 0.08 : 0)))
            .overlay(alignment: .leading) {
                Text("오디오 파일을 여기로 끌어오면 새 트랙에 들어갑니다")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.purple.opacity(0.6))
                    .padding(.leading, 14)
                    .fixedSize()
            }
            .padding(8)
            .frame(height: spacerH)
            .contentShape(Rectangle())
            .modifier(PanToScroll())
            .dropDestination(for: URL.self) { urls, loc in
                ed.importFiles(urls, trackIndex: ed.state.tracks.count, at: loc.x / ed.pxPerSec)
                return true
            } isTargeted: { targeted = $0 }
    }
}

struct RecordingRegion: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        if ed.isRecording, let ti = ed.state.tracks.firstIndex(where: { $0.id == ed.recordTrackID }) {
            let w = max(2, CGFloat((ed.playhead - ed.recordStart) * ed.pxPerSec))
            RoundedRectangle(cornerRadius: 7)
                .fill(Palette.red.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.red, lineWidth: 2))
                .overlay(alignment: .topLeading) {
                    Text("녹음 중").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.red).padding(6).fixedSize()
                }
                .frame(width: w, height: laneH - 8)
                .offset(x: CGFloat(ed.recordStart * ed.pxPerSec), y: CGFloat(ti) * laneH + 4)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 클립

/// 모든 트랙의 클립을 한 레이어에 그려야 트랙 사이로 끌어도 뷰가 유지되어 드래그가 끊기지 않음
struct ClipsLayer: View {
    @Environment(Editor.self) private var ed
    var body: some View {
        let items = ed.state.tracks.enumerated().flatMap { ti, t in t.clips.map { (clip: $0, ti: ti, color: t.colorIndex) } }
        ForEach(items, id: \.clip.id) { item in
            ClipView(clip: item.clip, trackIndex: item.ti, colorIndex: item.color)
        }
    }
}

struct ClipView: View {
    @Environment(Editor.self) private var ed
    let clip: Clip
    let trackIndex: Int
    let colorIndex: Int

    @State private var origin: Clip?
    @State private var moved = false

    var body: some View {
        let pps = ed.pxPerSec
        let w = max(3, CGFloat(clip.length * pps))
        let h = laneH - 8
        let selected = ed.selectedClipID == clip.id
        let (c1, c2) = Palette.track(colorIndex)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let src = ed.sources[clip.sourceID] {
                WaveformView(source: src, offset: clip.offset, length: clip.length, speed: clip.speed, gain: clip.gain, pps: pps)
                    .frame(width: w, height: h - 22)
                    .offset(y: 19)
            }
            if clip.fadeIn > 0 {
                FadeShape(isIn: true)
                    .fill(Color.black.opacity(0.22))
                    .frame(width: CGFloat(clip.fadeIn * pps), height: h)
            }
            if clip.fadeOut > 0 {
                FadeShape(isIn: false)
                    .fill(Color.black.opacity(0.22))
                    .frame(width: CGFloat(clip.fadeOut * pps), height: h)
                    .frame(width: w, height: h, alignment: .trailing)
            }
            Text(clip.name + badge)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                .lineLimit(1)
                .padding(.leading, 16).padding(.trailing, 16).padding(.top, 3)
                .frame(width: w, alignment: .leading)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.35), lineWidth: selected ? 3 : 1)
        )
        .shadow(color: selected ? c1.opacity(0.55) : .black.opacity(0.12), radius: selected ? 8 : 2, y: 1)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .overlay(alignment: .leading) { edgeHandle(left: true) }
        .overlay(alignment: .trailing) { edgeHandle(left: false) }
        .overlay(alignment: .topLeading) {
            fadeHandle(isIn: true).offset(x: min(max(0, CGFloat(clip.fadeIn * pps) - 6), w - 12), y: 2)
        }
        .overlay(alignment: .topTrailing) {
            fadeHandle(isIn: false).offset(x: -min(max(0, CGFloat(clip.fadeOut * pps) - 6), w - 12), y: 2)
        }
        .contextMenu {
            Button("재생헤드에서 자르기") { ed.selectClip(clip.id); ed.split() }
            Button("복제") { ed.selectClip(clip.id); ed.duplicateSelected() }
            Button("노멀라이즈") { ed.selectClip(clip.id); ed.normalizeSelected() }
            Button("피치/배속 초기화") { ed.selectClip(clip.id); ed.resetPitchSpeed() }
            Divider()
            Button("삭제") { ed.selectClip(clip.id); ed.deleteSelected() }
        }
        .offset(x: CGFloat(clip.start * pps), y: CGFloat(trackIndex) * laneH + 4)
    }

    private var badge: String {
        var parts: [String] = []
        if clip.speed != 1 { parts.append(String(format: "x%.2f", clip.speed)) }
        if clip.pitch != 0 { parts.append(String(format: "%+d반음", Int(clip.pitch))) }
        return parts.isEmpty ? "" : "   " + parts.joined(separator: " ")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("lanes"))
            .onChanged { v in
                if origin == nil {
                    origin = clip
                    moved = false
                    ed.selectClip(clip.id)
                }
                if !moved && abs(v.translation.width) < 3 && abs(v.translation.height) < 3 { return }
                if !moved { moved = true; ed.beginEdit() }
                guard let o = origin else { return }
                ed.moveClip(clip.id, origin: o, dx: v.translation.width, toTrack: Int(floor(v.location.y / laneH)))
            }
            .onEnded { v in
                if moved { ed.endEdit() } else { ed.seek(v.location.x / ed.pxPerSec) }
                origin = nil
                moved = false
            }
    }

    private func edgeHandle(left: Bool) -> some View {
        EdgeHandle()
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes"))
                    .onChanged { v in
                        if origin == nil { origin = clip; ed.selectClip(clip.id); ed.beginEdit() }
                        guard let o = origin else { return }
                        if left { ed.trimLeft(clip.id, origin: o, dx: v.translation.width) }
                        else { ed.trimRight(clip.id, origin: o, dx: v.translation.width) }
                    }
                    .onEnded { _ in origin = nil; ed.endEdit() }
            )
            .help("끌어서 길이 조절")
    }

    private func fadeHandle(isIn: Bool) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1))
            .frame(width: 12, height: 12)
            .contentShape(Circle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes"))
                    .onChanged { v in
                        if origin == nil { origin = clip; ed.selectClip(clip.id); ed.beginEdit() }
                        guard let o = origin else { return }
                        ed.setFade(clip.id, origin: o, dx: v.translation.width, isIn: isIn)
                    }
                    .onEnded { _ in origin = nil; ed.endEdit() }
            )
            .help(isIn ? "끌어서 페이드 인" : "끌어서 페이드 아웃")
    }
}

struct EdgeHandle: View {
    @State private var hover = false
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(hover ? 0.55 : 0.001))
            .frame(width: 7)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

struct FadeShape: Shape {
    var isIn: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if isIn {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: r.maxX, y: 0))
            p.addLine(to: CGPoint(x: 0, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.maxX, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// 긴 클립도 텍스처 한계를 넘지 않게 1024px 조각으로 나눠 그림
struct WaveformView: View {
    let source: AudioSource
    let offset: Double
    let length: Double
    let speed: Double
    let gain: Float
    let pps: Double

    var body: some View {
        let w = CGFloat(length * pps)
        let tile: CGFloat = 1024
        let n = max(1, Int(ceil(w / tile)))
        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                let x0 = CGFloat(i) * tile
                Canvas { ctx, size in draw(ctx, size, x0) }
                    .frame(width: max(0, min(tile, w - x0)))
            }
        }
        .frame(width: w, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ x0: CGFloat) {
        let peaks = source.peaks
        let bps = SR / Double(peakBlock)
        let mid = size.height / 2
        var path = Path()
        var x: CGFloat = 0
        while x < size.width {
            let t0 = offset + Double(x0 + x) / pps * speed
            let t1 = t0 + speed / pps
            let p0 = max(0, Int(t0 * bps))
            let p1 = min(peaks.count, max(p0 + 1, Int(t1 * bps)))
            var m: Float = 0
            if p0 < p1 { for k in p0..<p1 { m = max(m, peaks[k]) } }
            let a = CGFloat(min(1, m * gain)) * mid
            path.addRect(CGRect(x: x, y: mid - a, width: 1, height: max(1, a * 2)))
            x += 1
        }
        ctx.fill(path, with: .color(.white.opacity(0.88)))
    }
}

// MARK: - 트랙 헤더

struct TrackHeader: View {
    @Environment(Editor.self) private var ed
    let track: Track

    var body: some View {
        let (c1, c2) = Palette.track(track.colorIndex)
        let selected = ed.selectedTrackID == track.id
        HStack(spacing: 0) {
            LinearGradient(colors: [c1, c2], startPoint: .top, endPoint: .bottom).frame(width: 6)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text(track.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ToggleChip(label: "M", on: track.mute, color: Palette.orange, help: "음소거") { ed.toggleMute(track.id) }
                    ToggleChip(label: "S", on: track.solo, color: Palette.purple, help: "솔로") { ed.toggleSolo(track.id) }
                    Button { ed.deleteTrack(track.id) } label: {
                        Image(systemName: "trash").font(.system(size: 11)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .help("트랙 삭제")
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(Palette.muted).frame(width: 16)
                    GradientSlider(value: Binding(
                        get: { max(-40, dB(track.volume)) },
                        set: { v in ed.liveTrack(track.id) { $0.volume = v <= -40 ? 0 : gain(fromDB: v) } }
                    ), range: -40...6, colors: [c1, c2], resetTo: 0) { editing in editing ? ed.beginEdit() : ed.endEdit() }
                    Text(track.volume <= 0 ? "-inf" : String(format: "%+.1f", dB(track.volume)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 38, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text("L R").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted).frame(width: 16)
                    GradientSlider(value: Binding(
                        get: { Double(track.pan) },
                        set: { v in ed.liveTrack(track.id) { $0.pan = abs(v) < 0.04 ? 0 : Float(v) } }
                    ), range: -1...1, colors: [c2, c1], center: true, resetTo: 0) { editing in editing ? ed.beginEdit() : ed.endEdit() }
                    Text(track.pan == 0 ? "C" : (track.pan < 0 ? "L\(Int(-track.pan * 100))" : "R\(Int(track.pan * 100))"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: laneH)
        .background(selected ? c1.opacity(0.09) : Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { ed.selectTrack(track.id) }
    }
}

struct ToggleChip: View {
    let label: String
    let on: Bool
    let color: Color
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? color : Color.black.opacity(0.06)))
                .foregroundStyle(on ? .white : Palette.muted)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 하단 인스펙터

struct InspectorBar: View {
    @Environment(Editor.self) private var ed

    var body: some View {
        HStack(spacing: 16) {
            if let c = ed.selectedClip {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text("\(fmtTime(c.start)) ~ \(fmtTime(c.end)) · \(String(format: "%.2f", c.length))초")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(width: 170, alignment: .leading)

                InspectorSlider(title: "게인", value: dB(c.gain), range: -24...12, text: String(format: "%+.1f dB", dB(c.gain)), resetTo: 0) { v in
                    ed.liveClip(c.id) { $0.gain = gain(fromDB: v) }
                }
                InspectorSlider(title: "피치", value: c.pitch, range: -12...12, text: c.pitch == 0 ? "원래 음" : String(format: "%+d 반음", Int(c.pitch)), resetTo: 0) { v in
                    ed.setPitch(c.id, v)
                }
                InspectorSlider(title: "배속", value: c.speed, range: 0.5...2, text: String(format: "x%.2f", c.speed), resetTo: 1) { v in
                    ed.setSpeed(c.id, v)
                }
                InspectorSlider(title: "페이드 인", value: c.fadeIn, range: 0...max(0.01, min(10, c.length - c.fadeOut)), text: String(format: "%.2fs", c.fadeIn)) { v in
                    ed.liveClip(c.id) { $0.fadeIn = v }
                }
                InspectorSlider(title: "페이드 아웃", value: c.fadeOut, range: 0...max(0.01, min(10, c.length - c.fadeIn)), text: String(format: "%.2fs", c.fadeOut)) { v in
                    ed.liveClip(c.id) { $0.fadeOut = v }
                }
                Spacer(minLength: 0)
                PillButton(title: "노멀라이즈", icon: "waveform.path.ecg") { ed.normalizeSelected() }
                PillButton(title: "삭제", icon: "trash") { ed.deleteSelected() }
            } else {
                Text("오디오 파일을 타임라인에 끌어다 놓거나 가져오기(⌘I)   ·   Space 재생   ·   S 자르기   ·   Delete 삭제   ·   R 녹음   ·   ⌘Z 실행 취소")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1) }
    }
}

struct InspectorSlider: View {
    @Environment(Editor.self) private var ed
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    var resetTo: Double? = nil
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                Spacer()
                Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink)
            }
            GradientSlider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: set),
                           range: range, colors: [Palette.pink, Palette.orange], resetTo: resetTo) { editing in
                editing ? ed.beginEdit() : ed.endEdit()
            }
        }
        .frame(width: 118)
    }
}

/// 시스템 슬라이더는 밝은 배경에서 트랙이 안 보여서 직접 그림. 더블클릭하면 resetTo 값으로
struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var colors: [Color]
    var center = false
    var resetTo: Double? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let knob: CGFloat = 14
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
            let x = frac * (w - knob) + knob / 2
            let mid = w / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.12)).frame(height: 5)
                if center {
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: abs(x - mid), height: 5)
                        .clipShape(Capsule())
                        .offset(x: min(x, mid))
                } else {
                    LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(0, x), height: 5)
                        .clipShape(Capsule())
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(colors[0], lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(dragging ? 0.3 : 0.15), radius: dragging ? 3 : 1.5, y: 1)
                    .scaleEffect(dragging ? 1.15 : 1)
                    .offset(x: x - knob / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        let f = min(max((v.location.x - knob / 2) / max(1, w - knob), 0), 1)
                        value = range.lowerBound + Double(f) * span
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let r = resetTo else { return }
                onEditingChanged(true); value = r; onEditingChanged(false)
            })
        }
        .frame(height: 16)
    }
}

// MARK: - 스크롤 제어 (SwiftUI ScrollView 밑의 NSScrollView를 직접 움직임)

@MainActor
final class Scroller {
    static let shared = Scroller()
    weak var h: NSScrollView?   // 타임라인 가로 스크롤
    weak var v: NSScrollView?   // 트랙 세로 스크롤

    var origin: CGPoint {
        CGPoint(x: h?.contentView.bounds.minX ?? 0, y: v?.contentView.bounds.minY ?? 0)
    }

    private func set(_ sv: NSScrollView?, x: CGFloat? = nil, y: CGFloat? = nil) {
        guard let sv, let doc = sv.documentView else { return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        if let x { o.x = min(max(0, x), max(0, doc.frame.width - clip.bounds.width)) }
        if let y { o.y = min(max(0, y), max(0, doc.frame.height - clip.bounds.height)) }
        guard o != clip.bounds.origin else { return }
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
    }

    /// 손바닥 도구: 마우스가 움직인 만큼 화면을 반대로
    func pan(from s: CGPoint, dx: CGFloat, dy: CGFloat) {
        set(h, x: s.x - dx)
        let flipped = v?.documentView?.isFlipped ?? true
        set(v, y: flipped ? s.y - dy : s.y + dy)
    }

    /// 재생 중: 재생헤드가 화면 오른쪽 끝에 닿으면 한 페이지 넘김 (베가스 방식)
    func follow(_ x: CGFloat) {
        guard let h else { return }
        let b = h.contentView.bounds
        if x > b.maxX - 40 || x < b.minX { set(h, x: x - 40) }
    }

    /// 정지/처음으로 등으로 재생헤드가 화면 밖이면 보이게
    func reveal(_ x: CGFloat) {
        guard let h else { return }
        let b = h.contentView.bounds
        if x < b.minX || x > b.maxX - 20 { set(h, x: x - b.width * 0.2) }
    }
}

struct ScrollerAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { attach(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if Scroller.shared.h == nil { attach(nsView) }
    }
    private func attach(_ v: NSView) {
        guard let h = v.enclosingScrollView else { return }
        Scroller.shared.h = h
        Scroller.shared.v = h.superview?.enclosingScrollView
    }
}

/// 빈 곳을 끌면 스크롤. 좌표는 global 기준이어야 화면이 움직여도 떨리지 않음
struct PanToScroll: ViewModifier {
    @State private var start: CGPoint?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil {
                        start = Scroller.shared.origin
                        NSCursor.closedHand.push()
                    }
                    if let s = start { Scroller.shared.pan(from: s, dx: v.translation.width, dy: v.translation.height) }
                }
                .onEnded { _ in
                    if start != nil { NSCursor.pop() }
                    start = nil
                }
        )
    }
}
