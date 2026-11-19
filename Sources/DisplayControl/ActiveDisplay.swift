import AppKit
import CoreGraphics

/// 矩形の幾何計算だけを行う純粋な関数群。テストから直接検証する。
enum ActiveDisplayGeometry {
    /// window と最も広く重なる画面の ID を返す。重なりがなければ中心が最も近い画面。displays が空なら nil。
    static func displayID(
        for window: CGRect,
        among displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    ) -> CGDirectDisplayID? {
        guard isFinite(window) else { return nil }
        let target = window.standardized
        let validDisplays = displays.compactMap { entry -> (id: CGDirectDisplayID, bounds: CGRect)? in
            guard isFinite(entry.bounds), !entry.bounds.isEmpty else { return nil }
            return (id: entry.id, bounds: entry.bounds.standardized)
        }
        guard !validDisplays.isEmpty else { return nil }

        // 交差面積が最大の画面を優先する。辺や点だけの接触は面積 0 なので重なりとみなさない。
        var bestOverlapID: CGDirectDisplayID?
        var bestArea: CGFloat = 0
        for display in validDisplays {
            let intersection = target.intersection(display.bounds)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestOverlapID = display.id
            }
        }
        if let bestOverlapID {
            return bestOverlapID
        }

        // どの画面とも重ならないときは、ウインドウの中心から各画面の矩形までの距離が最小の画面を選ぶ。
        let windowCenter = CGPoint(x: target.midX, y: target.midY)
        var bestNearestID: CGDirectDisplayID?
        var bestEdgeDistance = CGFloat.infinity
        var bestCenterDistance = CGFloat.infinity
        for display in validDisplays {
            let edgeDistance = squaredDistance(from: windowCenter, to: display.bounds)
            let displayCenter = CGPoint(x: display.bounds.midX, y: display.bounds.midY)
            let centerDistance = squaredDistance(from: windowCenter, to: displayCenter)
            if edgeDistance < bestEdgeDistance
                || (edgeDistance == bestEdgeDistance && centerDistance < bestCenterDistance)
            {
                bestEdgeDistance = edgeDistance
                bestCenterDistance = centerDistance
                bestNearestID = display.id
            }
        }
        return bestNearestID
    }

    /// point を含む画面の ID を返す。含む画面がなければ nil。
    static func displayID(
        containing point: CGPoint,
        among displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    ) -> CGDirectDisplayID? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return displays.first { entry in
            guard isFinite(entry.bounds), !entry.bounds.isEmpty else { return false }
            return entry.bounds.standardized.contains(point)
        }?.id
    }

    /// 矩形の座標と寸法がすべて有限かつ null・無限大でないかを返す。NaN や無効矩形の混入を防ぐ。
    private static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isInfinite
            && rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }

    /// 点から矩形までの最短距離の二乗を返す。サイズが異なる画面同士でも外側のウインドウを正しく対応付ける。
    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// 2 点間の距離の二乗を返す。矩形までの距離が同じ画面が複数あるときの比較に使う。
    private static func squaredDistance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

/// 前面のアプリのウインドウがある画面を求める。自分自身が前面のときは直前の他アプリを使う。
@MainActor
final class ActiveDisplayTracker {
    /// 自分自身のプロセス ID。メニュー表示などで自分が前面になったかを判定する。
    private let selfPID: pid_t
    /// 自分以外で最後に前面になったアプリの PID。自分が前面のときの参照先として保持する。
    private var lastOtherPID: pid_t?
    /// アプリ切り替え通知の購読トークン。破棄時に監視を解除するために保持する。
    private var activationObserver: (any NSObjectProtocol)?

    private let frontmostPIDProvider: @MainActor () -> pid_t?
    private let displayBoundsProvider: @MainActor (CGDirectDisplayID) -> CGRect
    private let windowListProvider: @MainActor () -> [[String: Any]]?
    private let mouseLocationProvider: @MainActor () -> CGPoint?

    /// システムの前面アプリ・画面配置・ウインドウ一覧・ポインタ位置を参照する既定のトラッカーを作る。
    convenience init() {
        self.init(
            selfPID: ProcessInfo.processInfo.processIdentifier,
            observeWorkspace: true,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            displayBounds: { CGDisplayBounds($0) },
            windowList: { Self.copyOnScreenWindowInfo() },
            mouseLocation: { CGEvent(source: nil)?.location }
        )
    }

