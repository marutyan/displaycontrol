import AppKit
import ApplicationServices
import CoreGraphics

enum BrightnessKey: Sendable, Hashable {
    case up
    case down

    var other: BrightnessKey { self == .up ? .down : .up }
    var direction: Int { self == .up ? 1 : -1 }
}

/// systemDefined イベントから取り出した輝度キーの状態。
struct BrightnessKeyEvent: Equatable, Sendable {
    let key: BrightnessKey
    let isDown: Bool
    let isRepeat: Bool

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS
    static let auxControlSubtype: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP / NX_KEYTYPE_BRIGHTNESS_DOWN
    static let brightnessUpKeyType = 2
    static let brightnessDownKeyType = 3

    /// data1 の上位16bitがキー種別、次の8bitが状態（0x0A 押下 / 0x0B 解放）、最下位bitがリピート。
    static func parse(subtype: Int16, data1: Int) -> BrightnessKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        let key: BrightnessKey
        switch keyType {
        case brightnessUpKeyType: key = .up
        case brightnessDownKeyType: key = .down
        default: return nil
        }
        switch state {
        case 0x0A: return BrightnessKeyEvent(key: key, isDown: true, isRepeat: flags & 0x1 != 0)
        case 0x0B: return BrightnessKeyEvent(key: key, isDown: false, isRepeat: false)
        default: return nil
        }
    }
}

/// 輝度キーの単押し・Shift・上下同時押しを判定する純粋な状態機械。
/// 最初の押下は同時押し判定のために最大 `chordWindow` だけ保留し、
/// 片方を離した時点・もう片方が来た時点・期限切れのいずれか早い時点で確定する。
struct KeyChordDetector {
    /// 同時押しとみなす最大間隔（秒）。
    static let defaultChordWindow: TimeInterval = 0.075

    let chordWindow: TimeInterval
    private(set) var held: Set<BrightnessKey> = []
    /// 同時押し判定待ちの Shift なし押下。Shift 付きは保留せず即座に Active 画面を変える。
    private var pendingPress: (key: BrightnessKey, time: TimeInterval)?
    /// Shift 付きで押されたキー。離すまでのリピートは Active 画面だけを変える。
    private var shiftPressed: Set<BrightnessKey> = []
    /// 同時押しで揃えた後、両方離すまで追加の操作を出さない。
    private var chordLatched = false

    init(chordWindow: TimeInterval = defaultChordWindow) {
        self.chordWindow = chordWindow
    }

    /// 保留中の押下が確定する時刻。
    var deadline: TimeInterval? {
        pendingPress.map { $0.time + chordWindow }
    }

    mutating func press(_ key: BrightnessKey, shift: Bool, isRepeat: Bool, at time: TimeInterval) -> [KeyAction] {
        // タイマーが遅れても、期限切れかどうかは入力時刻で判定する。
        var actions = expire(at: time)
        if isRepeat {
            // リピートは押し始めの種類を引き継ぐ。Shift 付きで押したキーは Active 画面だけを変え続ける。
            guard !chordLatched, pendingPress == nil, held.contains(key) else { return actions }
            if shiftPressed.contains(key) { return actions + [.stepActive(key.direction)] }
            guard !shift else { return actions }
            return actions + [.step(key.direction)]
        }

        held.insert(key)
        if chordLatched { return actions }

        if let pending = pendingPress {
            pendingPress = nil
            // 期限内の Shift なし上下押しだけを同時押しとして揃える。
            if pending.key == key.other, !shift {
                chordLatched = true
                return actions + [.match]
            }
            // 同時押しにならない保留（解放の取りこぼしや Shift 混在）は先に確定させる。
            actions.append(.step(pending.key.direction))
        }
        if shift {
            shiftPressed.insert(key)
            return actions + [.stepActive(key.direction)]
        }
        shiftPressed.remove(key)
        pendingPress = (key, time)
        return actions
    }

    mutating func release(_ key: BrightnessKey, at time: TimeInterval) -> [KeyAction] {
        held.remove(key)
        shiftPressed.remove(key)
        var actions: [KeyAction] = []
        if let pending = pendingPress, pending.key == key {
            actions.append(.step(pending.key.direction))
            pendingPress = nil
        }
        if held.isEmpty { chordLatched = false }
        return actions
    }

    mutating func expire(at time: TimeInterval) -> [KeyAction] {
        guard let pending = pendingPress, time >= pending.time + chordWindow else { return [] }
        pendingPress = nil
        return [.step(pending.key.direction)]
    }

    /// tap の無効化などで解放イベントを失ったときに初期化する。
    mutating func reset() {
        held = []
        pendingPress = nil
        shiftPressed = []
        chordLatched = false
    }
}

/// CGEvent tap で輝度メディアキーを受け取る。
/// 権限確認はプロンプトなしで行い、承認フローはユーザーのボタン操作でだけ開始する。
@MainActor
final class BrightnessKeyMonitor {
    /// 制御可能な画面があるときだけキーを消費する。
    private let isActive: @MainActor () -> Bool
    private let perform: @MainActor (KeyAction) -> Void
    private let permissionChanged: @MainActor (Bool) -> Void

