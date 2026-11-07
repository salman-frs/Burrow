import BurrowCore
import SwiftUI

struct DigView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @ViewState private var hover: FieldHover?
    @ViewState private var focusStratum: Int?

    var body: some View {
        let model = app.dig
        GeometryReader { proxy in
            let inspectorOpen = Self.inspectorOpen(model)
            ZStack(alignment: .topLeading) {
                DotFieldView(field: model.field,
                             focus: DotField.Focus(stratum: focusStratum, vein: model.hoveredVein,
                                                   pulsing: pulsingVeins(model)),
                             onResize: model.fieldResized, onHover: hover(at:))
                    .mask(FieldMask(width: proxy.size.width))
                DigHero(model: model, free: app.disk.free)
                    .padding(.leading, Metrics.contentX)
                    .padding(.top, Metrics.heroTop)
                    .allowsHitTesting(false)
                DigToolbar()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
                if inspectorOpen {
                    DigInspector(model: model)
                        .frame(width: Metrics.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .glass()
                        .padding(.top, 66)
                        .padding([.bottom, .trailing], Metrics.inset)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.asymmetric(insertion: .offset(x: 24).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
                                                removal: .offset(x: 24).combined(with: .opacity)))
                }
                DigCapsule(model: model)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, Metrics.inset + Metrics.sidebarWidth)
                    .padding(.trailing, inspectorOpen ? Metrics.inspectorWidth + Metrics.inset : 0)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 26)
                if let hover {
                    FieldTooltip(swatch: hover.swatch, title: hover.title, detail: hover.detail)
                        .offset(x: min(hover.location.x + 16, proxy.size.width - 240), y: hover.location.y + 18)
                }
            }
            .animation(.spring(duration: 0.55, bounce: 0.25), value: inspectorOpen)
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .digging || phase == .clearing else { return }
            hover = nil
            focusStratum = nil
        }
        .onAppear { app.vitals.start() }
        .onDisappear { app.vitals.stop() }
    }

    static func inspectorOpen(_ model: DigModel) -> Bool {
        switch model.phase {
        case .digging, .ready, .clearing: true
        case .done: !model.clearNotes.isEmpty
        case .idle: false
        }
    }

    private func pulsingVeins(_ model: DigModel) -> Set<Int> {
        guard let kind = model.clearing else { return [] }
        return Set(model.categories.filter { $0.kind == kind }.map(\.vein))
    }

    private func hover(at location: CGPoint?) {
        let model = app.dig
        guard let location, model.phase != .digging, model.phase != .clearing,
              let cell = model.field.cell(at: location), cell.row >= model.field.firstRow else {
            hover = nil
            focusStratum = nil
            if model.phase != .clearing { model.hoveredVein = nil }
            return
        }
        let theme = FieldTheme.of(scheme)
        if cell.vein >= 0, cell.revealedAt > 0, let category = model.categories.first(where: { $0.vein == cell.vein }) {
            focusStratum = nil
            model.hoveredVein = cell.vein
            hover = FieldHover(location: location, swatch: theme.amber.color(), title: category.name,
                               detail: ByteText.string(model.picked(category)))
        } else if cell.stratum >= 0, cell.stratum < model.field.strata.count {
            let stratum = model.field.strata[cell.stratum]
            model.hoveredVein = nil
            focusStratum = cell.stratum
            hover = FieldHover(location: location, swatch: theme.color(of: stratum.shade).color(), title: stratum.name,
                               detail: ByteText.string(stratum.bytes))
        } else {
            model.hoveredVein = nil
            focusStratum = nil
            hover = FieldHover(location: location, swatch: nil, title: "Free", detail: ByteText.string(app.disk.free))
        }
    }
}

private struct DigHero: View {
    let model: DigModel
    let free: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch model.phase {
            case .idle:
                ByteFigure(free, word: "free")
            case .digging:
                ByteFigure(model.found, word: "found", amber: true)
                    .animation(.easeOut(duration: 0.6), value: model.found)
            case .ready:
                ByteFigure(model.selectedTotal, word: "to clear", amber: true)
                    .animation(.easeOut(duration: 0.4), value: model.selectedTotal)
            case .clearing:
                ByteFigure(model.remaining, word: "to clear", amber: true)
                    .animation(.easeOut(duration: 1.3), value: model.remaining)
            case .done:
                CountingFigure(from: model.freeBefore, to: free, word: "free")
                if model.cleared > 0 {
                    Text("+\(ByteText.string(model.cleared))")
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.amberText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.amber.opacity(0.2)))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: model.phase)
    }
}

private struct CountingFigure: View {
    let from: Int64
    let to: Int64
    let word: String
    @ViewState private var shown: Int64?

    var body: some View {
        ByteFigure(shown ?? from, word: word)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).delay(0.2)) { shown = to }
            }
            .onChange(of: to) { _, value in
                withAnimation(.easeOut(duration: 0.8)) { shown = value }
            }
    }
}

