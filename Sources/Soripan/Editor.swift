import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Editor {
    var state = ProjectState()
    var sources: [UUID: AudioSource] = [:]
    var selectedClipID: UUID?
    var selectedTrackID: UUID?
    var playhead: Double = 0
    var isPlaying = false
    var isRecording = false
    var recordStart: Double = 0
    var recordTrackID: UUID?
    var pxPerSec: Double = 60
    var toast: String?
    var loading = 0
    var canUndo = false
    var canRedo = false
    var projectURL: URL?
    var savedState = ProjectState()

    var isDirty: Bool { state != savedState }
    var projectName: String { projectURL?.deletingPathExtension().lastPathComponent ?? "제목 없음" }

    /// App 구조체가 여러 번 init 돼도 편집기는 하나만 존재하도록
    static let shared = Editor()
    static var current: Editor? { shared }
    @ObservationIgnored var closing = false

    @ObservationIgnored private var undoStack: [ProjectState] = []
    @ObservationIgnored private var redoStack: [ProjectState] = []
    @ObservationIgnored private var snapshot: ProjectState?
    @ObservationIgnored private let playback = Playback()
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playOrigin: Double = 0
    @ObservationIgnored private var trackCounter = 0
    @ObservationIgnored private var toastToken = 0

    private init() {
        for _ in 0..<3 { state.tracks.append(makeTrack()) }
        selectedTrackID = state.tracks.first?.id
        savedState = state
        // `Soripan.app/Contents/MacOS/Soripan a.wav b.mp3` 또는 `... x.soripan` 처럼 실행하면 바로 불러옴
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
        if let proj = args.first(where: { $0.pathExtension == ProjectFile.ext }) {
            loadProject(proj)
        } else if !args.isEmpty {
            importFiles(args, trackIndex: 0, at: 0)
        }
    }

    // MARK: 프로젝트 저장 / 불러오기

    static var projectType: UTType {
        UTType("com.wqrvq2wr.soripan.project") ?? UTType(filenameExtension: ProjectFile.ext, conformingTo: .json) ?? .json
    }

    /// 저장 안 된 변경이 있으면 물어봄. true면 계속 진행
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "'\(projectName)'의 변경 사항을 저장할까요?"
        a.informativeText = "저장하지 않으면 변경 사항이 사라집니다."
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "취소")
        a.addButton(withTitle: "저장 안 함")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = projectURL else { return saveAs() }
        return write(to: url)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "프로젝트 저장"
        panel.allowedContentTypes = [Editor.projectType]
        panel.nameFieldStringValue = projectName + "." + ProjectFile.ext
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        let used = Set(state.tracks.flatMap(\.clips).map(\.sourceID))
        let refs = used.compactMap { id -> ProjectFile.SourceRef? in
            guard let s = sources[id] else { return nil }
            return .init(id: id, path: s.url.path, relative: ProjectFile.relativePath(of: s.url, from: dir))
        }
        let file = ProjectFile(pxPerSec: pxPerSec, sources: refs.sorted { $0.path < $1.path }, tracks: state.tracks)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(file).write(to: url, options: .atomic)
            projectURL = url
            savedState = state
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            flash("저장됨: \(url.lastPathComponent)")
            return true
        } catch {
            flash("저장 실패: \(error.localizedDescription)")
            return false
        }
    }

    func openDialog() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.title = "프로젝트 열기"
        panel.allowedContentTypes = [Editor.projectType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadProject(url)
    }

    func openFromFinder(_ url: URL) {
        guard url != projectURL, confirmDiscard() else { return }
        loadProject(url)
    }

    func newProject() {
        guard confirmDiscard() else { return }
        resetSession()
        trackCounter = 0
        state = ProjectState(tracks: (0..<3).map { _ in makeTrack() })
        savedState = state
        projectURL = nil
        selectedTrackID = state.tracks.first?.id
    }

    private func resetSession() {
        if isRecording { _ = recorder.stop(); isRecording = false }
        pause()
        stopTimer()
        undoStack.removeAll()
        redoStack.removeAll()
        syncUndo()
        snapshot = nil
        selectedClipID = nil
        playhead = 0
    }

    func loadProject(_ url: URL) {
        let file: ProjectFile
        do {
            file = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
        } catch {
            flash("프로젝트를 열 수 없음: \(url.lastPathComponent)")
            return
        }
        resetSession()
        let dir = url.deletingLastPathComponent()
        var found: [(UUID, URL)] = []
        var missing: [String] = []
        for ref in file.sources {
            if let u = file.resolve(ref, projectDir: dir) { found.append((ref.id, u)) }
            else { missing.append(URL(fileURLWithPath: ref.path).lastPathComponent) }
        }
        sources = [:]
        state = ProjectState(tracks: file.tracks)
        savedState = state
        projectURL = url
        pxPerSec = min(max(file.pxPerSec, 4), 2000)
        trackCounter = file.tracks.compactMap { Int($0.name.replacingOccurrences(of: "트랙 ", with: "")) }.max() ?? file.tracks.count
        selectedTrackID = state.tracks.first?.id
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if !missing.isEmpty { flash("못 찾은 오디오 \(missing.count)개: \(missing.prefix(3).joined(separator: ", "))") }

        loading += 1
        Task {
            for (id, u) in found {
                if let d = try? await Task.detached(operation: { try AudioIO.decode(u) }).value {
                    sources[id] = AudioSource(id: id, url: u, decoded: d)
                }
            }
            loading -= 1
            prewarmVariants()
        }
    }

    var contentWidth: CGFloat { CGFloat(max(state.end + 60, 120) * pxPerSec) }

    var selectedClip: Clip? {
        guard let id = selectedClipID, let (ti, ci) = locate(id) else { return nil }
        return state.tracks[ti].clips[ci]
    }

    func locate(_ id: UUID) -> (Int, Int)? {
        for (ti, t) in state.tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    func flash(_ msg: String) {
        toast = msg
        toastToken += 1
        let token = toastToken
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if token == toastToken { toast = nil }
        }
    }

    // MARK: 실행 취소

    private func pushUndo(_ s: ProjectState) {
        undoStack.append(s)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndo()
    }

    private func syncUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// 한 번에 끝나는 편집
    func commit(_ f: (inout ProjectState) -> Void) {
        let before = state
        f(&state)
        guard state != before else { return }
        pushUndo(before)
        changed()
    }

    /// 드래그/슬라이더처럼 여러 번 바뀌는 편집은 begin~end 사이를 한 단계로 묶음
    func beginEdit() { if snapshot == nil { snapshot = state } }

    func endEdit() {
        guard let s = snapshot else { return }
        snapshot = nil
        if s != state { pushUndo(s); changed() }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(state)
        state = s
        fixSelection()
        syncUndo()
        changed()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(state)
        state = s
        fixSelection()
        syncUndo()
        changed()
    }

    private func fixSelection() {
        if let id = selectedClipID, locate(id) == nil { selectedClipID = nil }
        if let id = selectedTrackID, !state.tracks.contains(where: { $0.id == id }) {
            selectedTrackID = state.tracks.first?.id
        }
    }

    /// 재생 중에 편집하면 바뀐 믹스로 바로 다시 재생
    private func changed() {
        if isPlaying && !isRecording {
            playback.stop()
            startPlayback(from: playhead)
        } else {
            prewarmVariants()
        }
    }

    // MARK: 피치 / 배속 처리본

    private func missingVariants() -> [(AudioSource, Double, Double)] {
        var seen = Set<String>()
        var out: [(AudioSource, Double, Double)] = []
        for t in state.tracks {
            for c in t.clips where c.isProcessed {
                guard let src = sources[c.sourceID], src.variant(c.variantKey) == nil else { continue }
                if seen.insert("\(src.id)\(c.variantKey)").inserted { out.append((src, c.pitch, c.speed)) }
            }
        }
        return out
    }

    /// 재생/내보내기 직전: 없는 처리본은 바로 만듦
    private func ensureVariants() {
        for (src, p, sp) in missingVariants() {
            if let m = try? AudioIO.timePitch(src, pitch: p, speed: sp) {
                src.setVariant(AudioSource.key(pitch: p, speed: sp), m)
            }
        }
    }

    /// 편집 직후: 백그라운드에서 미리 만들어 둠
    private func prewarmVariants() {
        let jobs = missingVariants()
        guard !jobs.isEmpty else { return }
        loading += 1
        Task {
            for (src, p, sp) in jobs {
                let m = try? await Task.detached { try AudioIO.timePitch(src, pitch: p, speed: sp) }.value
                if let m { src.setVariant(AudioSource.key(pitch: p, speed: sp), m) }
            }
            loading -= 1
        }
    }

    /// 배속을 바꿔도 원본 구간은 그대로, 타임라인 길이만 늘었다 줄었다
    func setSpeed(_ id: UUID, _ v: Double) {
        let v = min(max((v * 20).rounded() / 20, 0.5), 2)
        liveClip(id) { c in
            let r = c.speed / v
            c.length *= r
            c.fadeIn *= r
            c.fadeOut *= r
            c.speed = v
        }
    }

    func setPitch(_ id: UUID, _ v: Double) {
        liveClip(id) { $0.pitch = min(max(v.rounded(), -12), 12) }
    }

    func resetPitchSpeed() {
        guard let c = selectedClip else { return }
        beginEdit()
        setSpeed(c.id, 1)
        setPitch(c.id, 0)
        endEdit()
    }

    // MARK: 트랙

    private func makeTrack() -> Track {
        trackCounter += 1
        return Track(name: "트랙 \(trackCounter)", colorIndex: (trackCounter - 1) % paletteCount)
    }

    func addTrack() {
        let t = makeTrack()
        commit { $0.tracks.append(t) }
        selectedTrackID = t.id
    }

    func deleteTrack(_ id: UUID) {
        commit { $0.tracks.removeAll { $0.id == id } }
        fixSelection()
    }

    func selectTrack(_ id: UUID) { selectedTrackID = id }

    func toggleMute(_ id: UUID) {
        commit { s in if let i = s.tracks.firstIndex(where: { $0.id == id }) { s.tracks[i].mute.toggle() } }
    }

    func toggleSolo(_ id: UUID) {
        commit { s in if let i = s.tracks.firstIndex(where: { $0.id == id }) { s.tracks[i].solo.toggle() } }
    }

    /// beginEdit/endEdit 사이에서 쓰는 즉시 변경
    func liveTrack(_ id: UUID, _ f: (inout Track) -> Void) {
        if let i = state.tracks.firstIndex(where: { $0.id == id }) { f(&state.tracks[i]) }
    }

    func liveClip(_ id: UUID, _ f: (inout Clip) -> Void) {
        if let (ti, ci) = locate(id) { f(&state.tracks[ti].clips[ci]) }
    }

    // MARK: 가져오기 / 내보내기

    func importDialog() {
        let panel = NSOpenPanel()
        panel.title = "오디오 가져오기"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, trackIndex: nil, at: nil)
    }

    /// trackIndex == tracks.count 이면 새 트랙을 만들어서 넣음
    func importFiles(_ urls: [URL], trackIndex: Int?, at time: Double?) {
        if let proj = urls.first(where: { $0.pathExtension == ProjectFile.ext }) {
            openFromFinder(proj)
            return
        }
        let urls = urls.filter { !$0.hasDirectoryPath }
        guard !urls.isEmpty else { return }
        var tid: UUID?
        if let ti = trackIndex, ti < state.tracks.count {
            tid = state.tracks[ti].id
        } else if trackIndex == nil {
            tid = selectedTrackID ?? state.tracks.first?.id
        }
        load(urls, trackID: tid, at: max(0, time ?? playhead))
    }

    private func load(_ urls: [URL], trackID: UUID?, at time: Double) {
        loading += 1
        Task {
            var t = time
            var clips: [Clip] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let d = try await Task.detached { try AudioIO.decode(url) }.value
                    let src = AudioSource(url: url, decoded: d)
                    sources[src.id] = src
                    clips.append(Clip(sourceID: src.id, name: url.deletingPathExtension().lastPathComponent,
                                      start: t, offset: 0, length: src.duration))
                    t += src.duration
                } catch {
                    flash("못 읽는 파일: \(url.lastPathComponent)")
                }
            }
            loading -= 1
            guard !clips.isEmpty else { return }
            let newTrack = (trackID.flatMap { id in state.tracks.contains { $0.id == id } ? id : nil } == nil) ? makeTrack() : nil
            commit { s in
                if let nt = newTrack { s.tracks.append(nt) }
                let id = newTrack?.id ?? trackID!
                if let i = s.tracks.firstIndex(where: { $0.id == id }) { s.tracks[i].clips += clips }
            }
            selectedTrackID = newTrack?.id ?? trackID
            selectedClipID = clips.last?.id
        }
    }

    func export(m4a: Bool) {
        let end = state.end
        guard end > 0 else { flash("내보낼 클립이 없습니다"); return }
        let panel = NSSavePanel()
        panel.title = "믹스다운 내보내기"
        panel.allowedContentTypes = [m4a ? .mpeg4Audio : .wav]
        panel.nameFieldStringValue = "믹스다운." + (m4a ? "m4a" : "wav")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ensureVariants()
        let mix = Mixer.render(state, sources, from: 0, to: end)
        loading += 1
        Task {
            do {
                try await Task.detached { try AudioIO.write(mix, to: url, m4a: m4a) }.value
                flash("내보내기 완료: \(url.lastPathComponent)")
            } catch {
                flash("내보내기 실패: \(error.localizedDescription)")
            }
            loading -= 1
        }
    }

    // MARK: 재생

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying, !isRecording else { return }
        let end = state.end
        guard end > 0 else { flash("재생할 클립이 없습니다"); return }
        if playhead >= end - 0.01 { playhead = 0 }
        playOrigin = playhead
        startPlayback(from: playhead)
    }

    private func startPlayback(from t: Double) {
        ensureVariants()
        let end = state.end
        guard end > t, let buf = AudioIO.buffer(Mixer.render(state, sources, from: t, to: end)) else {
            isPlaying = false
            return
        }
        do {
            try playback.play(buf, from: t)
            isPlaying = true
            startTimer()
        } catch {
            isPlaying = false
            flash("재생 실패: \(error.localizedDescription)")
        }
    }

    func pause() {
        playback.stop()
        isPlaying = false
        if !isRecording { stopTimer() }
    }

    func stop() {
        if isRecording { finishRecording(); return }
        let was = isPlaying
        pause()
        playhead = was ? playOrigin : 0
        Scroller.shared.reveal(CGFloat(playhead * pxPerSec))
    }

    func seek(_ t: Double) {
        playhead = max(0, t)
        Scroller.shared.reveal(CGFloat(playhead * pxPerSec))
        if isPlaying && !isRecording {
            playback.stop()
            startPlayback(from: playhead)
        }
    }

    /// 눈금자 드래그 중에는 위치만 옮기고, 손 떼면 seek
    func scrub(_ t: Double) { playhead = max(0, t) }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if isRecording {
            playhead = recordStart + recorder.elapsed
            Scroller.shared.follow(CGFloat(playhead * pxPerSec))
            return
        }
        guard isPlaying, let t = playback.time else { return }
        playhead = t
        Scroller.shared.follow(CGFloat(t * pxPerSec))
        if t >= state.end { pause() }
    }

    // MARK: 녹음

    func toggleRecord() {
        if isRecording { finishRecording(); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    if ok { self.beginRecording() } else { self.flash("마이크 권한이 필요합니다") }
                }
            }
        default:
            flash("시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 소리판을 허용하세요")
        }
    }

    private func beginRecording() {
        if isPlaying { pause() }
        if state.tracks.isEmpty { addTrack() }
        let tid = selectedTrackID ?? state.tracks[0].id
        let dir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("소리판 녹음", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("녹음 \(df.string(from: Date())).caf")
        do {
            try recorder.start(url)
        } catch {
            flash("녹음 시작 실패: \(error.localizedDescription)")
            return
        }
        recordStart = playhead
        recordTrackID = tid
        playOrigin = playhead
        isRecording = true
        // 기존 트랙을 들으면서 녹음 (오버더빙)
        if state.end > playhead { startPlayback(from: playhead) }
        startTimer()
    }

    private func finishRecording() {
        let url = recorder.stop()
        isRecording = false
        pause()
        let start = recordStart
        guard let url else { flash("녹음된 소리가 없습니다"); return }
        load([url], trackID: recordTrackID, at: start)
        flash("녹음 저장: \(url.lastPathComponent)")
    }

    // MARK: 클립 편집

    func selectClip(_ id: UUID) {
        selectedClipID = id
        if let (ti, _) = locate(id) { selectedTrackID = state.tracks[ti].id }
    }

    /// S: 선택한 클립을 재생헤드에서 자름. 선택이 없으면 재생헤드에 걸친 모든 클립
    func split() {
        let p = playhead
        let covers: (Clip) -> Bool = { $0.start + 0.001 < p && p < $0.end - 0.001 }
        var targets: [UUID] = []
        if let c = selectedClip, covers(c) {
            targets = [c.id]
        } else {
            targets = state.tracks.flatMap(\.clips).filter(covers).map(\.id)
        }
        guard !targets.isEmpty else { flash("재생헤드 위치에 자를 클립이 없습니다"); return }
        var rightOfSelected: UUID?
        commit { s in
            for ti in s.tracks.indices {
                var out: [Clip] = []
                for c in s.tracks[ti].clips {
                    guard targets.contains(c.id) else { out.append(c); continue }
                    var a = c, b = c
                    b.id = UUID()
                    a.length = p - c.start
                    a.fadeOut = 0
                    a.fadeIn = min(a.fadeIn, a.length)
                    b.start = p
                    b.offset = c.offset + (p - c.start) * c.speed
                    b.length = c.end - p
                    b.fadeIn = 0
                    b.fadeOut = min(b.fadeOut, b.length)
                    out += [a, b]
                    if c.id == selectedClipID { rightOfSelected = b.id }
                }
                s.tracks[ti].clips = out
            }
        }
        if let r = rightOfSelected { selectedClipID = r }
    }

    func deleteSelected() {
        guard let id = selectedClipID else { return }
        commit { s in for ti in s.tracks.indices { s.tracks[ti].clips.removeAll { $0.id == id } } }
        selectedClipID = nil
    }

    func duplicateSelected() {
        guard let c = selectedClip, let (ti, _) = locate(c.id) else { return }
        var d = c
        d.id = UUID()
        d.start = c.end
        commit { $0.tracks[ti].clips.append(d) }
        selectedClipID = d.id
    }

    func normalizeSelected() {
        guard let c = selectedClip, let src = sources[c.sourceID], let (ti, ci) = locate(c.id) else { return }
        let pk = src.peak(from: c.offset, length: c.length * c.speed)
        guard pk > 0.0001 else { flash("무음 클립입니다"); return }
        let g = min(Float(0.98) / pk, 31.6)
        commit { $0.tracks[ti].clips[ci].gain = g }
        flash(String(format: "노멀라이즈: %+.1f dB", 20 * log10(g)))
    }

    // MARK: 드래그 (마우스 이동량을 원래 클립 기준으로 계산)

    private func snapPoints(excluding id: UUID) -> [Double] {
        var pts: [Double] = [0, playhead]
        for t in state.tracks { for c in t.clips where c.id != id { pts += [c.start, c.end] } }
        return pts
    }

    private func snapEdge(_ x: Double, excluding id: UUID) -> Double {
        let th = 8 / pxPerSec
        var best = x, bd = th
        for p in snapPoints(excluding: id) where abs(p - x) < bd { bd = abs(p - x); best = p }
        return best
    }

    func moveClip(_ id: UUID, origin: Clip, dx: Double, toTrack target: Int) {
        guard let (cti, ci) = locate(id) else { return }
        var c = state.tracks[cti].clips[ci]
        var ns = max(0, origin.start + dx / pxPerSec)
        let th = 8 / pxPerSec
        var bd = th
        var best = ns
        for p in snapPoints(excluding: id) {
            if abs(p - ns) < bd { bd = abs(p - ns); best = p }
            if abs(p - (ns + c.length)) < bd { bd = abs(p - (ns + c.length)); best = p - c.length }
        }
        ns = max(0, best)
        c.start = ns
        let ti = min(max(target, 0), state.tracks.count - 1)
        if ti == cti {
            state.tracks[cti].clips[ci] = c
        } else {
            state.tracks[cti].clips.remove(at: ci)
            state.tracks[ti].clips.append(c)
            selectedTrackID = state.tracks[ti].id
        }
    }

    func trimLeft(_ id: UUID, origin o: Clip, dx: Double) {
        var ns = snapEdge(o.start + dx / pxPerSec, excluding: id)
        ns = min(max(ns, max(0, o.start - o.offset / o.speed)), o.end - 0.02)
        liveClip(id) { c in
            c.start = ns
            c.offset = o.offset + (ns - o.start) * o.speed
            c.length = o.end - ns
            c.fadeIn = min(c.fadeIn, c.length)
            c.fadeOut = min(c.fadeOut, c.length - c.fadeIn)
        }
    }

    func trimRight(_ id: UUID, origin o: Clip, dx: Double) {
        let dur = sources[o.sourceID]?.duration ?? (o.offset + o.length)
        var ne = snapEdge(o.end + dx / pxPerSec, excluding: id)
        ne = min(max(ne, o.start + 0.02), o.start + (dur - o.offset) / o.speed)
        liveClip(id) { c in
            c.length = ne - o.start
            c.fadeOut = min(c.fadeOut, c.length)
            c.fadeIn = min(c.fadeIn, c.length - c.fadeOut)
        }
    }

    func setFade(_ id: UUID, origin o: Clip, dx: Double, isIn: Bool) {
        liveClip(id) { c in
            if isIn {
                c.fadeIn = min(max(0, o.fadeIn + dx / pxPerSec), c.length - c.fadeOut)
            } else {
                c.fadeOut = min(max(0, o.fadeOut - dx / pxPerSec), c.length - c.fadeIn)
            }
        }
    }

    // MARK: 보기

    func zoomIn() { pxPerSec = min(2000, pxPerSec * 1.5) }
    func zoomOut() { pxPerSec = max(4, pxPerSec / 1.5) }
}
