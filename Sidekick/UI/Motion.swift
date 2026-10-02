import SwiftUI
import QuartzCore

/// Shared motion tokens (spec §7b) so every animation feels consistent.
enum Motion {
    // With Reduce Motion on, every token falls back to a short crossfade.
    static var snappy: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85) }
    static var smooth: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.82) }
    static var bouncy: Animation { reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.65) }
    static let fadeFast = Animation.easeOut(duration: 0.12)
    static let fade = Animation.easeOut(duration: 0.22)

    /// Core Animation equivalents.
    enum CA {
        static let flight: CFTimeInterval = 0.55
        static let drawOn: CFTimeInterval = 0.3
        static let fadeFast: CFTimeInterval = 0.12
        static let fade: CFTimeInterval = 0.22
        static let follow: CFTimeInterval = 0.16

        /// Spring with the given response/damping, mapped to CASpringAnimation physics.
        static func spring(_ keyPath: String, response: Double, damping: Double) -> CASpringAnimation {
            let a = CASpringAnimation(keyPath: keyPath)
            a.mass = 1
            a.stiffness = pow(2 * .pi / response, 2)
            a.damping = 4 * .pi * damping / response
            a.duration = a.settlingDuration
            return a
        }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
