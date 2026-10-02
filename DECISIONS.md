# Decisions

Simplest-robust choices made where the spec was ambiguous or the environment forced a call.

## Phase 1

- **Location & name.** Project lives at `trials/sidekick/` inside the existing `Desktop/mac` repo. The app keeps the name "Sidekick".
- **Swift 5.9 language mode** on the Swift 6.2 toolchain, with `SWIFT_STRICT_CONCURRENCY=minimal`. This avoids strict-concurrency churn while the architecture settles. Our code compiles with zero warnings.
- **Build output lives outside Desktop.** Files under `~/Desktop` carry iCloud/Finder extended attributes, which make `codesign` fail ("resource fork… not allowed"). `build.sh` puts DerivedData in `~/Library/Developer/Xcode/DerivedData/Sidekick-cli`.
- **Ad-hoc signing** (no Apple Developer identity on this Mac). Two consequences:
  - Xcode turns off hardened runtime for ad-hoc builds. It is still on in `project.yml` and takes effect once a real team/identity is set.
  - macOS ties permission grants (TCC) and Keychain access to the code signature, so a rebuild may ask you to re-grant permissions or re-allow Keychain access. Setting `DEVELOPMENT_TEAM` and a "Apple Development" identity in `project.yml` fixes this.
- **AudioCapture is a class with an unfair lock, not an `actor`.** The `AVAudioEngine` tap runs on a realtime thread and can't `await`. The ring buffer is guarded by `OSAllocatedUnfairLock`. STT, screen capture and Gemini are actors as the spec asks. TTS is `@MainActor`, because `AVSpeechSynthesizer` delegates and UI state live there.
- **Push-to-talk "pre-roll".** The spec asks for both a 150 ms hold threshold and "<50 ms to listening". On an exact ⌃⌥ match, the mic and screenshot start immediately (invisible "armed" state). The UI appears when the 150 ms threshold passes. If the keys are released early, or another key is pressed (e.g. ⌃⌥→), everything is discarded. So no audio is lost at the start of speech, and the UI latency is measured from the threshold.
- **Event tap is an active tap** (`.defaultTap`), so Esc can be consumed while Sidekick is busy. That requires Accessibility. Esc passes through untouched when Sidekick is idle.
- **Whisper warm-up** runs a 1 s low-noise clip through the real decode path (auto language detection, then fixed `en`). A pure-silence decode with a fixed language didn't warm the detection path: the first real request took 907 ms. With this warm-up it takes 365 ms.
- **Whisper model ids** map to the WhisperKit repo names: `openai_whisper-base`, `openai_whisper-small`, `openai_whisper-large-v3-v20240930_turbo_632MB`. Models are stored in `~/Library/Application Support/Sidekick/Models`.
- **Gemini model ids** default to the spec's ids and are editable in Settings → ai. Key validation calls `GET models/{fastModel}`, which costs nothing. A 404 means the key works but the model id is wrong, and the UI says so.
- **Thinking level** defaults to `minimal`. If the API rejects the thinking config with a 400, the client retries once without it, so a model that doesn't support a level still works.
- **Images are sent as camelCase `inlineData`** (the REST API accepts both spellings).
- **Screenshot sizing.** ScreenCaptureKit scales straight to the 1280-px-long-side target. No separate resize pass, so less CPU. The cursor is included in the screenshot, which gives the model useful context.
- **Browser URL** is read with AppleScript for Safari, Chrome, Brave, Edge, Arc and Vivaldi, with a 400 ms timeout, running in parallel with the capture. It can be turned off in Settings. The first use triggers macOS's Automation prompt.
- **Cost meter persistence.** In Phase 1 it is stored in UserDefaults (JSON, last 60 days). It moves to GRDB `usage_daily` in Phase 5.
- **Phase 1 bubble.** `CursorBubble` is a simple click-through panel. Phase 2 replaces it with the per-screen buddy overlay.
- **Settings and onboarding use plain `NSWindow`s** managed by `WindowManager`. SwiftUI's `Settings` scene is unreliable to open from an `LSUIElement` app.
- **Debug benchmark.** `Sidekick -benchWhisper <audio file>` is Debug-only. It loads the model, transcribes the file 3 times, and prints timings and RSS. It is used to report the STT numbers.
- **Input Monitoring is optional in Phase 1.** The push-to-talk tap is an active tap (Accessibility). Input Monitoring is only needed for listen-only taps (ClickObserver, Phase 3), so onboarding marks it optional and doesn't block on it. macOS often doesn't list an ad-hoc app there until it is added with "+".
- **`./build.sh install`** copies the app to `/Applications/Sidekick.app`, so it is easy to find in System Settings permission lists and keeps a stable path.
- **Stable local signing.** `scripts/setup-signing.sh` creates a self-signed "Sidekick Dev" identity (one time). `./build.sh install` re-signs `/Applications/Sidekick.app` with it, so macOS identifies the app by bundle id + certificate instead of a per-build hash, and permission grants survive rebuilds. `ENABLE_DEBUG_DYLIB=NO`, because Xcode's split `Sidekick.debug.dylib` would otherwise keep an ad-hoc signature and fail library validation under hardened runtime.