    private var detector = KeyChordDetector()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 押下を消費したキー。対応する解放も同じく消費する。
    private var consumedKeys: Set<BrightnessKey> = []
    private var expiryTask: Task<Void, Never>?
    private var permissionPoll: Task<Void, Never>?
    /// システム設定で直接許可されたときに気づくための通知の購読。tap を張ったら解除する。
    private var trustObserver: NSObjectProtocol?

    init(
        isActive: @escaping @MainActor () -> Bool,
        perform: @escaping @MainActor (KeyAction) -> Void,
        permissionChanged: @escaping @MainActor (Bool) -> Void
    ) {
        self.isActive = isActive
        self.perform = perform
        self.permissionChanged = permissionChanged
    }

    /// 起動時に呼ぶ。権限があれば tap を張り、なければ状態だけ伝える。ダイアログは出さない。
    func start() {
        if AXIsProcessTrusted() {
            installTap()
        } else {
            permissionChanged(true)
            observeTrustChanges()
        }
    }

    /// アクセシビリティの許可一覧が変わると macOS が配る通知を受け、許可されていれば tap を張る。
    /// ボタンを押さずにシステム設定から直接許可した場合も、起動し直さずにキーを使えるようにする。
    private func observeTrustChanges() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // 通知は許可の反映より先に届くことがあるため、少し待ってから確かめる。
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.tap == nil, AXIsProcessTrusted() else { return }
                self.installTap()
            }
        }
    }

    /// ユーザーのボタン押下から呼ぶ。システムの承認フローを開始し、許可されたら tap を張る。
    func requestPermission() {
        if AXIsProcessTrusted() {
            installTap()
            return
        }
        // kAXTrustedCheckOptionPrompt と同じキー。グローバル変数参照を避けて文字列で渡す。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionPoll?.cancel()
        permissionPoll = Task { [weak self] in
            // 許可の反映を最大5分待つ。
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    self.installTap()
                    return
                }
            }
        }
    }

    private func installTap() {
        guard tap == nil else {
            permissionChanged(false)
            return
        }
        let systemDefined = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: brightnessTapCallback,
            userInfo: refcon
        ) else {
            permissionChanged(true)
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        if let trustObserver {
            DistributedNotificationCenter.default().removeObserver(trustObserver)
            self.trustObserver = nil
        }
        permissionChanged(false)
    }

    /// tap から呼ばれる。true を返すとイベントを消費する。
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            detector.reset()
            consumedKeys = []
            expiryTask?.cancel()
            return false
        }
        guard type.rawValue == NSEvent.EventType.systemDefined.rawValue,
              let nsEvent = NSEvent(cgEvent: event),
              let keyEvent = BrightnessKeyEvent.parse(
                  subtype: nsEvent.subtype.rawValue, data1: nsEvent.data1)
        else { return false }

        // 入力時刻（NSEvent.timestamp は systemUptime と同じ起動時からの秒）。取れなければ処理時刻。
        let now = nsEvent.timestamp > 0 ? nsEvent.timestamp : ProcessInfo.processInfo.systemUptime
        if keyEvent.isDown {
            if !keyEvent.isRepeat || !consumedKeys.contains(keyEvent.key) {
                // 新しい押下ごとに消費するか決める。制御対象がなければ macOS に渡す。
                guard isActive() else {
                    consumedKeys.remove(keyEvent.key)
                    return false
                }
                consumedKeys.insert(keyEvent.key)
            }
            let shift = event.flags.contains(.maskShift)
                || CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
            dispatch(detector.press(keyEvent.key, shift: shift, isRepeat: keyEvent.isRepeat, at: now))
        } else {
            guard consumedKeys.remove(keyEvent.key) != nil else { return false }
            dispatch(detector.release(keyEvent.key, at: now))
        }
        scheduleExpiry()
        return true
    }

    private func dispatch(_ actions: [KeyAction]) {
        for action in actions { perform(action) }
    }

    /// 保留中の押下を期限で確定させる。待ち時間は同時押し判定に必要な分だけ。
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = detector.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        expiryTask = Task { [weak self] in
            // 許容誤差を0にして、OSによるタイマーのまとめ実行で確定が遅れないようにする。
            try? await Task.sleep(for: .seconds(delay), tolerance: .zero)
            guard let self, !Task.isCancelled else { return }
            self.dispatch(self.detector.expire(at: deadline))
        }
    }
}

/// C の tap コールバック。tap はメインの run loop に登録しているので MainActor 上で動く。
private func brightnessTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    // コールバックは常にメインスレッドで同期的に呼ばれるので、そのまま MainActor へ渡してよい。
    let context = TapContext(userInfo: userInfo, type: type, event: event)
    let consumed = MainActor.assumeIsolated {
        let monitor = Unmanaged<BrightnessKeyMonitor>.fromOpaque(context.userInfo).takeUnretainedValue()
        return monitor.handle(type: context.type, event: context.event)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

private struct TapContext: @unchecked Sendable {
    let userInfo: UnsafeMutableRawPointer
    let type: CGEventType
    let event: CGEvent
}
