import BurrowCore
import SwiftUI

struct AppsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = app.apps
        ZStack(alignment: .topLeading) {
            ByteFigure(model.totalBytes, word: "in \(model.apps.count) apps")
                .animation(.easeOut(duration: 0.6), value: model.totalBytes)
                .padding(.leading, Metrics.contentX)
                .padding(.top, Metrics.heroTop)
            AppsToolbar(model: model)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 16)
                .padding(.trailing, 16)
            AppGrid(model: model)
                .padding(.top, 136)
                .padding(.leading, Metrics.contentX - 14)
                .padding(.trailing, Metrics.inspectorWidth + Metrics.inset + 12)
            AppInspector(model: model)
                .frame(width: Metrics.inspectorWidth)
                .frame(maxHeight: .infinity)
                .glass()
                .padding(.top, 66)
                .padding([.bottom, .trailing], Metrics.inset)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .task { if model.apps.isEmpty { await model.load() } }
    }
}

private struct AppsToolbar: View {
    @Bindable var model: AppsModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .onExitCommand { model.search = "" }
                    .accessibilityLabel("Search apps")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(width: 210, height: 38)
            .glass(Capsule())
            HStack(spacing: 0) {
                OrderButton(title: "Largest", symbol: nil, order: .largest, model: model)
                OrderButton(title: "A–Z", symbol: nil, order: .name, model: model)
                OrderButton(title: "Slimmable", symbol: "scissors", order: .slimmable, model: model)
                    .help("Apps that still carry Intel code")
            }
            .padding(4)
            .frame(height: 38)
            .glass(Capsule())
        }
    }
}

private struct OrderButton: View {
    let title: String
    let symbol: String?
    let order: AppsModel.Order
    let model: AppsModel

    var body: some View {
        let selected = model.order == order
        Button { withAnimation(.spring(duration: 0.4, bounce: 0.2)) { model.order = order } } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(selected ? Palette.selected : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppGrid: View {
    let model: AppsModel

    var body: some View {
        if model.apps.isEmpty {
            Group {
                if let failure = model.failure {
                    VStack(spacing: 12) {
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await model.load() } }.buttonStyle(QuietButtonStyle(filled: true))
                    }
                } else {
                    Spinner(size: 22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleApps.isEmpty {
            EmptyGrid(model: model)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 4)], spacing: 4) {
                    ForEach(model.visibleApps) { installed in
                        AppTile(model: model, installed: installed)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                       .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(.spring(duration: 0.45, bounce: 0.25), value: model.visibleApps.map(\.id))
        }
    }
}

private struct EmptyGrid: View {
    let model: AppsModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "scissors")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if searching {
                Button("Clear search") { model.search = "" }
                    .buttonStyle(QuietButtonStyle(height: 32, filled: true))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var searching: Bool { !model.search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var title: String {
        searching ? "No apps match \u{201C}\(model.search.trimmingCharacters(in: .whitespaces))\u{201D}" : "Nothing to slim"
    }

    private var detail: String {
        if searching { return model.order == .slimmable ? "Only apps that still carry Intel code are listed here." : "Try the app's name or bundle ID." }
        return model.slimmableChecked ? "Every app here is already Apple silicon only." : "Mole is still checking your apps for Intel code."
    }
}

private struct AppTile: View {
    let model: AppsModel
    let installed: InstalledApp
    @Environment(\.colorScheme) private var scheme
    @ViewState private var hovering = false

    var body: some View {
        let selected = model.selection.contains(installed.id)
        let leaving = model.leaving.contains(installed.id)
        Button { model.toggle(installed) } label: {
            VStack(spacing: 6) {
                Image(nsImage: AppIcons.image(for: installed.path))
                    .resizable()
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 6)
                    .scaleEffect(hovering ? 1.04 : 1)
                    .offset(y: hovering ? -3 : 0)
                    .overlay(alignment: .bottomTrailing) {
                        if model.slimmable[installed.path] != nil {
                            Image(systemName: "scissors")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.accentText)
                                .frame(width: 24, height: 24)
                                .glass(Circle())
                                .offset(x: 8, y: 2)
                                .help("Has Intel code it doesn't need")
                        }
                    }
                Text(model.name(of: installed))
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(sizeText)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.top, -3)
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(background(selected: selected), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if selected && scheme == .light {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.55), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.accent))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .scaleEffect(selected ? 1 : 0.01)
                    .opacity(selected ? 1 : 0)
                    .padding(.top, 10)
                    .padding(.trailing, 18)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .disabled(model.uninstalling)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.35, bounce: 0.4), value: hovering)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: selected)
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving ? 0.6 : 1)
        .offset(y: leaving ? 20 : 0)
        .animation(.easeIn(duration: 0.38), value: leaving)
        .contextMenu {
            Button("Show in Finder") { revealInFinder(installed.path) }
        }
        .accessibilityLabel("\(model.name(of: installed)), \(sizeText)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sizeText: String {
        if model.order == .slimmable, let intel = model.slimmable[installed.path] { return "−\(ByteText.string(intel))" }
        return model.sizes[installed.path].map(ByteText.string) ?? "…"
    }