## Phase 2

- **Buddy follow uses short eased Core Animation moves (160 ms)** retargeted on every mouse event, instead of a display-link spring. Interpolation happens in the render server, so the app does almost no work per mouse event, and there is no display link to start or stop.
- **The buddy lives on one overlay at a time.** It is re-hosted when it crosses to another display. Annotations are drawn on the overlay of the display that contains their target.
- **Overlay level is `popUpMenu + 1`**, so it can point at menu bar items such as Wi-Fi and Control Center, and at open menus.
- **AX snapping** probes 17 points (the target, plus rings at 20 and 40 pt). Each hit walks up to 4 ancestors to find an actionable role, with frames capped at 900×320 pt so it never "snaps" to a whole window. Hits on Sidekick's own process are ignored. AX calls run off the main thread with an 80 ms messaging timeout.
- **CIRCLE `r`** is interpreted in the same 0–1000 units, relative to display width. A snapped element's frame (with padding) takes precedence.
- **Tags not handled yet** (STEP, WAIT_CLICK, ESCALATE, AGENT, TYPE) are parsed and logged. They are wired up in Phases 3, 4 and 6.

## Phase 3

- **Click detection uses NSEvent global monitors rather than a listen-only CGEventTap.** Mouse-down monitors are event-driven and need no Input Monitoring permission, so that permission stays optional.
- **Ink capture flips the overlay to accept mouse events only between hotkey "began" and release.** Otherwise the overlay is click-through. Ctrl-clicks may arrive as right-clicks, so both are handled.
- **The screenshot is taken at hotkey-down, before the ink is drawn.** Strokes are mapped global points → normalized → image pixels, then burned into a copy of the in-memory `CGImage`. Nothing touches disk.
- **A lesson ends** when a reply contains no `[WAIT_CLICK]`. If the model asks for a click but gave no target, the session stays in "explaining" instead of hanging on a click wait.
- **Voice commands** are only interpreted during a lesson, and only for utterances of 4 words or fewer, so "how do I stop the music" still goes to the model.
- **Escalation** discards the fast model's partial turn: it isn't added to history, and its usage is still billed.

## Phase 4

- **Dictionary is stored in JSON** at `~/Library/Application Support/Sidekick/dictionary.json` until the GRDB database lands in Phase 5, when it migrates to the `dictionary` table.
- **AX insertion is verified, not trusted.** Some apps return `.success` from setting `kAXSelectedTextAttribute` but don't insert anything. The field value is read again afterwards, and if it hasn't changed, the text is pasted instead.
- **Correction learning is event-driven.** It uses an `AXObserver` on `kAXValueChangedNotification` for 20 s, debounced 1.2 s, and stops after the first correction it learns. Apps that don't post value-changed notifications just don't learn.
- **The talk prompt gained one rule for `[TYPE]`.** It is a deliberate addition to the spec §8 prompt, because the model needs to be told how to use the tag.
- **fn key.** If macOS "Press 🌐 key to" is set to Emoji or Dictation, pressing fn alone still does that. fn ⌃ combos don't trigger it. The binding is stored in settings as `dictateKeys`.

## Phase 5

- **GRDB is vendored as a source tarball** (`scripts/fetch-vendor.sh` → `Vendor/GRDB`, used as a local SwiftPM package). SwiftPM's full-history `git clone --mirror` of GRDB ran at about 55 KB/s here and would have taken over an hour; the tarball takes 2 minutes. The test target is stripped from the vendored manifest, because its sources aren't vendored.
- **The `conversation` table gained `kind` ("chat" / "voice") and `unread`, and `message` gained `feedback`.** They are small additions on top of spec §6.
- **Usage keeps its in-memory `CostMeter`** for budget checks without database reads, and also writes to `usage_daily` for the chart.
- **The notch window resizes in two steps.** It grows to the larger of the two sizes before the shape springs, then trims to the visible shape 0.45 s later. Only the SwiftUI shape and content animate (size, corner radius, opacity, scale, blur), never the window frame itself.
- **Chat uses its own prompt** (`Resources/Prompts/chat.md`, markdown allowed). Voice keeps `talk.md` (spoken, no markdown).
- **Edit & resend branches by truncating.** The edited message and everything after it are deleted, then the new text is sent. A tree of branches can come later.
- **The scroll position "at bottom" check** uses a geometry preference, because `onScrollGeometryChange` needs macOS 15 and the target is 14.2.

## Phase 6

- **Agents use non-streaming `generateContent` with raw JSON bodies.** The model's content object is appended to history exactly as received, so `thoughtSignature` fields round-trip, which Gemini 3 function calling requires.
- **`web_search` is a separate grounded call.** Google Search grounding can't be combined with function declarations in one request, so `web_search` makes its own call (with `tools: [{google_search:{}}]`) on the fast model and returns the text plus its sources.
- **What needs approval:**
  - Always: `run_shell`, and `files_write` when it would overwrite.
  - Never: creating notes, events, reminders and new files, because they are additive. Nothing that sends, posts, purchases or deletes exists yet. MCP tools (Phase 8) default to asking.
