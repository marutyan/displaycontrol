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

// 画面との通信を一本の直列キューで行うactor。
// I/Oの途中にawaitを置かないので、DDCの要求と応答が他の呼び出しと交錯しない。
// 専用キューを実行器にして、待ち時間のあるI/OでSwiftの共有スレッドやメインスレッドを塞がない。
actor DisplayHardware {
    // 内部で照合済みの制御先。identityをキーに保持する。
    private enum Target {
        case builtIn(displayID: CGDirectDisplayID, attributes: CGAttributes)
        case external(displayID: CGDirectDisplayID, attributes: CGAttributes, channel: ExternalChannel)

        var displayID: CGDirectDisplayID {
            switch self {
            case .builtIn(let id, _), .external(let id, _, _): return id
            }
        }
    }

    // CoreGraphicsが報告する個体情報。書き込み直前の再照合に使う。
    private struct CGAttributes: Equatable {
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

    // 外部画面のDDC経路。サービスはscanごとに作り直し、registryIDで節点の存続を確かめる。
    private final class ExternalChannel {
        let registryID: UInt64
        let service: CFTypeRef
        let edid: EDIDInfo
        var maximum: UInt16
        var lastTransaction: UInt64 = 0

        init(registryID: UInt64, service: CFTypeRef, edid: EDIDInfo, maximum: UInt16) {
            self.registryID = registryID
            self.service = service
            self.edid = edid
            self.maximum = maximum
        }
    }

    private let queue = DispatchSerialQueue(label: "DisplayControl.DisplayHardware", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let av: AVServiceAPI?
    private let displayServices: DisplayServicesAPI?
    private var targets: [String: Target] = [:]
    // 直前のscanで得た値。DDCの一時的な読み取り失敗時、同じ個体・同じ経路のときだけ使う。
    private var lastBrightness: [String: Double] = [:]

    init() {
        av = AVServiceAPI.load()
        displayServices = DisplayServicesAPI.load()
    }

    // 接続中で輝度を読める画面を返す。識別できない画面や読めない画面は含めない。
    func scan() -> [DisplaySnapshot] {
        let onlineIDs = Self.onlineDisplayIDs()
        let previousTargets = targets
        var newTargets: [String: Target] = [:]
        var newBrightness: [String: Double] = [:]
        var snapshots: [DisplaySnapshot] = []

        // 外部画面はEDIDの個体情報で1対1に照合できたものだけ採用する。
        let externalMatches = matchExternalChannels(onlineIDs: onlineIDs)

        for displayID in onlineIDs {
            let attributes = CGAttributes(displayID)
            let bounds = CGDisplayBounds(displayID)
            let isMain = CGDisplayIsMain(displayID) != 0

            if attributes.isBuiltIn {
                guard let displayServices, displayServices.canChange(displayID) else { continue }
                let identity = Self.builtInIdentity(attributes)
                let measured = displayServices.read(displayID)
                let level: Double
                if let measured {
                    level = measured
                } else if let cached = lastBrightness[identity],
                          case .builtIn(let previousID, let previousAttributes)? = previousTargets[identity],
                          previousID == displayID, previousAttributes == attributes {
                    level = cached
                } else {
                    continue
                }
                newTargets[identity] = .builtIn(displayID: displayID, attributes: attributes)
                newBrightness[identity] = level
                snapshots.append(DisplaySnapshot(
                    id: displayID, identity: identity, name: "Built-in Display",
                    isBuiltIn: true, isMain: isMain,
                    x: Double(bounds.origin.x), y: Double(bounds.origin.y), brightness: level))
                continue
            }

            guard let channel = externalMatches[displayID] else { continue }
            let identity = Self.externalIdentity(channel.edid)
            let level: Double
            if let reading = readBrightness(channel) {
                channel.maximum = reading.maximum
                level = Double(reading.current) / Double(reading.maximum)
            } else if let cached = lastBrightness[identity],
                      case .external(let previousID, let previousAttributes, let previousChannel)? = previousTargets[identity],
                      previousID == displayID, previousAttributes == attributes,
                      previousChannel.registryID == channel.registryID {
                // 識別はEDIDで今回確定済み。値だけを同じ経路の直前値で補う。
                channel.maximum = previousChannel.maximum
                level = cached
            } else {
                continue
            }
            newTargets[identity] = .external(displayID: displayID, attributes: attributes, channel: channel)
            newBrightness[identity] = level
            snapshots.append(DisplaySnapshot(
                id: displayID, identity: identity, name: channel.edid.name ?? "External Display",
                isBuiltIn: false, isMain: isMain,
                x: Double(bounds.origin.x), y: Double(bounds.origin.y), brightness: level))
        }

        targets = newTargets
        lastBrightness = newBrightness
        return snapshots
    }

    // 指定画面へ輝度を書き込む。scan時の照合と現在の接続が一致しない場合は書き込まずに拒否する。
    func setBrightness(_ level: Double, for display: DisplaySnapshot) throws {
        guard level.isFinite else { throw DisplayHardwareError.invalidLevel }
        let clamped = min(max(level, 0), 1)
        guard let target = targets[display.identity] else { throw DisplayHardwareError.unknownDisplay }
        guard target.displayID == display.id else { throw DisplayHardwareError.stale }
        guard Self.onlineDisplayIDs().contains(display.id) else {
            invalidate(display.identity)
            throw DisplayHardwareError.disconnected
        }

        switch target {
        case .builtIn(let displayID, let attributes):
            guard CGAttributes(displayID) == attributes else {
                invalidate(display.identity)
                throw DisplayHardwareError.stale
            }
            guard let displayServices else {
                throw DisplayHardwareError.unavailable("DisplayServices is not available on this system.")
            }
            try displayServices.write(Float(clamped), to: displayID)
            lastBrightness[display.identity] = clamped

        case .external(let displayID, let attributes, let channel):
            guard CGAttributes(displayID) == attributes else {
                invalidate(display.identity)
                throw DisplayHardwareError.stale
            }
            guard let av else {
                throw DisplayHardwareError.unavailable("IOAVService is not available on this system.")
            }
            // 経路の節点が消えていれば切断扱い。
            guard Self.registryEntryExists(channel.registryID) else {
                invalidate(display.identity)
                throw DisplayHardwareError.disconnected
            }
            // 差し替え直後の取り違えを防ぐため、書き込み直前にEDIDの個体情報を照合し直す。
            // EDIDを読めないときは個体を確定できないので書き込まない。
            guard let currentEDID = av.copyEDID(channel.service).flatMap(EDIDInfo.init) else {
                throw DisplayHardwareError.communication("Could not verify the display identity.")
            }
            guard currentEDID.sameUnit(as: channel.edid) else {
                invalidate(display.identity)
                throw DisplayHardwareError.stale
            }
            guard channel.maximum > 0 else { throw DisplayHardwareError.stale }
            let value = UInt16((clamped * Double(channel.maximum)).rounded())
            try writeVCP(DDC.brightnessCode, value: value, channel: channel, api: av)
            lastBrightness[display.identity] = Double(value) / Double(channel.maximum)
        }
    }

    private func invalidate(_ identity: String) {
        targets[identity] = nil
        lastBrightness[identity] = nil
    }

    // MARK: - 外部画面の照合

    // DCPAVServiceProxy（Location=External）を列挙し、EDIDのベンダー・製品・シリアルが
    // CoreGraphicsの画面と互いにちょうど1つずつ一致したものだけ返す。
    // 名前や列挙順では決めない。シリアル0や重複は曖昧なので採用しない。
    private func matchExternalChannels(onlineIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: ExternalChannel] {
        guard let av else { return [:] }
        let candidates = onlineIDs.filter { CGDisplayIsBuiltin($0) == 0 }
        guard !candidates.isEmpty else { return [:] }

        var channels: [ExternalChannel] = []
        for node in Self.externalAVNodes() {
            defer { IOObjectRelease(node.entry) }
            guard let service = av.createService(node.entry) else { continue }
            // EDIDは一時的に読めないことがあるので数回試す。読めなければその経路は今回は使わない。
            var edid: EDIDInfo?
            for attempt in 0..<3 {
                if let data = av.copyEDID(service), let parsed = EDIDInfo(data) {
                    edid = parsed
                    break
                }
                if attempt < 2 { usleep(20_000) }
            }
            guard let edid else { continue }
            channels.append(ExternalChannel(registryID: node.registryID, service: service, edid: edid, maximum: 0))
        }

        var result: [CGDirectDisplayID: ExternalChannel] = [:]
        for displayID in candidates {
            let attributes = CGAttributes(displayID)
            guard attributes.serial != 0 else { continue }
            let matchingChannels = channels.filter { Self.edid($0.edid, matches: attributes) }
            guard matchingChannels.count == 1, let channel = matchingChannels.first else { continue }
            // 逆方向も一意であること。同じ個体情報を持つCG画面が複数あれば採用しない。
            let matchingDisplays = candidates.filter { Self.edid(channel.edid, matches: CGAttributes($0)) }
            guard matchingDisplays == [displayID] else { continue }
            result[displayID] = channel
        }
        return result
    }

    private static func edid(_ edid: EDIDInfo, matches attributes: CGAttributes) -> Bool {
        edid.matches(vendor: attributes.vendor, model: attributes.model, serial: attributes.serial)
    }

    private struct AVNode {
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

    // MARK: - DDC/CI

    private func readBrightness(_ channel: ExternalChannel) -> (current: UInt16, maximum: UInt16)? {
        guard let av else { return nil }
        let request = DDC.getVCPRequest(DDC.brightnessCode)
        for attempt in 0..<3 {
            waitForBusIdle(channel)
            let sendStatus = request.withUnsafeBytes {
                av.writeI2C(channel.service, DDC.chipAddress, DDC.hostSubAddress, $0.baseAddress!, UInt32($0.count))
            }
            usleep(DDC.replyDelay)
            var reply = [UInt8](repeating: 0, count: DDC.replyLength)
            let readStatus = reply.withUnsafeMutableBytes {
                av.readI2C(channel.service, DDC.chipAddress, 0, $0.baseAddress!, UInt32($0.count))
            }
            channel.lastTransaction = DispatchTime.now().uptimeNanoseconds
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

    private func writeVCP(_ code: UInt8, value: UInt16, channel: ExternalChannel, api: AVServiceAPI) throws {
        let packet = DDC.setVCPRequest(code, value: value)
        var lastStatus: IOReturn = kIOReturnSuccess
        for attempt in 0..<3 {
            waitForBusIdle(channel)
            lastStatus = packet.withUnsafeBytes {
                api.writeI2C(channel.service, DDC.chipAddress, DDC.hostSubAddress, $0.baseAddress!, UInt32($0.count))
            }
            channel.lastTransaction = DispatchTime.now().uptimeNanoseconds
            if lastStatus == kIOReturnSuccess { return }
            if attempt < 2 { usleep(20_000) }
        }
        throw DisplayHardwareError.communication(String(format: "I2C write failed (0x%08X).", UInt32(bitPattern: lastStatus)))
    }

    // DDC/CIは連続コマンド間に最低50ms空ける必要がある。
    private func waitForBusIdle(_ channel: ExternalChannel) {
        guard channel.lastTransaction != 0 else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- channel.lastTransaction
        let required = UInt64(DDC.commandInterval) * 1_000
        if elapsed < required { usleep(useconds_t((required - elapsed) / 1_000)) }
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
private struct AVServiceAPI {
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
private struct DisplayServicesAPI {
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