    private func background(selected: Bool) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(Palette.accent.opacity(scheme == .dark ? 0.14 : 0.09)) }
        return AnyShapeStyle(hovering ? Palette.hover : .clear)
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

// MARK: Inspector

private struct AppInspector: View {
    let model: AppsModel
    @ViewState private var targeted = false

    var body: some View {
        Group {
            if model.selection.isEmpty {
                DropWell(targeted: targeted)
            } else {
                AppDetail(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            model.pick(droppedURLs: urls)
        } isTargeted: { targeted = $0 }
    }
}

private struct DropWell: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .light))
                .frame(width: 120, height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(targeted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(0.18)),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
                .scaleEffect(targeted ? 1.05 : 1)
            Text("Drop an app here\nor pick some on the left")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.tertiary)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: targeted)
    }
}

private struct AppDetail: View {
    let model: AppsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent
    @ViewState private var expanded: FootprintPart?

    var body: some View {
        let theme = FieldTheme(scheme: scheme, accent: accent)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: -26) {
                ForEach(model.selectedApps.suffix(5)) { installed in
                    Image(nsImage: AppIcons.image(for: installed.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 6)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(height: 64)
            .animation(.spring(duration: 0.45, bounce: 0.35), value: model.selection)
            VStack(alignment: .leading, spacing: 4) {
                ByteFigure(model.footprintTotal, size: 44)
                    .animation(.easeOut(duration: 0.6), value: model.footprintTotal)
                HStack(spacing: 8) {
                    Text(model.selectionLabel).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    if model.planning { Spinner(size: 12).help("Mole is checking what goes with it") }
                }
            }
            DotFieldView(field: model.footprint, onResize: model.footprintResized)
                .frame(height: 128)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(FootprintPart.allCases, id: \.self) { part in
                        LegendRow(swatch: theme.color(of: part.shade).color(), title: part.title, bytes: model.bytes(of: part),
                                  measuring: model.planning && part != .app,
                                  paths: model.paths[part] ?? [], expanded: expanded == part) {
                            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded = expanded == part ? nil : part }
                        }
                    }
                    if !model.personalPaths.isEmpty {
                        PersonalDataRow(model: model)
                    }
                }
            }
            .scrollIndicators(.never)
            if let problem = model.planProblem {
                Note(text: problem)
            } else if !model.runningApps.isEmpty {
                Note(text: "\(model.runningApps.joined(separator: ", ")) \(model.runningApps.count == 1 ? "is" : "are") running. Quit first.")
            }
            VStack(spacing: 8) {
                if model.slimBytes > 0 {
                    Button { model.slimInTerminal() } label: {
                        Label("Slim instead, save \(ByteText.string(model.slimBytes))", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(QuietButtonStyle(filled: true))
                    .help("Keep the app and remove the Intel code it doesn't need. Opens Mole's picker in Terminal.")
                }
                Button { Task { await model.uninstall() } } label: {
                    Label(model.uninstalling ? "Uninstalling" : "Uninstall \(model.selectionLabel)", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!model.planCoversSelection || model.planning || model.uninstalling)
                .help("Everything goes to the Trash, so you can put it back.")
            }
        }
        .padding(.top, 22)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }
}

private struct LegendRow: View {
    let swatch: Color
    let title: String
    let bytes: Int64
    let measuring: Bool
    let paths: [String]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let empty = bytes == 0
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Circle().fill(swatch).frame(width: 9, height: 9).opacity(empty ? 0.4 : 1)
                    Text(title).foregroundStyle(empty ? .tertiary : .secondary)
                    Spacer()
                    Text(measuring ? "…" : empty ? "None" : ByteText.string(bytes))
                        .fontWeight(empty ? .regular : .semibold)
                        .monospacedDigit()
                        .foregroundStyle(empty ? .tertiary : .primary)
                        .contentTransition(.numericText(value: Double(bytes)))
                    Chevron(expanded: expanded)
                        .opacity(paths.isEmpty ? 0 : 1)
                }
                .font(.system(size: 12.5))
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(paths.isEmpty)
            if expanded {
                ForEach(paths.prefix(30), id: \.self) { path in
                    Text(Paths.abbreviatingHome(path))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .padding(.leading, 19)
                        .contextMenu { Button("Show in Finder") { revealInFinder(path) } }
                        .help(path)
                }
            }
        }
    }
}

private struct PersonalDataRow: View {
    let model: AppsModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.togglePersonalData() } label: { CheckCircle(on: model.includePersonalData, size: 16) }
                .buttonStyle(.plain)
                .disabled(model.uninstalling)
                .accessibilityLabel("Also remove personal data")
            Text("Personal data")
                .foregroundStyle(model.includePersonalData ? .secondary : .tertiary)
                .strikethrough(!model.includePersonalData, color: .secondary)
            Spacer()
            Text(ByteText.string(model.personalBytes))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(model.includePersonalData ? .primary : .tertiary)
            Color.clear.frame(width: 22)
        }
        .font(.system(size: 12.5))
        .frame(height: 28)
        .help(model.personalPaths.map(Paths.abbreviatingHome).joined(separator: "\n"))
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accentText)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
