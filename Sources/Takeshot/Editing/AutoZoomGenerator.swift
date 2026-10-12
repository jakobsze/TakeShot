import Foundation
import CoreGraphics

/// Generates automatic zoom ranges from click activity: clicks close together
/// in time are clustered into one "follow the cursor" zoom that starts just
/// before the first click and lingers a little after the last. Only runs
/// right after recording (or on explicit "Regenerate"), so manual edits are
/// never clobbered.
enum AutoZoomGenerator {
    static let leadIn: Double = 0.7
    static let holdAfter: Double = 1.6
    static let mergeGap: Double = 1.2
    static let minLength: Double = 1.4

    static func generate(events: [InputEvent], project: Project) -> [ZoomRange] {
        let offset = project.screenOffset
        let duration = project.duration
        let clicks = events.filter { $0.isPress }.map { $0.t - offset }.filter { $0 >= 0 && $0 <= duration }.sorted()
        guard !clicks.isEmpty else { return [] }

        var spans: [(Double, Double)] = []
        for t in clicks {
            let s = max(0, t - leadIn), e = min(duration, t + holdAfter)
            if let last = spans.last, s - last.1 <= mergeGap {
                spans[spans.count - 1].1 = max(last.1, e)
            } else {
                spans.append((s, e))
            }
        }
        return spans.compactMap { s, e in
            guard e - s >= 0.3 else { return nil }
            let end = max(e, min(duration, s + minLength))
            return ZoomRange(start: s, end: end, scale: project.style.defaultZoom, mode: .auto)
        }
    }
}
