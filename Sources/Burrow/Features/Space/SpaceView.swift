import BurrowCore
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @ViewState private var hover: FieldHover?
    @ViewState private var focus: Int?

    var body: some View {
        @Bindable var model = app.space
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                DotFieldView(field: model.field, focus: DotField.Focus(stratum: focus),
                             onResize: model.fieldResized, onHover: hover(at:))
                    .mask(FieldMask(width: proxy.size.width))
                    .onTapGesture(count: 2) { openFocused() }
                    .onTapGesture { selectFocused() }
                VStack(alignment: .leading, spacing: 12) {
                    Crumbs(model: model)
                    if model.atRoot {
                        ByteFigure(model.total, word: "used")
                    } else {
                        ByteFigure(model.total)
                    }
                }
                .animation(.easeOut(duration: 0.5), value: model.total)
                .padding(.leading, Metrics.contentX)
                .padding(.top, Metrics.heroTop - 4)
                SpaceInspector(model: model, focus: $focus)
                    .frame(width: Metrics.inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .glass()
                    .padding(Metrics.inset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if let hover {
                    FieldTooltip(swatch: hover.swatch, title: hover.title, detail: hover.detail)
                        .offset(x: min(hover.location.x + 16, proxy.size.width - Metrics.inspectorWidth - 200), y: hover.location.y + 18)
                }
            }
        }
        .confirmationDialog("Move \(model.pendingTrash?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
                            titleVisibility: .visible) {
            if let item = model.pendingTrash {
                Button("Move to Trash, \(ByteText.string(item.bytes))", role: .destructive) { Task { await model.trash(item) } }
            }
        } message: {
            Text("You can put it back from the Trash until you empty it.")
        }
    }

    private func hover(at location: CGPoint?) {
        let model = app.space
        guard let location, let cell = model.field.cell(at: location), cell.row >= model.field.firstRow else {
            hover = nil
            focus = nil
            return
        }
        guard cell.stratum >= 0, cell.stratum < model.field.strata.count else {
            focus = nil
            hover = FieldHover(location: location, swatch: nil, title: "Free", detail: ByteText.string(app.disk.free))
            return
        }
        let stratum = model.field.strata[cell.stratum]
        focus = cell.stratum
        hover = FieldHover(location: location, swatch: FieldTheme.of(scheme).color(of: stratum.shade).color(),
                           title: stratum.name, detail: ByteText.string(stratum.bytes))
    }

    private func focusedItem() -> SpaceItem? {
        let items = app.space.items
        guard let focus, focus < items.count else { return nil }
        return items[focus]
    }

    private func selectFocused() {
        guard let item = focusedItem() else { return }
        app.space.selectedID = app.space.selectedID == item.id ? nil : item.id
    }

    private func openFocused() {
        guard let item = focusedItem() else { return }
        hover = nil
        Task { await app.space.open(item) }
    }
}

private struct Crumbs: View {
    let model: SpaceModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.trail.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                Button(crumb.path == nil ? model.diskName : crumb.name) { Task { await model.go(to: index) } }
                    .buttonStyle(CrumbStyle(current: index == model.trail.count - 1))
            }
            if model.loadingPath != nil {
                Spinner(size: 13).padding(.leading, 6)
            }
            Button { model.chooseFolder() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(IconButtonStyle())
                .help("Measure another folder")
                .accessibilityLabel("Measure another folder")
                .padding(.leading, 6)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help("Measure again")
                .accessibilityLabel("Measure again")
                .disabled(model.loadingPath != nil)
        }
        .padding(.leading, -10)
    }
}

private struct CrumbStyle: ButtonStyle {
    let current: Bool

    func makeBody(configuration: Configuration) -> some View {
        CrumbLabel(configuration: configuration, current: current)
    }
}

private struct CrumbLabel: View {
    let configuration: ButtonStyleConfiguration
    let current: Bool
    @ViewState private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(current || hovering ? .primary : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(hovering && !current ? Palette.hover : .clear))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

private struct SpaceInspector: View {
    @Bindable var model: SpaceModel
    @Binding var focus: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let items = model.items
        let theme = FieldTheme.of(scheme)
        let strata = model.strata(for: items)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated().reversed()), id: \.element.id) { index, item in
                        StratumRow(item: item, swatch: theme.color(of: strata[index].shade).color(),
                                   selected: model.selectedID == item.id, highlighted: focus == index) {
                            model.selectedID = model.selectedID == item.id ? nil : item.id
                        } open: {
                            Task { await model.open(item) }
                        }
                        .onHover { focus = $0 ? index : (focus == index ? nil : focus) }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .animation(.spring(duration: 0.45, bounce: 0.25), value: items.map(\.id))
            }
            .scrollIndicators(.never)
            if let files = model.report?.largeFiles, !files.isEmpty, model.selected == nil {
                LargeFilesRow(files: files)
                    .padding(8)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
            if let selected = model.selected {
                SpaceDetail(model: model, item: selected)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.selectedID)
    }
}

private struct StratumRow: View {
    let item: SpaceItem
    let swatch: Color
    let selected: Bool
    let highlighted: Bool
    let select: () -> Void
    let open: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(swatch)
                .frame(width: 12, height: 12)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            HStack(spacing: 6) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.insight {
                    Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amberText)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(item.kind == .rest ? .secondary : .primary)
            Spacer(minLength: 6)
            Text(ByteText.string(item.bytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Group {
                switch item.kind {
                case .folder:
                    Button(action: open) { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help("Open")
                case .system:
                    Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                case .file, .rest:
                    Color.clear
                }
            }
            .frame(width: 14)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(selected ? Palette.selected : (hovering || highlighted ? Palette.hover : .clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .transition(.asymmetric(insertion: .offset(x: 14).combined(with: .opacity), removal: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: "Open") { open() }
    }
}

private struct SpaceDetail: View {
    let model: SpaceModel
    let item: SpaceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 15, weight: .semibold))
                Text(item.path.map(Paths.abbreviatingHome) ?? description)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.insight {
                HStack(spacing: 9) {
                    Image(systemName: "eye").foregroundStyle(Palette.amberText)
                    (Text(item.cleanable ? "Mole can clear this. " : "Often safe to clear. ")
                        + Text("Check what's inside first.").foregroundStyle(.primary))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.amber.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let path = item.path {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if item.kind == .folder {
                            Button { Task { await model.open(item) } } label: { Label("Open", systemImage: "folder").frame(maxWidth: .infinity) }
                                .buttonStyle(QuietButtonStyle(height: 36, filled: true))
                        }
                        Button { revealInFinder(path) } label: {
                            Label("Finder", systemImage: "arrow.up.forward.square").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuietButtonStyle(height: 36, filled: true))
                    }
                    if model.canTrash(item) {
                        Button { model.pendingTrash = item } label: {
                            Label("Move to Trash", systemImage: "trash").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AmberButtonStyle(height: 36))
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var description: String {
        switch item.kind {
        case .system: "macOS, system data, snapshots and swap"
        case .rest: "Smaller items in this folder"
        case .folder, .file: ""
        }
    }
}

private struct LargeFilesRow: View {
    let files: [LargeFile]

    var body: some View {
        DisclosureRow(symbol: "doc", title: "Large files", bytes: files.map(\.size).reduce(0, +)) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(files.prefix(30)) { RevealRow(title: $0.name, path: $0.path, bytes: $0.size) }
                }
                .padding(.leading, 43)
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 220)
            .scrollIndicators(.never)
        }
    }
}
