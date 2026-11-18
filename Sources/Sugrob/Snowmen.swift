import AppKit
import simd

/// A picture laid on the screen as a quad, drawn sharp over the snow.
struct PictureSprite {
    enum Kind: Int, CaseIterable {
        case ball, face, hat, scarf, arms, buttons, plow, wheel, beacon
    }

    var kind: Kind
    /// The middle of its bottom edge, which it turns around.
    var anchor: SIMD2<Float>
    /// In points; a negative width mirrors it.
    var size: SIMD2<Float>
    var angle: Float = 0
    var alpha: Float = 1
}

/// Snowmen rolled out of the snow on the Dock, or along the bottom of the screen without one, and the snowplow that
/// comes by now and then.
///
/// Moving the pointer along through the drift packs the snow into a ball; the pointer then pushes the ball along, and
/// it grows with the snow it rolls over. Pushed into another ball, it rolls up on top of it; the third ball makes a
/// snowman, with a face, a hat, a scarf and arms. A fast swipe knocks a stack down. The plow drives through every few
/// minutes, more often in heavier snow, and anything standing in its way bursts into powder.
final class SnowYard {
    /// A stack of balls: one lying loose, which the pointer can push, or two or three standing.
    struct Snowman {
        var x: Float
        var base: Float
        /// Radii from the bottom up.
        var balls: [Float]
        let facing: Float
        let seed: Float
        /// How far a loose ball has turned rolling.
        var angle: Float = 0
        var appear: Float = 0
        var squash: Float = 0
        /// Seconds a loose ball has lain untouched.
        var idle: Float = 0
        /// The top ball rolling up onto the stack: from 0 where it was pushed in, to 1 on top.
        var climb: Float = 1
        var climbFrom = SIMD2<Float>(repeating: 0)
        /// A whole snowman's face, hat, scarf and arms popping into place.
        var dressed: Float = 0

        var loose: Bool { balls.count == 1 }
        var whole: Bool { balls.count == 3 }
        var volume: Float { balls.reduce(0) { $0 + .pi * $1 * $1 } }
    }

    struct Plow {
        var x: Float
        let direction: Float
        /// Whether this run goes up over the Dock; the first runs along the bottom of the screen below it, in front.
        var climbs = false
        var travelled: Float = 0
        /// The bottom of the snow under it: the ground, or the top of the Dock.
        var road: Float = 0
        /// Snow piled against the bucket, eased: how big a heap rides in front of it.
        var load: Float = 0
        var smoke: Float = 0
    }

    /// Snow thrown off the bucket, exhaust, and powder from a burst: drawn as sprites, gone without settling.
    struct Bit {
        enum Kind { case spray, smoke, powder }
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var size: Float
        var life: Float
        let maxLife: Float
        let kind: Kind
    }

    /// Snowmen and the plow are drawn at two thirds of their first size.
    static let scale: Float = 1 / 1.5
    static let largestBall: Float = 40
    private static let seedRadius: Float = 5
    /// How far the pointer travels through the drift before the snow it packs becomes a ball.
    private static let seedTravel: Float = 30
    private static let maxLoose = 4
    private static let maxStacks = 8
    /// How far from its middle the pointer pushes a ball.
    private static let pointerReach: Float = 8
    private static let plowSpeed: Float = 95
    /// The plow's reach behind and ahead of its middle, and the snow it leaves on the road.
    private static let plowReach: (back: Float, front: Float) = (72 * scale, 94 * scale)
    private static let leftOnRoad: Float = 0.8
    /// How long the ramps up onto the Dock and down off it are.
    private static let ramp: Float = 55

    private(set) var snowmen: [Snowman] = []
    private(set) var plow: Plow?
    private(set) var bits: [Bit] = []
    /// Minutes between the plow's runs at a steady snowfall; heavier snow brings it sooner, lighter later. Zero: never.
    var plowEvery: Float = 5 {
        didSet { nextPlowAt = nil }
    }
    /// Snow, not leaves or rain, settling where the snowmen stand.
    var active = true
    /// Throws snow as loose grains that fall back into the drift: an area, from where, how fast.
    var release: (Float, SIMD2<Float>, SIMD2<Float>) -> Void = { _, _, _ in }

    /// The drift snowmen are rolled from: the snow on the Dock where there is one, else the ground; and how far along
    /// it they can go, left to right.
    private var layer: SnowLayer?
    private var span: ClosedRange<Float> = 0...0
    /// The drift along the bottom of the screen, which the plow drives in and out along, and the screen's width.
    private var bottom: SnowLayer?
    private var screenWidth: Float = 0
    /// Whether the yard is on the Dock's snow rather than the ground's.
    private var onDock = false
    /// Drawn over the snow, in a sharp layer of their own, the balls sit on top of the drift rather than in it.
    private let footSink: Float = 0.95
    private var nextPlowAt: Float?
    private var packed: Float = 0
    private var lastCursor: SIMD2<Float>?
    private var time: Float = 0
    private var changed = false

    /// Anything moving that needs the next frame drawn.
    var busy: Bool {
        plow != nil || !bits.isEmpty || changed
            || snowmen.contains { $0.appear < 1 || $0.squash > 0 || $0.climb < 1 || ($0.whole && $0.dressed < 1) }
    }

    /// Sets the drift to work on, before the pointer is tracked: the snow on the Dock, or the ground.
    func use(_ ground: SnowLayer, span: ClosedRange<Float>, onDock: Bool, bottom: SnowLayer, screenWidth: Float) {
        layer = ground
        self.span = span
        self.onDock = onDock
        self.bottom = bottom
        self.screenWidth = screenWidth
    }

    /// Whether the pointer is at a loose ball, pushing it, or packing snow along the drift, rather than sweeping it.
    func claims(_ point: SIMD2<Float>, velocity: SIMD2<Float>) -> Bool {
        guard active, let ground = layer else { return false }
        let pushing = snowmen.contains { snowman in
            guard snowman.loose else { return false }
            let radius = snowman.balls[0]
            return abs(point.x - snowman.x) < radius + Self.pointerReach + 4
                && point.y > floor(under: snowman.x, in: ground) - 14 && point.y < snowman.base + radius * 2 + 6
        }
        return pushing || packs(at: point, velocity: velocity, ground: ground)
    }

    private func floor(under x: Float, in ground: SnowLayer) -> Float {
        ground.floor(ground.clampedIndex(at: x))
    }

