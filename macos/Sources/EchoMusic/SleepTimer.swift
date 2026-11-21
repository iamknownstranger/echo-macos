import Foundation

@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    enum Mode: Hashable, Equatable {
        case off
        case minutes(Int)
        case endOfTrack

        var title: String {
            switch self {
            case .off: return "Off"
            case .minutes(let m): return "\(m) minutes"
            case .endOfTrack: return "End of track"
            }
        }
    }

    @Published private(set) var activeMode: Mode = .off
    @Published private(set) var remainingSeconds: Double? = nil

    private var timerTask: Task<Void, Never>?
    private weak var player: Player?

    init() {}

    func attach(player: Player) {
        self.player = player
    }

    func start(mode: Mode) {
        timerTask?.cancel()
        activeMode = mode

        switch mode {
        case .off:
            remainingSeconds = nil
        case .minutes(let mins):
            let total = Double(mins * 60)
            remainingSeconds = total
            timerTask = Task { [weak self] in
                var left = total
                while left > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    left -= 1
                    self?.remainingSeconds = left
                }
                self?.finish()
            }
        case .endOfTrack:
            remainingSeconds = player?.currentTrackRemainingTime()
            timerTask = Task { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    guard let remaining = self?.player?.currentTrackRemainingTime() else { continue }
                    self?.remainingSeconds = remaining
                    if remaining <= 1.0 {
                        self?.finish()
                        return
                    }
                }
            }
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil
        activeMode = .off
        remainingSeconds = nil
    }

    private func finish() {
        timerTask = nil
        activeMode = .off
        remainingSeconds = nil
        player?.pause()
    }
}
