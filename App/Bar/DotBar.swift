import SwiftUI

struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, +)
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, -)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combine(_ lhs: AnimatableVector, _ rhs: AnimatableVector, _ operation: (Double, Double) -> Double) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        return AnimatableVector(values: (0..<count).map { index in
            operation(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }
}

struct BarColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// The dot-matrix bar. A Metal shader draws the cells, the borders, and the glow; a canvas draws the embers above it.
struct DotBar: View, @preconcurrency Animatable {
    static let pitch: CGFloat = 5
    static let defaultColumns = 92
    static let glowPadding: CGFloat = 14
    static let emberHeadroom: CGFloat = 46

    /// The width of each segment as a fraction of the bar.
    var widths: AnimatableVector
    var scan: Double
    let colors: [BarColor]
    var hovered: Int?
    var emberSource: Int?
    var columns = DotBar.defaultColumns
    var rows = 13
    var isAnimating = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var embers = EmberSystem()
    private let start = Date()

    var animatableData: AnimatablePair<AnimatableVector, Double> {
        get { AnimatablePair(widths, scan) }
        set {
            widths = newValue.first
            scan = newValue.second
        }
    }

    var size: CGSize {
        CGSize(width: CGFloat(columns) * Self.pitch, height: CGFloat(rows) * Self.pitch)
    }

    var body: some View {
        TimelineView(.animation(paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSince(start)
            Color.clear
                .frame(width: size.width, height: size.height)
                .overlay {
                    Rectangle()
                        .fill(.white)
                        .colorEffect(shader(time: time))
                        .frame(width: size.width + Self.glowPadding * 2, height: size.height + Self.glowPadding * 2)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    emberCanvas(date: context.date)
                }
        }
        .accessibilityHidden(true)
    }

    private var bounds: [(start: Double, end: Double)] {
        var cursor = 0.0
        return widths.values.map { width in
            let start = cursor
            cursor = min(1, cursor + max(0, width))
            return (start, cursor)
        }
    }

    private func shader(time: TimeInterval) -> Shader {
        var segments: [Float] = []
        for (index, bound) in bounds.enumerated() {
            let color = index < colors.count ? colors[index] : BarColor(0x888888)
            segments += [Float(bound.start), Float(bound.end), Float(color.red), Float(color.green), Float(color.blue)]
        }
        let front: Double = emberSource.flatMap { $0 < bounds.count ? bounds[$0].end : nil } ?? -1
        return ShaderLibrary.dotBar(
            .float2(size.width + Self.glowPadding * 2, size.height + Self.glowPadding * 2),
            .float(Self.glowPadding),
            .float(Self.pitch),
            .float(time),
            .float(Double(hovered ?? -1)),
            .float(scan),
            .float(front),
            .float(colorScheme == .light ? 1 : 0),
            .floatArray(segments)
        )
    }

    private func emberCanvas(date: Date) -> some View {
        let source: (x: CGFloat, color: BarColor)? = emberSource.flatMap { index in
            guard index < bounds.count, index < colors.count else { return nil }
            return ((bounds[index].end * size.width / Self.pitch).rounded() * Self.pitch, colors[index])
        }
        let isLight = colorScheme == .light
        return Canvas { context, canvasSize in
            let floor = canvasSize.height
            embers.step(to: date, source: source.map { CGPoint(x: $0.x, y: floor) }, barHeight: size.height)
            for ember in embers.particles {
                let progress = ember.age / ember.life
                let tint = source?.color ?? BarColor(0xFF8A1F)
                let heat = isLight ? 0 : max(0, 1 - progress * 1.6)
                let color = Color(
                    red: tint.red + (1 - tint.red) * heat,
                    green: tint.green + (0.94 - tint.green) * heat,
                    blue: tint.blue + (0.86 - tint.blue) * heat
                )
                let side = ember.size
                let rect = CGRect(x: ember.position.x - side / 2, y: ember.position.y - side / 2, width: side, height: side)
                context.fill(Path(rect), with: .color(color.opacity(1 - progress)))
            }
        }
        .frame(width: size.width + 80, height: size.height + Self.emberHeadroom)
        .allowsHitTesting(false)
    }
}

private struct Ember {
    var position: CGPoint
    var velocity: CGVector
    var age: Double = 0
    var life: Double
    var size: CGFloat
}

/// Mutable state that the canvas updates while it draws. It is a class so that a redraw does not invalidate the view.
@MainActor
private final class EmberSystem {
    private(set) var particles: [Ember] = []
    private var last: Date?

    func step(to date: Date, source: CGPoint?, barHeight: CGFloat) {
        let delta = min(last.map { date.timeIntervalSince($0) } ?? 0, 1.0 / 20)
        last = date

        for index in particles.indices {
            particles[index].age += delta
            particles[index].velocity.dy -= 60 * delta
            particles[index].velocity.dx *= 1 - 0.8 * delta
            particles[index].position.x += particles[index].velocity.dx * delta
            particles[index].position.y += particles[index].velocity.dy * delta
        }
        particles.removeAll { $0.age >= $0.life }

        guard let source, delta > 0 else { return }
        for _ in 0..<Int((delta * 420).rounded(.up)) {
            // The canvas is 40 points wider than the bar on each side.
            let cell = DotBar.pitch
            let x = 40 + source.x + CGFloat.random(in: -4...1).rounded() * cell
            let y = source.y - CGFloat.random(in: 0...1).magnitude * barHeight
            particles.append(Ember(
                position: CGPoint(x: x, y: (y / cell).rounded() * cell),
                velocity: CGVector(dx: .random(in: -14...46), dy: .random(in: -70...(-12))),
                life: .random(in: 0.35...1.1),
                size: .random(in: 2.2...3.4)
            ))
        }
    }
}
