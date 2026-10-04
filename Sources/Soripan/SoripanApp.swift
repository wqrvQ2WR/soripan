import SwiftUI

@main
struct SoripanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var editor = Editor.shared

    var body: some Scene {
        // 단일 창 앱: WindowGroup은 파일 열기 이벤트마다 창을 새로 만들어서 Window 사용
        Window("소리판", id: "main") {
            ContentView()
                .environment(editor)
                .frame(minWidth: 1220, minHeight: 560)
        }
        .defaultSize(width: 1360, height: 780)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { editor.undo() }
                    .keyboardShortcut("z")
                    .disabled(!editor.canUndo)
                Button("다시 실행") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("새 프로젝트") { editor.newProject() }.keyboardShortcut("n")
                Button("프로젝트 열기...") { editor.openDialog() }.keyboardShortcut("o")
                Divider()
                Button("저장") { editor.save() }.keyboardShortcut("s")
                Button("다른 이름으로 저장...") { editor.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("오디오 가져오기...") { editor.importDialog() }.keyboardShortcut("i")
                Button("새 트랙") { editor.addTrack() }.keyboardShortcut("t")
                Divider()
                Button("WAV로 내보내기...") { editor.export(m4a: false) }.keyboardShortcut("e")
                Button("M4A로 내보내기...") { editor.export(m4a: true) }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("재생") {
                Button("재생 / 일시정지") { editor.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("정지") { editor.stop() }.keyboardShortcut(".")
                Button("처음으로") { editor.seek(0) }.keyboardShortcut(.home, modifiers: [])
                Divider()
                Button(editor.isRecording ? "녹음 중지" : "녹음") { editor.toggleRecord() }.keyboardShortcut("r", modifiers: [])
            }
            CommandMenu("클립") {
                Button("재생헤드에서 자르기") { editor.split() }.keyboardShortcut("s", modifiers: [])
                Button("복제") { editor.duplicateSelected() }.keyboardShortcut("d")
                Button("노멀라이즈") { editor.normalizeSelected() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("삭제") { editor.deleteSelected() }.keyboardShortcut(.delete, modifiers: [])
            }
            CommandGroup(after: .toolbar) {
                Button("확대") { editor.zoomIn() }.keyboardShortcut("=")
                Button("축소") { editor.zoomOut() }.keyboardShortcut("-")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ed = Editor.current, !ed.closing else { return .terminateNow }
        return ed.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    /// Finder에서 .soripan 더블클릭 / Dock 아이콘에 오디오 끌어다 놓기
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let ed = Editor.current else { return }
        if let proj = urls.first(where: { $0.pathExtension == ProjectFile.ext }) {
            ed.openFromFinder(proj)
        } else {
            ed.importFiles(urls, trackIndex: nil, at: nil)
        }
    }
}