- **XLSX** is a minimal hand-written OOXML package (inline strings, one sheet) zipped by the system `zip`, so no third-party dependency.
- **One agent at a time.** A follow-up starts a new run with the previous task as context.
- **The hardened runtime needs `com.apple.security.personal-information.calendars`** for EventKit, which covers events and reminders.

## Phase 7

- **Element ids are positions in the latest `ui_read` snapshot.** `ComputerUse.shared` holds the `AXUIElement` references until the next read. Ids are only valid until then, and the prompt tells the model to call `ui_read` again after acting.
- **The synthesized-click fallback restores the cursor position** (`CGWarpMouseCursorPosition`) about 30 ms later, so the user's pointer barely moves.
- **Always-on uses a second `AVAudioEngine`** instead of sharing push-to-talk's, so the two can't stop each other's capture. There is no acoustic echo cancellation, so listening pauses while Sidekick speaks. With speakers, you can't interrupt it by voice.
- **Triple-tap ⌃ is a third hotkey binding** (exactly ⌃, counted with `TapCounter`, 300 ms between taps). Any other key or modifier pressed during a tap cancels it, so ⌃⌥ / fn⌃ / ⌃-click don't count.
- **The OTP guard blocks 6–8 digit strings.** 4-digit numbers (years, small quantities) are allowed.

## Phase 8

- **Buddy conversations** are `conversation` rows with `kind = "buddy"` and `buddyId` set. They are hidden from the history list and shown in the sidebar's buddies section instead.
- **Routines and approvals.** A routine never pauses to wait for approval, because nobody is watching. Tools that need approval (shell, overwrites, computer use, MCP writes) are declined, and the summary says so.
- **Offline detection** uses `NWPathMonitor`. When offline, a run is postponed by 15 min without counting as a failure.
- **MCP**:
  - Settings (name, type, command or URL) live in UserDefaults; env vars and tokens live only in the Keychain.
  - OAuth is left to each MCP server, as the spec says.
  - The HTTP transport sends `Authorization: Bearer <TOKEN>` when an `AUTHORIZATION` or `TOKEN` env var is set.
- **Skill triggers** are matched as substrings of your message. Skills with no triggers always apply when enabled.
- **Notes auto-linking** only links the first plain mention of each other topic, and never inside an existing `[[link]]`.

## Language drift (fix)

- **The "(Hinglish if they speak Hinglish)" example was removed from the talk and chat prompts.** This deviates from the spec §8 wording. Measured with the lite fallback model (`gemini-3.5-flash-lite`) on "can you help me java codes?":
  - With the example in the prompt, it replied in Hinglish 3 out of 3 times.
  - With the neutral "Reply in the same language as the user's latest message", it replied in English 3 out of 3 times.
  - Adding a per-turn "reply in English" note only half-worked.
- Hinglish input still gets Hinglish replies, because it's the same language as the user's message. The opt-in "Hinglish mode" skill is unchanged.

## Design reference (2026-10-01)

- `SPEC.md` no longer forbids HeyClicky's visual design: the project is for the owner's personal use, and HeyClicky is now the look-and-feel reference. Sidekick keeps its own name and icon, and its code and assets are still written from scratch, recreated from observation rather than copied out of HeyClicky's app bundle.

## HeyClicky look & feel (2026-10-02)

- **The cursor triangle got a sharper tip than its base corners.** A near-equilateral triangle with even rounding looks the same after a ±120° turn, so a 146° heading appeared to point down (−94°). Measured from captures, then fixed and covered by a unit test.
- **The cursor bubble is optional, matching HeyClicky.** Status lives in the notch instead. "didn't catch that" and similar messages show there for 3 s.
- **Opening with the shortcut or a click focuses the text field; hovering opens talk-first.** Otherwise the "stay open while typing" protection never engaged. This was found by the UI test run.

## Natural offline voice (0.11.0)
- Replies are spoken with sherpa-onnx (v1.13.8 prebuilt C API, vendored in `Vendor/sherpa`, embedded in Contents/Frameworks) instead of AVSpeechSynthesizer.
- English: Kokoro multi-lang v1.0 (Apache-2.0), default voice "af_heart" (sid 3). Hindi (Devanagari replies): Piper "hi_IN-priyamvada-medium" (CC BY-NC-SA 4.0 — fine for this personal-use app).
- Models live in `~/Library/Application Support/Sidekick/Voices` (≈460 MB), not in the repo. If they're missing or fail to load, the Mac voice is used.
- Voice is chosen once per reply (Hindi if its first sentence is Devanagari) so it never switches mid-answer; romanized Hinglish uses the English voice.
- The idle buddy hides with the Mac pointer (typing, or 3 s without mouse movement) and reappears on any movement.
