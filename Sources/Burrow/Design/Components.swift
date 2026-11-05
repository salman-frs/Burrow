import BurrowCore
import SwiftUI

struct StrataLayer: Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: Int64
}

struct StrataColumn: View {
    let layers: [StrataLayer]
    var minimumBand: CGFloat = 6
    @Environment(\.moduleAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let bands = bandHeights(total: proxy.size.height)
            VStack(spacing: 2) {
                ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Mineral.layer(accent, index: index, of: layers.count))
                        .frame(height: bands[index])
                        .help("\(layer.title), \(ByteSize.format(layer.bytes))")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: layers)
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(layers.count) layers, \(ByteSize.format(layers.map(\.bytes).reduce(0, +)))")
    }

    private func bandHeights(total: CGFloat) -> [CGFloat] {
        let spacing = CGFloat(max(layers.count - 1, 0)) * 2
        let available = max(total - spacing, 0)
        let bytes = layers.map { max($0.bytes, 0) }
        let sum = bytes.reduce(0, +)
        guard sum > 0 else { return layers.map { _ in minimumBand } }
        let floorShare = minimumBand * CGFloat(layers.count)
        let flexible = max(available - floorShare, 0)
        return bytes.map { minimumBand + flexible * CGFloat(Double($0) / Double(sum)) }
    }
}

struct ModuleHeader<Trailing: View>: View {
    let module: Module
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(module.accent.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title2.weight(.semibold))
                Text(module.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: Module) {
        self.init(module: module) { EmptyView() }
    }
}

struct Figure: View {
    let bytes: Int64
    let caption: String
    var partial = false
    var size: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ByteSize.format(bytes) + (partial ? "+" : ""))
                .font(.figure(size))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.moduleAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(isEnabled ? AnyShapeStyle(accent.opacity(configuration.isPressed ? 0.75 : 1))
                                         : AnyShapeStyle(.quaternary))
            )
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accent: AccentButtonStyle { AccentButtonStyle() }
}

struct StatusGlyph: View {
    let status: ReportRow.Status

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 16)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .pending: "circle.dashed"
        case .review: "eye.circle"
        case .attention: "exclamationmark.circle"
        case .failed: "xmark.octagon.fill"
        case .info: "info.circle"
        }
    }

    private var color: Color {
        switch status {
        case .done: Mineral.malachite
        case .pending: .secondary
        case .review: Mineral.azurite
        case .attention: Mineral.citrine
        case .failed: Mineral.garnet
        case .info: .secondary
        }
    }

    private var label: String {
        switch status {
        case .done: "Done"
        case .pending: "Ready"
        case .review: "Needs your review"
        case .attention: "Skipped"
        case .failed: "Failed"
        case .info: "Information"
        }
    }
}

struct EmptyPrompt<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            actions.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct WorkingStrip: View {
    let title: String
    let detail: String?
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let onStop {
                Button("Stop", action: onStop).controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct OutcomeBanner: View {
    enum Tone { case success, warning, failure }
    let tone: Tone
    let title: String
    let lines: [String]
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var symbol: String {
        switch tone {
        case .success: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .success: Mineral.malachite
        case .warning: Mineral.citrine
        case .failure: Mineral.garnet
        }
    }
}

struct SizeLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct TranscriptDisclosure: View {
    let lines: [String]
    @ViewState private var expanded = false

    var body: some View {
        DisclosureGroup("Mole output", isExpanded: $expanded) {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .font(.callout)
    }
}
