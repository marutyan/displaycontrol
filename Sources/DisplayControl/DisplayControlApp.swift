import AppKit
import ApplicationServices
import SwiftUI

/// 起動入口。`--diagnose` のときは UI を出さずに読み取り結果だけ表示して終了する。
@main
enum DisplayControlMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
        } else {
            DisplayControlApp.main()
        }
    }
}

/// 実機の読み取り結果を出力してすぐ終了する。書き込みと権限の要求は行わない。
/// identity はシリアルや UUID を含みうるので値そのものは出力しない。
enum Diagnostics {
    static func run() -> Never {
        Task.detached {
            let hardware = DisplayHardware()
            let displays = BrightnessModel.ordered(await hardware.scan())
            var lines = ["DisplayControl diagnose: \(displays.count) display(s)"]
            for (index, display) in displays.enumerated() {
                let level = String(format: "%.3f", display.brightness)
                lines.append(
                    "[\(index)] \(display.name) builtIn=\(display.isBuiltIn) main=\(display.isMain) "
                        + "origin=(\(Int(display.x)), \(Int(display.y))) brightness=\(level) "
                        + "identity=<redacted, \(display.identity.count) chars>"
                )
            }
            let distinct = Set(displays.map(\.identity)).count
            lines.append("distinct identities: \(distinct)/\(displays.count)")
            lines.append("keyboard access granted: \(AXIsProcessTrusted())")
            print(lines.joined(separator: "\n"))
            exit(0)
        }
        dispatchMain()
    }
}

struct DisplayControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            AppRootPanel(controller: AppController.shared)
        } label: {
            Image(systemName: "sun.max")
                .accessibilityLabel("DisplayControl")
        }
        .menuBarExtraStyle(.window)
    }
}

/// モデルの状態を UI 共有契約の BrightnessPanel に渡す。
private struct AppRootPanel: View {
    let controller: AppController

    var body: some View {
        let model = controller.model
        BrightnessPanel(
            displays: model.displays,
            activeIdentity: model.activeIdentity,
            status: model.status,
            keyboardNeedsPermission: model.keyboardNeedsPermission,
            onSetDisplay: { model.setDisplay($0, $1) },
            onOpen: { model.updateActive() },
            onMatch: { model.matchToActive() },
            onEnableKeyboard: { controller.keys.requestPermission() },
            onQuit: { NSApp.terminate(nil) }
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // swift run でも Dock に出さないメニューバー専用アプリにする。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
    }
}

/// モデル・キー監視・HUD・画面変化の監視をまとめる。
@MainActor
final class AppController {
    static let shared = AppController()

    let model: BrightnessModel
    let keys: BrightnessKeyMonitor
    private let hud = BrightnessHUDPresenter()
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {
        // Active 画面は前面のウインドウがある画面。キー操作やメニューを開いたときにこの追跡器へ問い合わせる。
        let tracker = ActiveDisplayTracker()
        let model = BrightnessModel(
            hardware: DisplayHardware(),
            activeDisplay: { tracker.currentDisplayID(among: $0) }
        )
        self.model = model
        self.keys = BrightnessKeyMonitor(
            isActive: { model.hasControllableDisplays },
            perform: { model.perform($0) },
            permissionChanged: { model.keyboardNeedsPermission = $0 }
        )
        let hud = self.hud
        model.feedback = { title, level in hud.show(title: title, level: level) }
    }

    func start() {
        guard !started else { return }
        started = true
        // 起動時は現在値の読み取りだけ行う。
        model.requestRefresh()
        keys.start()
        observeTopology()
    }

    /// 画面構成の変化と wake で再走査する。DDC の応答が戻るまで少し待つ。
    private func observeTopology() {
        let model = self.model
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.scheduleRefresh(after: .seconds(1)) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.scheduleRefresh(after: .seconds(2)) }
            })
        }
    }
}
