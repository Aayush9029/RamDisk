import SwiftUI

/// A thin track with a small thumb, in place of the system slider.
struct PanelSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    var onEnded: () -> Void = {}

    private static let thumb: CGFloat = 14

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width - Self.thumb
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let offset = travel * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(tint)
                    .frame(width: offset + Self.thumb / 2, height: 4)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .offset(x: offset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let fraction = min(max((drag.location.x - Self.thumb / 2) / travel, 0), 1)
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnded()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 18)
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }
}
