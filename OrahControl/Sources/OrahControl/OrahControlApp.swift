import SwiftUI
import AppKit
import OrahKit

/// An app assembled by hand around a SwiftPM binary does not get the activation
/// behaviour Xcode would arrange for it: without this it launches, takes the menu
/// bar, and never shows a window. Saying so explicitly is the fix.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set once the interface has built the model, so shutdown can reach it.
    weak var model: AppModel?

    private var terminateSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installTerminationHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quit, in every form of it, has to close the cameras' control sockets.
    ///
    /// The camera holds a control session open until it is told otherwise, and a
    /// process that simply dies leaves that session hanging: the camera still
    /// believes someone is connected. Enough of those and it stops answering
    /// commands altogether — a start returns `unknownError`, its own files return
    /// `unknownError`, and only a power cycle brings it back. That is what
    /// MEASUREMENTS M5 recorded, and this is the other half of the fix: not just
    /// "hold one connection", but "give it back when you are finished with it".
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    /// `applicationWillTerminate` covers Quit. It does not cover SIGTERM, which
    /// is what a shutdown, a crash reporter or a `pkill` sends — the exact cases
    /// where leaving the camera wedged is least convenient.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.info("app", "terminating — closing camera connections")
                self.model?.stop()
            }
            // The close frames are already on their way; give them a moment to
            // leave before the process does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
        source.resume()
        terminateSource = source
    }
}

@main
struct OrahControlApp: App {
    static let outputMonitorWindow = "output-monitor"
    static let multiviewWindow = "multiview"
    static let consoleWindow = "console"

    @Environment(\.openWindow) private var openWindow

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(AppPaths.name) {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    delegate.model = model
                    model.start()
                }
                .onDisappear { model.stop() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .windowArrangement) {
                Button("Output Monitor") { openOutputMonitor() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Rig Check") { model.setRigCheck(!model.showsRigCheck) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Multiview") { openWindow(id: Self.multiviewWindow) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Console") { openWindow(id: Self.consoleWindow) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }

        // A separate window on purpose: the output monitor belongs on the second
        // screen, next to the stitcher, while the desk stays in front of the
        // operator.
        Window("Output Monitor", id: Self.outputMonitorWindow) {
            OutputMonitorView()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 900)

        // Multiview and console as windows of their own.
        //
        // A gallery is more than one screen: the wall goes on the display the
        // operator looks up at, the desk stays under their hands, and neither
        // should have to share a window with the other. Both keep working in
        // the main window as well — this is another way to see them, not a
        // different mode.
        Window("Multiview", id: Self.multiviewWindow) {
            DetachedPane { MultiviewPane(showsUndock: false) }
                .environment(model)
        }
        .defaultSize(width: 1500, height: 950)

        Window("Console", id: Self.consoleWindow) {
            DetachedPane { ConsoleView(showsUndock: false) }
                .environment(model)
        }
        .defaultSize(width: 1280, height: 640)
    }

    private func openOutputMonitor() {
        openWindow(id: Self.outputMonitorWindow)
    }
}

/// A pane on its own, with the room around it a window needs.
///
/// The panes are built to sit in a stack inside the main window, so on their
/// own they want padding and a ground of their own — otherwise they float
/// against the window chrome and read as something that came loose rather than
/// as a window in its own right.
@MainActor
struct DetachedPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content().padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.fg)
    }
}
