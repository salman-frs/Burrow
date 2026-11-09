import SwiftUI

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF)
        g = Double((hex >> 8) & 0xFF)
        b = Double(hex & 0xFF)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func color(_ alpha: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: alpha)
    }
}

struct FieldTheme {
    let ramp: [RGB]
    let air: RGB
    let airAlpha: Double
    let glow: Double
    let edgeTo: RGB
    let edgeMix: Double
    let accent: RGB
    let accentBright: RGB
    let spark: RGB
    let additive: Bool

    init(scheme: ColorScheme, accent palette: Accent) {
        let dark = scheme == .dark
        ramp = (dark ? Self.darkRamp : Self.lightRamp).map(RGB.init)
        air = dark ? RGB(0xFFFFFF) : RGB(0x463A28)
        airAlpha = 0.075
        glow = dark ? palette.glow : 0
        edgeTo = dark ? RGB(0xFFFFFF) : RGB(0x14161E)
        edgeMix = dark ? 0.38 : 0.3
        accent = RGB(palette.fill.hex(for: scheme))
        accentBright = RGB(palette.bright.hex(for: scheme))
        spark = RGB(palette.spark.hex(for: scheme))
        additive = dark
    }

    private static let darkRamp: [UInt32] = [0x46578C, 0x5269A0, 0x5F7FAD, 0x7093AE, 0x86A2A6, 0x9DAA9B, 0xB1AB90, 0xBCA586, 0xC29E7E]
    private static let lightRamp: [UInt32] = [0x32447B, 0x365281, 0x3B6186, 0x456D85, 0x4F7984, 0x787E77, 0x9C8067, 0xA78065, 0xB27F63]

    /// Spreads `count` layers evenly over the ramp, deepest first.
    static func rampIndex(_ index: Int, of count: Int) -> Int {
        let last = 8
        guard count > 1 else { return last }
        return Int((Double(index) * Double(last) / Double(count - 1)).rounded())
    }

    func color(of shade: Shade) -> RGB {
        switch shade {
        case .ramp(let index): ramp[min(max(index, 0), ramp.count - 1)]
        case .insight(let index): ramp[min(max(index, 0), ramp.count - 1)].mixed(with: accent, 0.72)
        case .accent: accent
        }
    }
}

enum Shade: Equatable {
    case ramp(Int)
    case insight(Int)
    case accent
}

struct Stratum: Equatable {
    let name: String
    let bytes: Int64
    let shade: Shade
}

struct DotCell {
    let column: Int
    var row: Int
    let x: CGFloat
    var y: CGFloat
    var stratum = -1
    var edge = false
    var morph: Morph?
    var vein = -1
    var revealedAt = 0.0
    var lit = false
    var takenAt: Double?
    var fall: Fall?

    struct Morph {
        let from: Shade?
        let to: Shade?
        let start: Double
    }

    struct Fall {
        let fromY: CGFloat
        let start: Double
    }
}

/// A cleared dot dropping out of the ground.
struct Particle {
    let x: CGFloat
    let y: CGFloat
    let born: Double
    let life: Double
    let vy: Double
    let ay: Double
}

/// The worm's search through the top layer. A scan that outlasts the path sends it back the way it came.
struct DiggerPath {
    let points: [CGPoint]
    let lengths: [CGFloat]
    let entryLength: CGFloat
    let start: Double
    let speed: CGFloat
    var endedAt: Double?

    var total: CGFloat { lengths.last ?? 0 }

    /// How far the worm has crawled, every turn back included.
    func crawled(at now: Double) -> CGFloat {
        CGFloat(max(min(now, endedAt ?? now) - start, 0)) * speed
    }

    func place(of crawled: CGFloat) -> (distance: CGFloat, forward: Bool) {
        guard crawled > total else { return (max(crawled, 0), true) }
        let sweep = max(total - entryLength, 1)
        let cycle = (crawled - total).truncatingRemainder(dividingBy: sweep * 2)
        return cycle <= sweep ? (total - cycle, false) : (entryLength + cycle - sweep, true)
    }