    /// Moving steadily along just above or in the drift, the pointer packs its snow; a fast swipe sweeps it.
    private func packs(at point: SIMD2<Float>, velocity: SIMD2<Float>, ground: SnowLayer) -> Bool {
        guard point.x > span.lowerBound + 6, point.x < span.upperBound - 6, simd_length(velocity) < 1400,
              point.y > floor(under: point.x, in: ground) - 14 else { return false }
        let from = ground.clampedIndex(at: point.x - 8), to = ground.clampedIndex(at: point.x + 8)
        var top: Float = 0, depth: Float = 0
        for i in from...to {
            top = max(top, ground.surface(i))
            depth += ground.heights[i]
        }
        return depth / Float(to - from + 1) > 1.2 && point.y < top + 14
    }

    // MARK: - Step

    /// Returns whether the drift's heights changed.
    func step(dt: Float, cursor: SIMD2<Float>, cursorVelocity: SIMD2<Float>, intensity: Float) -> Bool {
        guard let ground = layer else { return false }
        time += dt
        changed = false
        // A Dock that shrinks drops what stood past its new end.
        for k in snowmen.indices.reversed() where snowmen[k].x < span.lowerBound - 4 || snowmen[k].x > span.upperBound + 4 {
            burst(k, push: .zero, violent: false)
        }
        let previous = lastCursor
        lastCursor = cursor
        var dug = false
        if active, let previous {
            dug = handle(cursor, from: previous, velocity: cursorVelocity, ground: ground)
        }
        settle(dt: dt, ground: ground)
        dug = drivePlow(dt: dt, ground: ground, intensity: intensity) || dug
        advanceBits(dt: dt)
        return dug
    }

    private func handle(_ cursor: SIMD2<Float>, from previous: SIMD2<Float>, velocity: SIMD2<Float>, ground: SnowLayer) -> Bool {
        if simd_length(velocity) > 1600, let k = snowmen.lastIndex(where: { !$0.loose && touches($0, cursor) }) {
            burst(k, push: velocity * 0.3, violent: false)
            return false
        }
        // The pointer pushes a loose ball ahead of it, the way it came from.
        for k in snowmen.indices where snowmen[k].loose && snowmen[k].climb >= 1 {
            let radius = snowmen[k].balls[0]
            // Anywhere below its top counts, down in the drift too: the pointer is packing snow there.
            guard cursor.y > floor(under: snowmen[k].x, in: ground) - 14, cursor.y < snowmen[k].base + radius * 2 + 4 else { continue }
            let gap = radius + Self.pointerReach
            guard abs(snowmen[k].x - cursor.x) < gap else { continue }
            let side: Float = previous.x <= snowmen[k].x ? 1 : -1
            let target = min(max(cursor.x + side * gap, span.lowerBound + radius), span.upperBound - radius)
            let dug = roll(k, to: target, in: ground)
            if let j = stackTarget(for: k) { stack(k, onto: j) }
            packed = 0
            return dug
        }
        // Moved along the drift, the pointer packs the snow it passes into a new ball.
        guard packs(at: cursor, velocity: velocity, ground: ground) else {
            packed = 0
            return false
        }
        // A jump across the screen packs no more than a steady stroke would.
        packed += min(abs(cursor.x - previous.x), 20)
        guard packed > Self.seedTravel, snowmen.filter(\.loose).count < Self.maxLoose else { return false }
        packed = 0
        let side: Float = cursor.x >= previous.x ? 1 : -1
        let x = min(max(cursor.x + side * (Self.seedRadius + Self.pointerReach), span.lowerBound + 6), span.upperBound - 6)
        if snowmen.count >= Self.maxStacks, let oldest = snowmen.firstIndex(where: \.loose) ?? snowmen.indices.first {
            burst(oldest, push: .zero, violent: false)
        }
        var ball = Snowman(x: x, base: ground.surface(ground.clampedIndex(at: x)), balls: [Self.seedRadius],
                           facing: Bool.random() ? 1 : -1, seed: Float.random(in: 0...6.28))
        ball.appear = 0.4
        gather(&ball, at: ground.clampedIndex(at: x), in: ground, amount: 2)
        snowmen.append(ball)
        changed = true
        return true
    }

    private func roll(_ k: Int, to target: Float, in ground: SnowLayer) -> Bool {
        var ball = snowmen[k]
        let distance = target - ball.x
        guard distance != 0 else { return false }
        let steps = max(1, Int(abs(distance) / ground.columnWidth))
        let step = distance / Float(steps)
        for _ in 0..<steps {
            ball.x += step
            gather(&ball, at: ground.clampedIndex(at: ball.x), in: ground, amount: max(1, ball.balls[0] * 0.12))
        }
        ball.angle -= distance / max(ball.balls[0], 1)
        ball.base = ground.surface(ground.clampedIndex(at: ball.x))
        ball.idle = 0
        snowmen[k] = ball
        changed = true
        return true
    }

    /// Packs snow from the columns under the ball into it, most from the middle: it leaves a groove behind.
    private func gather(_ ball: inout Snowman, at i: Int, in ground: SnowLayer, amount: Float) {
        var radius = ball.balls[0]
        guard radius < Self.largestBall else { return }
        var area = Float.pi * radius * radius
        let reach = max(1, Int(radius * 0.4 / ground.columnWidth))
        for j in max(0, i - reach)...min(ground.count - 1, i + reach) {
            let weight = 1 - Float(abs(j - i)) / Float(reach + 1)
            let height = ground.heights[j]
            let take = min(max(height - Self.leftOnRoad, 0), amount * weight)
            guard take > 0 else { continue }
            ground.set(j, height - take)
            area += take * ground.columnWidth
        }
        radius = min(Self.largestBall, (area / .pi).squareRoot())
        ball.balls[0] = radius
    }

    /// The stack a loose ball has been pushed into, with room for it on top.
    private func stackTarget(for k: Int) -> Int? {
        let ball = snowmen[k]
        let touching = snowmen.indices.filter { j in
            j != k && snowmen[j].balls.count < 3 && snowmen[j].climb >= 1
                && abs(snowmen[j].x - ball.x) < ball.balls[0] + snowmen[j].balls[0] * 0.9
        }
        return touching.min { abs(snowmen[$0].x - ball.x) < abs(snowmen[$1].x - ball.x) }
    }

