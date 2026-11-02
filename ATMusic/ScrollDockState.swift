import Foundation

/// Dock placement is independent of scroll/collapse state, so its reservation never jumps.
enum ATMusicDockLayout {
    static let reservedHeight: CGFloat = 136
    static let reservedBottomPadding: CGFloat = 12
    static let targetScreenBottomGap: CGFloat = 22

    static func downwardAdjustment(safeAreaBottom: CGFloat) -> CGFloat {
        // A keyboard inset must not be mistaken for the home-indicator safe area.
        guard safeAreaBottom.isFinite, safeAreaBottom >= 0, safeAreaBottom <= 60 else { return 0 }
        return max(0, safeAreaBottom + reservedBottomPadding - targetScreenBottomGap)
    }
}

/// Normalized scroll geometry: zero is the top, including the adjusted top inset.
/// Kept independent of SwiftUI so bounce/layout regressions can be tested directly.
struct ATMusicScrollSample: Equatable {
    let offset: CGFloat
    let maximum: CGFloat
    let viewport: CGFloat
}

struct ATMusicScrollDockState {
    private var source: UUID?
    private var previous: ATMusicScrollSample?
    private var travel: CGFloat = 0

    mutating func reset() {
        source = nil
        previous = nil
        travel = 0
    }

    /// Returns a desired state only for actual user scrolling, never layout corrections.
    mutating func consume(_ sample: ATMusicScrollSample, source newSource: UUID,
                          userDriven: Bool) -> Bool? {
        guard sample.offset.isFinite, sample.maximum.isFinite,
              sample.viewport.isFinite, sample.viewport > 0 else { return nil }
        guard userDriven else {
            if source == newSource {
                previous = sample
                travel = 0
            }
            return nil
        }
        guard source == newSource, let old = previous else {
            source = newSource
            previous = sample
            travel = 0
            return sample.offset <= 2 ? false : nil
        }
        previous = sample

        // Loading data, safe-area changes and lazy layout measurements are not gestures.
        guard abs(sample.maximum - old.maximum) < 1,
              abs(sample.viewport - old.viewport) < 1 else {
            travel = 0
            return nil
        }
        if sample.maximum <= 2 {
            travel = 0
            return false
        }
        // Ignore elastic motion in BOTH directions, including the re-entry frame.
        guard (0...sample.maximum).contains(sample.offset),
              (0...old.maximum).contains(old.offset) else {
            travel = 0
            return nil
        }
        if sample.offset <= 2 {
            travel = 0
            return false
        }
        let delta = sample.offset - old.offset
        guard abs(delta) > 0.01 else { return nil }
        if delta * travel < 0 { travel = 0 }
        travel += delta
        if travel >= 12 {
            travel = 0
            return true
        }
        if travel <= -18, sample.offset < sample.maximum - 24 {
            travel = 0
            return false
        }
        return nil
    }
}
