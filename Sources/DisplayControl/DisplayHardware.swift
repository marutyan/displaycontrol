import CoreGraphics
import Darwin
import Dispatch
import Foundation
import IOKit

// 画面1台分の読み取り結果。UI・モデル側との共有契約。
// 座標はCoreGraphicsのグローバル座標（主画面の左上が原点）。brightnessは0...1。
struct DisplaySnapshot: Identifiable, Sendable {
    let id: UInt32
    let identity: String
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    let x: Double
    let y: Double
    let brightness: Double
}

// ユーザーに見える可能性があるため、説明文は英語にする。
enum DisplayHardwareError: Error, LocalizedError, Sendable {
    case invalidLevel
    case unknownDisplay
    case disconnected
    case stale
    case unavailable(String)
    case communication(String)

    var errorDescription: String? {
        switch self {
        case .invalidLevel:
            return "The requested brightness is not a valid number."
        case .unknownDisplay:
            return "This display is not controllable. Rescan displays and try again."
        case .disconnected:
            return "The display is no longer connected."
        case .stale:
            return "The display configuration changed. Rescan displays and try again."
        case .unavailable(let detail):
            return "Brightness control is unavailable: \(detail)"
        case .communication(let detail):
            return "The display did not accept the brightness command: \(detail)"
        }
    }
}

