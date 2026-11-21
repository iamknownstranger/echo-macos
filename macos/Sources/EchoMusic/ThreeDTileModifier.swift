import SwiftUI

struct ThreeDTileModifier: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    @ViewState private var offset: CGPoint = .zero
    @ViewState private var isHovered: Bool = false
    @ViewState private var isPressed: Bool = false

    var maxAngle: Double = 12.0

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let isActive = controlActiveState == .key
            let size = proxy.size
            let normalizedX = size.width > 0 ? (offset.x - size.width / 2) / (size.width / 2) : 0
            let normalizedY = size.height > 0 ? (offset.y - size.height / 2) / (size.height / 2) : 0

            let pitch = (isHovered && isActive) ? Double(-normalizedY) * maxAngle : 0
            let yaw = (isHovered && isActive) ? Double(normalizedX) * maxAngle : 0

            content
                .overlay(
                    Group {
                        if isHovered {
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ]),
                                center: UnitPoint(
                                    x: size.width > 0 ? offset.x / size.width : 0.5,
                                    y: size.height > 0 ? offset.y / size.height : 0.5
                                ),
                                startRadius: 10,
                                endRadius: max(size.width, size.height) * 0.7
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                        }
                    }
                )
                .rotation3DEffect(
                    .degrees(pitch),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.5
                )
                .rotation3DEffect(
                    .degrees(yaw),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.5
                )
                .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.04 : 1.0))
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.35 : 0.15),
                    radius: isHovered ? 14 : 5,
                    x: isHovered ? -CGFloat(yaw) * 0.8 : 0,
                    y: isHovered ? CGFloat(pitch) * 0.8 + 6 : 2
                )
                .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: offset)
                .animation(.easeOut(duration: 0.2), value: isHovered)
                .animation(.easeInOut(duration: 0.1), value: isPressed)
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
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressed = true }
                        .onEnded { _ in isPressed = false }
                )
        }
    }
}

extension View {
    func threeDTilt(maxAngle: Double = 12.0) -> some View {
        modifier(ThreeDTileModifier(maxAngle: maxAngle))
    }
}
