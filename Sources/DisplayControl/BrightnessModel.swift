import Foundation
import Observation

/// モデルが使う画面通信の境界。実機は `DisplayHardware`、テストでは偽装実装を差し込む。
protocol BrightnessHardware: Sendable {
    func scan() async -> [DisplaySnapshot]
    /// 指定画面へ書き込める状態（DDC/CIの最小間隔経過後など）になるまで待つ。
    func waitUntilReady(for identity: String) async
    func setBrightness(_ level: Double, for display: DisplaySnapshot) async throws
}

extension DisplayHardware: BrightnessHardware {}

/// キー入力から確定した操作。
enum KeyAction: Equatable, Sendable {
    /// 全画面に同じ差分を適用する（+1 / -1 段）。
    case step(Int)
    /// Primary を表示順で前後に切り替える（+1 / -1）。
    case cyclePrimary(Int)
    /// 現在の Primary の値に全画面を揃える。
    case match
}

/// メニューとキー操作の状態を MainActor 上で直接保持するモデル。
/// 書き込みは画面ごとに直列化し、未送信の値は最新の1件にまとめる。
@MainActor
@Observable
final class BrightnessModel {
    /// キー1回あたりの変化量（16段バーの1段）。
    static let keyStep = 1.0 / 16.0

    /// 表示順（x、次に y）に並べた接続中の画面。brightness は手元の最新意図値。
    private(set) var displays: [DisplaySnapshot] = []
    /// 実際に使っている Primary。
    private(set) var primaryIdentity: String?
    /// キー入力に権限が必要な状態か。キー監視側が更新する。
    var keyboardNeedsPermission = false

    /// 走査状態などの案内文。
    private var notice: String? = "Reading displays…"
    /// 最新の意図に対して書き込みが失敗した画面（identity → 名前）。
    private var writeFailures: [String: String] = [:]

    /// メニューに出す状態文。書き込み失敗を優先する。
    var status: String? {
        if !writeFailures.isEmpty {
            let names = displays.filter { writeFailures[$0.identity] != nil }.map(\.name)
            let list = names.isEmpty ? Array(writeFailures.values).sorted() : names
            return "Couldn't change brightness on \(list.joined(separator: ", "))."
        }
        return notice
    }

    /// 制御可能な画面があるか。キーを消費するかどうかの判定に使う。
    var hasControllableDisplays: Bool { !displays.isEmpty }

    /// キー操作時の一時表示。アプリ側で HUD に接続する。
    @ObservationIgnored var feedback: (@MainActor (String, Double?) -> Void)?

    @ObservationIgnored private let hardware: any BrightnessHardware
    /// ユーザーが選んだ Primary。切断中も保持し、再接続で復帰させる。
    @ObservationIgnored private var preferredPrimary: String?
    /// 画面ごとの未送信の最新値。
    @ObservationIgnored private var pending: [String: Double] = [:]
    /// 画面ごとの意図の世代。新しい操作のたびに増える。
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// 画面ごとの送信処理。存在する間は送信中とみなす。
    @ObservationIgnored private var workers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?

    init(hardware: any BrightnessHardware) {
        self.hardware = hardware
    }

    var primary: DisplaySnapshot? {
        guard let primaryIdentity else { return nil }
        return displays.first { $0.identity == primaryIdentity }
    }

    // MARK: - 読み取り

    /// 画面を再走査する。読み取りのみで書き込みは行わない。
    func refresh() async {
        await requestRefresh().value
    }

    /// 再走査を開始する。実行中なら終了後にもう一度走査する。
    @discardableResult
    func requestRefresh() -> Task<Void, Never> {
        if let running = refreshTask {
            refreshAgain = true
            return running
        }
        let task = Task { await self.runRefreshLoop() }
        refreshTask = task
        return task
    }