// 画面ごとの直列レーンを管理し、走査と書き込みの振り分けを行うactor。
// ブロッキングI/Oや待機はこのactor上で行わず、画面ごとの専用キューへ委譲して互いに待たせない。
actor DisplayHardware {
    // 内部で照合済みの制御先。identityをキーに対応するDisplayLaneが保持する。
    private enum Target: Sendable {
        case builtIn(displayID: CGDirectDisplayID, attributes: CGAttributes)
        case external(displayID: CGDirectDisplayID, attributes: CGAttributes, channel: ExternalChannel)

        var displayID: CGDirectDisplayID {
            switch self {
            case .builtIn(let id, _), .external(let id, _, _): return id
            }
        }
    }

    // CoreGraphicsが報告する個体情報。書き込み直前の再照合に使う。
    private struct CGAttributes: Equatable, Sendable {
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let isBuiltIn: Bool

        init(_ id: CGDirectDisplayID) {
            vendor = CGDisplayVendorNumber(id)
            model = CGDisplayModelNumber(id)
            serial = CGDisplaySerialNumber(id)
            isBuiltIn = CGDisplayIsBuiltin(id) != 0
        }
    }

    // IOAVServiceの参照を保持するラッパ。生成後は対応する1つのDisplayLaneの直列キュー内だけで使用する。
    private final class ServiceHandle: @unchecked Sendable {
        let raw: CFTypeRef

        init(_ raw: CFTypeRef) {
            self.raw = raw
        }
    }

    // 外部画面のDDC経路。サービスはscanごとに作り直し、registryIDで節点の存続を確かめる。
    private struct ExternalChannel: Sendable {
        let registryID: UInt64
        let service: ServiceHandle
        let edid: EDIDInfo
        let maximum: UInt16
    }

    // 走査時にCoreGraphicsから取得した画面1台分の属性と配置。
    private struct DisplayEntry: Sendable {
        let index: Int
        let displayID: CGDirectDisplayID
        let attributes: CGAttributes
        let x: Double
        let y: Double
        let isMain: Bool
    }

    // 外部AVノードからEDIDを読み取れた照合候補。双方向の一意照合を経てDisplayLaneへ渡す。
    private struct ExternalProbe: Sendable {
        let registryID: UInt64
        let service: ServiceHandle
        let edid: EDIDInfo
    }

    // 画面1台分の通信と照合状態を専用の直列キューで隔離するactor。
    // 同一画面の読み取り・書き込み・EDID照合を重ならないように直列化し、他画面の通信を止めない。
    private actor DisplayLane {
        private let queue: DispatchSerialQueue
        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

        private var target: Target?
        // 直前のscanまたは書き込みで得た値。DDCの一時的な読み取り失敗時、同じ個体・同じ経路のときだけ使う。
        private var lastBrightness: Double?
        // 同じ外部画面へのDDCコマンド（読み取り・書き込み共通）の最終完了時刻（uptimeNanoseconds）。
        private var lastTransaction: UInt64 = 0

        init(queueLabel: String) {
            queue = DispatchSerialQueue(label: queueLabel, qos: .userInitiated)
        }

        // 既知の外部ポートに対するEDID読み取りを、この画面の直列キュー上で実行する。
        func probeExternalNode(_ node: AVNode, av: AVServiceAPI) -> ExternalProbe? {
            DisplayHardware.readExternalProbe(node, av: av)
        }

        // 内蔵画面の現在値を読み取り、読めた場合または同一画面の直前値で補えた場合だけ制御先を更新する。
        func scanBuiltIn(
            entry: DisplayEntry,
            identity: String,
            displayServices: DisplayServicesAPI
        ) -> DisplaySnapshot? {
            guard displayServices.canChange(entry.displayID) else {
                clearTarget()
                return nil
            }
            let level: Double
            if let measured = displayServices.read(entry.displayID) {
                level = measured
            } else if let cached = lastBrightness,
                      case .builtIn(let previousID, let previousAttributes)? = target,
                      previousID == entry.displayID,
                      previousAttributes == entry.attributes,
                      DisplayHardware.onlineDisplayIDs().contains(entry.displayID),
                      CGAttributes(entry.displayID) == entry.attributes {
                level = cached
            } else {
                clearTarget()
                return nil
            }
            target = .builtIn(displayID: entry.displayID, attributes: entry.attributes)
            lastBrightness = level
            return DisplaySnapshot(
                id: entry.displayID, identity: identity, name: "Built-in Display",
                isBuiltIn: true, isMain: entry.isMain,
                x: entry.x, y: entry.y, brightness: level)
        }

        // 外部画面の現在値を読み取り、読めた場合または同一経路の直前値で補えた場合だけ制御先を更新する。
        func scanExternal(
            entry: DisplayEntry,
            identity: String,
            probe: ExternalProbe,
            av: AVServiceAPI
        ) -> DisplaySnapshot? {
            let maximum: UInt16
            let level: Double
            if let reading = readBrightness(service: probe.service, av: av) {
                maximum = reading.maximum
                level = Double(reading.current) / Double(reading.maximum)
            } else if let cached = lastBrightness,
                      case .external(let previousID, let previousAttributes, let previousChannel)? = target,
                      previousID == entry.displayID,
                      previousAttributes == entry.attributes,
                      previousChannel.registryID == probe.registryID,
                      DisplayHardware.onlineDisplayIDs().contains(entry.displayID),
                      DisplayHardware.registryEntryExists(probe.registryID) {
                // 識別はEDIDで今回確定済み。値だけを同じ経路の直前値で補う。
                maximum = previousChannel.maximum
                level = cached
            } else {
                clearTarget()
                return nil
            }
            let channel = ExternalChannel(
                registryID: probe.registryID,
                service: probe.service,
                edid: probe.edid,
                maximum: maximum)
            target = .external(displayID: entry.displayID, attributes: entry.attributes, channel: channel)
            lastBrightness = level
            return DisplaySnapshot(
                id: entry.displayID, identity: identity, name: probe.edid.name ?? "External Display",
                isBuiltIn: false, isMain: entry.isMain,
                x: entry.x, y: entry.y, brightness: level)
        }

        // 制御先と直前値を破棄する。再接続直後の間隔保護のためlastTransactionは保持する。
        func clearTarget() {
            target = nil
            lastBrightness = nil
        }

        // 次のDDC書き込みまで必要な残り待ち時間（ナノ秒）を返す。外部画面以外は待機不要。
        func remainingBusWaitNanoseconds() -> UInt64 {
            guard case .external = target else { return 0 }
            return DDC.remainingCommandWaitNanoseconds(
                since: lastTransaction, now: DispatchTime.now().uptimeNanoseconds)
        }

        // この画面へ輝度を書き込む。照合から送信まで同一キューで不可分に実行し、不一致なら書き込まずに拒否する。
        func setBrightness(
            _ level: Double,
            for display: DisplaySnapshot,
            av: AVServiceAPI?,
            displayServices: DisplayServicesAPI?
        ) throws {
            guard level.isFinite else { throw DisplayHardwareError.invalidLevel }
            let clamped = min(max(level, 0), 1)
            guard let target else { throw DisplayHardwareError.unknownDisplay }
            guard target.displayID == display.id else { throw DisplayHardwareError.stale }
            guard DisplayHardware.onlineDisplayIDs().contains(display.id) else {
                clearTarget()
                throw DisplayHardwareError.disconnected
            }

            switch target {
            case .builtIn(let displayID, let attributes):
                guard CGAttributes(displayID) == attributes else {
                    clearTarget()
                    throw DisplayHardwareError.stale
                }
                guard let displayServices else {
                    throw DisplayHardwareError.unavailable("DisplayServices is not available on this system.")
                }
                try displayServices.write(Float(clamped), to: displayID)
                lastBrightness = clamped

            case .external(let displayID, let attributes, let channel):
                guard CGAttributes(displayID) == attributes else {
                    clearTarget()
                    throw DisplayHardwareError.stale
                }
                guard let av else {
                    throw DisplayHardwareError.unavailable("IOAVService is not available on this system.")
                }
                // 経路の節点が消えていれば切断扱い。
                guard DisplayHardware.registryEntryExists(channel.registryID) else {
                    clearTarget()
                    throw DisplayHardwareError.disconnected
                }
                // 差し替え直後の取り違えを防ぐため、書き込み直前にEDIDの個体情報を照合し直す。
                // EDIDを読めないときは個体を確定できないので書き込まない。
                guard let currentEDID = av.copyEDID(channel.service.raw).flatMap(EDIDInfo.init) else {
                    throw DisplayHardwareError.communication("Could not verify the display identity.")
                }
                guard currentEDID.sameUnit(as: channel.edid) else {
                    clearTarget()
                    throw DisplayHardwareError.stale
                }
                guard channel.maximum > 0 else { throw DisplayHardwareError.stale }
                let value = UInt16((clamped * Double(channel.maximum)).rounded())
                try writeVCP(DDC.brightnessCode, value: value, channel: channel, api: av)
                lastBrightness = Double(value) / Double(channel.maximum)
            }
        }

        // 外部画面の現在輝度をDDC/CIで読み取る。失敗時は最大3回試す。
        private func readBrightness(service: ServiceHandle, av: AVServiceAPI) -> (current: UInt16, maximum: UInt16)? {
            let request = DDC.getVCPRequest(DDC.brightnessCode)
            for attempt in 0..<3 {
                waitForBusIdle()
                let sendStatus = request.withUnsafeBytes {
                    av.writeI2C(service.raw, DDC.chipAddress, DDC.hostSubAddress, $0.baseAddress!, UInt32($0.count))
                }
                usleep(DDC.replyDelay)
                var reply = [UInt8](repeating: 0, count: DDC.replyLength)
                let readStatus = reply.withUnsafeMutableBytes {
                    av.readI2C(service.raw, DDC.chipAddress, 0, $0.baseAddress!, UInt32($0.count))
                }
                lastTransaction = DispatchTime.now().uptimeNanoseconds
                if sendStatus == kIOReturnSuccess, readStatus == kIOReturnSuccess,
                   case .value(let current, let maximum)? = DDC.parseVCPReply(reply, code: DDC.brightnessCode) {
                    return (current, maximum)
                }
                // 「未対応」の正しい応答は再試行しても変わらない。
                if case .unsupported? = DDC.parseVCPReply(reply, code: DDC.brightnessCode) { return nil }
                if attempt < 2 { usleep(20_000) }
            }
            return nil
        }

        // 外部画面へVCP設定コマンドを送信する。失敗時は最大3回試す。
        private func writeVCP(_ code: UInt8, value: UInt16, channel: ExternalChannel, api: AVServiceAPI) throws {
            let packet = DDC.setVCPRequest(code, value: value)
            var lastStatus: IOReturn = kIOReturnSuccess
            for attempt in 0..<3 {
                waitForBusIdle()
                lastStatus = packet.withUnsafeBytes {
                    api.writeI2C(channel.service.raw, DDC.chipAddress, DDC.hostSubAddress, $0.baseAddress!, UInt32($0.count))
                }
                lastTransaction = DispatchTime.now().uptimeNanoseconds
                if lastStatus == kIOReturnSuccess { return }
                if attempt < 2 { usleep(20_000) }
            }
            throw DisplayHardwareError.communication(String(format: "I2C write failed (0x%08X).", UInt32(bitPattern: lastStatus)))
        }

        // DDC/CIは連続コマンド間に最低50ms空ける必要がある。
        private func waitForBusIdle() {
            while true {
                let remaining = DDC.remainingCommandWaitNanoseconds(
                    since: lastTransaction, now: DispatchTime.now().uptimeNanoseconds)
                guard remaining > 0 else { return }
                // 端数を切り上げてマイクロ秒へ変換し、規定間隔を下回らないようにする。
                let microseconds = (remaining + 999) / 1_000
                usleep(useconds_t(min(microseconds, UInt64(useconds_t.max))))
            }
        }
    }

    // 画面一覧とIORegistryの列挙を行う専用キュー。協調スレッドプールや画面ごとのキューを塞がない。
    private let scanQueue = DispatchQueue(label: "DisplayControl.DisplayHardware.scan", qos: .userInitiated)
    private let av: AVServiceAPI?
    private let displayServices: DisplayServicesAPI?
    // identityごとの専用直列レーン。
    private var lanes: [String: DisplayLane] = [:]
    // 直前のscanで判明した外部ポート（registryID）と担当レーンの対応。同一ポートのEDID読み取りと書き込みを直列化する。
    private var registryLanes: [UInt64: DisplayLane] = [:]
    // レーンのキュー名に生のidentity（シリアル等）を出さないための連番。
    private var nextLaneNumber = 0
    // scan()の多重実行を順番に並べるための状態。
    private var isScanning = false
    private var scanWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        av = AVServiceAPI.load()
        displayServices = DisplayServicesAPI.load()
    }

    // 接続中で輝度を読める画面を返す。識別できない画面や読めない画面は含めない。
    // 同時に呼ばれた場合は前の走査が終わってから実行し、走査中でも他画面の書き込みを止めない。
    func scan() async -> [DisplaySnapshot] {
        await beginScan()
        defer { endScan() }
        return await performScan()
    }

    // 指定画面へすぐ書き込める状態（DDC/CIの最小間隔経過後）になるまで非同期に待つ。
    // 待機中はレーンの専用キューを占有しないため、他画面や走査を止めない。
    func waitUntilReady(for identity: String) async {
        while !Task.isCancelled {
            guard let lane = lanes[identity] else { return }
            let remaining = await lane.remainingBusWaitNanoseconds()
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .nanoseconds(remaining), clock: .suspending)
        }
    }

    // 指定画面へ輝度を書き込む。scan時の照合と現在の接続が一致しない場合は書き込まずに拒否する。
    func setBrightness(_ level: Double, for display: DisplaySnapshot) async throws {
        guard level.isFinite else { throw DisplayHardwareError.invalidLevel }
        guard let lane = lanes[display.identity] else { throw DisplayHardwareError.unknownDisplay }
        try await lane.setBrightness(level, for: display, av: av, displayServices: displayServices)
    }

    // MARK: - 走査の調整

    // 走査の排他制御に入る。別の走査が実行中なら順番が来るまで待つ。
    private func beginScan() async {
        if isScanning {
            await withCheckedContinuation { scanWaiters.append($0) }
        }
        isScanning = true
    }

    // 走査の排他制御を終え、待機中の次の走査があれば起こす。
    private func endScan() {
        if !scanWaiters.isEmpty {
            scanWaiters.removeFirst().resume()
        } else {
            isScanning = false
        }
    }

    // identityに対応するレーンを返す。無ければ新しい直列キュー付きレーンを作る。
    private func lane(for identity: String) -> DisplayLane {
        if let existing = lanes[identity] { return existing }
        nextLaneNumber += 1
        let created = DisplayLane(queueLabel: "DisplayControl.DisplayLane.\(nextLaneNumber)")
        lanes[identity] = created
        return created
    }

    // 画面一覧の取得・EDID照合・各画面の現在値読み取りを、画面ごとのレーンへ分散して実行する。
    private func performScan() async -> [DisplaySnapshot] {
        let av = self.av
        let displayServices = self.displayServices
        let snapshotInput = await runOnScanQueue {
            let onlineIDs = Self.onlineDisplayIDs()
            let entries = onlineIDs.enumerated().map { index, displayID in
                let attributes = CGAttributes(displayID)
                let bounds = CGDisplayBounds(displayID)
                let isMain = CGDisplayIsMain(displayID) != 0
                return DisplayEntry(
                    index: index, displayID: displayID, attributes: attributes,
                    x: Double(bounds.origin.x), y: Double(bounds.origin.y), isMain: isMain)
            }
            let hasExternal = entries.contains { !$0.attributes.isBuiltIn }
            let nodes = (av != nil && hasExternal) ? Self.externalAVNodes() : []
            return (entries: entries, nodes: nodes)
        }

        // 各外部ノードのEDID読み取りを並列に進める。既知ポートは対応レーンで直列化する。
        let probes: [ExternalProbe]
        if let av, !snapshotInput.nodes.isEmpty {
            let knownLanes = registryLanes
            probes = await withTaskGroup(of: ExternalProbe?.self) { group in
                for node in snapshotInput.nodes {
                    let knownLane = knownLanes[node.registryID]
                    group.addTask {
                        if let knownLane {
                            return await knownLane.probeExternalNode(node, av: av)
                        }
                        return await Self.probeDetachedExternalNode(node, av: av)
                    }
                }
                var collected: [ExternalProbe] = []
                for await probe in group {
                    if let probe { collected.append(probe) }
                }
                return collected
            }
        } else {
            probes = []
        }

        // 外部画面はEDIDの個体情報で1対1に照合できたものだけ採用する。
        let externalMatches = Self.matchExternalProbes(entries: snapshotInput.entries, probes: probes)

        // 走査結果から確定した画面ごとの読み取り・更新計画。
        enum LanePlan: Sendable {
            case builtIn(entry: DisplayEntry, identity: String, lane: DisplayLane)
            case external(entry: DisplayEntry, identity: String, probe: ExternalProbe, lane: DisplayLane)
        }

        var plans: [LanePlan] = []
        var activeIdentities: Set<String> = []
        for entry in snapshotInput.entries {
            if entry.attributes.isBuiltIn {
                guard displayServices != nil else { continue }
                let identity = Self.builtInIdentity(entry.attributes)
                activeIdentities.insert(identity)
                plans.append(.builtIn(entry: entry, identity: identity, lane: lane(for: identity)))
            } else if let probe = externalMatches[entry.displayID] {
                let identity = Self.externalIdentity(probe.edid)
                activeIdentities.insert(identity)
                plans.append(.external(entry: entry, identity: identity, probe: probe, lane: lane(for: identity)))
            }
        }

        let inactiveLanes = lanes.filter { !activeIdentities.contains($0.key) }.map(\.value)

        // 外部ポートの担当レーンが変わった場合（ケーブルの差し替え等）は、新レーンが読む前に旧レーンの参照を外す。
        var reassignedLanes: [DisplayLane] = []
        for plan in plans {
            if case .external(_, _, let probe, let targetLane) = plan,
               let previousLane = registryLanes[probe.registryID],
               previousLane !== targetLane {
                reassignedLanes.append(previousLane)
            }
        }
        if !reassignedLanes.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for previousLane in reassignedLanes {
                    group.addTask { await previousLane.clearTarget() }
                }
            }
        }

        // 画面ごとの走査結果。元のonlineIDs順へ並べ直すためのインデックスを保持する。
        struct ScanOutcome: Sendable {
            let index: Int
            let snapshot: DisplaySnapshot?
            let registryMapping: (UInt64, DisplayLane)?
        }

        let outcomes = await withTaskGroup(of: ScanOutcome?.self) { group in
            for inactiveLane in inactiveLanes {
                group.addTask {
                    await inactiveLane.clearTarget()
                    return nil
                }
            }
            for plan in plans {
                group.addTask {
                    switch plan {
                    case .builtIn(let entry, let identity, let targetLane):
                        guard let displayServices else { return nil }
                        let snapshot = await targetLane.scanBuiltIn(
                            entry: entry, identity: identity, displayServices: displayServices)
                        return ScanOutcome(index: entry.index, snapshot: snapshot, registryMapping: nil)
                    case .external(let entry, let identity, let probe, let targetLane):
                        guard let av else { return nil }
                        let snapshot = await targetLane.scanExternal(
                            entry: entry, identity: identity, probe: probe, av: av)
                        let mapping = snapshot != nil ? (probe.registryID, targetLane) : nil
                        return ScanOutcome(index: entry.index, snapshot: snapshot, registryMapping: mapping)
                    }
                }
            }

            var collected: [ScanOutcome] = []
            for await outcome in group {
                if let outcome { collected.append(outcome) }
            }
            return collected
        }

        var newRegistryLanes: [UInt64: DisplayLane] = [:]
        for outcome in outcomes {
            if let (registryID, mappedLane) = outcome.registryMapping {
                newRegistryLanes[registryID] = mappedLane
            }
        }
        registryLanes = newRegistryLanes

        return outcomes
            .sorted { $0.index < $1.index }
            .compactMap(\.snapshot)
    }

    // ブロッキングになり得るIOKit/CGの列挙を専用キュー上で実行し、協調スレッドプールを塞がない。
    nonisolated private func runOnScanQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let queue = scanQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - 外部画面の照合

    // まだレーンに紐づいていない外部ノードのEDID読み取りを、協調スレッドプール外で実行する。
    private static func probeDetachedExternalNode(_ node: AVNode, av: AVServiceAPI) async -> ExternalProbe? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readExternalProbe(node, av: av))
            }
        }
    }

    // 外部AVノードからサービスを生成し、EDIDを最大3回試して読み取る。ノード参照は必ず解放する。
    private static func readExternalProbe(_ node: AVNode, av: AVServiceAPI) -> ExternalProbe? {
        defer { IOObjectRelease(node.entry) }
        guard let service = av.createService(node.entry) else { return nil }
        // EDIDは一時的に読めないことがあるので数回試す。読めなければその経路は今回は使わない。
        var edid: EDIDInfo?
        for attempt in 0..<3 {
            if let data = av.copyEDID(service), let parsed = EDIDInfo(data) {
                edid = parsed
                break
            }
            if attempt < 2 { usleep(20_000) }
        }
        guard let edid else { return nil }
        return ExternalProbe(registryID: node.registryID, service: ServiceHandle(service), edid: edid)
    }

    // EDIDのベンダー・製品・シリアルがCoreGraphicsの画面と互いにちょうど1つずつ一致したものだけ返す。
    // 名前や列挙順では決めない。シリアル0や重複は曖昧なので採用しない。
    private static func matchExternalProbes(
        entries: [DisplayEntry],
        probes: [ExternalProbe]
    ) -> [CGDirectDisplayID: ExternalProbe] {
        let candidates = entries.filter { !$0.attributes.isBuiltIn }
        guard !candidates.isEmpty, !probes.isEmpty else { return [:] }

        var result: [CGDirectDisplayID: ExternalProbe] = [:]
        for candidate in candidates {
            guard candidate.attributes.serial != 0 else { continue }
            let matchingProbes = probes.filter { edid($0.edid, matches: candidate.attributes) }
            guard matchingProbes.count == 1, let probe = matchingProbes.first else { continue }
            // 逆方向も一意であること。同じ個体情報を持つCG画面が複数あれば採用しない。
            let matchingDisplays = candidates.filter { edid(probe.edid, matches: $0.attributes) }
            guard matchingDisplays.count == 1, matchingDisplays[0].displayID == candidate.displayID else { continue }
            result[candidate.displayID] = probe
        }
        return result
    }

    private static func edid(_ edid: EDIDInfo, matches attributes: CGAttributes) -> Bool {
        edid.matches(vendor: attributes.vendor, model: attributes.model, serial: attributes.serial)
    }

    private struct AVNode: Sendable {
        let entry: io_registry_entry_t
        let registryID: UInt64
    }

    private static func externalAVNodes() -> [AVNode] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("DCPAVServiceProxy"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var nodes: [AVNode] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            var registryID: UInt64 = 0
            guard location == "External",
                  IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }
            nodes.append(AVNode(entry: entry, registryID: registryID))
        }
        return nodes
    }

    private static func registryEntryExists(_ registryID: UInt64) -> Bool {
        guard let matching = IORegistryEntryIDMatching(registryID) else { return false }
        // IOServiceGetMatchingServiceはmatchingの参照を消費する。
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return false }
        IOObjectRelease(entry)
        return true
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func builtInIdentity(_ attributes: CGAttributes) -> String {
        "builtin:" + String(format: "%04X-%04X-%08X", attributes.vendor, attributes.model, attributes.serial)
    }

    private static func externalIdentity(_ edid: EDIDInfo) -> String {
        "edid:" + edid.manufacturerID + String(format: "-%04X-%08X", edid.productCode, edid.serial)
    }
}

