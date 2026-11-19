import SwiftUI

// メニューバーから開くパネル。一括・各画面の輝度、Primaryの選択、揃え直し、終了を並べる。
// 値はすべて呼び出し側のモデルが持ち、このViewは表示と操作の通知だけを行う。
@MainActor
struct BrightnessPanel: View {
    let displays: [DisplaySnapshot]
    let primaryIdentity: String?
    let status: String?
    let keyboardNeedsPermission: Bool
    let onSetAll: (Double) -> Void
    let onSetDisplay: (String, Double) -> Void
    let onSelectPrimary: (String) -> Void
    let onMatch: () -> Void
    let onEnableKeyboard: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if displays.isEmpty {
                Text("No adjustable displays found")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
            } else {
                if showsAllDisplays {
                    allDisplaysSection
                    PanelSeparator()
                }
                ForEach(displays) { display in
                    displaySection(display)
                }
            }

            if let status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            PanelSeparator()
            if showsAllDisplays {
                MenuRowButton(title: "Match All to Primary", action: onMatch)
                    .disabled(isMatched)
                    .accessibilityHint("Sets every display to the Primary display's brightness")
            }
            if keyboardNeedsPermission {
                MenuRowButton(title: "Enable Brightness Keys…", action: onEnableKeyboard)
                    .accessibilityHint("Brightness keys need Accessibility access")
            }
            if showsAllDisplays || keyboardNeedsPermission {
                PanelSeparator()
            }
            MenuRowButton(title: "Quit DisplayControl", shortcut: "⌘Q", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
        .frame(width: 300)
    }

    // MARK: - 一括

    private var allDisplaysSection: some View {
        let level = primaryDisplay?.brightness ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("All Displays").fontWeight(.semibold)
                Spacer(minLength: 4)
                PercentText(level: level)
            }
            .frame(height: 24)
            .accessibilityHidden(true)

            LevelSlider(
                accessibilityLabel: "All Displays",
                accessibilityHint: primaryDisplay.map { "Follows \(label(for: $0).accessibilityText); changes every display by the same amount" },
                level: level,
                onChange: onSetAll
            )
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }

    // MARK: - 各画面

    private func displaySection(_ display: DisplaySnapshot) -> some View {
        let isPrimary = display.identity == resolvedPrimaryIdentity
        let label = label(for: display)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                onSelectPrimary(display.identity)
            } label: {
                DisplayHeader(display: display, label: label, isPrimary: isPrimary)
            }
            .buttonStyle(HoverRowButtonStyle())
            .help(isPrimary ? "Primary display" : "Set as Primary")
            .accessibilityLabel(label.accessibilityText)
            .accessibilityValue(isPrimary ? "Primary" : "")
            .accessibilityHint(isPrimary ? "" : "Sets this display as Primary")
            .accessibilityAddTraits(isPrimary ? .isSelected : [])

            LevelSlider(
                accessibilityLabel: label.accessibilityText,
                accessibilityHint: nil,
                level: display.brightness,
                onChange: { onSetDisplay(display.identity, $0) }
            )
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
    }

    // MARK: - 状態の導出

    // 選択中のPrimaryが一覧にないとき（再検出直後など）はmacOSの主画面、なければ先頭を表示上の基準にする。
    private var primaryDisplay: DisplaySnapshot? {
        displays.first { $0.identity == primaryIdentity }
            ?? displays.first { $0.isMain }
            ?? displays.first
    }

    private var resolvedPrimaryIdentity: String? { primaryDisplay?.identity }

    // 画面が1台だけなら一括と揃え直しは個別と同じ意味になるため出さない。
    private var showsAllDisplays: Bool { displays.count > 1 }

    // 表示上の段（1%）で同じなら揃っているとみなす。
    private var isMatched: Bool {
        guard let primary = primaryDisplay else { return true }
        let target = (primary.brightness * 100).rounded()
        return displays.allSatisfy { ($0.brightness * 100).rounded() == target }
    }

    private func label(for display: DisplaySnapshot) -> DisplayLabel {
        DisplayLabel.make(for: display, among: displays)
    }
}