private struct DigToolbar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            if let snapshot = app.vitals.snapshot {
                VitalsPill(snapshot: snapshot, cpuHistory: app.vitals.cpuHistory)
                    .transition(.opacity)
            }
            TuneUpButton()
        }
        .animation(.easeOut(duration: 0.3), value: app.vitals.snapshot == nil)
    }
}

private struct DigCapsule: View {
    let model: DigModel
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .idle:
                Button {
                    model.includeSystem.toggle()
                    app.notify(model.includeSystem ? "System caches included" : "System caches skipped",
                               symbol: model.includeSystem ? "lock.open.fill" : "checkmark.circle.fill")
                } label: {
                    Image(systemName: model.includeSystem ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.includeSystem ? AnyShapeStyle(Palette.amberText) : AnyShapeStyle(.tertiary))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(model.includeSystem ? Palette.amber.opacity(0.16) : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Include system caches. Asks for your password.")
                .accessibilityLabel("Include system caches")
                .accessibilityAddTraits(model.includeSystem ? .isSelected : [])
                Button { Task { await model.dig() } } label: {
                    HStack(spacing: 7) {
                        ShovelIcon(size: 19, weight: 2)
                        Text("Dig").font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 8)
                }
                .buttonStyle(AmberButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!app.canStart(.dig))
                .help(app.canStart(.dig) ? "Scans only. Nothing is removed until you press Clear." : "Another task is still running")
            case .digging:
                Ticker(text: model.job.stopping ? "Stopping" : model.ticker)
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(model.job.stopping)
            case .ready:
                Button("Dig again") { Task { await model.dig() } }
                    .buttonStyle(QuietButtonStyle())
                Button { Task { await model.clear() } } label: {
                    Label("Clear \(ByteText.string(model.selectedTotal))", systemImage: "sparkles")
                        .contentTransition(.numericText(value: Double(model.selectedTotal)))
                }
                .buttonStyle(AmberButtonStyle())
                .disabled(model.selectedTotal == 0 || !app.canStart(.dig))
            case .clearing:
                Ticker(text: model.job.stopping ? "Stopping after this step" : model.ticker)
                if model.clearing == .cache && model.job.isRunning {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(model.job.stopping)
                }
            case .done:
                Button { app.section = .log } label: { Label("See log", systemImage: "clock") }
                    .buttonStyle(QuietButtonStyle())
                Button("Done") { model.finish() }
                    .buttonStyle(AmberButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(8)
        .frame(height: 56)
        .glass(Capsule())
        .animation(.spring(duration: 0.5, bounce: 0.3), value: model.phase)
    }
}

private struct Ticker: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Spinner()
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: 300)
    }
}

// MARK: Inspector

private struct DigInspector: View {
    let model: DigModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if !model.cacheCategories.isEmpty {
                        CachesHeader(model: model)
                        ForEach(model.cacheCategories) { CategoryRow(model: model, category: $0) }
                    }
                    if !model.pickableCategories.isEmpty, !model.cacheCategories.isEmpty {
                        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(model.pickableCategories) { CategoryRow(model: model, category: $0) }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: model.categories.map(\.id))
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.categories.isEmpty && model.phase == .digging {
                    VStack(spacing: 6) {
                        Text("Nothing found yet").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        Text("Findings show up here as Mole digs.").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                    .transition(.opacity)
                }
            }
            let notes = model.phase == .done ? model.clearNotes : model.scanNotes
            if !model.review.isEmpty || !notes.isEmpty {
                VStack(spacing: 0) {
                    if !model.review.isEmpty, model.phase != .done { ReviewRow(items: model.review) }
                    if !notes.isEmpty { NotesRow(notes: notes) }
                }
                .padding(8)
                .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
        }
    }
}

private struct CachesHeader: View {
    let model: DigModel

    var body: some View {
        let picked = model.cacheCategories.map(model.picked).reduce(0, +)
        let total = picked > 0 ? picked : model.cacheCategories.map(\.total).reduce(0, +)
        HStack(spacing: 10) {
            Text("Caches")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteText.string(total))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(picked > 0 ? .secondary : .tertiary)
                .contentTransition(.numericText(value: Double(total)))
            Button { model.toggleCaches() } label: { CheckCircle(on: model.cachesIncluded && model.cachesClearable) }
                .buttonStyle(.plain)
                .disabled(model.phase != .ready || !model.cachesClearable)
                .help("Mole clears caches together. Keep a path to leave it alone.")
                .accessibilityLabel("Include caches")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 34)
    }
}

private struct CategoryRow: View {
    let model: DigModel
    let category: DigCategory
    @ViewState private var expanded = false
    @ViewState private var hovering = false