    /// 再接続や wake の直後は画面が落ち着くまで待ってから走査する。連続通知はまとめる。
    func scheduleRefresh(after delay: Duration) {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.scheduledRefresh = nil
            self.requestRefresh()
        }
    }

    private func runRefreshLoop() async {
        repeat {
            refreshAgain = false
            await scanOnce()
        } while refreshAgain
        refreshTask = nil
    }

    private func scanOnce() async {
        if displays.isEmpty { notice = "Reading displays…" }
        let generationsAtStart = generations
        let scanned = await hardware.scan()

        var current: [String: DisplaySnapshot] = [:]
        for display in displays { current[display.identity] = display }

        let merged = scanned.map { snapshot -> DisplaySnapshot in
            let id = snapshot.identity
            // 走査中に操作された画面や送信中の画面は、手元の意図値を優先する。
            let touched = generations[id] != generationsAtStart[id]
                || pending[id] != nil || workers[id] != nil
            if touched, let local = current[id] {
                return snapshot.withBrightness(local.brightness)
            }
            return snapshot
        }
        displays = Self.ordered(merged)

        let present = Set(displays.map(\.identity))
        pending = pending.filter { present.contains($0.key) }
        writeFailures = writeFailures.filter { present.contains($0.key) }
        resolvePrimary()
        notice = displays.isEmpty ? "No controllable displays found." : nil
    }

    /// 表示順は x、次に y。
    nonisolated static func ordered(_ list: [DisplaySnapshot]) -> [DisplaySnapshot] {
        list.sorted { a, b in
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.identity < b.identity
        }
    }

    private func resolvePrimary() {
        let ids = Set(displays.map(\.identity))
        if let preferredPrimary, ids.contains(preferredPrimary) {
            primaryIdentity = preferredPrimary
        } else if let main = displays.first(where: \.isMain) {
            primaryIdentity = main.identity
        } else {
            primaryIdentity = displays.first?.identity
        }
    }

    // MARK: - メニュー操作

    /// Primary を基準にした絶対値を受け取り、その差分を全画面に適用する。
    func setAll(_ level: Double) {
        guard let primary else { return }
        applyDelta(clamp(level) - primary.brightness)
    }

    func setDisplay(_ identity: String, _ level: Double) {
        setLevel(clamp(level), for: identity)
    }

    func selectPrimary(_ identity: String) {
        guard displays.contains(where: { $0.identity == identity }) else { return }
        preferredPrimary = identity
        primaryIdentity = identity
    }

    /// 全画面を Primary の値に揃える。
    func matchToPrimary() {
        guard let primary else { return }
        for display in displays where display.identity != primary.identity {
            setLevel(primary.brightness, for: display.identity)
        }
    }

    // MARK: - キー操作

    func perform(_ action: KeyAction) {
        switch action {
        case .step(let direction):
            guard primary != nil else { return }
            applyDelta(Double(direction) * Self.keyStep)
            feedback?("All Displays", primary?.brightness)
        case .cyclePrimary(let direction):
            guard !displays.isEmpty else { return }
            let index = displays.firstIndex { $0.identity == primaryIdentity } ?? 0
            let count = displays.count
            let next = displays[((index + direction) % count + count) % count]
            selectPrimary(next.identity)
            // 切替は輝度を変えないのでレベルは出さない。
            feedback?(hudTitle(for: next), nil)
        case .match:
            guard let primary else { return }
            matchToPrimary()
            feedback?("Matched to \(hudTitle(for: primary))", primary.brightness)
        }
    }

    /// 同名の画面は DisplayLabel の左右・番号を付けて見分ける。
    private func hudTitle(for display: DisplaySnapshot) -> String {
        let label = DisplayLabel.make(for: display, among: displays)
        return label.detail.map { "\(label.name) (\($0))" } ?? label.name
    }

    // MARK: - 書き込み

    private func applyDelta(_ delta: Double) {
        guard delta != 0 else { return }
        for display in displays {
            setLevel(clamp(display.brightness + delta), for: display.identity)
        }
    }

    private func setLevel(_ level: Double, for identity: String) {
        guard let index = displays.firstIndex(where: { $0.identity == identity }) else { return }
        // 表示は即座に意図値へ。書き込みは別処理でまとめて送る。
        if displays[index].brightness != level {
            displays[index] = displays[index].withBrightness(level)
        }
        generations[identity, default: 0] += 1
        pending[identity] = level
        startWorker(for: identity)
    }

    private func startWorker(for identity: String) {
        guard workers[identity] == nil else { return }
        workers[identity] = Task { await self.drain(identity) }
    }

    /// 1画面分の送信を直列に処理する。書ける状態になるまで待ってから最新の1件だけ送る。
    private func drain(_ identity: String) async {
        var needsReread = false
        while pending[identity] != nil {
            // 切断済みの画面は間隔待ちをせずに未送信値を捨てる。
            guard displays.contains(where: { $0.identity == identity }) else {
                pending.removeValue(forKey: identity)
                break
            }
            // DDCの間隔待ちなどが終わってから送る値を確定させ、待機中の新しい値を反映する。
            await hardware.waitUntilReady(for: identity)
            guard let level = pending.removeValue(forKey: identity) else { break }
            let generation = generations[identity, default: 0]
            // 送信直前の最新スナップショットを使う。切断済みなら捨てる。
            guard let target = displays.first(where: { $0.identity == identity }) else { continue }
            do {
                try await hardware.setBrightness(level, for: target)
                if generations[identity, default: 0] == generation {
                    writeFailures[identity] = nil
                }
            } catch {
                // 新しい操作が既にあれば古い失敗は表示しない。
                if generations[identity, default: 0] == generation, pending[identity] == nil {
                    writeFailures[identity] = target.name
                    needsReread = true
                }
            }
        }
        workers[identity] = nil
        // 最新の意図が失敗したときは実機の値を読み直して表示を正す（読み取りのみ）。
        if needsReread, writeFailures[identity] != nil {
            requestRefresh()
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, (value * 10_000).rounded() / 10_000))
    }

    // MARK: - テスト補助

    /// 送信と再走査がすべて終わるまで待つ。
    func waitUntilIdle() async {
        while true {
            if let worker = workers.values.first {
                await worker.value
            } else if let refreshTask {
                await refreshTask.value
            } else {
                return
            }
        }
    }
}

extension DisplaySnapshot {
    func withBrightness(_ level: Double) -> DisplaySnapshot {
        DisplaySnapshot(
            id: id, identity: identity, name: name, isBuiltIn: isBuiltIn,
            isMain: isMain, x: x, y: y, brightness: level
        )
    }
}