// MARK: - 画面名

// 同じ名前の画面（同型の2台など）は配置の左右で見分ける。
struct DisplayLabel: Equatable {
    let name: String
    let detail: String?

    var accessibilityText: String {
        detail.map { "\(name), \($0)" } ?? name
    }

    static func make(for display: DisplaySnapshot, among displays: [DisplaySnapshot]) -> DisplayLabel {
        let twins = displays
            .filter { $0.name == display.name }
            .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard twins.count > 1, let index = twins.firstIndex(where: { $0.identity == display.identity }) else {
            return DisplayLabel(name: display.name, detail: nil)
        }
        // 2台で左右に並ぶときは Left/Right、それ以外は左からの番号にする。
        if twins.count == 2, twins[0].x != twins[1].x {
            return DisplayLabel(name: display.name, detail: index == 0 ? "Left" : "Right")
        }
        return DisplayLabel(name: display.name, detail: "\(index + 1)")
    }
}

private struct DisplayHeader: View {
    let display: DisplaySnapshot
    let label: DisplayLabel
    let isPrimary: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                .foregroundStyle(isPrimary ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 16)
            Text(label.name)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail = label.detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if isPrimary {
                PrimaryBadge()
            }
            Spacer(minLength: 4)
            PercentText(level: display.brightness)
        }
        .frame(height: 24)
    }
}

private struct PrimaryBadge: View {
    var body: some View {
        Text("Primary")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

private struct PercentText: View {
    let level: Double

    var body: some View {
        Text("\(Int((min(max(level, 0), 1) * 100).rounded()))%")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 34, alignment: .trailing)
    }
}

// MARK: - 操作できる段階バー

// 細いバーの上下に余白を取り、クリックとドラッグを広い範囲で受ける。
// 値はポインタ位置を段単位に丸めて通知する。キーボードでは矢印で1段ずつ、Home/Endで端へ動かす。
// VoiceOverには標準のSliderとして見せる。
private struct LevelSlider: View {
    let accessibilityLabel: String
    let accessibilityHint: String?
    let level: Double
    let onChange: (Double) -> Void

    @FocusState private var isFocused: Bool
    // 同じ値を繰り返し通知しないための直近の送信値。ドラッグ中だけ使う。
    @State private var lastSent: Double?

    private static let hitHeight: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            stepButton(systemImage: "sun.min", direction: -1)
            GeometryReader { proxy in
                LevelBar(level: level)
                    .frame(height: LevelBar.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: proxy.size.width))
            }
            .frame(height: Self.hitHeight)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                        .padding(.vertical, 4)
                        .padding(.horizontal, -3)
                        .allowsHitTesting(false)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.leftArrow, .downArrow]) { _ in step(-1); return .handled }
            .onKeyPress(keys: [.rightArrow, .upArrow]) { _ in step(1); return .handled }
            .onKeyPress(keys: [.home]) { _ in send(0); return .handled }
            .onKeyPress(keys: [.end]) { _ in send(1); return .handled }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(get: { clamped(level) }, set: { send(LevelSteps.snap($0)) }),
                    in: 0...1,
                    step: LevelSteps.unit
                ) {
                    Text(accessibilityLabel)
                }
                .accessibilityValue("\(Int((clamped(level) * 100).rounded())) percent")
                .accessibilityHint(accessibilityHint ?? "")
            }
            stepButton(systemImage: "sun.max", direction: 1)
        }
    }

    // 両端の太陽はクリックで1段ずつ動かす。読み上げはスライダー側にまとめる。
    private func stepButton(systemImage: String, direction: Int) -> some View {
        Button {
            step(direction)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: Self.hitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityHidden(true)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard width > 0 else { return }
                let snapped = LevelSteps.snap(value.location.x / width)
                if snapped != lastSent {
                    lastSent = snapped
                    onChange(snapped)
                }
            }
            .onEnded { _ in lastSent = nil }
    }

    private func step(_ direction: Int) {
        send(LevelSteps.next(from: level, direction: direction))
    }

    private func send(_ value: Double) {
        let value = clamped(value)
        guard value != clamped(level) else { return }
        onChange(value)
    }

    private func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}

