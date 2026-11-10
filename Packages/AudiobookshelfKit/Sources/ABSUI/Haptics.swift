import ABSCore
import SwiftUI

extension HapticFeedback {
    /// The impact feedback for this setting, or `nil` when haptics are off. Port of the
    /// legacy `$hapticsImpact`. Platforms without haptics (most Macs) ignore it.
    public var sensoryFeedback: SensoryFeedback? {
        switch self {
        case .off: nil
        case .light: .impact(weight: .light)
        case .medium: .impact(weight: .medium)
        case .heavy: .impact(weight: .heavy)
        }
    }
}

extension View {
    /// Plays the impact for `level` whenever `trigger` changes; nothing when haptics are off.
    public func absHaptic<Trigger: Equatable>(_ level: HapticFeedback, trigger: Trigger) -> some View {
        sensoryFeedback(trigger: trigger) { _, _ in level.sensoryFeedback }
    }
}
