# Build Spec: "Sidekick" — an AI screen buddy for macOS

> Personal-use project. The look and feel (cursor, UI, animations, timing) may be modeled on HeyClicky as a reference.

---

## 0. How you (Claude Code) must work

1. Read this whole file first. Save it in the repo as `SPEC.md` and keep it updated when decisions change.
2. Build **phase by phase** (Section 9). Finish one phase, make it compile, run its tests, give me a short summary + manual test steps, then **stop and wait** for me before starting the next phase.
3. Keep the project compiling at all times. Run `xcodebuild` after each meaningful change and fix every error/warning you introduced.
4. Prefer native Apple frameworks. Add a third-party dependency only when listed here or when you justify it in one line.
5. Performance is a hard requirement (Section 3). Choose the lowest time-complexity approach, avoid blocking the main thread, never re-load models per request, never poll when an event/callback exists.
6. Write unit tests for all pure logic (tag parser, coordinate mapping, router, memory updater, dictionary learner, cost meter).
7. Never hard-code secrets. API keys live in the macOS Keychain.
8. When something is ambiguous, pick the simplest robust option, note it in `DECISIONS.md`, and continue.

---

## 1. Product summary

Sidekick is a tiny AI buddy that lives next to the mouse cursor and in the top-center notch area of the Mac. The user holds a hotkey and talks. Sidekick:

- hears the voice (local Whisper, free, offline),
- takes a screenshot of what the user sees (only while the hotkey is used),
- sends text + screenshot to Google Gemini,
- answers **out loud** and **draws on the screen** (points, circles, arrows) to show exactly where to click,
- teaches any app step by step and detects when the user clicks the right spot,
- types/dictates into any app,
- remembers the user (memory files),
- runs agents that do tasks (tools, integrations, computer use),
- keeps persistent named buddies with their own memory, files, and scheduled routines.

---

## 2. Tech stack & constraints

