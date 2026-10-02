import Foundation

/// Hidden switches for verification runs (never on by default).
enum DebugFlags {
    /// `-debugCapturable YES`: lets screen capture see Sidekick's overlays so visuals can be checked
    /// against a reference. Off normally, so the buddy never appears in screen shares.
    static let capturable = UserDefaults.standard.bool(forKey: "debugCapturable")
}
