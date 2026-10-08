import CoreGraphics
import Foundation

/// A damped spring sampled for Core Animation. Bounding the sizes keeps a
/// tall card on-screen and a collapsing shape from acquiring negative bounds.
public enum PanelSpring {
    public static func sizes(from: CGSize, to: CGSize, maximumSize: CGSize) -> [CGSize] {
        let steps = 80
        // Keep a small shape throughout a large collapse instead of vanishing
        // at zero height and reappearing during the spring's rebound.
        let minimumWidth = min(from.width, to.width) / 2
        let minimumHeight = min(from.height, to.height) / 2
        return (0...steps).map { index in
            let progress: Double
            if index == 0 {
                progress = 0
            } else if index == steps {
                progress = 1
            } else {
                let time = Double(index) / Double(steps)
                // Natural frequency 12.5, damping ratio 0.6: one clear bounce
                // followed by a small settle. Time is normalized to duration.
                progress = 1 - exp(-7.5 * time) * (cos(10 * time) + 0.75 * sin(10 * time))
            }
            return CGSize(
                width: max(minimumWidth, min(maximumSize.width, from.width + (to.width - from.width) * progress)),
                height: max(minimumHeight, min(maximumSize.height, from.height + (to.height - from.height) * progress)))
        }
    }
}
