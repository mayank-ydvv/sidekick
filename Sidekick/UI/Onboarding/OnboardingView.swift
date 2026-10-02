import SwiftUI

struct OnboardingView: View {
    let env: AppEnvironment
    @State private var granted: [Permission: Bool] = [:]
    @State private var key = ""
    @State private var keyStatus: KeyStatus = .idle
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum KeyStatus: Equatable { case idle, checking, ok, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("hey, i'm sidekick 👋").font(.system(size: 22, weight: .semibold))
                Text("a few quick things and we're ready. hold \(env.settings.data.pushToTalk.symbols) and talk to me anytime.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 10) {
                    ForEach(Permission.allCases) { p in
                        PermissionRow(permission: p, granted: granted[p] ?? false)
                        if p != Permission.allCases.last { Divider() }
                    }
                }.padding(6)
            } label: { Text("permissions").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("paste your gemini api key", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        Button(keyStatus == .checking ? "checking…" : "save", action: saveKey)
                            .disabled(key.isEmpty || keyStatus == .checking)
                    }
                    switch keyStatus {
                    case .ok: Label("key saved to your keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    default:
                        if env.state.hasAPIKey {
                            Label("a key is already saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Link("get a free key at aistudio.google.com", destination: URL(string: "https://aistudio.google.com/apikey")!)
                                .font(.callout)
                        }
                    }
                }.padding(6)
            } label: { Text("gemini").font(.headline) }

            GroupBox {
                WhisperStatusView(state: env.state.whisper)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("speech model (runs on your mac)").font(.headline) }

            HStack {
                if Permission.allCases.contains(where: { $0.isRequired && granted[$0] != true }) {
                    Text("allowed it but no tick? screen recording only shows up after a relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("relaunch") { env.relaunch() }.controlSize(.small)
                }
                Spacer()
                Button("try the tutorial") { env.startTutorial() }
                    .disabled(!(env.state.hasAPIKey) || granted[.accessibility] != true)
                Button("done") { env.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(env.state.hasAPIKey))
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        var g: [Permission: Bool] = [:]
        for p in Permission.allCases { g[p] = PermissionsManager.isGranted(p) }
        if g != granted { granted = g }
        if g[.accessibility] == true { env.installHotkeysIfNeeded() }
    }

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        keyStatus = .checking
        Task {
            do {
                try await env.gemini.validate(key: k, model: env.settings.data.fastModel)
                env.saveAPIKey(k)
                keyStatus = .ok
                key = ""
            } catch GeminiError.modelNotFound(let m) {
                // Key works; model id may need changing in settings.
                env.saveAPIKey(k)
                keyStatus = .failed("key works, but model \"\(m)\" wasn't found — change it in settings")
                key = ""
            } catch {
                keyStatus = .failed(error.localizedDescription)
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : (permission.isRequired ? "circle" : "circle.dashed"))
                .foregroundStyle(granted ? .green : .secondary)
                .font(.system(size: 16))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.system(size: 13, weight: .semibold))
                    if !permission.isRequired {
                        Text("optional").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("allow") { PermissionsManager.request(permission) }
                    .controlSize(.small)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: granted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(permission.title), \(granted ? "granted" : "not granted")")
    }
}

struct WhisperStatusView: View {
    let state: WhisperKitSTT.LoadState
    var body: some View {
        switch state {
        case .idle: Text("waiting…").foregroundStyle(.secondary)
        case .downloading(let p):
            VStack(alignment: .leading) {
                ProgressView(value: p)
                Text("downloading… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("warming up…").foregroundStyle(.secondary) }
        case .ready: Label("ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
