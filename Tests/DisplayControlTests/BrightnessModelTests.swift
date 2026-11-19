import Foundation
import Testing
@testable import DisplayControl

struct FakeWriteError: Error {}

/// 書き込みを任意の時点まで止められる偽装ハードウェア。
actor FakeHardware: BrightnessHardware {
    var displays: [DisplaySnapshot]
    private(set) var writes: [(String, Double)] = []
    private(set) var scanCount = 0
    var holdWrites = false
    var failingLevels: Set<Double> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var scanGate: CheckedContinuation<Void, Never>?
    var holdScan = false

    init(_ displays: [DisplaySnapshot]) { self.displays = displays }

    func scan() async -> [DisplaySnapshot] {
        scanCount += 1
        if holdScan { await withCheckedContinuation { scanGate = $0 } }
        return displays
    }

    func setBrightness(_ level: Double, for display: DisplaySnapshot) async throws {
        if holdWrites { await withCheckedContinuation { waiting.append($0) } }
        writes.append((display.identity, level))
        if failingLevels.contains(level) { throw FakeWriteError() }
        if let i = displays.firstIndex(where: { $0.identity == display.identity }) {
            displays[i] = displays[i].withBrightness(level)
        }
    }

    func setHoldWrites(_ value: Bool) { holdWrites = value }
    func setHoldScan(_ value: Bool) { holdScan = value }
    func setFailing(_ levels: Set<Double>) { failingLevels = levels }
    func setDisplays(_ value: [DisplaySnapshot]) { displays = value }
    var waitingCount: Int { waiting.count }
    var isScanWaiting: Bool { scanGate != nil }

    func releaseOne() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
    func releaseScan() {
        scanGate?.resume()
        scanGate = nil
    }
    func writtenLevels(_ identity: String) -> [Double] {
        writes.filter { $0.0 == identity }.map(\.1)
    }
}

func snapshot(
    _ identity: String, x: Double, y: Double = 0, main: Bool = false,
    builtIn: Bool = false, brightness: Double = 0.5, id: UInt32 = 1
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id, identity: identity, name: identity.uppercased(), isBuiltIn: builtIn,
        isMain: main, x: x, y: y, brightness: brightness
    )
}

/// 他タスクが MainActor やアクターで進むまで待つ。
@MainActor
func waitFor(_ condition: () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("条件が満たされなかった")
}

@MainActor
@Suite("輝度モデル")
struct BrightnessModelTests {
    let threeDisplays = [
        snapshot("right", x: 3000, brightness: 0.6),
        snapshot("builtin", x: 0, y: 200, main: true, builtIn: true, brightness: 0.4),
        snapshot("left", x: -2500, y: 0, brightness: 0.8),
    ]

