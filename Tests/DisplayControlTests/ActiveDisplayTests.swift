import CoreGraphics
import Foundation
import Testing
@testable import DisplayControl

/// ウインドウ情報辞書の 1 件分をテスト用に組み立てる。
private func windowInfo(
    pid: Any,
    layer: Any = 0,
    bounds: CGRect?
) -> [String: Any] {
    var dict: [String: Any] = [
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
    ]
    if let bounds {
        dict[kCGWindowBounds as String] = bounds.dictionaryRepresentation
    }
    return dict
}

@Suite("Active画面の幾何判定")
struct ActiveDisplayGeometryTests {
    @Test("2画面にまたがるウインドウは重なりの広い画面を選ぶ")
    func picksDisplayWithLargestOverlap() {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (id: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
        ]
        // 左画面に 300x600、右画面に 500x600 重なる。
        let mostlyRight = CGRect(x: 1620, y: 200, width: 800, height: 600)
        #expect(ActiveDisplayGeometry.displayID(for: mostlyRight, among: displays) == 2)

        // 左画面に 600x600、右画面に 200x600 重なる。
        let mostlyLeft = CGRect(x: 1320, y: 200, width: 800, height: 600)
        #expect(ActiveDisplayGeometry.displayID(for: mostlyLeft, among: displays) == 1)

        // 3画面にまたがる場合も交差面積が最大の画面を選ぶ。
        let threeDisplays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),
            (id: 2, bounds: CGRect(x: 1000, y: 0, width: 1000, height: 1000)),
            (id: 3, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000)),
        ]
        // 画面1に 200x400、画面2に 1000x400、画面3に 300x400 重なる。
        let acrossThree = CGRect(x: 800, y: 100, width: 1500, height: 400)
        #expect(ActiveDisplayGeometry.displayID(for: acrossThree, among: threeDisplays) == 2)
    }

    @Test("負の座標の外部画面（主画面の左上）を正しく扱える")
    func handlesNegativeCoordinateDisplay() {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 10, bounds: CGRect(x: -1920, y: -1080, width: 1920, height: 1080)),
            (id: 20, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ]

        // 完全に負座標の外部画面内にあるウインドウ。
        let insideExternal = CGRect(x: -1500, y: -800, width: 900, height: 600)
        #expect(ActiveDisplayGeometry.displayID(for: insideExternal, among: displays) == 10)

        // 外部画面に 400x300、主画面に 100x200 重なるウインドウ。
        let mostlyExternal = CGRect(x: -400, y: -300, width: 500, height: 500)
        #expect(ActiveDisplayGeometry.displayID(for: mostlyExternal, among: displays) == 10)

        // 外部画面に 100x100、主画面に 400x300 重なるウインドウ。
        let mostlyMain = CGRect(x: -100, y: -100, width: 500, height: 400)
        #expect(ActiveDisplayGeometry.displayID(for: mostlyMain, among: displays) == 20)

        // 負座標の外部画面内にあるポインタ。
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: -500, y: -200), among: displays) == 10)
        // 主画面の原点 (0, 0) は半開区間の仕様により主画面側へ入る。
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 0, y: 0), among: displays) == 20)
    }

    @Test("どの画面とも重ならないウインドウは中心に最も近い画面を選ぶ")
    func fallsBackToNearestDisplayWhenNoOverlap() {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (id: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
        ]

        // 画面2の上方に外れたウインドウ。
        let aboveRight = CGRect(x: 2200, y: -300, width: 400, height: 200)
        #expect(ActiveDisplayGeometry.displayID(for: aboveRight, among: displays) == 2)

        // 画面1の左方に外れたウインドウ。
        let leftOfLeft = CGRect(x: -500, y: 200, width: 300, height: 300)
        #expect(ActiveDisplayGeometry.displayID(for: leftOfLeft, among: displays) == 1)

        // 画面2の右辺に接しているだけ（交差面積 0）のウインドウ。
        let touchingRightEdge = CGRect(x: 3840, y: 100, width: 400, height: 300)
        #expect(ActiveDisplayGeometry.displayID(for: touchingRightEdge, among: displays) == 2)

        // 画面サイズが異なる場合でも、大画面の真上にあるウインドウは大画面を選ぶ。
        let mixedDisplays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
            (id: 2, bounds: CGRect(x: 2560, y: 440, width: 1440, height: 1000)),
        ]
        let directlyAboveLarge = CGRect(x: 2400, y: -200, width: 150, height: 150)
        #expect(ActiveDisplayGeometry.displayID(for: directlyAboveLarge, among: mixedDisplays) == 1)
    }

    @Test("画面一覧が空なら nil を返す")
    func returnsNilWhenDisplaysEmpty() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(ActiveDisplayGeometry.displayID(for: window, among: []) == nil)
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 100, y: 100), among: []) == nil)
    }

    @Test("ポインタの位置から該当する画面を選び、範囲外は nil を返す")
    func picksDisplayContainingPointer() {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [
            (id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            (id: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
        ]

        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 960, y: 540), among: displays) == 1)
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 2500, y: 300), among: displays) == 2)
        // 境界線上 (x = 1920) は右画面の最小端として扱う。
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 1920, y: 500), among: displays) == 2)
        // どの画面にも含まれない座標は nil。
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 4000, y: 500), among: displays) == nil)
        #expect(ActiveDisplayGeometry.displayID(containing: CGPoint(x: 500, y: 1080), among: displays) == nil)
    }
}