// MARK: - DDC/CIのパケット

// 純粋関数のみ。テストから直接検証できるようにactorの外へ置く。
enum DDC {
    static let brightnessCode: UInt8 = 0x10
    // IOAVServiceに渡す7bitのチップアドレス（8bit表記で0x6E）とホスト側サブアドレス0x51。
    static let chipAddress: UInt32 = 0x37
    static let hostSubAddress: UInt32 = 0x51
    static let destinationAddress: UInt8 = 0x6E
    static let replyLength = 11
    static let replyDelay: useconds_t = 50_000
    static let commandInterval: useconds_t = 50_000

    enum Reply: Equatable {
        case value(current: UInt16, maximum: UInt16)
        case unsupported
    }

    // Get VCP（0x01）。実機（Dell S2725QC 2台）で検証済みの形をそのまま使う:
    // 82 01 <code> <0x6E ^ 82 ^ 01 ^ code>
    static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [body.reduce(destinationAddress, ^)]
    }

    // Set VCP（0x03）。DDC/CIの規定どおり、チェックサムは宛先0x6E・送信元0x51と全バイトのXOR:
    // 84 03 <code> <high> <low> <0x6E ^ 0x51 ^ 84 ^ 03 ^ code ^ high ^ low>
    static func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [body.reduce(destinationAddress ^ UInt8(hostSubAddress), ^)]
    }

    // VCP応答の検証。形式・項目コード・チェックサム・値の範囲のいずれかが不正ならnil。
    // 応答: 6E 88 02 <result> <code> <type> <maxH> <maxL> <curH> <curL> <checksum>
    // チェックサムは0x50（ホストの仮想アドレス）と全バイトのXORが0になること。
    static func parseVCPReply(_ reply: [UInt8], code: UInt8) -> Reply? {
        guard reply.count == replyLength,
              reply[0] == destinationAddress,
              reply[1] == 0x88,
              reply[2] == 0x02,
              reply[4] == code,
              reply.reduce(0x50, ^) == 0 else { return nil }
        guard reply[3] == 0 else { return reply[3] == 1 ? .unsupported : nil }
        let maximum = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return .value(current: current, maximum: maximum)
    }

    // 前回のDDC通信完了時刻から、次のコマンドを送るまでに必要な残り待ち時間（ナノ秒）を返す。
    // 初回（0）は待たず、時刻が逆転した場合は安全側として規定間隔ぶん待つ。
    static func remainingCommandWaitNanoseconds(since lastTransaction: UInt64, now: UInt64) -> UInt64 {
        guard lastTransaction != 0 else { return 0 }
        let required = UInt64(commandInterval) * 1_000
        guard now >= lastTransaction else { return required }
        let elapsed = now - lastTransaction
        return elapsed < required ? required - elapsed : 0
    }
}