| Area | Choice |
|---|---|
| OS | macOS 14.2+ (Sonoma), Apple Silicon primary target |
| Language/UI | Swift 5.9+, SwiftUI + AppKit (NSPanel/NSWindow where SwiftUI can't) |
| Project | XcodeGen (`project.yml`) so the project is reproducible from the CLI; build with `xcodebuild` |
| App type | Menu-bar/agent app (`LSUIElement = YES`), **not sandboxed** (needs Accessibility, event taps). Hardened runtime on. |
| Speech-to-text | **WhisperKit** (Swift Package, CoreML/Apple Neural Engine). Default model `small`; optional `base` (fast) and `large-v3-turbo` (accurate) selectable in Settings. Auto language detection (English, Hindi, Hinglish, 50+ languages). |
| AI | **Google Gemini REST API** via `URLSession` (no SDK). Streaming via `:streamGenerateContent?alt=sse`. Header `x-goog-api-key`. |
| Models (configurable) | Fast: `gemini-3.8-flash` (default for talk). Smart: `gemini-3.1-pro-preview` (hard questions, agents). Cheap: `gemini-3.5-flash-lite` (memory updates, text cleanup). Store ids in settings, never hard-code at call sites. |
| Text-to-speech | `AVSpeechSynthesizer` (free, local). Pluggable `TTSProvider` protocol so a cloud voice can be added later. |
| Screen capture | **ScreenCaptureKit** `SCScreenshotManager.captureImage` (macOS 14+), excluding Sidekick's own windows. |
| Hotkeys / input | `CGEventTap` (listen-only for observing clicks; flagsChanged for modifier-only hotkeys incl. Fn). |
| UI element lookup | Accessibility API (`AXUIElement`). |
| Storage | SQLite via **GRDB** (with FTS5 for chat search). Markdown files for memory/skills/notes. |
| Secrets | Keychain (`kSecClassGenericPassword`). |
| Logging | `os.Logger` with categories; no screenshots or transcripts in logs at release level. |

---

## 3. Performance requirements (hard)

Latency budgets on an M1 MacBook Air:

| Step | Budget |
|---|---|
| Hotkey down → buddy shows "listening" | < 50 ms |
| Screenshot capture (runs **in parallel** with recording, taken at hotkey-down) | < 150 ms |
| Whisper final text after hotkey release (5 s clip, `small`) | < 700 ms |
| Hotkey release → first spoken word (Flash) | < 1.8 s |
| Buddy cursor animation | 60–120 fps, < 3% CPU idle |
| Idle RAM (Whisper loaded) | < 600 MB with `small` |

Rules:
- Load + warm Whisper once at launch (run a 1 s silent decode) — never per request.
- Audio stays in memory (`[Float]` ring buffer, 16 kHz mono). No temp files.
- Screenshot: capture only the display under the cursor, downscale so the long side = 1280 px, JPEG quality 0.7, encode off the main thread. Keep the scale factor for coordinate mapping.
- Stream Gemini output; parse tags incrementally (single pass, O(n)); start TTS at the first complete sentence; start overlay animations as soon as a tag closes.
- Conversation context: send only the **latest** screenshot; older turns as text only; cap history to the last 10 turns + summary.
- Use Swift Concurrency (`actor`s for AudioEngine, STT, AIClient, TTS). UI updates on `@MainActor` only.
- Overlay drawing with Core Animation layers (`CAShapeLayer`), not redrawing whole views every frame. Use `CVDisplayLink`/`CADisplayLink` only while animating; stop it when idle.
- DB writes batched/off-main; FTS5 for search (no `LIKE '%x%'` scans).
- Cancel in-flight network/TTS immediately on barge-in or Esc (`Task.cancel()` + `URLSessionTask.cancel()`).

---

## 4. Architecture

```
Sidekick/
  App/                SidekickApp.swift, AppDelegate, AppState (single source of truth, @Observable)
  Core/
    Hotkeys/          EventTapManager, HotkeyBindings, ClickObserver
    Audio/            AudioCapture (AVAudioEngine, 16k mono), VAD (energy-based), Waveform level publisher
    STT/              STTProvider protocol, WhisperKitSTT
    Screen/           ScreenCapturer, CoordinateMapper, AXInspector (element lookup/snapping)
    AI/               GeminiClient (REST+SSE), ModelRouter, PromptBuilder, TagParser, ToolRegistry, CostMeter
    TTS/              TTSProvider protocol, SystemTTS (sentence queue, barge-in)
    Memory/           MemoryStore (PROFILE.md, VOLATILE.md), MemoryUpdater
    Dictation/        DictationController, TextInserter, PersonalDictionary, TextCleaner
    Teaching/         TeachingSession (step state machine), AppSkillsLoader
    Agents/           AgentRunner, AgentCard, Tools/ (Local, AppleScript, EventKit, Files, Web, ComputerUse), MCPClient (later)
    Buddies/          Buddy model, BuddyStore, RoutineScheduler
    Skills/           SkillLibrary, SkillEditor
    Notes/            NotesWiki
    Persistence/      Database (GRDB), migrations, Keychain
    Privacy/          PermissionsManager, QuietModeDetector
  UI/
    Overlay/          OverlayWindow (per screen), BuddyCursorLayer, AnnotationLayer, LabelBubble, UserInkLayer
    Notch/            NotchPanel, HomeView, PeekView
    Chat/             ChatView, MessageView, HoldToTalkPill
    Onboarding/       PermissionSteps, Tutorial
    Settings/         SettingsView (tabs)
  Resources/          AppSkills/*.md, Skills/*.md, Prompts/*.md, Assets
Tests/
```

Data flow for one voice question:

```
hotkey down ─┬─> AudioCapture.start()  ──> waveform → buddy "listening"
             └─> ScreenCapturer.capture(screen under cursor)   (parallel)
hotkey up ────> AudioCapture.stop() → WhisperKitSTT.transcribe → text
              → PromptBuilder(system + memory + app skill + history + screenshot + user ink + text)
              → ModelRouter picks Flash/Pro → GeminiClient.stream
              → TagParser (incremental) ─┬─> TTS sentence queue → speak
                                         ├─> Overlay: POINT/CIRCLE/ARROW/HIGHLIGHT
                                         └─> TeachingSession / AgentRunner
              → Persist turn (text only) → MemoryUpdater (background, cheap model)
```

---

## 5. Features (implement all, in the phase order of Section 9)

### F1. Onboarding & permissions
- First launch: friendly step-by-step screens requesting **Microphone**, **Screen Recording**, **Accessibility**, **Input Monitoring**. Each step: why we need it, a button that opens the exact System Settings pane, and live status that turns green when granted (poll at most once per second only while the onboarding window is visible).
- Ask for the Gemini API key, validate it with a tiny request, save to Keychain.
- Download/warm the Whisper model with a progress bar.
- Interactive tutorial: user holds the hotkey and asks "what's on my screen?"; then a guided mini-task where the buddy points at something (e.g. the Apple menu) and waits for the click.

### F2. Global hotkeys (all rebindable in Settings)
| Action | Default |
|---|---|
| Push-to-talk (hold) | `Control + Option` |
| Dictation (hold) / hands-free (double-tap) | `Fn + Control` |
| Screen-aware "write it for me" | `Control + Option` then say "type a reply…" (intent-detected) |
| Open Home panel | `Control + Command + A` |
| Cancel / stop speaking | `Esc` (only consumed while Sidekick is active) |
| Always-on voice mode toggle | Triple-tap `Control` (warn: headphones recommended) |
- Implement modifier-only hotkeys with a `CGEventTap` on `flagsChanged` (including `.maskSecondaryFn`). Hold threshold 150 ms to avoid accidental triggers. Double/triple tap window 300 ms.

### F3. Audio capture + VAD
- `AVAudioEngine` input tap, convert to 16 kHz mono Float32 into a pre-allocated ring buffer (max 120 s).
- Publish RMS level ~30×/s for the listening waveform.
- Energy-based VAD: trim leading/trailing silence before STT; in always-on mode, segment utterances by 600 ms silence.

### F4. Speech-to-text (WhisperKit)
- Load once, warm up, keep resident. Model selectable (`base` / `small` / `large-v3-turbo`), downloaded on demand with progress.
- Auto language detect; optional fixed language in Settings.
- Pass the personal dictionary words as the initial prompt to bias spelling of names/jargon.
- Optional streaming partial transcripts shown in the bubble while speaking.
- If transcript is empty or < 2 chars → show "didn't catch that" and do nothing (no API call, no cost).

### F5. Screen capture
- Capture the display under the mouse at hotkey-down using ScreenCaptureKit, excluding all Sidekick windows (`SCContentFilter` excluding our app).
- Also record: frontmost app name + bundle id, window title, browser URL if frontmost app is a browser (via AX / AppleScript for Safari/Chrome/Arc), mouse position.
- Downscale + JPEG encode off-main. Keep a `CoordinateMapper` (screenshot px ⇄ normalized 0–1000 ⇄ screen points, handles Retina scale + multi-display origins). Unit-test it.
- Screenshots are held in memory only and released after the request. **Never written to disk.**

### F6. AI brain (Gemini)
- `GeminiClient`: POST `https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse`, header `x-goog-api-key`. Parts: `inline_data` (JPEG base64) + text. `systemInstruction` for the system prompt. Parse SSE lines incrementally. Handle 429/5xx with exponential backoff (max 2 retries), show a friendly error bubble.
- Use the lowest thinking level for talk replies (fast); higher for Pro/agents. Make it a setting.
- `ModelRouter`: Flash by default. Escalate to Pro when: user says "think hard / explain in detail", the question needs multi-step reasoning, or Flash returns `[ESCALATE]`. Agents use Pro. Background jobs use Flash-Lite.
- Read `usageMetadata` from every response → `CostMeter` (tokens + estimated cost per model, prices editable in Settings). Daily budget cap with a warning at 80% and hard stop at 100% (configurable).
- System prompt lives in `Resources/Prompts/talk.md` (see Section 8).

**Output tag protocol** (the model writes normal spoken text plus inline tags; `TagParser` strips tags from the spoken text):

```
[POINT y=412 x=733 label="Export button"]
[CIRCLE y=300 x=500 r=40 label="this panel"]
[ARROW from_y=.. from_x=.. to_y=.. to_x=.. label=".."]
[HIGHLIGHT y1=.. x1=.. y2=.. x2=.. label=".."]
[STEP n=2 of=5]
[WAIT_CLICK]            -> teaching: wait until user clicks the last target
[ESCALATE]              -> router retries with Pro
[AGENT task="..."]      -> hand off to AgentRunner
[TYPE text="..."]       -> insert text at cursor (screen-aware writing)
```
- Coordinates are **Gemini-native normalized 0–1000, `y` first** (Gemini is trained on this format → better accuracy). Map to screen with `CoordinateMapper`.
- `TagParser`: single-pass streaming state machine, tolerant of partial chunks and malformed tags (ignore bad ones, never crash). Unit tests with fuzzed chunk boundaries.

### F7. Voice output (TTS)
- `AVSpeechSynthesizer` with a sentence queue: speak each sentence as soon as it completes in the stream.
- Settings: voice picker (list installed voices, highlight premium/enhanced ones), rate, pitch, volume, "show text only" mode.
- **Barge-in**: if the user presses push-to-talk while Sidekick is speaking → stop speech instantly, cancel the stream, start listening.
- Spoken text never includes tags, markdown symbols, or URLs (read "link" instead).

### F8. Buddy cursor overlay
- One transparent, borderless, non-activating `NSPanel` per display: `ignoresMouseEvents = true`, level above normal windows, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `sharingType = .none` (so it doesn't show in our own screenshots or screen shares).
- Buddy = small original shape (design your own, e.g. a rounded triangle with a face) offset ~24 px bottom-right of the real cursor, following with a spring animation. Track mouse via `NSEvent.addGlobalMonitorForEvents(.mouseMoved)`; only animate while moving.
- States: idle (subtle breathe), listening (waveform ring), thinking (spinner/dots), speaking (mouth/pulse), pointing (flies to target along a curved path, shows label bubble, returns after 4 s or on next mouse move > 200 px).
- "Dock" mode: buddy rests in the notch instead of following the cursor.
- Text bubble next to the buddy shows partial transcript and the reply (max 3 lines, fades).

### F9. AI draws on screen (annotations)
- Render POINT/CIRCLE/ARROW/HIGHLIGHT as `CAShapeLayer`s with a hand-drawn look (slight jitter path), draw-on animation (strokeEnd 0→1 in 300 ms), auto-fade after 6 s or when the step completes.
- **Snap to real UI elements**: for each target, query `AXUIElementCopyElementAtPosition` near the point; if an actionable element (button, menu item, text field, link, tab) is within 40 px, snap the target to its frame center and use its frame for circles/highlights. Fallback to raw coordinates.

### F10. Spatial context (user draws for the AI)
- While push-to-talk is held, the user can drag the mouse with the left button to draw a paint trail (UserInkLayer). Temporarily set the overlay to accept mouse events only during hold + drag (so normal clicking is unaffected otherwise).
- Burn the strokes onto the outgoing screenshot (red, 6 px) and add "The user circled/pointed at the marked area" to the prompt.
- Trail fades 1.5 s after release.

### F11. Teaching mode (step-by-step tutor)
- Triggered by intent ("teach me…", "how do I…", "walk me through…").
- `TeachingSession` state machine: `explain → point → waitClick → verify → next`. Each step the AI emits `[STEP]`, a target, and `[WAIT_CLICK]`.
- `ClickObserver` (listen-only event tap) detects the user's next left click. If within the target frame (or 30 px of the point) → green check, "nice!", take a fresh screenshot, ask Gemini for the next step. If elsewhere → gentle hint and re-point. User can say "skip", "go back", "stop".
- **App skills**: `Resources/AppSkills/<bundle-id or domain>.md` (e.g. `com.blackmagic-design.DaVinciResolve.md`, `figma.com.md`) with UI layout notes, common workflows, shortcuts. Auto-inject the matching skill for the frontmost app/site. Ship starter skills for: Finder, Safari, Chrome, VS Code, Cursor, Xcode, Terminal, Figma, Notion, Google Docs/Sheets, Excel, PowerPoint, Keynote, DaVinci Resolve, Final Cut Pro, FL Studio, Logic Pro, Photoshop, Canva, Slack, Gmail. Users can add their own.

### F12. Dictation (type anywhere)
- Hold `Fn + Control` → record → Whisper → insert text at the cursor in any app. Double-tap = hands-free until tap again or 3 s silence.
- `TextCleaner`: local fast rules (capitalization, punctuation, remove "um/uh", spoken "new line"/"comma") — optional Flash-Lite polishing toggle (off by default to stay free + fast).
- `TextInserter`: try AX (`kAXSelectedTextAttribute` set on focused element); fallback = save pasteboard → set text → synthesize `Cmd+V` → restore pasteboard after 300 ms. Must work in Electron apps (Slack, Discord, VS Code).
- **PersonalDictionary**: if the user edits an inserted word within ~20 s (observe via AX value diff of the focused field), learn the correction (store pair, used as Whisper prompt + replacement map). Editable in Settings → Dictionary.
- **Screen-aware writing**: push-to-talk + "write a reply to this…" → screenshot + ramble → Gemini drafts in the user's voice (uses PROFILE.md) → `[TYPE]` inserts it into the focused text box.
- Dictation never calls Gemini unless polishing/screen-aware mode is used.

### F13. Memory
- Files in `~/Library/Application Support/Sidekick/Memory/`:
  - `PROFILE.md` – long-term: name, languages, job, preferences, writing style, "talks too much → keep replies short", etc.
  - `VOLATILE.md` – current project/context, auto-expires items older than 7 days.
- Both injected (trimmed to a token cap, e.g. 800 tokens) into every talk/agent prompt.
- `MemoryUpdater`: after each conversation (debounced 30 s), send the transcript (text only) to Flash-Lite with instructions to output a minimal diff (add/update/remove lines). Apply in O(lines). Never store secrets, passwords, card numbers.
- User can say "remember that…", "forget that…"; Settings shows both files in an editor; "Delete all memory" button.

### F14. Notch app — the AI lives in the MacBook notch (primary UI)

**Notch detection & trigger**
- Detect the notch with `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (gap between them = notch rect) and `safeAreaInsets.top`. On screens without a notch (external monitors), create a virtual notch: a 180×32 black pill at top-center.
- At rest the panel is **invisible-looking**: a black shape exactly matching the notch size and corner radii, sitting over the real notch (optional tiny unread badge / buddy face peeking at the edge).
- Hover trigger: a global `mouseMoved` monitor checks only `y` within the top 6 pt **and** `x` inside the notch rect ± 20 pt (O(1) check per event). After a **120 ms dwell** → open. Also opens via `Control + Command + A` or clicking the notch.
- Close: when the pointer leaves the panel for **350 ms** (grace period), unless the text field is focused, a reply is streaming and the user is reading (scrolled up), a menu is open, or the panel is **pinned** (pin button). Esc closes. Unsent drafts are kept.
- Never steal focus on hover. The panel is a non-activating `NSPanel`; it becomes key only when the user clicks into it or starts typing, and returns focus to the previous app on close.

**Open/close animation (must feel clean, like Dynamic Island)**
- Open: the black notch shape **morphs** (one continuous spring, `response 0.38, dampingFraction 0.82`) — width/height/corner-radius grow from the notch to the panel size, anchored to the top-center. Content fades in + scales from 0.96 → 1.0 + blur 6 → 0, starting 80 ms after the morph begins (staggered: header → messages → input bar, 30 ms apart).
- Close: reverse — content fades out fast (120 ms), then the shape springs back into the notch (`response 0.3`).
- Subtle shadow grows with the panel; no animation jank: animate only `transform`, `opacity`, `bounds`, `cornerRadius` on layers (no re-layout of the chat list during the morph).
- Three sizes with smooth spring transitions between them: **Peek** (hover preview ~420×140: last reply, suggestions, quick input), **Compact** (~720×520 chat), **Expanded** (user-resized, remembered). Drag left/right/bottom edges or bottom corners to resize; double-click an edge to reset. **Pop-out** button turns it into a normal movable window (state remembered across restarts) and **tuck-back** morphs it back into the notch.

**Chat UI — looks and works like ChatGPT / Claude desktop apps (original design, not a copy of either)**
- Layout: collapsible **left sidebar** (New chat button, search, chat history grouped by Today / Yesterday / Previous 7 days / Older, buddies, notes, skills, settings at the bottom with profile) + **main chat area** + **input bar** at the bottom.
- Header: chat title (auto-generated by Flash-Lite after the first reply, editable), model picker (Auto / Fast / Smart), pin, pop-out, close.
- Empty state: greeting ("hey Mayank, what are we doing today?") + 4 suggestion chips based on the frontmost app.
- Messages: user messages right-aligned in a soft bubble; AI replies left-aligned full-width with no bubble (like Claude/ChatGPT). Full **markdown**: headings, lists, tables, links, inline code, **code blocks with syntax highlighting + language label + Copy button**, LaTeX optional. Text selectable; ⌘A/⌘C work.
- Message actions on hover: copy, regenerate, edit (user messages — edit & resend branches the conversation), read aloud, thumbs up/down.
- **Streaming**: text appears as it arrives with a soft fade-in per chunk + blinking caret; "Stop generating" button replaces Send while streaming.
- Input bar: auto-growing multiline text field (Enter = send, Shift+Enter = newline), **attach** (files/images; drag & drop anywhere on the panel; paste images), **"include my screen"** toggle (attach current screenshot), **mic button** (hold-to-talk with live waveform → Whisper → text into the box), Send button.
- Agent runs appear inline as collapsible "working…" cards with step list and produced files.
- Keyboard shortcuts: ⌘N new chat, ⌘K search, ⌘[ / ⌘] previous/next chat, ⌘⇧S toggle sidebar, ⌘, settings, Esc close.
- Unread badge on the notch for buddies with new results. Search uses FTS5 across all chats including archived; archive/unarchive; rename; delete (with confirm).
- Peek size shows: latest reply snippet, 2 suggestion cards, buddies with unread dots, each buddy's 3 newest files (drag files out to other apps; drag files in to give them to Sidekick), and a one-line quick input.

### F15. Agents (do tasks for me)
- Intent detection: the talk model decides whether to **guide** or **do**; if do → emits `[AGENT task="..."]`.
- 5-second cancel window with a countdown card (top-right) before the agent starts; spoken follow-up questions if info is missing.
- `AgentRunner`: Gemini function-calling loop (Pro), max 25 steps, per-step timeout, streaming status lines to an **Agent Card** (top-right): title, live step list (collapsible), files produced (thumbnails), follow-up box + mic. Says "done" out loud + cursor bubble when finished.
- Tool registry (each tool: name, JSON schema, `requiresConfirmation` flag):
  - `open_app`, `open_url`, `web_search` (Gemini Google Search grounding), `fetch_url` (readable text)
  - `files_read/write/list` (scoped to the buddy's folder + user-approved folders)
  - `notes_*`, `calendar_*`, `reminders_*` via EventKit / AppleScript (Apple Notes)
  - `run_shell` (**always** requires confirmation, shows the command)
  - `create_csv/xlsx/markdown` outputs saved into the buddy folder
  - `ui_click`, `ui_type`, `ui_read` (computer use, F16)
- Integrations (Gmail, Google Calendar/Sheets, Notion, Linear, Slack, GitHub, Supabase): implement through an **MCP client** (stdio + HTTP) so users can plug in MCP servers; OAuth handled by those servers. Settings → Connections lists them with status.
- Safety: never type passwords, card numbers, or 2FA codes; never send emails/messages, purchase, delete, or post without an explicit spoken/typed "yes" for that action.

### F16. Computer use
- Prefer **Accessibility actions** (`AXPress`, set value, menu navigation) so the real cursor isn't moved and it can work in background windows. Fallback: synthesized `CGEvent` clicks with a visible "Sidekick is controlling…" banner and Esc to abort.
- Loop: screenshot + AX tree summary (top 200 actionable elements with role/title/frame) → model picks an action → execute → verify.
- Permission is asked **per conversation** ("Allow Sidekick to use your Mac for this task?").
- Always-on realtime voice mode (triple Ctrl): continuous VAD segmentation → quick commands ("open my Stripe dashboard", "play X on Spotify").

### F17. Buddies (persistent named agents)
- User can create buddies by conversation ("make me three buddies: inbox, competitor research, newsletter" → up to 5 at once). Each buddy: name (2 friendly words describing the job), original avatar (generated from a few style presets you design), role prompt, own memory file, own conversation, own folder `~/Sidekick/Buddies/<name>/`.
- Two default buddies: "General Helper" and "Tutor".
- **Routines**: schedule a buddy task (daily/weekly/cron-like) via `RoutineScheduler` (single timer heap, O(log n) inserts, fires next due). Waits for wake + network; marks offline failures separately; pauses after 3 real failures; results show as unread.
- Archive/unarchive buddies; search finds archived ones.

### F18. Skills library
- Skills = markdown files in `~/Library/Application Support/Sidekick/Skills/` (frontmatter: name, description, triggers). Active skills are appended to the system prompt for talk + agents.
- UI: browse, enable/disable with one click, "Create a skill" (describe it → Flash drafts the markdown → user edits/saves), import/export `.md`.
- Ship ~10 starter skills (e.g. "Concise answers", "Explain like I'm a beginner", "Code reviewer", "Email writer in my style", "Hinglish mode").

### F19. Proactive suggestions (OFF by default, privacy first)
- If enabled: once each morning (and optional afternoon), read-only scan of connected integrations (last 48 h) → Flash proposes 2 task cards in the notch carousel ("Approve" / "Adjust" / "Dismiss").
- Back off: 3 unopened days → pause 1 day, doubling up to 7 days max.

### F20. Notes wiki
- "Save this…" → writes/updates a markdown wiki in `~/Sidekick/Notes/` (one file per topic, auto-linked). Viewable/searchable in Home.

### F21. Quiet mode
- Auto-silence voice, chimes, and unprompted bubbles when: the user is on a call (mic in use by another app — best-effort via CoreAudio device "is running somewhere" + known call apps frontmost) or screen sharing is active; or Focus/DND is on (for routines).

### F22. Settings
Tabs: General (launch at login, dock buddy, quick peek on hover), Shortcuts, Voice (STT model, language, TTS voice/rate), AI (model ids, thinking level, router rules, prices, daily budget), Memory, Dictionary, Skills, Buddies & Routines, Connections, Privacy, Usage (tokens + cost today/month chart), About/Updates.
- "Sidekick knows its own settings": the talk prompt includes a compact settings map, so "talk slower" → the buddy points at / changes the right setting (with confirmation).

### F23. Privacy & security
- Screen is captured **only** on hotkey/agent step; raw screenshots never stored; only text summaries of conversations persisted locally.
- Everything local except Gemini calls. No analytics by default (optional opt-in crash reporting later).
- Keychain for keys/tokens. "Delete all data" wipes DB, memory, skills, notes, buddies, Keychain items.
- Quitting stops everything (no background helpers).

---

## 6. Data model (GRDB)

```
buddy(id, name, avatar, rolePrompt, folderPath, archived, createdAt)
conversation(id, buddyId, title, archived, updatedAt)
message(id, conversationId, role, text, model, inputTokens, outputTokens, costUSD, createdAt)
message_fts(text)                         -- FTS5, content=message
routine(id, buddyId, prompt, schedule, nextRunAt, failCount, enabled)
agent_run(id, conversationId, task, status, steps JSON, filesJSON, startedAt, endedAt)
dictionary(id, wrong, right, hits, updatedAt)  -- unique(wrong)
usage_daily(date, model, inputTokens, outputTokens, costUSD) -- PK(date, model)
setting(key, valueJSON)
```

---

## 7. UX & design rules
- Original, friendly, minimal. Dark/light aware. Rounded glassy panels (`NSVisualEffectView`), soft shadows, small playful animations, lowercase friendly copy.
- Never steal focus from the user's app (non-activating panels) except when the user opens Home.
- Every long action shows progress; every error is one friendly sentence + a retry.
- Accessibility: VoiceOver labels on all controls; respect Reduce Motion.

### 7b. Motion & animation system (apply everywhere)
Create one `Motion.swift` with shared tokens so every animation feels consistent:

| Token | Value | Used for |
|---|---|---|
| `snappy` | spring response 0.3, damping 0.85 | buttons, toggles, small UI |
| `smooth` | spring response 0.38, damping 0.82 | notch morph, panel resize, sidebar |
| `bouncy` | spring response 0.45, damping 0.65 | buddy cursor flying to targets, success check |
| `fadeFast` | easeOut 120 ms | dismissals |
| `fade` | easeOut 220 ms | content appear |

**Notch & panels**: morph open/close (see F14), size changes between Peek/Compact/Expanded spring smoothly, sidebar slides in/out (`smooth`) while the chat area reflows without jumping.

**Scrolling & chat list**
- Smooth native scrolling (`ScrollView` + `LazyVStack`, or `NSTableView` if lists exceed ~500 messages). Scroll position stays stable when older messages load at the top (keep anchor message, no jump).
- **Auto-follow while streaming** only if the user is at the bottom; if they scroll up, stop following and show a floating **"↓ jump to latest"** button (fades/slides in); clicking it animates a smooth scroll to the bottom and the button pulses a ring once.
- New messages: slide up 8 pt + fade in (`fade`). User's sent message springs from the input bar into place.
- Streaming text: per-chunk opacity fade (0 → 1 in 150 ms) + blinking caret; code blocks expand height smoothly as they grow.
- Typing/thinking indicator: three dots wave; switches to the stream with a crossfade.
- Sidebar chat list: hover highlight fades in 100 ms; selected chat has a sliding selection pill (matchedGeometryEffect); deleting/archiving collapses the row smoothly.
- Scroll edge: soft top/bottom fade masks on the chat area.

**Micro-interactions**
- Buttons: press scale 0.97 (`snappy`), hover background fade 100 ms.
- Mic button: live waveform bars driven by the audio RMS; glowing ring while recording.
- Copy button: icon morphs to a checkmark for 1.2 s.
- Toggle "include my screen": small screen icon flashes.
- Agent card: slides in from top-right; steps tick off with a check animation; "done" card bounces once.
- Errors: input bar shakes gently (3 oscillations, 8 pt).

**Buddy cursor & screen drawing** (see F8/F9/F10): spring follow, curved flight path to targets, draw-on stroke animation for circles/arrows, success check burst on correct click in teaching mode, user-ink trail fading out.

**Performance rules for animation**
- Target 60 fps on M1 Air (120 fps on ProMotion displays). Animate only GPU-friendly properties (opacity, transform, bounds, cornerRadius, strokeEnd). No layout passes per frame.
- Markdown is parsed once per message and cached; while streaming, only the last message re-renders, and only the newly appended text (O(chunk), not O(message)).
- Heavy blur (`NSVisualEffectView`) only on the panel background, never per message.
- Every animation has a Reduce Motion fallback (simple crossfade or instant).
- Profile the notch open animation and chat scrolling with Instruments (Core Animation FPS + Time Profiler) in the polish phase; report numbers.

---

## 8. System prompt (save as `Resources/Prompts/talk.md`)

```
You are Sidekick, a friendly, concise AI buddy that lives on the user's Mac.
You can see the user's screen (screenshot attached) and you talk out loud.

Rules:
- Reply in 1–3 short spoken sentences unless the user asks for detail. No markdown, no lists, no URLs in speech.
- Reply in the user's language (Hinglish if they speak Hinglish).
- When the user needs to find or click something, include a tag: [POINT y=.. x=.. label=".."] using coordinates normalized 0–1000 on the screenshot (y first). Use [CIRCLE], [ARROW], [HIGHLIGHT] when clearer.
- If the user marked the screen (red ink), focus on the marked area.
- For "teach me / how do I", go one step at a time: [STEP n=.. of=..], point at the target, then [WAIT_CLICK].
- If the task should be done for the user (multi-step, uses apps/data), say what you'll do and emit [AGENT task="..."].
- If you are unsure or the question needs deep reasoning, emit [ESCALATE] only.
- Never ask for or type passwords, card numbers, or codes.
Context:
{PROFILE}
{VOLATILE}
{ACTIVE_SKILLS}
{APP_SKILL for current app}
Frontmost app: {APP} | Window: {TITLE} | URL: {URL}
```

---

## 9. Build phases (stop after each for my review)

**Phase 1 — Core talk loop (MVP)**
XcodeGen project, menu-bar app, onboarding (permissions + API key in Keychain), push-to-talk hotkey, AudioCapture, WhisperKit (warm, `small`), ScreenCapturer, GeminiClient streaming (Flash), SystemTTS with sentence queue + barge-in + Esc, simple bubble near cursor showing transcript/answer, CostMeter.
✅ Accept: hold Ctrl+Option, ask "what's on my screen?", hear an answer within the latency budget; Esc stops; no screenshot saved to disk.

**Phase 2 — Buddy overlay + pointing**
Per-screen overlay, buddy cursor with states, TagParser (with tests), CoordinateMapper (with tests), POINT/CIRCLE/ARROW/HIGHLIGHT rendering, AX snapping, label bubbles, dock mode.
✅ Accept: "where is the Wi-Fi icon?" → buddy flies to it and circles it accurately on Retina + external display.

**Phase 3 — Teaching + spatial context**
User ink while holding hotkey (burned into screenshot), ClickObserver, TeachingSession state machine, AppSkills loader + starter skills, ModelRouter + [ESCALATE].
✅ Accept: "teach me to create a new folder in Finder" → step-by-step, advances on correct clicks.

**Phase 4 — Dictation**
Fn+Ctrl hold/double-tap, TextCleaner, TextInserter (AX + paste fallback), PersonalDictionary learning, screen-aware writing with [TYPE].
✅ Accept: dictation works in Notes, Safari text field, Slack/VS Code; correction learned after an edit.

**Phase 5 — Memory + Home panel**
GRDB DB + migrations, MemoryStore/Updater, **notch app (F14)**: hover-to-open with morph animation, Peek/Compact/Expanded sizes, ChatGPT/Claude-style chat UI (sidebar, markdown, code blocks, streaming, message actions, attachments, mic, shortcuts), Motion system (7b) incl. scroll behaviors, FTS search, archive, pop-out window, resize, drafts, Settings window (all tabs that exist so far), Usage tab.
✅ Accept: moving the cursor to the notch opens the chat smoothly (60 fps, no focus steal), leaving closes it; a long streamed reply auto-follows, scrolling up shows "jump to latest"; tell it "my name is Mayank, keep answers short" → remembered after restart.

**Phase 6 — Agents + tools**
AgentRunner (function calling, Pro), agent card, 5 s cancel window, local tools (apps, URLs, files, EventKit, Notes, web search/fetch, shell with confirmation), outputs saved to folder, spoken "done".
✅ Accept: "make a CSV of the 10 biggest Indian IT companies by revenue and save it" → file appears in the agent card.

**Phase 7 — Computer use + always-on voice**
AX-based UI actions, CGEvent fallback with banner, per-conversation permission, always-on mode with VAD segmentation.
✅ Accept: "open Spotify and play lo-fi" works without moving the real cursor when AX allows.

**Phase 8 — Buddies, routines, skills library, notes, MCP integrations**
Buddy CRUD by conversation, avatars, per-buddy memory/folder, RoutineScheduler, skills library UI + create-a-skill, notes wiki, MCP client + Connections settings.
✅ Accept: "make me a buddy that summarizes my day every evening at 9" → runs on schedule and shows unread result.

**Phase 9 — Polish**
Proactive suggestions (opt-in), quiet mode, reduce-motion, error handling pass, performance profiling with Instruments (report numbers vs Section 3), app icon, signed/notarized `.dmg` build script, README.

---

## 10. Definition of done (every phase)
- Builds with zero errors; no new warnings.
- Unit tests pass (`xcodebuild test`).
- Latency/CPU numbers for the phase measured and reported.
- Short changelog entry in `CHANGELOG.md` + manual test checklist.
