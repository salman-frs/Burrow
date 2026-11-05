import AppKit
import BurrowCore
import SwiftUI

// MARK: Glass

extension View {
    /// Liquid Glass on macOS 26 and later, a material with a lit rim before that.
    /// `strong` backs the glass for small surfaces, such as tooltips, that sit over busy content.
    func glass(_ shape: some Shape = RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous),
               strong: Bool = false) -> some View {
        modifier(GlassSurface(shape: AnyShape(shape), strong: strong))
    }

    func hoverHighlight(_ active: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        modifier(HoverHighlight(active: active, cornerRadius: cornerRadius))
    }
}

private struct GlassSurface: ViewModifier {
    let shape: AnyShape
    let strong: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(strong ? Palette.windowBottom.opacity(scheme == .dark ? 0.55 : 0.6) : .clear, in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(strong ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay {
                    shape.stroke(LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.34 : 0.95), .white.opacity(0.03), .white.opacity(scheme == .dark ? 0.12 : 0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                }
                .shadow(color: .black.opacity(scheme == .dark ? 0.42 : 0.16), radius: 26, y: 14)
        }
    }
}

private struct HoverHighlight: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(active || hovering ? Palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: Buttons

struct AmberButtonStyle: ButtonStyle {
    var height: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        AmberButton(configuration: configuration, height: height)
    }
}

private struct AmberButton: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        configuration.label
            .font(.system(size: height >= 40 ? 14 : 13, weight: .semibold))
            .tracking(-0.14)
            .lineLimit(1)
            .foregroundStyle(Palette.amberInk)
            .padding(.horizontal, 20)
            .frame(height: height)
            .background {
                Capsule().fill(dark ? AnyShapeStyle(LinearGradient(colors: [Palette.amberHot, Palette.amber], startPoint: .top, endPoint: .center))
                                    : AnyShapeStyle(Palette.amber))
            }
            .overlay {
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.55 : 0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: Palette.amber.opacity(isEnabled ? (dark ? 0.38 : 0.22) : 0), radius: dark ? 12 : 6, y: dark ? 8 : 4)
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, height: height, filled: filled)
    }
}

private struct QuietButton: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let filled: Bool
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(Capsule().fill(hovering && isEnabled ? Palette.selected : (filled ? Palette.hover : .clear)))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .onHover { hovering = $0 }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, size: size)
    }
}

private struct IconButton: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? Palette.hover : .clear))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

struct CheckCircle: View {
    let on: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(on ? Palette.amber.opacity(0.2) : .clear)
            Circle().strokeBorder(.tertiary, lineWidth: 1.6).opacity(on ? 0 : 1)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .heavy))
                .foregroundStyle(Palette.amberText)
                .opacity(on ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.3, bounce: 0.4), value: on)
        .contentShape(Circle())
    }
}

// MARK: Figures

struct ByteFigure: View, Animatable {
    var bytes: Double
    var word: String?
    var size: CGFloat = 64
    var amber = false

    init(_ bytes: Int64, word: String? = nil, size: CGFloat = 64, amber: Bool = false) {
        self.bytes = Double(bytes)
        self.word = word
        self.size = size
        self.amber = amber
    }

    nonisolated var animatableData: Double {
        get { bytes }
        set { bytes = newValue }
    }

    var body: some View {
        let (value, unit) = ByteText.parts(Int64(bytes))
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(value)
                .font(.figure(size))
                .tracking(-size * 0.045)
                .monospacedDigit()
            Text(unit)
                .font(.system(size: size * 0.41, weight: .semibold))
                .foregroundStyle(amber ? AnyShapeStyle(Palette.amberText.opacity(0.65)) : AnyShapeStyle(.secondary))
                .padding(.leading, size * 0.08)
            if let word {
                Text(word)
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, size * 0.19)
            }
        }
        .foregroundStyle(amber ? AnyShapeStyle(Palette.amberText) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([ByteText.string(Int64(bytes)), word].compactMap { $0 }.joined(separator: " "))
    }
}

struct Spinner: View {
    var size: CGFloat = 16
    @ViewState private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.amber.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(Palette.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityLabel("Working")
    }
}

struct ShareBar: View {
    let share: Double
    var muted = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(LinearGradient(colors: [Palette.amber, Palette.amber.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                .frame(width: max(4, proxy.size.width * min(max(share, 0), 1)))
                .saturation(muted ? 0 : 1)
                .opacity(muted ? 0.4 : 1)
        }
        .frame(height: 3)
    }
}

// MARK: Rows

struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: 22)
    }
}

struct DisclosureRow<Content: View>: View {
    let symbol: String
    var tint: Color?
    let title: String
    var bytes: Int64?
    @ViewBuilder let content: Content
    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 11) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
                        .frame(width: 20)
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if let bytes {
                        Text(ByteText.string(bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    Chevron(expanded: expanded)
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content.transition(.opacity)
            }
        }
        .hoverHighlight(expanded)
    }
}

struct RevealRow: View {
    let title: String
    let path: String
    let bytes: Int64

    var body: some View {
        HStack(spacing: 10) {
            Text(title).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(ByteText.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button { revealInFinder(path) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Show in Finder")
                .accessibilityLabel("Show \(title) in Finder")
        }
        .font(.system(size: 12.5))
        .frame(minHeight: 30)
        .help(Paths.abbreviatingHome(path))
    }
}

// MARK: Overlays

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
    var warning = false
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .foregroundStyle(toast.warning ? Palette.amberText : Palette.ok)
                .font(.system(size: 14, weight: .semibold))
            Text(toast.text).font(.system(size: 13, weight: .medium)).lineLimit(2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(minHeight: 38)
        .glass(Capsule(), strong: true)
    }
}

struct FieldHover: Equatable {
    let location: CGPoint
    let swatch: Color?
    let title: String
    let detail: String
}

struct FieldTooltip: View {
    let swatch: Color?
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let swatch {
                Circle().fill(swatch).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            }
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .fixedSize()
        .glass(RoundedRectangle(cornerRadius: 11, style: .continuous), strong: true)
        .allowsHitTesting(false)
    }
}

// MARK: Icons

/// SF Symbols has no shovel, so Dig draws its own in the same stroke weight.
struct ShovelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9.2, y: 2.5))
        path.addLine(to: CGPoint(x: 14.8, y: 2.5))
        path.move(to: CGPoint(x: 12, y: 2.5))
        path.addLine(to: CGPoint(x: 12, y: 11))
        path.move(to: CGPoint(x: 8, y: 11))
        path.addLine(to: CGPoint(x: 16, y: 11))
        path.addLine(to: CGPoint(x: 16, y: 15.5))
        path.addQuadCurve(to: CGPoint(x: 12, y: 21.5), control: CGPoint(x: 16, y: 19))
        path.addQuadCurve(to: CGPoint(x: 8, y: 15.5), control: CGPoint(x: 8, y: 19))
        path.closeSubpath()
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(translationX: 12, y: 12)
            .rotated(by: .pi * 35 / 180)
            .translatedBy(x: -12, y: -12)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return path.applying(transform)
    }
}

struct ShovelIcon: View {
    var size: CGFloat = 18
    var weight: CGFloat = 1.65

    var body: some View {
        ShovelShape()
            .stroke(style: StrokeStyle(lineWidth: weight * size / 24 * 1.15, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
