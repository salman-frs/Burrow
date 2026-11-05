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

/// The earth palette the fields are drawn in: blue rock at depth rising to sand, graphite to stone in light mode.
struct FieldTheme {
    let ramp: [RGB]
    let air: RGB
    let airAlpha: Double
    let glow: Double
    let edgeTo: RGB
    let edgeMix: Double
    let amber: RGB
    let amberHot: RGB
    let core: RGB
    let additive: Bool

    static func of(_ scheme: ColorScheme) -> FieldTheme { scheme == .dark ? dark : light }

    static let dark = FieldTheme(
        ramp: [0x46578C, 0x5269A0, 0x5F7FAD, 0x7093AE, 0x86A2A6, 0x9DAA9B, 0xB1AB90, 0xBCA586, 0xC29E7E].map(RGB.init),
        air: RGB(0xFFFFFF), airAlpha: 0.075, glow: 0.1, edgeTo: RGB(0xFFFFFF), edgeMix: 0.38,
        amber: RGB(0xFFB547), amberHot: RGB(0xFFE2AE), core: RGB(0xFFF4DE), additive: true)

    static let light = FieldTheme(
        ramp: [0x1E2944, 0x2A3753, 0x394763, 0x4B5873, 0x5F6A80, 0x747C8B, 0x888C93, 0x9A9790, 0xA89C88].map(RGB.init),
        air: RGB(r: 24, g: 32, b: 52), airAlpha: 0.07, glow: 0, edgeTo: RGB(r: 12, g: 16, b: 28), edgeMix: 0.45,
        amber: RGB(0xEC9300), amberHot: RGB(0xC46A00), core: RGB(0xFFF6E5), additive: false)

    /// Spreads `count` layers evenly over the ramp, deepest first.
    static func rampIndex(_ index: Int, of count: Int) -> Int {
        let last = 8
        guard count > 1 else { return last }
        return Int((Double(index) * Double(last) / Double(count - 1)).rounded())
    }

    func color(of shade: Shade) -> RGB {
        switch shade {
        case .ramp(let index): ramp[min(max(index, 0), ramp.count - 1)]
        case .insight(let index): ramp[min(max(index, 0), ramp.count - 1)].mixed(with: amber, 0.72)
        case .amber: amber
        }
    }
}

enum Shade: Equatable {
    case ramp(Int)
    case insight(Int)
    case amber
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
    var tunnelAt = CGFloat.infinity
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

struct Particle {
    let x: CGFloat
    let y: CGFloat
    let born: Double
    let life: Double
    let vx: Double
    let vy: Double
    let ay: Double
    let wobble: Double
    let phase: Double
}

/// The path the digger's lamp follows: a dive into the top layer, then back-and-forth passes through it.
struct DiggerPath {
    let points: [CGPoint]
    let lengths: [CGFloat]
    let entryLength: CGFloat
    let start: Double
    let speed: CGFloat
    var endedAt: Double?

    var total: CGFloat { lengths.last ?? 0 }

    /// The first pass carves the tunnel; after that the lamp sweeps the passes until the scan ends.
    func travelled(at now: Double) -> (distance: CGFloat, forward: Bool) {
        let raw = CGFloat(max(now - start, 0)) * speed
        guard raw > total else { return (raw, true) }
        let sweep = max(total - entryLength, 1)
        let cycle = (raw - total).truncatingRemainder(dividingBy: sweep * 2)
        return cycle <= sweep ? (total - cycle, false) : (entryLength + cycle - sweep, true)
    }

