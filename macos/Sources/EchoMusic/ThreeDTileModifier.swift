import SwiftUI

struct ThreeDTileModifier: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    @ViewState private var size: CGSize = CGSize(width: 162, height: 215)
    @ViewState private var offset: CGPoint = .zero
    @ViewState private var isHovered: Bool = false

    var maxAngle: Double = 10.0

    func body(content: Content) -> some View {
        let isActive = controlActiveState == .key
        let currentSize = size.width > 0 && size.height > 0 ? size : CGSize(width: 162, height: 215)
        let normalizedX = currentSize.width > 0 ? (offset.x - currentSize.width / 2) / (currentSize.width / 2) : 0
        let normalizedY = currentSize.height > 0 ? (offset.y - currentSize.height / 2) / (currentSize.height / 2) : 0

        let pitch = (isHovered && isActive) ? Double(-normalizedY) * maxAngle : 0
        let yaw = (isHovered && isActive) ? Double(normalizedX) * maxAngle : 0

        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TileSizePreferenceKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(TileSizePreferenceKey.self) { newSize in
                if newSize.width > 0 && newSize.height > 0 && newSize != size {
                    size = newSize
                }
            }
            .overlay(
                Group {
                    if isHovered && isActive && currentSize.width > 0 && currentSize.height > 0 {
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.06),
                                Color.clear
                            ]),
                            center: UnitPoint(
                                x: min(max(offset.x / currentSize.width, 0), 1),
                                y: min(max(offset.y / currentSize.height, 0), 1)
                            ),
                            startRadius: 8,
                            endRadius: max(currentSize.width, currentSize.height) * 0.7
                        )
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            )
            .rotation3DEffect(
                .degrees(pitch),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.4
            )
            .rotation3DEffect(
                .degrees(yaw),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.4
            )
            .scaleEffect(isHovered && isActive ? 1.03 : 1.0)
            .shadow(
                color: Color.black.opacity(isHovered && isActive ? 0.30 : 0.12),
                radius: isHovered && isActive ? 12 : 4,
                x: isHovered && isActive ? -CGFloat(yaw) * 0.6 : 0,
                y: isHovered && isActive ? CGFloat(pitch) * 0.6 + 5 : 2
            )
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.75), value: offset)
            .animation(.easeOut(duration: 0.18), value: isHovered)
            .onContinuousHover { phase in
                guard isActive else {
                    if isHovered { isHovered = false; offset = .zero }
                    return
                }
                switch phase {
                case .active(let location):
                    offset = location
                    isHovered = true
                case .ended:
                    offset = .zero
                    isHovered = false
                }
            }
    }
}

private struct TileSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    func threeDTilt(maxAngle: Double = 12.0) -> some View {
        modifier(ThreeDTileModifier(maxAngle: maxAngle))
    }
}