// MARK: - EDID

struct EDIDInfo: Equatable, Sendable {
    let manufacturerID: String
    let vendorNumber: UInt32
    let productCode: UInt32
    let serial: UInt32
    let name: String?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        // 基本ブロック128バイト、固定ヘッダ、ブロックのチェックサムを確認する。
        guard bytes.count >= 128,
              bytes[0..<8].elementsEqual([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]),
              bytes[0..<128].reduce(UInt8(0), &+) == 0 else { return nil }
        let vendor = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        vendorNumber = UInt32(vendor)
        let letters = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F].map { value -> Character in
            (1...26).contains(value) ? Character(UnicodeScalar(UInt8(value) + 0x40)) : "?"
        }
        manufacturerID = String(letters)
        productCode = UInt32(bytes[10]) | (UInt32(bytes[11]) << 8)
        serial = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) | (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)
        // 表示名は記述子0xFC（モニター名）から取る。
        name = stride(from: 54, through: 108, by: 18).lazy.compactMap { base -> String? in
            guard bytes[base..<base + 4].elementsEqual([0, 0, 0, 0xFC]) else { return nil }
            let text = String(decoding: bytes[base + 5..<base + 18].prefix { $0 != 0x0A }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.first
    }

    // CoreGraphicsの個体情報（ベンダー・モデル・シリアル）と一致するか。シリアル0は一致とみなさない。
    func matches(vendor: UInt32, model: UInt32, serial cgSerial: UInt32) -> Bool {
        serial != 0 && vendorNumber == vendor && productCode == model && serial == cgSerial
    }

    // 個体として同一か。表示名は比較に使わない。
    func sameUnit(as other: EDIDInfo) -> Bool {
        vendorNumber == other.vendorNumber && productCode == other.productCode && serial == other.serial && serial != 0
    }
}

