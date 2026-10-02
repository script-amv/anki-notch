import AppKit
import AnkiNotchKit

extension NSScreen {
    /// This screen's measurements as the pure geometry the panel math works on.
    var panelGeometry: PanelGeometry {
        PanelGeometry(
            screenFrame: frame, visibleFrame: visibleFrame,
            notch: PanelGeometry.notchRect(
                screenFrame: frame, safeAreaTop: safeAreaInsets.top,
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea))
    }
}