    @Test("起動時の読み取りは書き込みをせず、表示順は x 次いで y、初回 Primary は主画面")
    func startupIsReadOnly() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        #expect(model.displays.map(\.identity) == ["left", "builtin", "right"])
        #expect(model.primaryIdentity == "builtin")
        #expect(model.status == nil)
        #expect(await hw.writes.isEmpty)
    }

    @Test("Shift 切替は表示順で巡回し、輝度を変えない")
    func cyclePrimaryInOrder() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        var shown: [String] = []
        model.feedback = { title, _ in shown.append(title) }
        model.perform(.cyclePrimary(1))
        #expect(model.primaryIdentity == "right")
        model.perform(.cyclePrimary(1))
        #expect(model.primaryIdentity == "left")
        model.perform(.cyclePrimary(-1))
        #expect(model.primaryIdentity == "right")
        #expect(shown == ["RIGHT", "LEFT", "RIGHT"])
        await model.waitUntilIdle()
        #expect(await hw.writes.isEmpty)
    }

    @Test("選んだ Primary は再走査で保持し、切断中は主画面、再接続で復帰する")
    func primarySurvivesTopologyChanges() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        model.selectPrimary("right")
        await model.refresh()
        #expect(model.primaryIdentity == "right")

        await hw.setDisplays(threeDisplays.filter { $0.identity != "right" })
        await model.refresh()
        #expect(model.primaryIdentity == "builtin")

        // 再接続で DisplayID が変わっても identity で復帰する。
        var back = threeDisplays
        back[0] = snapshot("right", x: 3000, brightness: 0.6, id: 99)
        await hw.setDisplays(back)
        await model.refresh()
        #expect(model.primaryIdentity == "right")
        #expect(model.primary?.id == 99)
    }

    @Test("送信中に来た値は画面ごとに最新の1件へまとめる")
    func coalescesPendingWrites() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        await hw.setHoldWrites(true)

        model.setDisplay("left", 0.2)
        await waitFor { await hw.waitingCount == 1 }
        model.setDisplay("left", 0.3)
        model.setDisplay("left", 0.4)
        model.setDisplay("left", 0.5)
        #expect(model.displays.first { $0.identity == "left" }?.brightness == 0.5)

        await hw.setHoldWrites(false)
        await hw.releaseOne()
        await model.waitUntilIdle()
        #expect(await hw.writtenLevels("left") == [0.2, 0.5])
        #expect(await hw.writtenLevels("right").isEmpty)
        #expect(model.displays.first { $0.identity == "left" }?.brightness == 0.5)
    }

    @Test("古い書き込みの失敗は新しい値の表示と状態を上書きしない")
    func staleFailureIsIgnored() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        await hw.setFailing([0.1])
        await hw.setHoldWrites(true)

        model.setDisplay("right", 0.1)
        await waitFor { await hw.waitingCount == 1 }
        model.setDisplay("right", 0.9)
        await hw.setHoldWrites(false)
        await hw.releaseOne()
        await model.waitUntilIdle()

        #expect(model.status == nil)
        #expect(model.displays.first { $0.identity == "right" }?.brightness == 0.9)
        #expect(await hw.writtenLevels("right") == [0.1, 0.9])
    }

    @Test("最新の書き込みが失敗したら明示し、実機の値を読み直す")
    func latestFailureIsReportedAndReread() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        await hw.setFailing([0.25])
        let scansBefore = await hw.scanCount

        model.setDisplay("left", 0.25)
        await model.waitUntilIdle()

        #expect(model.status?.contains("LEFT") == true)
        #expect(await hw.scanCount == scansBefore + 1)
        // 実機は変わっていないので読み直した値に戻る。他の画面には書き込まない。
        #expect(model.displays.first { $0.identity == "left" }?.brightness == 0.8)
        #expect(await hw.writes.count == 1)
    }

    @Test("再走査中に操作した値は走査結果で巻き戻らない")
    func refreshDoesNotClobberUserIntent() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        await hw.setHoldScan(true)
        await hw.setHoldWrites(true)

        let refresh = model.requestRefresh()
        await waitFor { await hw.isScanWaiting }
        model.setDisplay("builtin", 0.95)
        await hw.releaseScan()
        await refresh.value
        #expect(model.displays.first { $0.identity == "builtin" }?.brightness == 0.95)

        await hw.setHoldWrites(false)
        await hw.releaseOne()
        await model.waitUntilIdle()
        #expect(await hw.writtenLevels("builtin") == [0.95])
    }

    @Test("通常キーは全画面に同じ差分を適用し、上限・下限では画面ごとに止める")
    func stepAppliesDeltaWithPerDisplayClamp() async {
        var displays = threeDisplays
        displays[2] = snapshot("left", x: -2500, brightness: 0.98)
        let hw = FakeHardware(displays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()

        model.perform(.step(1))
        let levels = Dictionary(uniqueKeysWithValues: model.displays.map { ($0.identity, $0.brightness) })
        #expect(levels["left"] == 1.0)
        #expect(levels["builtin"] == 0.4625)
        #expect(levels["right"] == 0.6625)
        await model.waitUntilIdle()
        #expect(await hw.writes.count == 3)
    }

    @Test("揃えは Primary の値に他画面だけを書き込む")
    func matchWritesOthersOnly() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        model.perform(.match)
        #expect(model.displays.allSatisfy { $0.brightness == 0.4 })
        await model.waitUntilIdle()
        #expect(await hw.writtenLevels("builtin").isEmpty)
        #expect(await hw.writes.count == 2)
    }

    @Test("制御可能な画面がなければキーを消費せず、操作しても何も書かない")
    func noDisplaysMeansNoSideEffects() async {
        let hw = FakeHardware([])
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        #expect(!model.hasControllableDisplays)
        #expect(model.status == "No controllable displays found.")
        model.perform(.step(1))
        model.perform(.match)
        model.perform(.cyclePrimary(1))
        await model.waitUntilIdle()
        #expect(await hw.writes.isEmpty)
    }

    @Test("切断された画面の未送信値は送らない")
    func pendingWriteForRemovedDisplayIsDropped() async {
        let hw = FakeHardware(threeDisplays)
        let model = BrightnessModel(hardware: hw)
        await model.refresh()
        await hw.setHoldWrites(true)
        model.setDisplay("right", 0.1)
        await waitFor { await hw.waitingCount == 1 }
        model.setDisplay("right", 0.2)
        await hw.setDisplays(threeDisplays.filter { $0.identity != "right" })
        await model.refresh()
        await hw.setHoldWrites(false)
        await hw.releaseOne()
        await model.waitUntilIdle()
        #expect(await hw.writtenLevels("right") == [0.1])
    }
}