// MARK: - 非公開APIの動的読み込み

// IOAVService（Apple Silicon の外部画面DDC経路）。シンボルが無い環境ではnilになり、外部画面は対象外になる。
private struct AVServiceAPI: Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias CopyEDIDFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> IOReturn
    private typealias WriteFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn
    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let create: CreateFn
    private let copyEDIDFn: CopyEDIDFn
    private let write: WriteFn
    private let read: ReadFn

    static func load() -> AVServiceAPI? {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let copyEDID = dlsym(handle, "IOAVServiceCopyEDID"),
              let write = dlsym(handle, "IOAVServiceWriteI2C"),
              let read = dlsym(handle, "IOAVServiceReadI2C") else { return nil }
        return AVServiceAPI(
            create: unsafeBitCast(create, to: CreateFn.self),
            copyEDIDFn: unsafeBitCast(copyEDID, to: CopyEDIDFn.self),
            write: unsafeBitCast(write, to: WriteFn.self),
            read: unsafeBitCast(read, to: ReadFn.self))
    }

    // 戻り値は作成規則（+1）なのでtakeRetainedValueで所有権を受け取る。
    func createService(_ entry: io_service_t) -> CFTypeRef? {
        guard let raw = create(kCFAllocatorDefault, entry) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeRetainedValue()
    }

    func copyEDID(_ service: CFTypeRef) -> Data? {
        var raw: UnsafeMutableRawPointer?
        let status = copyEDIDFn(Unmanaged.passUnretained(service).toOpaque(), &raw)
        guard let raw else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeRetainedValue() as Data
        return status == kIOReturnSuccess ? data : nil
    }

    func writeI2C(_ service: CFTypeRef, _ address: UInt32, _ subAddress: UInt32, _ bytes: UnsafeRawPointer, _ count: UInt32) -> IOReturn {
        write(Unmanaged.passUnretained(service).toOpaque(), address, subAddress, bytes, count)
    }

    func readI2C(_ service: CFTypeRef, _ address: UInt32, _ offset: UInt32, _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> IOReturn {
        read(Unmanaged.passUnretained(service).toOpaque(), address, offset, bytes, count)
    }
}