/// テスト中に前面アプリ・ウインドウ一覧・ポインタ位置を差し替えるための状態保持。
@MainActor
private final class StubEnvironment {
    var frontPID: pid_t?
    var boundsMap: [CGDirectDisplayID: CGRect]
    var windows: [[String: Any]]?
    var pointer: CGPoint?

    init(
        frontPID: pid_t? = nil,
        boundsMap: [CGDirectDisplayID: CGRect],
        windows: [[String: Any]]? = [],
        pointer: CGPoint? = nil
    ) {
        self.frontPID = frontPID
        self.boundsMap = boundsMap
        self.windows = windows
        self.pointer = pointer
    }

    /// 差し替えた状態を参照する ActiveDisplayTracker を作る。
    func makeTracker(selfPID: pid_t = 100) -> ActiveDisplayTracker {
        ActiveDisplayTracker(
            selfPID: selfPID,
            observeWorkspace: false,
            frontmostPID: { self.frontPID },
            displayBounds: { self.boundsMap[$0] ?? .zero },
            windowList: { self.windows },
            mouseLocation: { self.pointer }
        )
    }
}

@MainActor
@Suite("Active画面の追跡")
struct ActiveDisplayTrackerTests {
    private let leftBounds = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let mainBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test("ウインドウ一覧から対象 PID の最前面にある通常ウインドウだけを選ぶ")
    func filtersFrontmostNormalWindowForTargetPID() {
        let frontRect = CGRect(x: -1400, y: 120, width: 900, height: 700)
        let backRect = CGRect(x: 100, y: 100, width: 800, height: 600)

        let windows: [[String: Any]] = [
            // 別アプリの通常ウインドウは対象外。
            windowInfo(pid: pid_t(999), layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
            // レイヤーが 0 以外のウインドウ（メニューやパネルなど）は対象外。
            windowInfo(pid: pid_t(200), layer: 25, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
            // 幅や高さが 0 以下のウインドウは対象外。
            windowInfo(pid: pid_t(200), layer: 0, bounds: CGRect(x: 50, y: 50, width: 0, height: 200)),
            windowInfo(pid: pid_t(200), layer: 0, bounds: CGRect(x: 50, y: 50, width: 200, height: 0)),
            [
                kCGWindowOwnerPID as String: pid_t(200),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: ["X": 50, "Y": 50, "Width": -200, "Height": 200],
            ],
            // bounds 欠落や真偽値のレイヤーは対象外。
            windowInfo(pid: pid_t(200), layer: 0, bounds: nil),
            windowInfo(pid: pid_t(200), layer: false, bounds: CGRect(x: 10, y: 10, width: 200, height: 200)),
            // CFNumber 経由で渡る実機形式の数値を想定した最前面の通常ウインドウ。
            windowInfo(pid: NSNumber(value: Int64(200)), layer: NSNumber(value: Int32(0)), bounds: frontRect),
            // 後ろにある同じアプリの通常ウインドウより手前が優先される。
            windowInfo(pid: pid_t(200), layer: 0, bounds: backRect),
        ]

        #expect(
            ActiveDisplayTracker.frontmostWindowBounds(for: 200, in: windows)
                == CGRect(x: -1400, y: 120, width: 900, height: 700)
        )
        #expect(ActiveDisplayTracker.frontmostWindowBounds(for: 300, in: windows) == nil)
    }

    @Test("前面の他アプリのウインドウがある画面を返し、自分が前面なら直前の他アプリを使う")
    func usesPreviousOtherAppWhenSelfIsFrontmost() {
        let env = StubEnvironment(
            frontPID: 200,
            boundsMap: [1: leftBounds, 2: mainBounds],
            windows: [
                windowInfo(pid: pid_t(200), layer: 0, bounds: CGRect(x: -1500, y: 100, width: 800, height: 600)),
                windowInfo(pid: pid_t(300), layer: 0, bounds: CGRect(x: 200, y: 100, width: 800, height: 600)),
            ]
        )
        let tracker = env.makeTracker(selfPID: 100)

        // 起動時点で前面だったアプリ (200) の画面 1 を返す。
        #expect(tracker.currentDisplayID(among: [1, 2]) == 1)

        // 自分自身 (100) が前面になっても、直前のアプリ (200) の画面 1 を保つ。
        env.frontPID = 100
        tracker.recordActivatedApplication(pid: 100)
        #expect(tracker.currentDisplayID(among: [1, 2]) == 1)

        // 別アプリ (300) へ切り替わった後、再び自分が前面になればアプリ 300 の画面 2 を使う。
        tracker.recordActivatedApplication(pid: 300)
        tracker.recordActivatedApplication(pid: 100)
        #expect(tracker.currentDisplayID(among: [1, 2]) == 2)
    }

    @Test("通常ウインドウが無いときや取得失敗時はポインタ位置へフォールバックし、決まらなければ nil")
    func fallsBackToPointerWhenNoNormalWindow() {
        let env = StubEnvironment(
            frontPID: 200,
            boundsMap: [1: leftBounds, 2: mainBounds],
            windows: [
                // レイヤー 0 のウインドウを持たない前面アプリ。
                windowInfo(pid: pid_t(200), layer: 25, bounds: CGRect(x: -1000, y: 100, width: 400, height: 300)),
            ],
            pointer: CGPoint(x: 500, y: 400)
        )
        let tracker = env.makeTracker(selfPID: 100)

        // 通常ウインドウが無いのでポインタのある画面 2 を返す。
        #expect(tracker.currentDisplayID(among: [1, 2]) == 2)

        // ウインドウ一覧の取得が nil でもポインタへフォールバックする。
        env.windows = nil
        env.pointer = CGPoint(x: -500, y: 400)
        #expect(tracker.currentDisplayID(among: [1, 2]) == 1)

        // ポインタが候補画面の外なら nil。
        env.pointer = CGPoint(x: 5000, y: 5000)
        #expect(tracker.currentDisplayID(among: [1, 2]) == nil)

        // ポインタも取得できなければ nil。
        env.pointer = nil
        #expect(tracker.currentDisplayID(among: [1, 2]) == nil)

        // 起動時から自分自身が前面で直前の他アプリが未記録のときも、ポインタへフォールバックする。
        let selfOnlyEnv = StubEnvironment(
            frontPID: 100,
            boundsMap: [1: leftBounds, 2: mainBounds],
            windows: [
                windowInfo(pid: pid_t(100), layer: 0, bounds: CGRect(x: -1500, y: 100, width: 800, height: 600)),
            ],
            pointer: CGPoint(x: 500, y: 400)
        )
        let selfOnlyTracker = selfOnlyEnv.makeTracker(selfPID: 100)
        #expect(selfOnlyTracker.currentDisplayID(among: [1, 2]) == 2)
    }

    @Test("候補画面の一覧に含まれる画面だけを返し、空や無効な候補は nil を返す")
    func restrictsResultToCandidates() {
        let env = StubEnvironment(
            frontPID: 200,
            boundsMap: [1: leftBounds, 2: mainBounds],
            windows: [
                windowInfo(pid: pid_t(200), layer: 0, bounds: CGRect(x: -1500, y: 100, width: 800, height: 600)),
            ],
            pointer: CGPoint(x: -500, y: 500)
        )
        let tracker = env.makeTracker(selfPID: 100)

        // 候補が画面 2 のみのときは、画面 1 のウインドウでも候補内の画面 2 を返す。
        #expect(tracker.currentDisplayID(among: [2]) == 2)
        // ウインドウが無くポインタが候補外 (画面 1) にあるときは nil。
        env.windows = []
        #expect(tracker.currentDisplayID(among: [2]) == nil)
        // 候補が空または無効な ID のみのときは nil。
        #expect(tracker.currentDisplayID(among: []) == nil)
        #expect(tracker.currentDisplayID(among: [999]) == nil)

        // 引数なし init() の公開シグネチャをコンパイル時に保証する（実機 API は呼ばない）。
        let factory: @MainActor () -> ActiveDisplayTracker = ActiveDisplayTracker.init
        _ = factory
    }
}
