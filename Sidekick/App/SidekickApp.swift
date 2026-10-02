import SwiftUI

@main
struct SidekickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(env: delegate.env)
        } label: {
            Image(systemName: "face.smiling")
        }
    }
}

private struct MenuContent: View {
    let env: AppEnvironment
    var body: some View {
        Text(statusLine)
        if let conflict = env.hotkeyConflict { Text("⚠︎ " + conflict) }
        Divider()
        Button(env.state.alwaysOn ? "stop always-on listening" : "start always-on listening") { env.alwaysOn.toggle() }
        Button("show me the buddy") { env.coordinator.overlay.demo() }
        Button("setup…") { env.showOnboarding() }
        Button("settings…") { env.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("quit sidekick") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        if !env.state.hasAPIKey { return "needs a gemini key" }
        if !env.state.hotkeyInstalled { return "needs accessibility permission" }
        switch env.state.whisper {
        case .ready: return "ready — hold \(env.settings.data.pushToTalk.symbols) to talk"
        case .downloading(let p): return "downloading speech model… \(Int(p * 100))%"
        case .loading: return "warming up…"
        case .failed: return "speech model failed — see settings"
        case .idle: return "starting…"
        }
    }
}