    /// Rolls the loose ball `k` up onto stack `j`; the bigger ball always ends up underneath.
    private func stack(_ k: Int, onto j: Int) {
        let mover = snowmen[k]
        var target = snowmen[j]
        let moverCenter = SIMD2(mover.x, mover.base + mover.balls[0] * footSink)
        let topCenter = geometry(of: target).last!.center
        if target.loose && mover.balls[0] > target.balls[0] {
            // The bigger one stays down and the smaller rolls up onto it.
            target.climbFrom = topCenter
            target.x = mover.x
            target.base = mover.base
        } else {
            target.climbFrom = moverCenter
        }
        target.balls = (target.balls + mover.balls).sorted(by: >)
        target.climb = 0
        target.idle = 0
        snowmen[j] = target
        snowmen.remove(at: k)
        changed = true
    }

    /// Builds a whole snowman at once, out of the snow around a spot clear of the others.
    func buildSnowman() {
        guard active, let ground = layer, span.upperBound - span.lowerBound > 120 else { return }
        let left = span.lowerBound, width = span.upperBound - span.lowerBound
        var x = left + Float.random(in: width * 0.15...width * 0.85)
        for _ in 0..<30 {
            let spot = left + Float.random(in: width * 0.1...width * 0.9)
            if snowmen.allSatisfy({ abs($0.x - spot) > 100 }) { x = spot; break }
        }
        let size = Float.random(in: 0.85...1.15)
        let balls = [21 * size, 16 * size, 11.5 * size]
        // As much of it as the drift around holds comes out of the drift.
        var wanted = balls.reduce(0) { $0 + .pi * $1 * $1 } * 0.6
        let from = ground.clampedIndex(at: x - 120), to = ground.clampedIndex(at: x + 120)
        for i in from...to where wanted > 0 {
            let take = min(max(ground.heights[i] - Self.leftOnRoad, 0) * 0.5, wanted / ground.columnWidth)
            ground.set(i, ground.heights[i] - take)
            wanted -= take * ground.columnWidth
        }
        if snowmen.count >= Self.maxStacks { burst(0, push: .zero, violent: false) }
        snowmen.append(Snowman(x: x, base: surface(under: x, reach: balls[0] * 0.4, in: ground), balls: balls,
                               facing: x > left + width / 2 ? -1 : 1, seed: Float.random(in: 0...6.28)))
        changed = true
    }

    func callPlow() {
        guard plow == nil, layer != nil else { return }
        // From either side: along the bottom of the screen under the Dock and off the far edge, then straight back
        // up over the Dock and off the edge it came in from. Without a Dock, the first run is all.
        start(direction: Bool.random() ? 1 : -1, climbs: false)
    }

    private func start(direction: Float, climbs: Bool) {
        let start = Self.plowReach.front + 20
        plow = Plow(x: direction > 0 ? -start : screenWidth + start, direction: direction, climbs: climbs)
        changed = true
    }

    /// Knocks every snowman down, as a gust clearing the snow does, blowing them `direction`.
    func knockAll(direction: Float) {
        while !snowmen.isEmpty { burst(snowmen.count - 1, push: SIMD2(direction * 500, 120), violent: false) }
    }

    /// Breaks a stack back into snow: tumbling into the drift, or, `violent`, bursting into a cloud of powder.
    private func burst(_ k: Int, push: SIMD2<Float>, violent: Bool) {
        let snowman = snowmen.remove(at: k)
        for (center, radius) in geometry(of: snowman) {
            let handfuls = max(1, Int(.pi * radius * radius / 40))
            let share = .pi * radius * radius * 0.85 / Float(handfuls)
            for _ in 0..<handfuls {
                let angle = Float.random(in: 0...(2 * .pi)), reach = radius * Float.random(in: 0...1).squareRoot()
                let out = SIMD2(cos(angle), sin(angle))
                let speed = violent ? Float.random(in: 120...330) : Float.random(in: 30...120)
                release(share, center + out * reach, push * Float.random(in: 0.5...1) + out * speed + SIMD2(0, violent ? 160 : 80))
            }
            guard violent else { continue }
            for _ in 0..<Int(radius * 2.2) {
                let angle = Float.random(in: 0...(2 * .pi))
                let out = SIMD2(cos(angle), sin(angle))
                let life = Float.random(in: 0.6...1.3)
                bits.append(Bit(position: center + out * radius * Float.random(in: 0...0.9),
                                velocity: out * Float.random(in: 40...240) + push * 0.3 + SIMD2(0, 50),
                                size: Float.random(in: 4...10), life: life, maxLife: life, kind: .powder))
            }
        }
        changed = true
    }

    /// A puff of sparkling powder as a third ball makes a snowman of the stack.
    private func celebrate(_ snowman: Snowman) {
        guard let head = geometry(of: snowman).last else { return }
        for _ in 0..<18 {
            let angle = Float.random(in: 0...(2 * .pi))
            let out = SIMD2(cos(angle), sin(angle))
            let life = Float.random(in: 0.5...0.9)
            bits.append(Bit(position: head.center + out * head.radius, velocity: out * Float.random(in: 40...110) + SIMD2(0, 30),
                            size: Float.random(in: 2...4), life: life, maxLife: life, kind: .powder))
        }
    }

    /// A loose ball rides on the drift; a stack sinks with the drift under it as it is swept or plowed away, and
    /// stands on a higher one at once. A small ball left alone long enough crumbles back into the drift.
    private func settle(dt: Float, ground: SnowLayer) {
        for k in snowmen.indices.reversed() {
            var snowman = snowmen[k]
            snowman.appear = min(1, snowman.appear + dt * 2.2)
            snowman.squash = max(0, snowman.squash - dt * 1.5)
            if snowman.climb < 1 {
                snowman.climb = min(1, snowman.climb + dt * 2.4)
                if snowman.climb >= 1 {
                    snowman.squash = 1
                    if snowman.whole { snowman.dressed = 0; celebrate(snowman) }
                }
            } else if snowman.whole {
                snowman.dressed = min(1, snowman.dressed + dt * 2.5)
            }
            let radius = snowman.balls.first ?? 10
            let foot = surface(under: snowman.x, reach: radius * 0.4, in: ground)
            if snowman.loose {
                snowman.base += (foot - snowman.base) * min(1, dt * 12)
                snowman.idle += dt
            } else if foot > snowman.base + 12 {
                // Moved onto a higher drift, as when the Dock comes back: it stands on it at once.
                snowman.base = foot
                changed = true
            } else if foot < snowman.base - 0.3 {
                snowman.base = max(foot, snowman.base - 220 * dt)
                changed = true
            }
            snowmen[k] = snowman
            if snowman.loose && radius < 9 && snowman.idle > 40 { burst(k, push: .zero, violent: false) }
        }
    }