// 段の計算。純正の輝度キーと同じ16段を単位にする。
enum LevelSteps {
    static let count = 16
    static let unit = 1.0 / Double(count)

    static func snap(_ value: Double) -> Double {
        (min(max(value, 0), 1) * Double(count)).rounded() / Double(count)
    }

    // 段の途中の値からは、指定方向の最初の段の境目へ動かす。
    static func next(from value: Double, direction: Int) -> Double {
        let position = min(max(value, 0), 1) * Double(count)
        let epsilon = 1e-6
        let target = direction > 0
            ? (position + epsilon).rounded(.down) + 1
            : (position - epsilon).rounded(.up) - 1
        return min(max(target, 0), Double(count)) / Double(count)
    }
}

// MARK: - メニュー風の行

private struct PanelSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
    }
}

private struct MenuRowButton: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 8)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

// 標準メニューと同じく、ポインタが乗った行を強調色で塗る。
private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let highlighted = isEnabled && (isHovered || configuration.isPressed)
            configuration.label
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(isEnabled ? .primary : .tertiary))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(highlighted ? Color.accentColor : .clear)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

// 画面の見出し行。押すとPrimaryになる。ポインタが乗ると薄く塗る。
private struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRowBody(configuration: configuration)
    }

    private struct HoverRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : isHovered ? 0.06 : 0))
                )
                .padding(.horizontal, -4)
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - 段階バーの描画

// 実機の輝度キー表示を測った細い長方形。外枠は161×8pt、内側に1ptの仕切りで16段を並べる。
// 端数の段は段内で左から部分的に塗る。パネルとHUDで共用する。
struct LevelBar: View {
    let level: Double

    static let width: CGFloat = 161
    static let height: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let palette = LevelBarPalette(colorScheme)
        Canvas { context, size in
            let inset: CGFloat = 1
            let gap: CGFloat = 1
            let count = LevelSteps.count
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.frame))

            let inner = size.width - inset * 2 - gap * CGFloat(count - 1)
            let segment = inner / CGFloat(count)
            let filled = min(max(level, 0), 1) * Double(count)
            let top = inset
            let height = size.height - inset * 2

            for index in 0..<count {
                // 端の座標を画素に揃え、幅が割り切れないときも仕切りをにじませない。
                let minX = align(inset + CGFloat(index) * (segment + gap))
                let maxX = align(inset + CGFloat(index) * (segment + gap) + segment)
                let rect = CGRect(x: minX, y: top, width: maxX - minX, height: height)
                context.fill(Path(rect), with: .color(palette.off))

                let fraction = min(max(filled - Double(index), 0), 1)
                if fraction > 0 {
                    var lit = rect
                    lit.size.width = fraction >= 1 ? rect.width : align(rect.width * fraction)
                    context.fill(Path(lit), with: .color(palette.on))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func align(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale
    }
}

// 外観ごとの色。暗い外観は実機の表示から測った値、明るい外観は試作で承認された近似値。
private struct LevelBarPalette {
    let frame: Color
    let off: Color
    let on: Color

    init(_ colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            frame = Color(red: 62 / 255, green: 61 / 255, blue: 70 / 255)
            off = Color(red: 73 / 255, green: 67 / 255, blue: 73 / 255)
            on = Color(red: 197 / 255, green: 191 / 255, blue: 197 / 255)
        default:
            frame = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.62)
            off = Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.42)
            on = Color.white.opacity(0.95)
        }
    }
}