    func index(at distance: CGFloat) -> Int {
        var low = 0
        var high = lengths.count - 1
        while low < high {
            let mid = (low + high) / 2
            if lengths[mid] < distance { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func point(at distance: CGFloat) -> CGPoint {
        let i = index(at: distance)
        guard i > 0 else { return points.first ?? .zero }
        let span = lengths[i] - lengths[i - 1]
        let t = span > 0 ? (distance - lengths[i - 1]) / span : 0
        return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                       y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
    }

    func alpha(at now: Double) -> Double {
        let fadeIn = min(max((now - start) / 0.3, 0), 1)
        guard let endedAt else { return fadeIn }
        return fadeIn * min(max(1 - (now - endedAt) / 0.35, 0), 1)
    }
}

struct SeededRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state &+= 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
private func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
private func settleOut(_ t: Double) -> Double { t >= 1 ? 1 : 1 - pow(1 - t, 4) + sin(t * .pi) * 0.035 }
enum Moment {
    static var now: Double { Date.now.timeIntervalSinceReferenceDate }
}

/// Drawing runs every frame and must only read; all mutation happens in event handlers.
@MainActor
@Observable
final class DotField {
    @ObservationIgnored let pitch: CGFloat
    @ObservationIgnored let radius: CGFloat
    @ObservationIgnored let top: CGFloat
    @ObservationIgnored let drawsAir: Bool
    @ObservationIgnored private let seed: UInt32

    @ObservationIgnored private(set) var size: CGSize = .zero
    @ObservationIgnored private(set) var columns = 0
    @ObservationIgnored private(set) var rows = 0
    @ObservationIgnored private var origin: CGPoint = .zero
    @ObservationIgnored private(set) var firstRow = 0
    @ObservationIgnored private(set) var cells: [DotCell] = []
    @ObservationIgnored private var grid: [Int] = []
    @ObservationIgnored private(set) var strata: [Stratum] = []
    @ObservationIgnored private(set) var total: Int64 = 0
    @ObservationIgnored private(set) var unit: Double = 1

    @ObservationIgnored private(set) var veins: [Int: [Int]] = [:]
    @ObservationIgnored var digger: DiggerPath?
    @ObservationIgnored private var particles: [Particle] = []
    @ObservationIgnored private var random = SeededRandom(seed: 91)

    private(set) var revision = 0
    private(set) var animating = false
    @ObservationIgnored private var animatingUntil = 0.0
    @ObservationIgnored private var continuous = false
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    init(pitch: CGFloat = 9, radius: CGFloat = 2.4, top: CGFloat = 0, seed: UInt32 = 23, drawsAir: Bool = true) {
        self.pitch = pitch
        self.radius = radius
        self.top = top
        self.seed = seed
        self.drawsAir = drawsAir
    }

    var hasLayout: Bool { !cells.isEmpty && !strata.isEmpty }

    // MARK: Geometry

    /// Rebuilds the grid for a new size and lays the current strata out again. Returns false when nothing changed.
    @discardableResult
    func resize(to newSize: CGSize) -> Bool {
        let rounded = CGSize(width: newSize.width.rounded(), height: newSize.height.rounded())
        guard rounded != size, rounded.width > 0, rounded.height > 0 else { return false }
        size = rounded
        columns = Int(rounded.width / pitch)
        rows = Int(rounded.height / pitch)
        origin = CGPoint(x: (rounded.width - CGFloat(columns - 1) * pitch) / 2,
                         y: (rounded.height - CGFloat(rows - 1) * pitch) / 2)
        firstRow = max(0, Int(((top - origin.y) / pitch).rounded(.up)))
        cells = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(DotCell(column: column, row: row, x: origin.x + CGFloat(column) * pitch,
                                     y: origin.y + CGFloat(row) * pitch))
            }
        }
        grid = Array(cells.indices)
        clearDigState()
        if !strata.isEmpty { layout(strata, total: total) }
        revision += 1
        return true
    }

    private func surface(_ column: Int) -> Double {
        let c = Double(column)
        return sin(c * 0.045 + 0.6) * 2.1 + sin(c * 0.13 + 2.1) * 0.8 + sin(c * 0.019) * 1.5
    }

    /// Fills the disk from the bottom up, `strata[0]` deepest, with a wavy surface between layers.
    func layout(_ newStrata: [Stratum], total newTotal: Int64, animate: Bool = false) {
        strata = newStrata
        total = max(newTotal, 1)
        guard !cells.isEmpty else { return }
        clearDigState()
        var rand = SeededRandom(seed: seed)
        let disk = cells.indices.filter { cells[$0].row >= firstRow }
        let keyed = disk.map { ($0, Double(cells[$0].row) + surface(cells[$0].column) + rand.next() * 0.4) }
        let ordered = keyed.sorted { $0.1 > $1.1 }.map(\.0)
        unit = Double(total) / Double(max(disk.count, 1))
        let start = Moment.now
        var deadline = start
        var next = 0
        func assign(_ index: Int, to stratum: Int) {
            let previous = cells[index].stratum
            if animate {
                let delay = Double(cells[index].x / max(size.width, 1)) * 0.42 + rand.next() * 0.16
                cells[index].morph = DotCell.Morph(from: previous >= 0 ? previousShades[previous] : nil,
                                                   to: stratum >= 0 ? strata[stratum].shade : nil, start: start + delay)
                deadline = max(deadline, start + delay + 0.42)
            } else {
                cells[index].morph = nil
            }
            cells[index].stratum = stratum
        }
        for (k, stratum) in strata.enumerated() {
            let count = Int((Double(stratum.bytes) / unit).rounded())
            for _ in 0..<count where next < ordered.count {
                assign(ordered[next], to: k)
                next += 1
            }
        }
        while next < ordered.count {
            assign(ordered[next], to: -1)
            next += 1
        }
        previousShades = strata.map(\.shade)
        markEdges()
        revision += 1
        if animate { self.animate(until: deadline) }
    }

    @ObservationIgnored private var previousShades: [Shade] = []

    private func markEdges() {
        for index in cells.indices {
            let cell = cells[index]
            guard cell.stratum >= 0 else {
                cells[index].edge = false
                continue
            }
            if cell.row == 0 {
                cells[index].edge = true
            } else {
                let above = cells[grid[(cell.row - 1) * columns + cell.column]]
                cells[index].edge = above.stratum != cell.stratum
            }
        }
    }

    func cell(at point: CGPoint) -> DotCell? {
        let column = Int(((point.x - origin.x) / pitch).rounded())
        let row = Int(((point.y - origin.y) / pitch).rounded())
        guard column >= 0, row >= 0, column < columns, row < rows else { return nil }
        return cells[grid[row * columns + column]]
    }

    /// The vertical band the given stratum occupies between two x positions, averaged over its columns.
    func band(of stratum: Int, from xMin: CGFloat, to xMax: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        var topSum: CGFloat = 0
        var bottomSum: CGFloat = 0
        var count: CGFloat = 0
        for column in 0..<columns {
            let x = origin.x + CGFloat(column) * pitch
            guard x >= xMin, x <= xMax else { continue }
            var low = CGFloat.infinity
            var high = -CGFloat.infinity
            for row in 0..<rows {
                let cell = cells[grid[row * columns + column]]
                guard cell.stratum == stratum else { continue }
                low = min(low, cell.y)
                high = max(high, cell.y)
            }
            guard low.isFinite else { continue }
            topSum += low
            bottomSum += high
            count += 1
        }
        guard count > 0 else { return nil }
        return (topSum / count, bottomSum / count)
    }

    // MARK: Animation clock

    func animate(until deadline: Double) {
        animatingUntil = max(animatingUntil, deadline)
        if !animating { animating = true }
        scheduleStop()
    }

    /// Keeps frames coming for open-ended work such as a scan, however long it runs.
    func setContinuous(_ on: Bool) {
        continuous = on
        if on, !animating { animating = true }
        if !on { scheduleStop() }
    }

    private func scheduleStop() {
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            guard let self else { return }
            let wait = self.animatingUntil - Moment.now
            if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.05)) }
            guard !Task.isCancelled, !self.continuous, Moment.now >= self.animatingUntil else { return }
            self.animating = false
            self.revision += 1
        }
    }

    // MARK: Digging

    private func clearDigState() {
        for index in cells.indices {
            cells[index].row = index / max(columns, 1)
            cells[index].y = origin.y + CGFloat(cells[index].row) * pitch
            cells[index].vein = -1
            cells[index].revealedAt = 0
            cells[index].lit = false
            cells[index].takenAt = nil
            cells[index].fall = nil
        }
        grid = Array(cells.indices)
        veins = [:]
        digger = nil
        particles = []
    }

    private static let searchSpeed: CGFloat = 118
    private static let searchSeconds: CGFloat = 90
    private static let wakeSeconds = 2.1

    /// Sends the worm into the top layer between `xMin` and `xMax`, wandering between far-apart spots
    /// so a long scan keeps it moving through new ground.
    func startDigging(from xMin: CGFloat, to xMax: CGFloat, start: Double) {
        let topStratum = strata.count - 1
        guard topStratum >= 0, let band = band(of: topStratum, from: xMin, to: xMax) else { return }
        let top = band.top + pitch * 2.5
        let bottom = max(band.bottom - pitch * 1.5, top)
        var rand = SeededRandom(seed: seed &+ 34)
        var side: CGFloat = 1
        func nextTarget() -> CGPoint {
            side = -side
            let half = (xMax - xMin) / 2
            return CGPoint(x: xMin + 40 + (side > 0 ? half : 0) + CGFloat(rand.next()) * max(half - 80, 0),
                           y: top + CGFloat(rand.next()) * (bottom - top))
        }

        var points: [CGPoint] = []
        let entry = CGPoint(x: xMin - 20, y: band.top - 70)
        var position = CGPoint(x: xMin + 30, y: top + (bottom - top) * 0.35)
        for step in 0...30 {
            let t = CGFloat(step) / 30
            let u = 1 - t
            points.append(CGPoint(x: u * u * entry.x + 2 * u * t * (position.x - 30) + t * t * position.x,
                                  y: u * u * entry.y + 2 * u * t * position.y + t * t * position.y))
        }
        let entryCount = points.count
        var heading: CGFloat = 0.1
        var target = nextTarget()
        for step in 0..<Int(Self.searchSeconds * Self.searchSpeed / 3) {
            if hypot(target.x - position.x, target.y - position.y) < 36 { target = nextTarget() }
            let wanted = atan2(target.y - position.y, target.x - position.x)
            let steer = atan2(sin(wanted - heading), cos(wanted - heading))
            heading += min(max(steer, -0.045), 0.045) + sin(CGFloat(step) * 0.07) * 0.012
            position.x += cos(heading) * 3
            position.y = min(max(position.y + sin(heading) * 3, top), bottom)
            points.append(position)
        }
        var lengths: [CGFloat] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        digger = DiggerPath(points: points, lengths: lengths, entryLength: lengths[entryCount - 1],
                            start: start, speed: Self.searchSpeed, endedAt: nil)
        setContinuous(true)
    }

    /// Lights every mark the worm has not reached yet, in trail order, and lets its wake heal.
    func stopDigging() {
        guard let digger, digger.endedAt == nil else { return }
        let now = Moment.now
        self.digger?.endedAt = now
        var pending = 0
        for indices in veins.values {
            for index in indices where cells[index].revealedAt > now {
                cells[index].revealedAt = now + Double(pending) * 0.004
                pending += 1
            }
        }
        setContinuous(false)
        animate(until: now + Self.wakeSeconds + 0.4 + Double(pending) * 0.004)
        revision += 1
    }

    /// Claims a thread of top-layer dots for a find along the worm's trail: the stretch it has just dug
    /// lights at once, the rest as the worm reaches it. A dot stands for twice its usual share so big finds stay a thread.
    func markTrail(_ vein: Int, bytes: Int64) {
        guard let digger, digger.endedAt == nil, !cells.isEmpty else { return }
        let topStratum = strata.count - 1
        let now = Moment.now
        let head = digger.crawled(at: now)
        let wanted = max(4, Int((Double(bytes) / (unit * 2)).rounded()))
        var claims: [(index: Int, at: Double)] = []
        var taken = Set<Int>()

        func claim(near crawled: CGFloat, within reach: CGFloat, at time: Double) {
            let point = digger.point(at: digger.place(of: crawled).distance)
            let column = Int(((point.x - origin.x) / pitch).rounded())
            let row = Int(((point.y - origin.y) / pitch).rounded())
            guard column >= 0, column < columns, row >= 0, row < rows else { return }
            for r in max(row - 1, 0)...min(row + 1, rows - 1) {
                for c in max(column - 1, 0)...min(column + 1, columns - 1) where claims.count < wanted {
                    let index = grid[r * columns + c]
                    let cell = cells[index]
                    guard cell.stratum == topStratum, cell.vein < 0, !taken.contains(index),
                          hypot(cell.x - point.x, cell.y - point.y) <= reach else { continue }
                    taken.insert(index)
                    claims.append((index, time))
                }
            }
        }

        for reach in [pitch * 0.72, pitch * 1.25] {
            for behind in stride(from: head, through: max(head - Self.searchSpeed * 3, 0), by: -4) where claims.count < wanted {
                claim(near: behind, within: reach, at: now + Double(claims.count) * 0.009)
            }
            for ahead in stride(from: head, to: head + digger.total * 2, by: 4) where claims.count < wanted {
                claim(near: ahead, within: reach, at: digger.start + Double(ahead / digger.speed))
            }
        }
        claims.sort { $0.at < $1.at }
        for claim in claims {
            cells[claim.index].vein = vein
            cells[claim.index].lit = true
            cells[claim.index].revealedAt = claim.at
        }
        veins[vein] = claims.map(\.index)
        animate(until: now + 1.2)
        revision += 1
    }

    /// Lights the share of each vein that will be cleared, nearest cells first.
    func light(_ shares: [Int: Double]) {
        for (vein, indices) in veins {
            let lit = Int((clamp01(shares[vein] ?? 0) * Double(indices.count)).rounded())
            for (rank, index) in indices.enumerated() {
                cells[index].lit = rank < lit
            }
        }
        revision += 1
    }

    /// Drops a vein's lit cells out of the ground along its thread; unlit ones go back to being plain ground.
    func release(_ vein: Int, rank: Int) {
        guard let indices = veins[vein] else { return }
        let start = Moment.now
        var deadline = start
        for (order, index) in indices.enumerated() {
            let cell = cells[index]
            guard cell.lit else {
                cells[index].vein = -1
                cells[index].revealedAt = 0
                continue
            }
            let delay = Double(rank) * 0.15 + Double(order) / Double(indices.count) * 0.5 + random.next() * 0.05
            let life = 0.82 + random.next() * 0.26
            particles.append(Particle(x: cell.x, y: cell.y, born: start + delay, life: life,
                                      vy: 6 + random.next() * 14, ay: 620 + random.next() * 280))
            cells[index].takenAt = start + delay
            deadline = max(deadline, start + delay + life)
        }
        veins[vein] = nil
        animate(until: deadline)
        revision += 1
    }

    /// Lets the ground fall into the space the cleared veins left, column by column.
    func settle() {
        let start = Moment.now
        var columnsOfCells = Array(repeating: [Int](), count: columns)
        for index in cells.indices { columnsOfCells[cells[index].column].append(index) }
        for indices in columnsOfCells {
            let ordered = indices.sorted { cells[$0].row > cells[$1].row }
            let ground = ordered.filter { cells[$0].stratum >= 0 && cells[$0].takenAt == nil }
            let freed = ordered.filter { !(cells[$0].stratum >= 0 && cells[$0].takenAt == nil) }
            var row = rows - 1
            for index in ground {
                let y = origin.y + CGFloat(row) * pitch
                if cells[index].row != row {
                    cells[index].fall = DotCell.Fall(fromY: cells[index].y,
                                                     start: start + Double(rows - row) * 0.004 + random.next() * 0.12)
                }
                cells[index].row = row
                cells[index].y = y
                row -= 1
            }
            for index in freed {
                cells[index].row = row
                cells[index].y = origin.y + CGFloat(row) * pitch
                cells[index].stratum = -1
                cells[index].vein = -1
                cells[index].revealedAt = 0
                cells[index].takenAt = nil
                cells[index].fall = nil
                row -= 1
            }
        }
        for index in cells.indices { grid[cells[index].row * columns + cells[index].column] = index }
        markEdges()
        animate(until: start + 1.6)
        revision += 1
    }

    // MARK: Drawing

    func drawAir(in context: inout GraphicsContext, theme: FieldTheme) {
        guard drawsAir, rows > 0 else { return }
        let r = radius * 0.8
        for row in 0..<rows {
            let y = origin.y + CGFloat(row) * pitch
            let fade = top > 0 ? clamp01(Double((y - 6) / (top + 40))) : 1
            var path = Path()
            for column in 0..<columns {
                let x = origin.x + CGFloat(column) * pitch
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            context.fill(path, with: .color(theme.air.color(theme.airAlpha * fade * fade)))
        }
    }

    struct Focus {
        var stratum: Int?
        var vein: Int?
        var pulsing: Set<Int> = []
    }

    func draw(in context: inout GraphicsContext, theme: FieldTheme, focus: Focus = Focus()) {
        let time = Moment.now
        drawGround(in: &context, theme: theme, focus: focus, time: time)
        drawVeins(in: &context, theme: theme, focus: focus, time: time)
        drawParticles(in: &context, theme: theme, time: time)
        drawDigger(in: &context, theme: theme, time: time)
    }

    private func y(of cell: DotCell, at time: Double) -> CGFloat {
        guard let fall = cell.fall else { return cell.y }
        let t = (time - fall.start) / 0.76
        if t <= 0 { return fall.fromY }
        if t >= 1 { return cell.y }
        return fall.fromY + (cell.y - fall.fromY) * CGFloat(settleOut(t))
    }

    /// How dim each dot near the worm's recent trail is drawn: dug ground closes up again behind it.
    private func wake(at time: Double) -> [Int: Double] {
        guard let digger, !cells.isEmpty else { return [:] }
        let head = digger.crawled(at: time)
        let stillFor = time - min(time, digger.endedAt ?? time)
        let reach = pitch * 0.85
        var dimming: [Int: Double] = [:]
        for crawled in stride(from: head, through: max(head - digger.speed * Self.wakeSeconds, 0), by: -3) {
            let age = Double((head - crawled) / digger.speed) + stillFor
            let alpha = 0.22 + 0.78 * clamp01((age - 0.5) / 1.6)
            guard alpha < 1 else { continue }
            let point = digger.point(at: digger.place(of: crawled).distance)
            let column = Int(((point.x - origin.x) / pitch).rounded())
            let row = Int(((point.y - origin.y) / pitch).rounded())
            guard column >= 0, column < columns, row >= 0, row < rows else { continue }
            for r in max(row - 1, 0)...min(row + 1, rows - 1) {
                for c in max(column - 1, 0)...min(column + 1, columns - 1) {
                    let index = grid[r * columns + c]
                    guard abs(cells[index].x - point.x) <= reach, abs(cells[index].y - point.y) <= reach else { continue }
                    dimming[index] = min(dimming[index] ?? 1, alpha)
                }
            }
        }
        return dimming
    }

    private func drawGround(in context: inout GraphicsContext, theme: FieldTheme, focus: Focus, time: Double) {
        var batches: [UInt32: Path] = [:]
        let r = radius
        let wake = wake(at: time)
        for (index, cell) in cells.enumerated() {
            if cell.takenAt != nil || (cell.vein >= 0 && cell.revealedAt > 0 && time >= cell.revealedAt) { continue }
            var rgb: RGB
            var alpha = 1.0
            if let morph = cell.morph, time < morph.start + 0.42 {
                let t = clamp01((time - morph.start) / 0.42)
                let q = (easeInOut(t) * 10).rounded() / 10
                switch (morph.from, morph.to) {
                case (nil, nil): continue
                case (nil, let to?): rgb = theme.color(of: to); alpha = q
                case (let from?, nil): rgb = theme.color(of: from); alpha = 1 - q
                case (let from?, let to?): rgb = theme.color(of: from).mixed(with: theme.color(of: to), q)
                }
            } else {
                guard cell.stratum >= 0, cell.stratum < strata.count else { continue }
                rgb = theme.color(of: strata[cell.stratum].shade)
                if cell.edge { rgb = rgb.mixed(with: theme.edgeTo, theme.edgeMix) }
                if let stratum = focus.stratum, stratum != cell.stratum { alpha = 0.3 }
                if focus.vein != nil { alpha = 0.38 }
                alpha *= wake[index] ?? 1
            }
            guard alpha > 0.01 else { continue }
            let key = UInt32(rgb.r.rounded()) << 24 | UInt32(rgb.g.rounded()) << 16 | UInt32(rgb.b.rounded()) << 8
                | UInt32((alpha * 50).rounded())
            let y = y(of: cell, at: time)
            batches[key, default: Path()].addEllipse(in: CGRect(x: cell.x - r, y: y - r, width: r * 2, height: r * 2))
        }
        for (key, path) in batches {
            let rgb = RGB(r: Double(key >> 24), g: Double((key >> 16) & 0xFF), b: Double((key >> 8) & 0xFF))
            context.fill(path, with: .color(rgb.color(Double(key & 0xFF) / 50)))
        }
    }

    private func drawVeins(in context: inout GraphicsContext, theme: FieldTheme, focus: Focus, time: Double) {
        guard !veins.isEmpty else { return }
        let r = radius
        var glow = Path(), offPath = Path(), offDim = Path(), core = Path(), coreDim = Path(), hot = Path(), pulse = Path()
        func dot(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        for indices in veins.values {
            for index in indices {
                let cell = cells[index]
                guard cell.revealedAt > 0, cell.takenAt == nil, time >= cell.revealedAt else { continue }
                let age = time - cell.revealedAt
                let pop = CGFloat(age < 0.42 ? 1 + sin(clamp01(age / 0.42) * .pi) * 0.9 : 1)
                let y = y(of: cell, at: time)
                let focused = focus.vein == cell.vein
                let dimmed = focus.vein != nil && !focused
                if !cell.lit, dimmed {
                    dot(&offDim, cell.x, y, r * pop)
                } else if !cell.lit {
                    dot(&offPath, cell.x, y, r * pop)
                } else if focused {
                    dot(&hot, cell.x, y, r * 1.4 * pop)
                } else if focus.pulsing.contains(cell.vein) {
                    dot(&pulse, cell.x, y, r * 1.18 * pop)
                } else if dimmed {
                    dot(&coreDim, cell.x, y, r * 1.18 * pop)
                } else {
                    dot(&core, cell.x, y, r * 1.18 * pop)
                }
                if cell.lit, !dimmed, theme.glow > 0 { dot(&glow, cell.x, y, r * (focused ? 3.4 : 2.6) * pop) }
            }
        }
        if theme.glow > 0 {
            context.drawLayer { layer in
                if theme.additive { layer.blendMode = .plusLighter }
                layer.fill(glow, with: .color(theme.accent.color(theme.glow)))
            }
        }
        context.fill(offPath, with: .color(theme.accent.color(0.26)))
        context.fill(offDim, with: .color(theme.accent.color(0.12)))
        context.fill(core, with: .color(theme.accent.color()))
        context.fill(coreDim, with: .color(theme.accent.color(0.35)))
        context.fill(pulse, with: .color(theme.accent.color(0.55 + 0.45 * (0.5 + 0.5 * sin(time * 6)))))
        context.fill(hot, with: .color(theme.accentBright.color()))
    }

    private func drawParticles(in context: inout GraphicsContext, theme: FieldTheme, time: Double) {
        guard !particles.isEmpty else { return }
        let r = radius
        context.drawLayer { layer in
            if theme.additive { layer.blendMode = .plusLighter }
            for p in particles {
                let age = time - p.born
                if age < 0 {
                    layer.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(theme.accent.color()))
                    continue
                }
                let t = age / p.life
                guard t < 1 else { continue }
                func position(_ s: Double) -> CGPoint {
                    CGPoint(x: p.x, y: p.y + CGFloat(p.vy * s + 0.5 * p.ay * s * s))
                }
                let head = position(age)
                let tail = position(max(0, age - 0.07))
                let fade = pow(1 - t, 2.2)
                var trail = Path()
                trail.move(to: tail)
                trail.addLine(to: head)
                layer.stroke(trail, with: .color(theme.accent.color(fade * 0.3)),
                             style: StrokeStyle(lineWidth: r * 1.3 * CGFloat(1 - t * 0.5), lineCap: .round))
                let size = r * CGFloat(1 - t * 0.7)
                layer.fill(Path(ellipseIn: CGRect(x: head.x - size, y: head.y - size, width: size * 2, height: size * 2)),
                           with: .color(theme.accent.color(fade)))
            }
        }
    }

    private func drawDigger(in context: inout GraphicsContext, theme: FieldTheme, time: Double) {
        guard let digger else { return }
        let alpha = digger.alpha(at: time)
        guard alpha > 0 else { return }
        let (distance, forward) = digger.place(of: digger.crawled(at: time))
        let head = digger.index(at: distance)
        let tailLength = 90
        let from = forward ? max(0, head - tailLength) : min(digger.points.count - 1, head + tailLength)
        let span = abs(head - from)
        if span > 1 {
            for step in 1...span {
                let a = Double(step) / Double(span)
                let i0 = forward ? from + step - 1 : from - step + 1
                let i1 = forward ? from + step : from - step
                var segment = Path()
                segment.move(to: digger.points[i0])
                segment.addLine(to: digger.points[i1])
                context.stroke(segment, with: .color(theme.accent.color(0.28 * a * a * alpha)),
                               style: StrokeStyle(lineWidth: 2 + 5 * a, lineCap: .round))
            }
        }
        let position = digger.point(at: distance)
        let strength = theme.additive ? alpha : alpha * 0.3
        let halo = Gradient(stops: [
            .init(color: theme.accent.color(0.55 * strength), location: 0),
            .init(color: theme.accent.color(0.16 * strength), location: 0.35),
            .init(color: theme.accent.color(0), location: 1),
        ])
        context.fill(Path(ellipseIn: CGRect(x: position.x - 54, y: position.y - 54, width: 108, height: 108)),
                     with: .radialGradient(halo, center: position, startRadius: 0, endRadius: 54))
        context.fill(Path(ellipseIn: CGRect(x: position.x - 4.6, y: position.y - 4.6, width: 9.2, height: 9.2)),
                     with: .color(theme.spark.color(alpha)))
    }
}

struct DotFieldView: View {
    let field: DotField
    var focus = DotField.Focus()
    var onResize: (CGSize) -> Void
    var onHover: ((CGPoint?) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accent) private var accent

    var body: some View {
        let theme = FieldTheme(scheme: scheme, accent: accent)
        let revision = field.revision
        ZStack {
            if field.drawsAir {
                Canvas { context, _ in
                    _ = revision
                    field.drawAir(in: &context, theme: theme)
                }
            }
            TimelineView(.animation(paused: !field.animating)) { timeline in
                let frame = timeline.date
                Canvas { context, _ in
                    _ = (revision, frame)
                    field.draw(in: &context, theme: theme, focus: focus)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onResize(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onResize(size) }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): onHover?(location)
            case .ended: onHover?(nil)
            }
        }
    }
}

struct FieldMask: View {
    let width: CGFloat

    var body: some View {
        let start = width > 0 ? min(90 / width, 0.4) : 0
        let end = width > 0 ? min(330 / width, 0.6) : 0
        LinearGradient(stops: [.init(color: .clear, location: start), .init(color: .black, location: end)],
                       startPoint: .leading, endPoint: .trailing)
    }
}