    private func surface(under x: Float, reach: Float, in ground: SnowLayer) -> Float {
        let from = ground.clampedIndex(at: x - reach), to = ground.clampedIndex(at: x + reach)
        return (from...to).reduce(Float(0)) { max($0, ground.surface($1)) }
    }

    // MARK: - Plow

    /// Every `plowEvery` minutes at a steady snowfall, half that in the heaviest and up to three times it in light snow.
    private func plowInterval(_ intensity: Float) -> Float {
        plowEvery * 60 * min(max(0.5 / max(intensity, 0.01), 0.5), 3)
    }

    private func drivePlow(dt: Float, ground: SnowLayer, intensity: Float) -> Bool {
        if plowEvery > 0, active, ground.count > 0 {
            let due = nextPlowAt ?? time + plowInterval(intensity)
            nextPlowAt = due
            if plow == nil, time >= due {
                nextPlowAt = time + plowInterval(intensity)
                // Nothing to clear, nothing to do.
                if ground.heights.reduce(0, +) / Float(ground.count) > 1.5 || !snowmen.isEmpty { callPlow() }
            }
        }
        guard var p = plow else { return false }
        let move = Self.plowSpeed * dt
        p.x += p.direction * move
        p.travelled += move
        p.road = road(at: p.x, climbing: p.climbs)

        let a = p.x - p.direction * Self.plowReach.back, b = p.x + p.direction * Self.plowReach.front
        let low = min(a, b), high = max(a, b)
        var removed: Float = 0
        // Up on the Dock it clears the Dock's snow; down below, the drift along the bottom of the screen.
        for (cleared, inside) in [(ground, true), (bottom, false)] {
            guard let cleared, inside ? (p.climbs || !onDock) : (onDock && cleared !== ground) else { continue }
            guard high > 0, low < screenWidth else { continue }
            for i in cleared.clampedIndex(at: low)...cleared.clampedIndex(at: high) {
                let x = cleared.centerX(i)
                let onTop = !onDock || (p.climbs && span.contains(x))
                guard x >= low, x <= high, onTop == inside, cleared.heights[i] > Self.leftOnRoad else { continue }
                removed += (cleared.heights[i] - Self.leftOnRoad) * cleared.columnWidth
                cleared.set(i, Self.leftOnRoad)
            }
        }
        p.load += (removed / max(dt * 60, 0.2) - p.load) * min(1, dt * 3)

        // Whatever stands in the bucket's way bursts: up on the Dock, where the snowmen are.
        for k in snowmen.indices.reversed() where p.climbs || !onDock {
            let near = snowmen[k].x - p.direction * snowmen[k].balls[0] * 0.6
            let hit = p.direction > 0 ? b >= near && a < snowmen[k].x : b <= near && a > snowmen[k].x
            if hit { burst(k, push: SIMD2(p.direction * 220, 40), violent: true) }
        }

        // Snow flies off the top of the bucket, forward and up.
        let s = Self.scale
        let thrown = min(10, Int(removed / 10) + (removed > 1 ? 1 : 0))
        for _ in 0..<thrown {
            let life = Float.random(in: 0.7...1.1)
            bits.append(Bit(position: SIMD2(p.x + p.direction * Float.random(in: 80...94) * s, p.road + Float.random(in: 14...40) * s),
                            velocity: SIMD2(p.direction * Float.random(in: 30...190) + Float.random(in: -15...15), Float.random(in: 120...280)),
                            size: Float.random(in: 1.4...3.4), life: life, maxLife: life, kind: .spray))
        }
        p.smoke += dt
        if p.smoke > 0.14 {
            p.smoke = 0
            bits.append(Bit(position: SIMD2(p.x - p.direction * 47.5 * s, p.road + 73 * s),
                            velocity: SIMD2(-p.direction * Float.random(in: 8...24), Float.random(in: 20...36)),
                            size: Float.random(in: 4...6), life: 1.4, maxLife: 1.4, kind: .smoke))
        }

        let past = Self.plowReach.back + 30
        let gone = p.direction > 0 ? p.x > screenWidth + past : p.x < -past
        plow = gone ? nil : p
        if gone && onDock && !p.climbs { start(direction: -p.direction, climbs: true) }
        return removed > 0
    }

    /// Where the plow's wheels run at `x`: along the bottom of the screen, and, climbing, up a short ramp onto the
    /// Dock's top at either end of it.
    private func road(at x: Float, climbing: Bool) -> Float {
        guard let bottom else { return 0 }
        let low = bottom.floor(bottom.clampedIndex(at: x))
        guard onDock, climbing, let layer else { return low }
        let top = layer.floor(layer.clampedIndex(at: x))
        let outside = min(max(max(span.lowerBound - x, x - span.upperBound), 0) / Self.ramp, 1)
        return top + (low - top) * outside * outside * (3 - 2 * outside)
    }

    private func advanceBits(dt: Float) {
        var i = bits.count - 1
        while i >= 0 {
            bits[i].life -= dt
            if bits[i].life <= 0 {
                bits.swapAt(i, bits.count - 1)
                bits.removeLast()
                i -= 1
                continue
            }
            switch bits[i].kind {
            case .smoke:
                bits[i].velocity *= exp(-1.5 * dt)
                bits[i].size += 6 * dt
            case .powder:
                bits[i].velocity *= exp(-3.5 * dt)
                bits[i].velocity.y -= 40 * dt
                bits[i].size += 5 * dt
            case .spray:
                bits[i].velocity.y -= 620 * dt
            }
            bits[i].position += bits[i].velocity * dt
            i -= 1
        }
    }

    func writeSprites(into buffer: UnsafeMutablePointer<Sprite>, from start: Int, capacity: Int) -> Int {
        var count = start
        for bit in bits where count < capacity {
            let fade = bit.life / bit.maxLife
            switch bit.kind {
            case .smoke:
                buffer[count] = Sprite(position: bit.position, size: bit.size, alpha: 0.3 * fade, soft: 1, tintAmount: 1, tintRed: 0.45, tintGreen: 0.46, tintBlue: 0.5)
            case .powder:
                buffer[count] = Sprite(position: bit.position, size: bit.size, alpha: 0.7 * fade, soft: 0.8)
            case .spray:
                buffer[count] = Sprite(position: bit.position, velocity: bit.velocity, size: bit.size, alpha: min(1, fade * 1.5), soft: 0.15)
            }
            count += 1
        }
        return count
    }