    var body: some View {
        let picked = model.picked(category)
        let on = picked > 0
        let shown = on ? picked : category.total
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Button { withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 11) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(on ? AnyShapeStyle(Palette.amberText) : AnyShapeStyle(.tertiary))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.name)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(on ? .primary : .tertiary)
                                .lineLimit(1)
                            ShareBar(share: Double(category.total) / Double(max(model.largestCategory, 1)), muted: !on)
                        }
                        Text(ByteText.string(shown))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(on ? .primary : .tertiary)
                            .contentTransition(.numericText(value: Double(shown)))
                        if !category.isPickable {
                            Chevron(expanded: expanded)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(expanded ? "Collapse" : "Expand")
                if category.isPickable {
                    Button { model.toggle(category) } label: {
                        CheckCircle(on: category.selection != .none, mixed: category.selection == .some)
                    }
                        .buttonStyle(.plain)
                        .disabled(!model.canEdit(category))
                        .accessibilityLabel("Include \(category.name)")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(minHeight: 46)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(category.items.prefix(60)) { item in
                        ItemRow(model: model, category: category, item: item)
                    }
                    if category.items.count > 60 {
                        Text("\(category.items.count - 60) more")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                }
                .padding(.leading, 43)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(hovering || expanded || model.hoveredVein == category.vein ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { inside in
            hovering = inside
            if model.phase == .ready || model.phase == .digging { model.hoveredVein = inside ? category.vein : nil }
        }
        .transition(.asymmetric(insertion: .offset(x: 14).combined(with: .opacity), removal: .opacity))
    }
}

private struct ItemRow: View {
    let model: DigModel
    let category: DigCategory
    let item: DigItem
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if category.isPickable {
                Button { model.toggle(item, in: category) } label: { CheckCircle(on: item.included, size: 18) }
                    .buttonStyle(.plain)
                    .disabled(!model.canEdit(category))
                    .accessibilityLabel("Include \(item.name)")
            }
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(!item.included, color: .secondary)
                .foregroundStyle(item.included ? .secondary : .tertiary)
            Spacer(minLength: 6)
            if category.kind == .cache, item.path != nil, model.phase == .ready, hovering || !item.included {
                Button(item.included ? "Keep" : "Kept") { model.toggle(item, in: category) }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.hover))
                    .help(item.included ? "Always keep this path. Saved to Mole's protected list." : "Let Mole clear this again")
            }
            Text(ByteText.string(item.bytes))
                .monospacedDigit()
                .foregroundStyle(item.included ? .secondary : .tertiary)
                .strikethrough(!item.included, color: .secondary)
        }
        .font(.system(size: 12.5))
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.path.map(Paths.abbreviatingHome) ?? item.name)
        .contextMenu {
            if let path = item.path {
                Button("Show in Finder") { revealInFinder(path) }
            }
        }
    }
}

private struct ReviewRow: View {
    let items: [ReviewItem]

    var body: some View {
        DisclosureRow(symbol: "eye", title: "Yours to check", bytes: items.map(\.bytes).reduce(0, +)) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { RevealRow(title: $0.title, path: $0.path, bytes: $0.bytes) }
                }
                .padding(.leading, 43)
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 200)
            .scrollIndicators(.never)
        }
        .help("Mole never clears these. Open them and decide yourself.")
    }
}

private struct NotesRow: View {
    let notes: [String]

    var body: some View {
        DisclosureRow(symbol: "exclamationmark.circle", tint: Palette.amberText,
                      title: notes.count == 1 ? "1 note from Mole" : "\(notes.count) notes from Mole") {
            ScrollView {
                Text(notes.joined(separator: "\n"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 43)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
            .frame(maxHeight: 180)
        }
    }
}

extension DigCategory {
    var name: String {
        switch kind {
        case .installers: "Installers"
        case .projects: "Build leftovers"
        case .cache: Self.cacheNames[id] ?? id
        }
    }

    var symbol: String {
        switch kind {
        case .installers: "shippingbox"
        case .projects: "hammer"
        case .cache: Self.cacheSymbols[id] ?? "square.stack.3d.up"
        }
    }

    private static let cacheNames = [
        "User essentials": "Caches & logs",
        "App caches": "macOS caches",
        "Browsers": "Browser caches",
        "Developer tools": "Developer caches",
        "Apps & utilities": "App storage",
        "Application Support": "Support files",
        "Apple Silicon updates": "Old updates",
        "Device backups & firmware": "Device backups",
    ]

    private static let cacheSymbols = [
        "User essentials": "square.grid.2x2",
        "App caches": "macwindow",
        "Browsers": "globe",
        "Cloud & Office": "cloud",
        "Developer tools": "chevron.left.forwardslash.chevron.right",
        "Apps & utilities": "cylinder.split.1x2",
        "Virtualization": "cube",
        "Application Support": "folder",
        "App leftovers": "app.dashed",
        "Apple Silicon updates": "arrow.down.circle",
        "Device backups & firmware": "iphone",
        "Time Machine": "clock.arrow.circlepath",
        "System": "gearshape",
    ]
}