// DisplayServices（内蔵画面の輝度）。フレームワークが無い環境ではnilになり、内蔵画面は対象外になる。
private struct DisplayServicesAPI: Sendable {
    private typealias CanChangeFn = @convention(c) (UInt32) -> Bool
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private let canChangeFn: CanChangeFn?
    private let get: GetFn
    private let set: SetFn

    static func load() -> DisplayServicesAPI? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return DisplayServicesAPI(
            canChangeFn: dlsym(handle, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeFn.self) },
            get: unsafeBitCast(get, to: GetFn.self),
            set: unsafeBitCast(set, to: SetFn.self))
    }

    // 判定関数が無い環境では、実際に読めるかどうかで判断する。
    func canChange(_ displayID: CGDirectDisplayID) -> Bool {
        canChangeFn?(displayID) ?? true
    }

    // 戻り値0（成功）かつ0...1の有限値だけを受け入れる。わずかな丸め誤差は範囲内へ収める。
    func read(_ displayID: CGDirectDisplayID) -> Double? {
        var value: Float = -1
        guard get(displayID, &value) == 0, value.isFinite, value >= -0.001, value <= 1.001 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    func write(_ level: Float, to displayID: CGDirectDisplayID) throws {
        guard level.isFinite, (0...1).contains(level) else { throw DisplayHardwareError.invalidLevel }
        let status = set(displayID, level)
        guard status == 0 else {
            throw DisplayHardwareError.communication("DisplayServices returned \(status).")
        }
    }
}