    // MARK: - Pictures

    private func touches(_ snowman: Snowman, _ point: SIMD2<Float>) -> Bool {
        geometry(of: snowman).contains { simd_distance($0.center, point) < $0.radius }
    }

    /// Each ball's middle and radius, scaled about the snowman's foot as it pops up or bounces; the top ball on its
    /// way up while it climbs.
    private func geometry(of snowman: Snowman, scale: SIMD2<Float> = SIMD2(1, 1)) -> [(center: SIMD2<Float>, radius: Float)] {
        var result: [(center: SIMD2<Float>, radius: Float)] = []
        var top: Float = 0
        for (k, radius) in snowman.balls.enumerated() {
            let middle = top + radius * (k == 0 ? footSink : 0.85)
            result.append((SIMD2(snowman.x, snowman.base + middle * scale.y), radius * scale.x))
            top = middle + radius * 0.88
        }
        if snowman.climb < 1, let last = result.last {
            let t = snowman.climb * snowman.climb * (3 - 2 * snowman.climb)
            let along = snowman.climbFrom + (last.center - snowman.climbFrom) * t
            result[result.count - 1].center = along + SIMD2(0, sin(t * .pi) * last.radius * 0.7)
        }
        return result
    }

    /// A ball picture turned `angle` about its middle.
    private func ball(at center: SIMD2<Float>, radius: Float, angle: Float) -> PictureSprite {
        let lift = SIMD2(-sin(angle), cos(angle)) * radius
        return PictureSprite(kind: .ball, anchor: center - lift, size: SIMD2(radius * 2, radius * 2), angle: angle)
    }

    var pictures: [PictureSprite] {
        var out: [PictureSprite] = []
        if let p = plow { out += plowPictures(p) }
        for snowman in snowmen { out += pictures(of: snowman) }
        return out
    }

    private func pictures(of snowman: Snowman) -> [PictureSprite] {
        let t = snowman.appear
        let pop = 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2)
        let wobble = sin((1 - snowman.squash) * .pi * 3) * snowman.squash * 0.12
        let geo = geometry(of: snowman, scale: SIMD2(pop * (1 + wobble * 0.6), pop * (1 - wobble)))
        let f = snowman.facing
        // Dressed with a pop once the third ball is up.
        let d = snowman.whole && snowman.climb >= 1 ? snowman.dressed : 0
        let wear = d <= 0 ? 0 : 1 + 2.2 * pow(d - 1, 3) + 1.2 * pow(d - 1, 2)
        var out: [PictureSprite] = []
        if wear > 0 {
            let (c, r) = geo[1]
            out.append(PictureSprite(kind: .arms, anchor: c - SIMD2(0, r * 0.25), size: SIMD2(3.6 * r * f, 1.2 * r) * wear))
        }
        for (k, (c, r)) in geo.enumerated() {
            out.append(ball(at: c, radius: r, angle: snowman.loose ? snowman.angle : snowman.seed + Float(k) * 2.1))
        }
        guard wear > 0 else { return out }
        let (body, br) = geo[1], (head, hr) = geo[2]
        out.append(PictureSprite(kind: .buttons, anchor: body + SIMD2(f * br * 0.1, -br * 0.42), size: SIMD2(br * 0.2, br * 0.84) * wear))
        out.append(PictureSprite(kind: .scarf, anchor: head - SIMD2(0, hr * 1.72), size: SIMD2(2 * hr * f, 1.2 * hr) * wear))
        out.append(PictureSprite(kind: .face, anchor: head - SIMD2(0, hr), size: SIMD2(2 * hr * f, 2 * hr) * wear))
        out.append(PictureSprite(kind: .hat, anchor: head + SIMD2(0, hr * 0.74), size: SIMD2(2 * hr * f, 1.4 * hr) * wear, angle: -f * 0.14))
        return out
    }

    private func plowPictures(_ p: Plow) -> [PictureSprite] {
        let d = p.direction, s = Self.scale
        // It tilts with the ramp, its wheels each on the road under them.
        let rear = p.x - d * 40 * s, front = p.x + d * 24 * s
        let rearY = road(at: rear, climbing: p.climbs), frontY = road(at: front, climbing: p.climbs)
        let tilt = atan((frontY - rearY) / (front - rear))
        let y = rearY + (frontY - rearY) * (40.0 / 64)
        func turned(_ offset: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(offset.x * cos(tilt) - offset.y * sin(tilt), offset.x * sin(tilt) + offset.y * cos(tilt))
        }
        var out: [PictureSprite] = []
        let heap = min(16, 2 + p.load.squareRoot() * 1.4)
        if heap > 4 {
            let x = p.x + d * (92 * s + heap * 0.8)
            out.append(PictureSprite(kind: .ball, anchor: SIMD2(x, road(at: x, climbing: p.climbs) - heap * 0.35), size: SIMD2(heap * 2.2, heap * 1.5)))
        }
        let anchor = SIMD2(p.x, y) + turned(SIMD2(0, -4 * s))
        out.append(PictureSprite(kind: .plow, anchor: anchor, size: SIMD2(196 * d, 100) * s, angle: tilt))
        for (x, groundY) in [(rear, rearY), (front, frontY)] {
            // The tyre's canvas reaches a little past the tyre, for its lugs.
            let radius = 23 * s, drawn = radius * 40 / 36
            let center = SIMD2(x, groundY + radius)
            let angle = -d * p.travelled / radius
            out.append(PictureSprite(kind: .wheel, anchor: center - SIMD2(-sin(angle), cos(angle)) * drawn,
                                     size: SIMD2(drawn * 2, drawn * 2), angle: angle))
        }
        if sin(time * 12) > 0 {
            let lamp = SIMD2(p.x, y) + turned(SIMD2(-d * 6 * s, 66.5 * s))
            out.append(PictureSprite(kind: .beacon, anchor: lamp, size: SIMD2(40, 40) * s, angle: tilt))
        }
        return out
    }
}

// MARK: - Art

/// The snowmen's and the plow's pictures, drawn once into premultiplied BGRA and mipmapped by the renderer.
enum SnowArt {
    /// The picture's canvas in points and how many pixels each point gets.
    private static func canvas(_ kind: PictureSprite.Kind) -> (size: CGSize, scale: CGFloat) {
        switch kind {
        case .ball, .face: (CGSize(width: 100, height: 100), 2.56)
        case .hat: (CGSize(width: 100, height: 70), 2.56)
        case .scarf: (CGSize(width: 100, height: 60), 2.56)
        case .arms: (CGSize(width: 360, height: 120), 1.2)
        case .buttons: (CGSize(width: 20, height: 84), 3)
        case .plow: (CGSize(width: 196, height: 100), 5)
        case .wheel: (CGSize(width: 40, height: 40), 6)
        case .beacon: (CGSize(width: 40, height: 40), 4)
        }
    }

