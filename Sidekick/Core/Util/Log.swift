import os

enum Log {
    static let subsystem = "com.mayankyadav.sidekick"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let screen = Logger(subsystem: subsystem, category: "screen")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let tts = Logger(subsystem: subsystem, category: "tts")
    static let perf = Logger(subsystem: subsystem, category: "perf")

    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}
