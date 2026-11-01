import PluginariumAudio
import SwiftUI

/// `.meter`: two bars of amber segments. It polls the render core 15 times a second itself, so
/// nothing around it redraws.
struct MeterView: View {
    private static let pollInterval = Duration.seconds(1.0 / 15)
    /// The bar spans this many dB below full scale.
    private static let range: Float = 60
    /// How far a bar falls per poll once the signal has dropped, so a short peak stays readable.
    private static let fall: Float = 0.08

    private static let barHeight: CGFloat = 6
    private static let segment: CGFloat = 8
    private static let gap: CGFloat = 3

    let channel: UUID
    let audio: AudioSession?

    @State private var levels: [Float] = [0, 0]

    var body: some View {
        VStack(spacing: 2) {
            bar(levels[0])
            bar(levels[1])
        }
        .task(id: channel) { await poll() }
        .accessibilityHidden(true)
    }

    private func bar(_ level: Float) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.panelDeep))
            let lit = size.width * CGFloat(level)
            var x: CGFloat = 0
            while x < lit {
                let width = min(Self.segment, lit - x)
                context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.led))
                x += Self.segment + Self.gap
            }
        }
        .frame(height: Self.barHeight)
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            let peaks = read()
            levels = [Self.follow(levels[0], peak: peaks.left), Self.follow(levels[1], peak: peaks.right)]
        }
    }

    /// A channel that is not in the graph has no meter activity.
    private func read() -> (left: Float, right: Float) {
        guard let audio, let strip = audio.runner?.meterStrip(channel: channel) else { return (0, 0) }
        return audio.engine.readMeters(strip: strip)
    }

    private static func follow(_ shown: Float, peak: Float) -> Float {
        let target = peak > 0 ? min(max((20 * log10(peak) + range) / range, 0), 1) : 0
        return target >= shown ? target : max(target, shown - fall)
    }
}