    static func draw(_ kind: PictureSprite.Kind) -> CGContext? {
        let (size, scale) = canvas(kind)
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch kind {
        case .ball: ball(ctx)
        case .face: face(ctx)
        case .hat: hat(ctx)
        case .scarf: scarf(ctx)
        case .arms: arms(ctx)
        case .buttons: buttons(ctx)
        case .plow: plow(ctx)
        case .wheel: wheel(ctx)
        case .beacon: beacon(ctx)
        }
        return ctx
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    }

    private static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private static func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
        ctx.setFillColor(fill)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    private static func polygon(_ ctx: CGContext, _ points: [CGPoint], _ fill: CGColor, stroke: CGColor? = nil, width: CGFloat = 1) {
        ctx.beginPath()
        ctx.addLines(between: points)
        ctx.closePath()
        ctx.setFillColor(fill)
        if let stroke {
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(width)
            ctx.drawPath(using: .fillStroke)
        } else {
            ctx.fillPath()
        }
    }

    private static func line(_ ctx: CGContext, _ points: [CGPoint], _ color: CGColor, _ width: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.beginPath()
        ctx.addLines(between: points)
        ctx.strokePath()
    }

    /// Packed snow, lit from the upper left, with specks that show it turn as it rolls.
    private static func ball(_ ctx: CGContext) {
        let rect = CGRect(x: 1, y: 1, width: 98, height: 98)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([color(1, 1, 1), color(0.95, 0.97, 1), color(0.74, 0.82, 0.94)], [0, 0.5, 1]),
            startCenter: CGPoint(x: 36, y: 66), startRadius: 0, endCenter: CGPoint(x: 50, y: 50), endRadius: 53,
            options: [.drawsAfterEndLocation]
        )
        // The same specks every launch: a fixed sequence, not the system's random numbers.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + (high - low) * CGFloat(state >> 40) / CGFloat(1 << 24)
        }
        for _ in 0..<16 {
            let angle = next(0, 2 * .pi), reach = 40 * next(0, 1).squareRoot()
            ctx.setFillColor(color(0.6, 0.7, 0.86, next(0.15, 0.3)))
            dot(ctx, 50 + cos(angle) * reach, 50 + sin(angle) * reach, next(1.2, 3.2))
        }
        ctx.restoreGState()
        ctx.setStrokeColor(color(0.55, 0.65, 0.82, 0.55))
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
    }

    /// Coal eyes and smile, and a carrot pointing the way it faces, on a head as big as the canvas.
    private static func face(_ ctx: CGContext) {
        ctx.setFillColor(color(0.1, 0.1, 0.12))
        dot(ctx, 42, 62, 4.6)
        dot(ctx, 70, 62, 4.6)
        for k in -2...2 {
            let kk = CGFloat(k)
            dot(ctx, 55 + kk * 7.5, 31 + kk * kk * 1.8, 2.4)
        }
        ctx.setFillColor(color(1, 1, 1, 0.8))
        dot(ctx, 43.3, 63.6, 1.3)
        dot(ctx, 71.3, 63.6, 1.3)
        let carrot = CGMutablePath()
        carrot.move(to: CGPoint(x: 56, y: 55))
        carrot.addQuadCurve(to: CGPoint(x: 98, y: 47.5), control: CGPoint(x: 80, y: 52))
        carrot.addQuadCurve(to: CGPoint(x: 56, y: 45), control: CGPoint(x: 80, y: 45))
        carrot.closeSubpath()
        ctx.addPath(carrot)
        ctx.setFillColor(color(0.97, 0.5, 0.1))
        ctx.fillPath()
        ctx.setStrokeColor(color(0.78, 0.33, 0.05, 0.8))
        ctx.setLineWidth(0.9)
        for x in [CGFloat(64), 72, 81] {
            ctx.move(to: CGPoint(x: x, y: 52 - (x - 56) * 0.08))
            ctx.addLine(to: CGPoint(x: x + 2, y: 49.5 - (x - 56) * 0.06))
            ctx.strokePath()
        }
    }

    private static func hat(_ ctx: CGContext) {
        let black = color(0.12, 0.12, 0.15)
        rounded(ctx, CGRect(x: 23, y: 6, width: 54, height: 58), 3, black)
        ctx.setFillColor(black)
        ctx.fillEllipse(in: CGRect(x: 6, y: 0, width: 88, height: 13))
        rounded(ctx, CGRect(x: 23, y: 11, width: 54, height: 10), 1, color(0.8, 0.16, 0.16))
        ctx.setStrokeColor(color(1, 1, 1, 0.18))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 30, y: 26))
        ctx.addLine(to: CGPoint(x: 30, y: 58))
        ctx.strokePath()
    }

    /// A knitted scarf round the neck, its end hanging behind the way the snowman faces.
    private static func scarf(_ ctx: CGContext) {
        let red = color(0.85, 0.2, 0.2), stripe = color(1, 0.92, 0.9)
        ctx.saveGState()
        ctx.translateBy(x: 30, y: 42)
        ctx.rotate(by: -0.12)
        rounded(ctx, CGRect(x: -8, y: -40, width: 16, height: 42), 4, red)
        for y in [CGFloat(-28), -16] { rounded(ctx, CGRect(x: -8, y: y, width: 16, height: 3.5), 1, stripe) }
        ctx.setStrokeColor(red)
        ctx.setLineWidth(1.6)
        for x in stride(from: CGFloat(-6), through: 6, by: 3) {
            ctx.move(to: CGPoint(x: x, y: -40))
            ctx.addLine(to: CGPoint(x: x, y: -45))
            ctx.strokePath()
        }
        ctx.restoreGState()
        rounded(ctx, CGRect(x: 5, y: 34, width: 90, height: 20), 9, red)
        ctx.setStrokeColor(color(0.62, 0.1, 0.12, 0.5))
        ctx.setLineWidth(1)
        for x in stride(from: CGFloat(14), through: 88, by: 7) {
            ctx.move(to: CGPoint(x: x, y: 37))
            ctx.addLine(to: CGPoint(x: x - 2, y: 51))
            ctx.strokePath()
        }
    }

    /// Two twigs reaching out of the middle ball: the one on the side it faces waves up.
    private static func arms(_ ctx: CGContext) {
        ctx.setStrokeColor(color(0.4, 0.26, 0.13))
        func stick(_ points: [CGPoint], _ width: CGFloat) {
            ctx.setLineWidth(width)
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
        stick([CGPoint(x: 248, y: 40), CGPoint(x: 300, y: 72), CGPoint(x: 350, y: 108)], 7)
        stick([CGPoint(x: 312, y: 80), CGPoint(x: 322, y: 114)], 4.5)
        stick([CGPoint(x: 336, y: 98), CGPoint(x: 356, y: 96)], 4)
        stick([CGPoint(x: 112, y: 40), CGPoint(x: 60, y: 54), CGPoint(x: 12, y: 74)], 7)
        stick([CGPoint(x: 48, y: 58), CGPoint(x: 36, y: 88)], 4.5)
        stick([CGPoint(x: 24, y: 69), CGPoint(x: 6, y: 62)], 4)
    }

    private static func buttons(_ ctx: CGContext) {
        ctx.setFillColor(color(0.12, 0.12, 0.14))
        for y in [CGFloat(12), 42, 72] { dot(ctx, 10, y, 6.5) }
    }

    /// A yellow wheel loader facing right, its bucket down to scrape the snow: rear counterweight and engine hood,
    /// a compact dark cab with big windows, the boom and its rams, and the bucket's teeth. Its wheels turn on their
    /// own. Drawn with the ground at y = 0 and the middle of the canvas at x = 0.
    private static func plow(_ ctx: CGContext) {
        ctx.translateBy(x: 98, y: 4)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let yellow = color(0.98, 0.72, 0.1), shade = color(0.84, 0.56, 0.05), light = color(1, 0.86, 0.4)
        let black = color(0.1, 0.1, 0.12), dark = color(0.2, 0.21, 0.24), steel = color(0.45, 0.47, 0.52)
        let chrome = color(0.82, 0.84, 0.88), glass = color(0.55, 0.68, 0.78, 0.92)

        // Shadow on the snow.
        ctx.setFillColor(color(0, 0, 0, 0.2))
        ctx.fillEllipse(in: CGRect(x: -72, y: -5, width: 168, height: 9))

        // Chassis and the articulation joint between the halves.
        rounded(ctx, CGRect(x: -64, y: 20, width: 122, height: 12), 3, dark)
        rounded(ctx, CGRect(x: -15, y: 18, width: 16, height: 22), 2, black)
        ctx.setFillColor(steel)
        dot(ctx, -7, 29, 3.2)

        // Rear: counterweight, engine hood, grille.
        polygon(ctx, [p(-72, 22), p(-68, 18), p(-58, 18), p(-58, 44), p(-70, 44), p(-73, 38)], shade)
        rounded(ctx, CGRect(x: -68, y: 30, width: 50, height: 24), 4, yellow)
        rounded(ctx, CGRect(x: -66, y: 50, width: 44, height: 6), 2, shade)
        for k in 0..<4 {
            let x = -64 + CGFloat(k) * 5
            line(ctx, [p(x, 34), p(x, 47)], color(0.25, 0.2, 0.08, 0.7), 1.6)
        }
        line(ctx, [p(-66, 53), p(-24, 53)], light, 1)
        // Tail lights and the rear bumper's step.
        rounded(ctx, CGRect(x: -72, y: 40, width: 3, height: 6), 1, color(0.85, 0.12, 0.1))
        rounded(ctx, CGRect(x: -74, y: 22, width: 8, height: 6), 1.5, black)

        // Exhaust stack and air precleaner.
        rounded(ctx, CGRect(x: -50, y: 54, width: 5, height: 16), 1.5, black)
        rounded(ctx, CGRect(x: -51, y: 68, width: 7, height: 3), 1, dark)
        rounded(ctx, CGRect(x: -38, y: 54, width: 7, height: 11), 2.5, black)
        rounded(ctx, CGRect(x: -39, y: 62, width: 9, height: 4), 2, dark)

        // Fenders over the big wheels.
        for x in [CGFloat(-40), 24] {
            ctx.setStrokeColor(black)
            ctx.setLineWidth(4)
            ctx.beginPath()
            ctx.addArc(center: p(x, 23), radius: 26, startAngle: .pi * 0.1, endAngle: .pi * 0.9, clockwise: false)
            ctx.strokePath()
        }

        // Cab, compact: dark frame, roof, big windows with an operator inside.
        rounded(ctx, CGRect(x: -22, y: 36, width: 30, height: 42), 3, black)
        rounded(ctx, CGRect(x: -25, y: 76, width: 36, height: 5), 2, yellow)
        line(ctx, [p(-24, 77), p(10, 77)], shade, 1)
        polygon(ctx, [p(-19, 49), p(-8, 49), p(-8, 74), p(-19, 74)], glass)
        polygon(ctx, [p(-5, 49), p(4, 49), p(6, 74), p(-5, 74)], glass)
        ctx.setFillColor(color(0.15, 0.17, 0.2, 0.75))
        dot(ctx, -9, 64, 3.2)
        rounded(ctx, CGRect(x: -13, y: 53, width: 9, height: 8), 2.5, color(0.15, 0.17, 0.2, 0.75))
        line(ctx, [p(-16, 71), p(-11, 52)], color(1, 1, 1, 0.45), 1.4)
        line(ctx, [p(0, 72), p(3, 58)], color(1, 1, 1, 0.35), 1.2)
        line(ctx, [p(-6.5, 46), p(-6.5, 76)], black, 1.4)
        // Roof work lights, the beacon's base, a mirror.
        rounded(ctx, CGRect(x: 5, y: 81, width: 5, height: 3), 1, color(1, 0.97, 0.85))
        rounded(ctx, CGRect(x: -24, y: 81, width: 5, height: 3), 1, color(1, 0.97, 0.85))
        rounded(ctx, CGRect(x: -11, y: 81, width: 10, height: 3), 1, dark)
        rounded(ctx, CGRect(x: -9, y: 83, width: 6, height: 6), 2.5, color(0.85, 0.55, 0.12))
        line(ctx, [p(8, 68), p(13, 71)], black, 1.3)
        rounded(ctx, CGRect(x: 12, y: 65, width: 3.5, height: 8), 1.5, black)

        // Handrails and the ladder up to the cab.
        line(ctx, [p(-28, 54), p(-28, 66), p(-24, 69)], black, 1.4)
        line(ctx, [p(-26, 18), p(-26, 36)], black, 1.4)
        line(ctx, [p(-18, 18), p(-18, 36)], black, 1.4)
        for y in stride(from: CGFloat(21), through: 35, by: 4.5) { line(ctx, [p(-26, y), p(-18, y)], black, 1.2) }

        // Front frame under the boom, with its headlight.
        polygon(ctx, [p(2, 22), p(30, 22), p(32, 38), p(12, 44), p(2, 40)], shade)
        rounded(ctx, CGRect(x: 29, y: 27, width: 4, height: 4), 1, color(1, 0.97, 0.8))

        // Lift ram: barrel and chrome rod, from the front frame up into the boom.
        line(ctx, [p(10, 28), p(26, 37)], dark, 5)
        line(ctx, [p(26, 37), p(40, 45)], chrome, 2.6)

        // Boom: from its pivot by the cab down to the bucket.
        polygon(ctx, [p(6, 54), p(14, 58), p(46, 40), p(66, 24), p(62, 16), p(42, 32), p(8, 48)], yellow, stroke: shade, width: 1)
        line(ctx, [p(10, 54), p(44, 36), p(63, 21)], light, 1)
        ctx.setFillColor(steel)
        dot(ctx, 10, 52, 3)
        dot(ctx, 63, 19, 3)

        // Tilt linkage: the bell crank on the boom and its ram, and the link down to the bucket.
        line(ctx, [p(14, 62), p(32, 54)], dark, 4.5)
        line(ctx, [p(32, 54), p(42, 50)], chrome, 2.2)
        polygon(ctx, [p(40, 54), p(46, 56), p(50, 42), p(44, 40)], yellow, stroke: shade, width: 0.8)
        line(ctx, [p(48, 44), p(70, 33)], dark, 3)
        ctx.setFillColor(steel)
        dot(ctx, 45, 48, 2.4)
        dot(ctx, 70, 33, 2.4)

        // Bucket: curved back, side plate, cutting edge and teeth.
        let bucket = CGMutablePath()
        bucket.move(to: p(64, 40))
        bucket.addLine(to: p(84, 36))
        bucket.addLine(to: p(92, 4))
        bucket.addLine(to: p(66, 2))
        bucket.addQuadCurve(to: p(64, 40), control: p(52, 18))
        ctx.addPath(bucket)
        ctx.setFillColor(color(0.17, 0.18, 0.2))
        ctx.fillPath()
        let plate = CGMutablePath()
        plate.move(to: p(66, 36))
        plate.addLine(to: p(82, 33))
        plate.addLine(to: p(88, 8))
        plate.addLine(to: p(68, 6))
        plate.addQuadCurve(to: p(66, 36), control: p(58, 20))
        ctx.addPath(plate)
        ctx.setFillColor(color(0.26, 0.27, 0.3))
        ctx.fillPath()
        line(ctx, [p(64, 40), p(84, 36)], color(0.5, 0.52, 0.56), 1.4)
        line(ctx, [p(66, 2), p(94, 3)], steel, 2)
        ctx.setFillColor(steel)
        for x in stride(from: CGFloat(70), through: 92, by: 5.5) {
            ctx.beginPath()
            ctx.addLines(between: [p(x - 1.8, 3), p(x + 2.4, 1), p(x + 1.2, 4.5)])
            ctx.closePath()
            ctx.fillPath()
        }
        // Wear on the bucket.
        line(ctx, [p(72, 30), p(80, 28)], color(0.6, 0.62, 0.66, 0.4), 1)
        line(ctx, [p(70, 20), p(76, 14)], color(0.6, 0.62, 0.66, 0.3), 1)
    }

    /// A big loader tyre with chunky slanted tread, on a yellow rim.
    private static func wheel(_ ctx: CGContext) {
        let c = CGPoint(x: 20, y: 20)
        ctx.setFillColor(color(0.13, 0.13, 0.15))
        dot(ctx, c.x, c.y, 18)
        // Slanted tread lugs: deep grooves between them, cut into the tyre's edge.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 18, y: c.y - 18, width: 36, height: 36))
        ctx.clip()
        ctx.setStrokeColor(color(0.04, 0.04, 0.05))
        ctx.setLineWidth(1.7)
        for k in 0..<18 {
            let a = CGFloat(k) * .pi / 9
            ctx.move(to: CGPoint(x: c.x + cos(a) * 14, y: c.y + sin(a) * 14))
            ctx.addLine(to: CGPoint(x: c.x + cos(a + 0.2) * 18.4, y: c.y + sin(a + 0.2) * 18.4))
            ctx.strokePath()
        }
        ctx.restoreGState()
        ctx.setStrokeColor(color(0.2, 0.2, 0.23))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: c.x - 13.5, y: c.y - 13.5, width: 27, height: 27))
        // Rim and hub.
        ctx.setFillColor(color(0.98, 0.7, 0.1))
        dot(ctx, c.x, c.y, 10)
        ctx.setFillColor(color(0.84, 0.55, 0.05))
        dot(ctx, c.x, c.y, 7)
        ctx.setFillColor(color(0.2, 0.2, 0.22))
        dot(ctx, c.x, c.y, 4.2)
        ctx.setFillColor(color(0.75, 0.76, 0.8))
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            dot(ctx, c.x + cos(a) * 5.6, c.y + sin(a) * 5.6, 0.9)
        }
        // The rim's notches show it turn.
        ctx.setFillColor(color(0.55, 0.36, 0.03))
        for k in 0..<4 {
            let a = CGFloat(k) * .pi / 2 + 0.4
            dot(ctx, c.x + cos(a) * 8.5, c.y + sin(a) * 8.5, 1.3)
        }
        ctx.setFillColor(color(1, 1, 1, 0.12))
        ctx.fillEllipse(in: CGRect(x: c.x - 12, y: c.y + 4, width: 10, height: 7))
    }

    /// The flashing beacon's lit lamp and its glow.
    private static func beacon(_ ctx: CGContext) {
        ctx.drawRadialGradient(
            gradient([color(1, 0.65, 0.1, 0.6), color(1, 0.65, 0.1, 0)], [0, 1]),
            startCenter: CGPoint(x: 20, y: 20), startRadius: 0, endCenter: CGPoint(x: 20, y: 20), endRadius: 20, options: []
        )
        rounded(ctx, CGRect(x: 16, y: 16, width: 8, height: 7), 2.5, color(1, 0.8, 0.25))
    }
}