    /// 前面アプリの追跡を初期化する。テストから OS 呼び出しを差し替えられるよう内部用に分けている。
    init(
        selfPID: pid_t,
        observeWorkspace: Bool,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        displayBounds: @escaping @MainActor (CGDirectDisplayID) -> CGRect,
        windowList: @escaping @MainActor () -> [[String: Any]]?,
        mouseLocation: @escaping @MainActor () -> CGPoint?
    ) {
        self.selfPID = selfPID
        self.frontmostPIDProvider = frontmostPID
        self.displayBoundsProvider = displayBounds
        self.windowListProvider = windowList
        self.mouseLocationProvider = mouseLocation

        // 起動時点で既に他アプリが前面なら、最初のメニュー操作から直前アプリを参照できるよう記録する。
        if let pid = frontmostPID(), pid != selfPID {
            self.lastOtherPID = pid
        }

        if observeWorkspace {
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Notification は Sendable でないため、先に PID だけ取り出してから MainActor へ渡す。
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                guard let pid else { return }
                MainActor.assumeIsolated {
                    self?.recordActivatedApplication(pid: pid)
                }
            }
        }
    }

    /// 破棄時にアプリ切り替え通知の購読を解除する。不要な通知の受け取りを防ぐ。
    isolated deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// candidates の中から Active 画面を返す。決まらなければ nil。
    func currentDisplayID(among candidates: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        guard !candidates.isEmpty else { return nil }
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = candidates.compactMap { id in
            let bounds = displayBoundsProvider(id)
            guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else { return nil }
            return (id: id, bounds: bounds)
        }
        guard !displays.isEmpty else { return nil }

        if let targetPID = resolveTargetPID(),
           let windowList = windowListProvider(),
           let windowBounds = Self.frontmostWindowBounds(for: targetPID, in: windowList),
           let displayID = ActiveDisplayGeometry.displayID(for: windowBounds, among: displays)
        {
            return displayID
        }

        if let pointer = mouseLocationProvider(),
           let displayID = ActiveDisplayGeometry.displayID(containing: pointer, among: displays)
        {
            return displayID
        }

        return nil
    }

    /// 自分以外のアプリが前面になったときにその PID を記録する。自分が前面になった通知は無視する。
    func recordActivatedApplication(pid: pid_t) {
        guard pid != selfPID else { return }
        lastOtherPID = pid
    }

    /// Active 画面の判定に使うアプリの PID を返す。自分が前面のときは直前の他アプリを使う。
    private func resolveTargetPID() -> pid_t? {
        guard let frontPID = frontmostPIDProvider() else { return nil }
        if frontPID == selfPID {
            return lastOtherPID
        }
        lastOtherPID = frontPID
        return frontPID
    }

    /// 画面上に表示中のウインドウ一覧を手前から奥の順で取得する。画面収録権限が不要な項目だけを使う。
    private static func copyOnScreenWindowInfo() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    }

    /// ウインドウ情報一覧（手前から奥の順）から、指定 PID の最前面にある通常ウインドウの矩形を返す。
    static func frontmostWindowBounds(for pid: pid_t, in windowList: [[String: Any]]) -> CGRect? {
        let ownerPIDKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String

        for info in windowList {
            guard let ownerPID = pidValue(info[ownerPIDKey]),
                  ownerPID == pid
            else { continue }

            guard let layer = layerValue(info[layerKey]),
                  layer == 0
            else { continue }

            guard let boundsDict = info[boundsKey] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  !rect.isNull, !rect.isInfinite,
                  rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.size.width.isFinite, rect.size.height.isFinite,
                  rect.size.width > 0, rect.size.height > 0
            else { continue }

            return rect
        }
        return nil
    }

    /// ウインドウ情報辞書の値から PID を取り出す。CFNumber と Swift の整数型の両方を受け付ける。
    private static func pidValue(_ value: Any?) -> pid_t? {
        if let pid = value as? pid_t { return pid }
        if let int = value as? Int { return pid_t(exactly: int) }
        return nil
    }

    /// ウインドウ情報辞書の値からレイヤー番号を取り出す。CFNumber と Swift の整数型の両方を受け付ける。
    private static func layerValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let int32 = value as? Int32 { return Int(int32) }
        return nil
    }
}
