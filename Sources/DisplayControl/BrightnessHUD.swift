import AppKit
import SwiftUI

// 輝度キー操作時に出す一時表示。中央に太陽、その下に対象名、最下段に16段バーを置く。
// フォーカスを奪わず、クリックも透過し、一定時間で消える。続けて呼ばれたら内容を差し替えて時間を延ばす。
@MainActor
final class BrightnessHUDPresenter {
    private static let width = BrightnessHUDView.width
    private static let cornerRadius: CGFloat = 14
    // 画面下端（Dockを除いた可視領域）からの距離。
    private static let bottomOffset: CGFloat = 120
    private static let visibleDuration: TimeInterval = 1.2
    private static let fadeInDuration: TimeInterval = 0.08
    private static let fadeOutDuration: TimeInterval = 0.35

    private let panel: HUDPanel
    private let hostingView: NSHostingView<BrightnessHUDView>
    private var hideTask: Task<Void, Never>?

    init() {
        hostingView = NSHostingView(rootView: BrightnessHUDView(title: "", level: nil))

        // 背景はHUD用の素材で背後をぼかし、角丸はマスク画像で切り抜く。
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        background.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0
    }

    /// 表示内容を差し替えて出す。`level` が nil のときはバーを出さない（Primaryの切り替えなど）。
    func show(title: String, level: Double?) {
        hostingView.rootView = BrightnessHUDView(title: title, level: level.map { min(max($0, 0), 1) })
        layout()

        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            animateAlpha(to: 1, duration: Self.fadeInDuration)
        }
        announce(title: title, level: level)
        scheduleHide()
    }

    // MARK: - 配置

    // ポインタのある画面の下中央に置く。
    private func layout() {
        let size = NSSize(width: Self.width, height: hostingView.fittingSize.height)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + Self.bottomOffset).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - 表示時間

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleDuration))
            guard !Task.isCancelled, let self else { return }
            self.animateAlpha(to: 0, duration: Self.fadeOutDuration) { [weak self] in
                // 消える途中で再表示されたら閉じない。
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // 視差効果を減らす設定ではフェードせずに切り替える。
    private func animateAlpha(to alpha: CGFloat, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            Task { @MainActor in completion?() }
        }
    }

    // MARK: - 読み上げ

    // HUDはフォーカスを持たないため、VoiceOverには通知で内容を伝える。
    private func announce(title: String, level: Double?) {
        var text = title
        if let level {
            text += ", \(Int((min(max(level, 0), 1) * 100).rounded())) percent"
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// キーウィンドウにも主ウィンドウにもならないパネル。操作中のアプリのフォーカスを保つ。
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// HUDの中身。寸法は承認済み試作に合わせる。
struct BrightnessHUDView: View {
    static let width: CGFloat = 201

    let title: String
    let level: Double?

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sun.max")
                .font(.system(size: 36, weight: .regular))
                .frame(width: 44, height: 44)
                .padding(.bottom, 6)
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let level {
                LevelBar(level: level)
                    .frame(width: LevelBar.width, height: LevelBar.height)
                    .padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }
}