    func firstPass(at now: Double) -> CGFloat {
        let time = min(now, endedAt ?? now)
        return min(CGFloat(max(time - start, 0)) * speed, total)
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
private func springOut(_ t: Double) -> Double { t >= 1 ? 1 : 1 - exp(-6.5 * t) * cos(8.5 * t) }
enum Moment {
    static var now: Double { Date.now.timeIntervalSinceReferenceDate }
}

/// A disk drawn as a cross-section of dots: free space is the air on top, the deepest layer sits at the bottom,
/// and each dot stands for the same number of bytes. Mutations happen in event handlers; drawing only reads.
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
    @ObservationIgnored private var tunnelsFadeAt: Double?
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

    func invalidate() { revision += 1 }

    // MARK: Digging

    private func clearDigState() {
        for index in cells.indices {
            cells[index].row = index / max(columns, 1)
            cells[index].y = origin.y + CGFloat(cells[index].row) * pitch
            cells[index].vein = -1
            cells[index].revealedAt = 0
            cells[index].lit = false
            cells[index].takenAt = nil
            cells[index].tunnelAt = .infinity
            cells[index].fall = nil
        }
        grid = Array(cells.indices)
        veins = [:]
        digger = nil
        tunnelsFadeAt = nil
        particles = []
    }

    /// Lays the lamp's path through the top layer between `xMin` and `xMax` and starts it moving.
    func startDigging(from xMin: CGFloat, to xMax: CGFloat, start: Double) {
        let topStratum = strata.count - 1
        guard topStratum >= 0, let band = band(of: topStratum, from: xMin, to: xMax) else { return }
        let passes = 3
        let spacing = max((band.bottom - band.top - 16) / CGFloat(passes), pitch * 1.5)
        let ys = (0..<passes).map { band.top + 12 + spacing * (CGFloat($0) + 0.5) }
        let turn = spacing / 2
        let left = xMin + turn
        let right = xMax - turn
        var points: [CGPoint] = []
        let entry = CGPoint(x: left - 50, y: band.top - 70)
        for step in 0...30 {
            let t = CGFloat(step) / 30
            let u = 1 - t
            points.append(CGPoint(x: u * u * entry.x + 2 * u * t * (left - 40) + t * t * left,
                                  y: u * u * entry.y + 2 * u * t * ys[0] + t * t * ys[0]))
        }
        let entryCount = points.count
        for (pass, y) in ys.enumerated() {
            let forward = pass % 2 == 0
            var x = left
            while x <= right {
                let px = forward ? x : right - (x - left)
                points.append(CGPoint(x: px, y: y + sin(px * 0.031 + CGFloat(pass) * 1.7) * 5))
                x += 4
            }
            guard pass < ys.count - 1 else { break }
            let cx = forward ? right : left
            let cy = (y + ys[pass + 1]) / 2
            for degrees in stride(from: -90.0, through: 90.0, by: 9) {
                let angle = degrees * .pi / 180
                points.append(CGPoint(x: cx + (forward ? 1 : -1) * CGFloat(cos(angle)) * turn * 0.9,
                                      y: cy + CGFloat(sin(angle)) * spacing / 2))
            }
        }
        var lengths: [CGFloat] = [0]
        for i in 1..<points.count {
            lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let path = DiggerPath(points: points, lengths: lengths, entryLength: lengths[entryCount - 1],
                              start: start, speed: max(lengths.last ?? 0, 1) / 7, endedAt: nil)
        markTunnel(along: path)
        digger = path
        setContinuous(true)
    }

    private func markTunnel(along path: DiggerPath) {
        let reach = pitch * 0.85
        for (point, distance) in zip(path.points, path.lengths) {
            let column = Int(((point.x - origin.x) / pitch).rounded())
            let row = Int(((point.y - origin.y) / pitch).rounded())
            guard row >= 0, row < rows, column >= 0, column < columns else { continue }
            for r in max(row - 1, 0)...min(row + 1, rows - 1) {
                for c in max(column - 1, 0)...min(column + 1, columns - 1) {
                    let index = grid[r * columns + c]
                    let cell = cells[index]
                    guard cell.stratum >= 0, abs(cell.x - point.x) <= reach, abs(cell.y - point.y) <= reach else { continue }
                    cells[index].tunnelAt = min(cell.tunnelAt, distance)
                }
            }
        }
    }

    var diggerPosition: CGPoint? {
        guard let digger else { return nil }
        return digger.point(at: digger.travelled(at: Moment.now).distance)
    }

    func stopDigging() {
        guard digger != nil else { return }
        digger?.endedAt = Moment.now
        setContinuous(false)
        animate(until: Moment.now + 0.4)
    }

    /// Claims a vein of cells in the top layer around `point`, sized for `bytes`, and lets it glow into view.
    func placeVein(_ vein: Int, bytes: Int64, near point: CGPoint, from xMin: CGFloat, to xMax: CGFloat) {
        let topStratum = strata.count - 1
        guard topStratum >= 0 else { return }
        let tilt = (random.next() - 0.5) * 0.5
        var scored: [(index: Int, score: Double)] = []
        for index in cells.indices {
            let cell = cells[index]
            guard cell.stratum == topStratum, cell.vein < 0, cell.x > xMin - 20, cell.x < xMax + 20 else { continue }
            let dx = Double(cell.x - point.x)
            let dy = Double(cell.y - point.y) - dx * tilt
            scored.append((index, dx * dx / 5.5 + dy * dy + random.next() * 260))
        }
        scored.sort { $0.score < $1.score }
        let count = min(max(4, Int((Double(bytes) / unit).rounded())), scored.count)
        let start = Moment.now
        let claimed = scored.prefix(count).map(\.index)
        for index in claimed {
            let distance = hypot(cells[index].x - point.x, cells[index].y - point.y)
            cells[index].vein = vein
            cells[index].lit = true
            cells[index].revealedAt = start + Double(distance) / 420
        }
        veins[vein] = claimed
        animate(until: start + 1.2)
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

    /// Sends a vein's lit cells up as sparks; unlit ones go back to being plain ground.
    func release(_ vein: Int, rank: Int, from xMin: CGFloat, to xMax: CGFloat) {
        guard let indices = veins[vein] else { return }
        let start = Moment.now
        var deadline = start
        for index in indices {
            let cell = cells[index]
            guard cell.lit else {
                cells[index].vein = -1
                cells[index].revealedAt = 0
                continue
            }
            let delay = Double(rank) * 0.15 + clamp01(Double((cell.x - xMin) / max(xMax - xMin, 1))) * 0.38 + random.next() * 0.12
            let life = 1.3 + random.next() * 0.9
            particles.append(Particle(x: cell.x, y: cell.y, born: start + delay, life: life,
                                      vx: (random.next() - 0.5) * 26, vy: -20 - random.next() * 50,
                                      ay: -150 - random.next() * 170, wobble: 2 + random.next() * 3,
                                      phase: random.next() * .pi * 2))
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
        tunnelsFadeAt = start + 0.2
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
        return fall.fromY + (cell.y - fall.fromY) * CGFloat(springOut(t))
    }

    private func drawGround(in context: inout GraphicsContext, theme: FieldTheme, focus: Focus, time: Double) {
        var batches: [UInt32: Path] = [:]
        let r = radius
        let firstPass = digger?.firstPass(at: time) ?? -1
        let tunnelAlpha = tunnelsFadeAt.map { 0.16 + 0.84 * clamp01((time - $0) / 0.7) } ?? 0.16
        for cell in cells {
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
                if cell.tunnelAt <= firstPass { alpha *= tunnelAlpha }
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
                    dot(&hot, cell.x, y, r * 1.25 * pop)
                } else if focus.pulsing.contains(cell.vein) {
                    dot(&pulse, cell.x, y, r * pop)
                } else if dimmed {
                    dot(&coreDim, cell.x, y, r * pop)
                } else {
                    dot(&core, cell.x, y, r * pop)
                }
                if cell.lit, !dimmed, theme.glow > 0 { dot(&glow, cell.x, y, r * (focused ? 3.4 : 2.6) * pop) }
            }
        }
        if theme.glow > 0 {
            context.drawLayer { layer in
                if theme.additive { layer.blendMode = .plusLighter }
                layer.fill(glow, with: .color(theme.amber.color(theme.glow)))
            }
        }
        context.fill(offPath, with: .color(theme.amber.color(0.26)))
        context.fill(offDim, with: .color(theme.amber.color(0.12)))
        context.fill(core, with: .color(theme.amber.color()))
        context.fill(coreDim, with: .color(theme.amber.color(0.35)))
        context.fill(pulse, with: .color(theme.amber.color(0.55 + 0.45 * (0.5 + 0.5 * sin(time * 6)))))
        context.fill(hot, with: .color(theme.amberHot.color()))
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
                               with: .color(theme.amber.color()))
                    continue
                }
                let t = age / p.life
                guard t < 1 else { continue }
                func position(_ s: Double) -> CGPoint {
                    CGPoint(x: p.x + CGFloat(p.vx * s + sin(s * p.wobble + p.phase) * 6 * s),
                            y: p.y + CGFloat(p.vy * s + 0.5 * p.ay * s * s))
                }
                let head = position(age)
                let tail = position(max(0, age - 0.07))
                let fade = pow(1 - t, 1.4)
                let rgb = theme.amber.mixed(with: theme.core, t * 0.8)
                var trail = Path()
                trail.move(to: tail)
                trail.addLine(to: head)
                layer.stroke(trail, with: .color(rgb.color(fade * 0.55)),
                             style: StrokeStyle(lineWidth: r * 1.3 * CGFloat(1 - t * 0.5), lineCap: .round))
                let size = r * CGFloat(1 - t * 0.45)
                layer.fill(Path(ellipseIn: CGRect(x: head.x - size, y: head.y - size, width: size * 2, height: size * 2)),
                           with: .color(rgb.color(fade)))
            }
        }
    }

    private func drawDigger(in context: inout GraphicsContext, theme: FieldTheme, time: Double) {
        guard let digger else { return }
        let alpha = digger.alpha(at: time)
        guard alpha > 0 else { return }
        let (distance, forward) = digger.travelled(at: time)
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
                context.stroke(segment, with: .color(theme.amber.color(0.28 * a * a * alpha)),
                               style: StrokeStyle(lineWidth: 2 + 5 * a, lineCap: .round))
            }
        }
        let position = digger.point(at: distance)
        let halo = Gradient(stops: [
            .init(color: theme.amber.color(0.55 * alpha), location: 0),
            .init(color: theme.amber.color(0.16 * alpha), location: 0.35),
            .init(color: theme.amber.color(0), location: 1),
        ])
        context.fill(Path(ellipseIn: CGRect(x: position.x - 54, y: position.y - 54, width: 108, height: 108)),
                     with: .radialGradient(halo, center: position, startRadius: 0, endRadius: 54))
        context.fill(Path(ellipseIn: CGRect(x: position.x - 4.6, y: position.y - 4.6, width: 9.2, height: 9.2)),
                     with: .color(theme.core.color(alpha)))
    }
}

/// Draws a field and reports its size and hover position. The air layer only redraws on resize or theme change.
struct DotFieldView: View {
    let field: DotField
    var focus = DotField.Focus()
    var onResize: (CGSize) -> Void
    var onHover: ((CGPoint?) -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = FieldTheme.of(scheme)
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
