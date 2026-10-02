# Changelog

## 0.10.0 — Look & feel modeled on HeyClicky (2026-10-02)
Measured from the running HeyClicky app (window captures, frame-by-frame timing), then rebuilt in Sidekick's own code.

| Area | Change |
|---|---|
| Cursor shape | blue `#327AF4` play-glyph triangle with a soft glow, at (+35, +25) pt from the pointer; sharper tip so its direction reads at any angle |
| Cursor follow | spring with a slight overshoot that settles in about 0.3–0.45 s |
| Cursor states | waveform bars while listening, faded triangle + spinner while thinking, glow pulse while speaking |
| Pointing | turns toward the target, flies there, lands with its tip on it, and stays until you move the mouse; no pulse ring or label |
| Notch status | closed notch has flared ears and widens to 352 pt to show Listening (cyan) / Thinking (magenta) / Speaking (orange) / Dictating / Working, or one-line messages, with a soft glow |
| Text bubble | the bubble next to the cursor is now optional and off by default |
| Notch timing | hover opens after 0.4 s and closes 0.06 s after leaving; peek 450 × 198 pt, full panel 907 × 626 pt |
| Peek | a messages list of Suggestions, buddies and recent chats (avatar, name, badge, time, preview, unread dot, file thumbnail) |
| Chat | 290 pt sidebar with a light-blue selected row; centered avatar + name pill; light-blue user bubbles with a tail; grey reply bubbles; typing bubble with "thinking · Ns" |
| Input | big blue "Hold Control + Option to talk" pill (release to send) next to a "Type…" pill, with the mascot peeking above; ⌃⌘A opens straight into the focused text field |
| Avatars | buddies are fluffy pastel clouds with "^^" eyes; Suggestions is a gradient sparkle |

**Hidden verification switches**
- `-debugCapturable YES`: lets screen capture see the overlays. Off by default, so the buddy stays out of screen shares.
- `-pointDemo YES`: makes the buddy point at the Apple menu, triggered by a distributed notification.

**Tests**
- 164 unit tests and 26/26 UI test checks pass.


## 0.9.2 — Suggestions: shortcuts, model note, voices, mic switching, UI tests (2026-10-01)
- **Settings → shortcuts**: record new hotkeys for push to talk, dictation, the always-on triple-tap key and the Home chord.
  - Changes apply live, and Sidekick's hotkeys are paused while you record.
  - Validation: at least two modifiers for holds, no duplicates, and no ⌘⇧ / ⌘⌥.
  - Warnings for ⌃⌥ while VoiceOver is on (also shown in the menu bar) and for fn on external keyboards.
  - All help text and spoken hints use your bindings.
- **Model note**: the bubble and the chat show when a different model answered and why, e.g. "lite model · fast model hit its free-tier limit · back in ~40s".
- **Voice by language**: each reply's voice is picked from its first sentence and kept for the whole reply.
  - Devanagari → a Hindi voice; Latin-script Hinglish → an Indian-English voice; other languages → the best installed voice for that language.
  - Your chosen voice is kept when it fits the language.
- **Mic switching**: on `AVAudioEngineConfigurationChange` (AirPods connected, USB mic unplugged), capture restarts on the new device and keeps what was already recorded. If the restart fails, the bubble says so.
- **Automated UI test run**: `./build.sh uitest` drives the installed app with synthesized keyboard and mouse events. It covers the hotkeys, ink, dictation, always-on, the notch (chord, hover, typing, resize, pop-out), the tutorial click, typing plus correction learning, mic switching and voices. It runs dry: no API calls and no typing into other apps. The exit code is the number of failures.
- 162 unit tests in total.


## 0.9.1 — Bug-hunt fixes (2026-10-01)
Found by running every feature against the live Gemini API (`-featureTest`, `-geminiProbe`) and by a code review.

**Gemini and models**
- The fast model rejected `thinkingLevel: minimal` (400). The client now steps down minimal → low → … and remembers what each model accepts. The default is now `low`.
- Free-tier quotas:
  - `limit: 0` (Pro isn't on the plan) → `quotaUnavailable`, no retries.
  - Temporary limits ("retry in 48s") → `rateLimited`, with a correct message.
- Model fallback chain: smart → fast → cheap for talk, chat, agents and `web_search`.
  - Talk gives up on a model after 6 s with no first token and remembers the failure for a while.
  - Agents wait out short rate limits instead of failing.

**Memory and language**
- The memory updater no longer learns preferences from Sidekick's own replies or from what's on screen. It only learns what the user states.
- Replies follow the language of the user's words, not the language on screen.

**Hotkeys and overlay**
- Releasing extra modifiers no longer starts push-to-talk or counts as a ⌃ tap.
- After the event tap times out, it resyncs with the real modifier state.
- Ink capture can't leave the overlay blocking clicks.

**Dictation**
- Dictation always hands the mic-level callback back, so the talk ring keeps moving.

**Notch and chat**
- Auto-close checks the panel's real first responder, so it no longer closes while you type or stays stuck open.
- Edge-resize no longer compounds.
- Pressing Enter while a reply streams keeps the draft and attachments.

**Agents and skills**
- Proactive suggestions are truly read-only, limited to a tool allowlist.
- A busy agent now tells you, instead of silently dropping a buddy or voice task.
- Skill drafting uses the cheap model and shows errors.

**Tests**
- 154 unit tests in total.


## 0.9.0 — Phase 9: polish (2026-10-01)
- **Quiet mode**: Sidekick goes silent when another app holds the mic (CoreAudio listener), during screen sharing, or in Focus (best effort). No voice, no unprompted bubbles, and routines are deferred.
- **Proactive suggestions** (off by default): a read-only headless agent runs in the morning (and optionally the afternoon) and shows 2 task cards in Peek — approve, adjust or dismiss. It backs off after 3 days of being ignored (1 → 2 → 4 → 7 days).
- **Settings by voice**: a `[SETTING]` tag plus a settings map in the prompt, so you can say "talk slower". Every change waits for a spoken "yes".
- **General settings**: launch at login (SMAppService), a quick-peek-on-hover toggle, a quiet-mode toggle, and an onboarding tutorial (the buddy circles the Apple menu and waits for your click).
- **Polish**: friendly one-line errors (offline, timeouts, unreachable server). Motion tokens fall back to short fades when Reduce Motion is on.
- **Notch performance**: content is laid out once at its final size and only the mask animates. The shadow fades instead of growing, and the content stays mounted between opens. The 30 Hz mic timer was removed.
- Result: 48 → 59.1 fps, idle CPU 0.6%.
- **`-selfTest`**: measures the spec §3 numbers inside the real app.
- **Instruments (Time Profiler, 75 s self-test run)**:
  - The run covered launch, Whisper load and warm-up, 3 transcriptions, 5 screenshots, 4 notch open/close cycles, and idle time.
  - The main thread was busy about 1.9 s in total (≈2.6% average). Most of that is SwiftUI graph updates during the notch morphs.
  - **0 potential hangs.** No single Sidekick function dominates: `NotchUIState` mutations ≈59 ms; JPEG encoding ≈16 ms over 5 captures.
- **Tests**: 148 unit tests in total. New ones cover settings changes (validation, clamping, yes/no), the `[SETTING]` tag, suggestion back-off doubling up to 7 days, the suggestion JSON parser, and friendly errors.
- **Packaging**: an original app icon (generated by `scripts/make-icon.swift`), `scripts/make-dmg.sh` (local or Developer ID signing plus notarization), and a README.


## 0.8.0 — Phase 8: buddies, routines, skills, notes, MCP (2026-10-01)

### Added
- **Buddies**: persistent named agents. Each one has a role, a folder (`~/Sidekick/Buddies/<name>/`) with `MEMORY.md` (the last 40 dated lines of what it did), its own conversation, and an original generated avatar (5 shape styles × 8 hues, derived from the name).
  - Two defaults: General Helper and Tutor.
  - Create them by asking ("make me a buddy that…"), through the agent's `buddy_create` tool, or in Settings → buddies.
  - Typing in a buddy's chat runs that buddy as an agent. Results come back as unread.
  - Archive and unarchive them; archived ones still show when you search.
- **Routines**:
  - Schedules accept `daily 21:00`, `9pm`, `weekdays 9:30am`, `weekly mon 08:00`, `friday 1800`, `every 3 hours`, or 5-field cron with lists, ranges and steps.
  - `RoutineScheduler` keeps one timer for the earliest due run, using a **min-heap** (O(log n)).
  - It re-checks on wake and when the network comes back. Missed runs while offline retry in 15 min and don't count as failures. A routine pauses after **3 real failures**.
  - Runs are **headless**: no card, no questions, and anything needing approval is declined and mentioned in the summary. The result lands in the buddy's chat as unread, so the notch shows a dot.
  - Settings → buddies: add routines (with a live preview of the parsed schedule), enable / pause, run now, delete.
- **Skills library**: markdown files in `~/Library/Application Support/Sidekick/Skills/` with `name`, `description` and `triggers` frontmatter.
  - 10 starter skills: concise answers, beginner explanations, code reviewer, email in my style, Hinglish mode, patient tutor, meeting notes, design critic, productivity coach, careful with facts.
  - Enabled skills go into voice, chat and agent prompts (capped at 2000 characters). Skills with triggers only apply when your message mentions one.
  - Settings → skills: toggle, edit, delete, "create a skill" (describe it → the fast model drafts it → you edit), import or export `.md`.
- **Notes wiki**: `~/Sidekick/Notes/`, one file per topic. Saving appends with a date and auto-links mentions of other topics as `[[Topic]]`.
  - Agent tools `wiki_save` / `wiki_search` handle "save this…".
  - Assistant messages have a "save to notes" action. Notes are listed in the sidebar and open in a reader view.
- **MCP client**: JSON-RPC 2.0 over **stdio** (newline-delimited; launched through a login shell so `npx`/`uvx` work) and **Streamable HTTP** (JSON or SSE replies, `Mcp-Session-Id`, an optional bearer token).
  - It runs initialize → `tools/list`, and each server tool becomes an agent tool named `mcp_<server>_<tool>`.
  - Tool schemas are sanitized for Gemini.
  - Tools that aren't marked `readOnlyHint` **always ask** before running.
  - Settings → connections: add (stdio command or URL, env vars stored in the **Keychain**), see status and tool count, reconnect, remove.
- **Notch chat**: the sidebar shows buddies (with avatars and unread dots) and notes. Peek shows buddies with unread dots and each one's 3 newest files, which you can drag out or click to open.
- **Delete all data** now also clears buddies, skills, notes and MCP servers and their tokens.

### Tests
- 140 unit tests in total. New ones cover schedule parsing and next-run math (daily, weekdays skipping weekends, cron steps), min-heap order, skill parsing and triggers, the prompt cap, skill library save/toggle, wiki auto-link/append/search, buddy names and avatars, MCP tool parsing and schema sanitizing, SSE parsing, tool naming, env parsing, and a **live stdio round-trip against a small Python MCP server**.


## 0.7.0 — Phase 7: computer use + always-on voice (2026-10-01)

### Added
- **Computer-use tools for agents**, Accessibility first:
  - `ui_read`: a screenshot of the frontmost app plus a numbered list of up to 200 actionable elements from a breadth-first walk of the focused window, with centers in 0–1000 (y, x) and the top-level menus. Only the newest screenshot stays in context.
  - `ui_click`: `AXPress` by element id; falls back to a synthesized click at the element (or at y,x), then warps the real cursor back.
  - `ui_type`: AX set-text into an element or the focused field, checked by reading the field back; falls back to typing unicode key events. It refuses secure (password) fields and text that looks like a card number or one-time code.
  - `ui_key` ("cmd+l", "return", "down", …) and `ui_menu` ("File > New Folder", walked through the AX menu bar and pressed directly).
- **Per-task permission**: "allow sidekick to use your mac for this task?" is asked once, on the first `ui_*` action of a run.
- **"controlling" banner**: a red "sidekick is controlling your mac · esc to stop" pill shows whenever synthesized mouse or keyboard events are sent. It doesn't appear in screen shares. Esc aborts the agent.
- **`open_url` accepts app deep links** from an allowlist (spotify, music, maps, slack, notion, figma, zoommtg, msteams, mailto). `file:` and `javascript:` are never opened.
- **Always-on voice**: triple-tap ⌃, or use the menu item.
  - It runs its own audio engine; macOS allows several input clients at once.
  - `UtteranceSegmenter` starts an utterance after 120 ms of voice, ends it after 600 ms of silence, and caps it at 30 s.
  - Each utterance takes a fresh screenshot and goes through the normal talk pipeline.
  - Listening pauses while Sidekick is thinking or speaking (so it doesn't hear itself), while you dictate, or while push-to-talk is active.
  - The buddy shows its ring while listening. The first time, it says headphones work best.
- **Agent prompt** gained a short "how to operate apps" rule.

### Tests
- 125 unit tests in total. New ones cover the segmenter (one utterance, short pauses, blips, 30 s cap), AX formatting, menu paths, key combos, the sensitive-text guard, dropping old screenshots, and the app-link allowlist.


## 0.6.0 — Phase 6: agents + tools (2026-10-01)

### Added
- **`[AGENT task="…"]`** (from a voice turn) starts an **agent run**. A **5-second cancel window** opens first: a countdown card with a cancel button. Esc or saying "cancel" also stops it.
- **`AgentRunner`**:
  - a Gemini **function-calling loop** on the smart model: at most 25 steps, 90 s per step, 60 s per tool
  - the model's turns are echoed back exactly as received, so Gemini 3 thought signatures survive
  - a built-in `ask_user` tool for missing info; answer in the card or by voice
  - says a one-sentence summary out loud when done
  - each run is saved in `agent_run` (steps and files as JSON), and the summary plus file list goes into the voice chat
- **Agent card** (top right, glassy):
  - slides in; steps tick off with check/cross animations and the step list collapses
  - an approval prompt shows the exact action, with allow / don't buttons, or say "yes" / "no" with ⌃⌥
  - files appear as QuickLook thumbnails: click to open, drag out to other apps
  - a follow-up box once the run is done, and a single bounce on completion
- **Tools**: each has a name, a JSON schema and a confirmation rule.
  - `open_app` and `open_url` (http(s) only)
  - `web_search` uses Gemini Google Search grounding and returns sources; `fetch_url` returns readable text
  - `files_list` / `files_read` / `files_write` are sandboxed to the output folder plus the folders you approve in Settings; the check blocks `..`, symlinks and prefix tricks. Overwriting a file needs approval.
  - `create_csv` (RFC 4180), `create_markdown`, and `create_xlsx` (a real OOXML file zipped with `/usr/bin/zip`; numbers stay numeric). They never overwrite: a name collision becomes "name 2.ext".
  - `notes_create` / `notes_search` (Apple Notes via AppleScript)
  - `calendar_list_events` / `calendar_create_event` and `reminders_list` / `reminders_create` (EventKit, full access asked on first use)
  - `run_shell` **always** asks first and shows the exact command; zsh, 30 s limit, runs in the output folder
- **Outputs** are saved in `~/Sidekick/Buddies/General Helper/`.
- **Settings → general**: a list of extra folders agents may use.

### Tests
- 114 unit tests in total. New ones cover path sandboxing, CSV escaping, unique names, overwrite approval, the XLSX contents (unzipped and checked), HTML → text, grounding sources, function-call parsing with thought signatures, timeouts, and the registry schema serializing to JSON.


## 0.5.0 — Phase 5: memory + notch home (2026-10-01)

### Added
- **Database**: GRDB 7.11 (vendored via `scripts/fetch-vendor.sh`). A single SQLite file in WAL mode, `sidekick.sqlite`, holds every spec §6 table:
  - `buddy`, `conversation`, `message`, `routine`, `agent_run`, `dictionary`, `usage_daily`, `setting`
  - `message_fts`, an FTS5 table kept in sync with messages
- **Memory**: `MemoryStore` keeps `PROFILE.md` and `VOLATILE.md` under `~/Library/Application Support/Sidekick/Memory/`. VOLATILE lines are date-stamped and expire after 7 days. Both files go into every voice and chat prompt, capped at about 800 tokens.
- **`MemoryUpdater`**: after a conversation, the cheap model returns a minimal line diff (`+`, `-`, `~ old => new`), applied in O(lines).
  - It runs 30 s after a conversation, or 2 s after phrases like "remember / forget / my name is / keep answers…".
  - Lines that look secret are rejected: cards, passwords, OTPs, API keys.
- **Notch app**:
  - finds the real notch from the screen's auxiliary top areas, or draws a virtual 180×32 pill on displays without one
  - hover check is O(1) on the top 6 pt band within ±20 pt of the notch; opens after a 120 ms dwell and closes after 350 ms outside unless pinned, typing, a menu is open, or you scrolled up during streaming
  - ⌃⌘A or clicking the notch opens it; Esc closes it
  - it never steals focus: a non-activating panel that becomes key only to type
- **Morph animation**: one spring (response 0.38, damping 0.82) grows the black shape out of the notch. Content fades in 80 ms later with scale 0.96→1 and blur 6→0, staggering header → messages → input 30 ms apart. Closing fades content out in 120 ms, then springs back.
- **Panel sizes**: Peek 420×150, Compact 720×520, and Expanded, which you resize by dragging the edges, is remembered, and resets on double-click. Pop-out turns the panel into a movable window whose frame and state persist; tuck-back returns it to the notch.
- **Chat UI** (original design):
  - collapsible sidebar: new chat, FTS search with debounce and prefix matching, history grouped Today / Yesterday / Previous 7 days / Older, a sliding selection pill, hover fades, rename / archive / delete (with confirm), and a show-archived toggle
  - header: editable title, Auto / Fast / Smart picker, pin, pop-out, close
  - empty state: a greeting using your name from memory, plus 4 suggestion chips based on the frontmost app
  - messages: your messages in bubbles on the right, replies full-width as markdown — headings, lists, quotes, tables, and code blocks with syntax highlighting, a language label and a copy button
  - streaming: only the streaming row re-renders, and `IncrementalMarkdown` re-parses only the open tail. There is a blinking caret, typing dots, and a Stop button.
  - auto-follow only when you're already at the bottom; otherwise a floating "jump to latest" button that pulses once when clicked
  - top and bottom fade masks on the message list
  - hover actions on messages: copy (icon morphs to a check), regenerate, edit & resend, read aloud, thumbs up/down
- **Input bar**: grows with your text (Enter sends, ⇧Enter adds a newline). Attach files with the button, by drag & drop, or by pasting images. There is an "include my screen" toggle, a hold-to-talk mic with a level ring, and a gentle shake on errors.
- **Shortcuts**: ⌘N, ⌘K, ⌘[ / ⌘], ⌘⇧S, ⌘,, and Esc.
- **Chat details**:
  - after the first reply, the cheap model writes the chat title
  - push-to-talk turns are saved (text only) in a daily "voice chat"
  - drafts are kept per chat
  - a dot on the notch shows unread chats
- **Settings**: new memory tab (edit both files, show in Finder, delete all memory). The usage tab has a monthly chart with Swift Charts, backed by `usage_daily`. A privacy section has "delete all data".
- **Moved to SQLite**: usage and the dictionary now live in the database. Legacy JSON is imported once.

### Measured
- The notch sits over the real notch: 179×32 pt on this MacBook Air.
- Idle CPU is 0.1% once warm. Launch peaks around 4% while Whisper loads.

### Tests
- 102 unit tests in total. New ones cover memory diff, secrets, expiry, markdown, the incremental parser matching a full parse for any chunk size, the highlighter, notch geometry, chat sections, and the DB (CRUD, FTS sync after delete, usage upsert, dictionary).


## 0.4.0 — Phase 4: dictation (2026-10-01)

### Added
- **Dictation hotkey**: hold **fn ⌃** to dictate into any app. Double-tap it for hands-free mode, which stops on another tap, after 3 s of silence, or after 8 s if nothing was said.
- **HUD**: a waveform pill at the bottom-center of the screen. It is click-through and doesn't appear in screen shares.
- **`TextCleaner`**:
  - removes fillers (um, uh, erm…)
  - turns spoken "comma / period / full stop / question mark / new line / new paragraph" into punctuation, without doubling punctuation Whisper already added
  - tidies spacing and capitalizes sentences
- **AI polish**: an optional Flash-Lite cleanup with a 3 s timeout. It is off by default; with it off, dictation never calls Gemini.
- **`TextInserter`**:
  - inserts through Accessibility (`kAXSelectedTextAttribute`) and reads the field back to confirm the value actually changed
  - falls back to paste: saves the clipboard, sets the text, sends ⌘V, and restores the clipboard after 300 ms, unless you copied something in the meantime
  - goes straight to paste for Electron apps (detected by their bundled framework) and Chromium browsers
  - adds a leading space when continuing right after a word
- **`PersonalDictionary`**:
  - after an insertion, an AX value-changed observer watches the field for 20 s
  - `CorrectionLearner` diffs the field in UTF-16 offsets and learns a small word fix, but only one inside the inserted text, not a rewrite, and checked with an edit-distance limit
  - learned spellings bias Whisper (initial prompt) and are applied as a whole-word replacement map
  - Settings → dictionary lets you view, add and remove entries
- **Screen-aware writing**: the talk prompt now has a `[TYPE text="…"]` rule. Ask with ⌃⌥ — e.g. "write a reply to this saying I'll be late" — and the draft is typed into the focused field.
- **Shared mic**: the talk and dictation hotkeys share one `AudioCapture` and won't start while the other is using the mic. Esc cancels dictation.
- **Hotkeys**:
  - the hotkey state machine now reports a clean `.tap` separately from `.cancelled`
  - `TapCounter` detects double and triple taps
  - the event tap supports several bindings at once

### Tests
- 85 unit tests in total.


## 0.3.0 — Phase 3: teaching + spatial context (2026-10-01)

### Added
- **Teaching mode**: a `TeachingSession` state machine runs explain → point → wait for click → verify → next.
  - The lesson starts when a reply contains `[WAIT_CLICK]`.
  - When the reply finishes, the coordinator waits for any pending AX snaps, then watches your next click.
  - A right click shows a green check, the buddy bounces, it says "nice!", takes a fresh look and asks for the next step.
  - A wrong click re-points at the target, with one spoken hint ("not quite, it's over here"). Re-pointing stops after 3 misses.
  - Spoken commands: "skip", "go back" and "stop" (plus Hinglish variants). These are handled locally, with no model call.
  - The bubble shows "step n of m".
- **`ClickObserver`**: NSEvent global and local `leftMouseDown` monitors, installed only while waiting for a click. They need no extra permission.
- **User ink**: while ⌃⌥ is held, you can drag on the screen to draw a red trail. The overlay accepts mouse input only during the hold. The strokes are burned onto the outgoing screenshot (red, 6 px) and the prompt says the marked area matters. The trail fades 1.5 s after release.
- **App skills**:
  - 21 starter skill files: Finder, Safari, Chrome, VS Code, Cursor, Xcode, Terminal/iTerm, Figma, Notion, Google Docs/Sheets/Slides, Excel, PowerPoint, Keynote, DaVinci Resolve, Final Cut Pro, FL Studio, Logic Pro, Photoshop, Canva, Slack, Gmail.
  - Each file lists what it matches (bundle ids and/or domains) in `match:` frontmatter. A site match beats the browser's own skill.
  - User files in `~/Library/Application Support/Sidekick/AppSkills` override bundled ones.
- **`ModelRouter`**: in auto mode it picks fast by default and smart for "think hard / explain in detail / detail mein…" or for questions of 45+ words. You can force fast or smart in Settings → ai.
- **`[ESCALATE]`**: if the fast model emits it, the stream is cut, Sidekick says "let me think about that." and the same turn is retried on the smart model, with its own thinking level and a larger output limit.

### Tests
- 69 unit tests in total. New ones cover the lesson cycle, hit testing, voice commands, router rules, the skills index, site-over-browser precedence, user overrides, every bundled skill having match keys, and ink burned at the right pixels.


## 0.2.0 — Phase 2: buddy overlay + pointing (2026-10-01)

### Added
- **Buddy cursor**: an original droplet-shaped buddy with eyes, whose tip points up-left. It follows the cursor, offset bottom-right, with a soft eased follow. Moods:
  - idle: breathes and blinks
  - listening: a ring reacts to your voice level
  - thinking: orbiting dots
  - speaking: an animated mouth
  - pointing
- All of this runs as Core Animation on the render server; the app itself uses 0.0% CPU at idle.
- **Overlays**: one click-through overlay panel per display. They sit above menus, don't appear in screen shares, and rebuild when displays change.
- **`TagParser`**: a single-pass streaming parser for `[POINT]`, `[CIRCLE]`, `[ARROW]`, `[HIGHLIGHT]`, `[STEP]`, `[WAIT_CLICK]`, `[ESCALATE]`, `[AGENT]` and `[TYPE]`. It handles quoted values containing `]`, escapes, loose number formats and malformed tags. 500 fuzzed chunkings are tested.
- **Annotations**:
  - hand-drawn ink with a wobbly, overshooting loop for circles
  - curved arrows with arrowheads, rounded highlight boxes, and pulse rings for points
  - a 300 ms draw-on animation, auto-fade after 6 s, and label pills
- **Pointing**: the buddy hops along a curved arc to its target and bounces on arrival. It returns after 4 s, or once the mouse moves more than 200 pt.
- **AX snapping**: a target snaps to the nearest actionable element within 40 pt, such as a button, menu bar item, field, link or tab. It probes 17 points around the target and uses the element's frame for circles.
- The cursor bubble now rides alongside the buddy.
- Settings → general: "show buddy" and "dock buddy in the notch".
- Menu → "show me the buddy": circles the Apple menu. It works without an API key.
- `Motion.swift` holds the shared animation tokens from spec §7b.
- Settings decoding is tolerant: new keys keep their defaults, and saved settings are never wiped.
- Latency logging: per-stage timings go to the unified log (`log show --predicate 'subsystem == "com.mayankyadav.sidekick"'`).

### Changed (speed)
- `./build.sh install` now builds Release.
- The TLS connection to Gemini is pre-opened when ⌃⌥ is pressed.
- The TTS voice is pre-warmed at launch.
- Speech starts at the first comma after about 24 characters, instead of waiting for a full sentence.

### Tests
- 56 unit tests in total.


## 0.1.0 — Phase 1: core talk loop (2026-10-01)

### Added
- XcodeGen project (`project.yml`): a menu-bar app (`LSUIElement`), not sandboxed, with WhisperKit 1.1 via SPM. `build.sh` builds it from the CLI.
- Onboarding window:
  - live status for the 4 permissions, polled once per second only while the window is visible
  - Gemini key check that costs nothing, then saved to Keychain
  - Whisper download/warm-up progress
- Push-to-talk on hold ⌃⌥: a `CGEventTap` with a 150 ms hold threshold, pre-roll capture, and cancel when another key is pressed. Esc is consumed only while Sidekick is busy.
- `AudioCapture`: AVAudioEngine → 16 kHz mono into a pre-allocated 120 s ring buffer, publishing an RMS level about 30×/s. Energy VAD trims silence.
- `WhisperKitSTT`: loads once, warms up, stays resident. Auto language detection, with an optional fixed language. Whisper markers like `[BLANK_AUDIO]` are stripped. If nothing is heard, it shows "didn't catch that" and makes no API call.
- `ScreenCapturer`: captures the display under the cursor with ScreenCaptureKit, excluding Sidekick's own windows. Long side is 1280 px, JPEG at 0.7, kept in memory only. Also collects the front app, window title and browser URL.
- `GeminiClient`: REST + SSE streaming. The latest screenshot is sent with the request; history is text only, capped at 10 turns. Retries 429/5xx with backoff. Retries without the thinking config if the model rejects it.
- `SentenceSplitter`: incremental, O(n). Strips tags, markdown and URLs from what gets spoken.
- `SystemTTS`: a sentence queue that starts speaking at the first full sentence. Pressing the hotkey interrupts it (barge-in), and Esc stops it instantly.
- `CursorBubble`: a click-through, non-activating panel that doesn't appear in screen shares. Shows the listening ring, transcript and streamed reply.
- `CostMeter`: per-model prices, daily totals, a warning at 80% and a hard stop at 100% (configurable).
- Settings with 4 tabs (general, voice, ai, usage). The general tab shows timings from the last run.
- 42 unit tests: ring buffer, VAD, hotkey state machine, sentence splitter (300 fuzzed chunkings), SSE parser and request body, prompt builder, cost meter, coordinate mapper, transcript cleaning.

### Measured (M-series Mac, Debug build)
- Whisper `small`, 3.7 s clip: first decode after warm-up 365 ms, then about 335 ms (budget for a 5 s clip: 700 ms).
- Load + warm from cache: about 6 s at launch, in the background.
- RSS with Whisper `small` loaded: about 210 MB (budget: 600 MB). Idle CPU: 0.0%.

## 0.11.0 — Natural voice
- Soft, human-sounding offline voice (Kokoro "Heart" by default; 8 soft female voices in Settings → Voice, with "hear a sample"). Hindi replies use the Priyamvada voice.
- Voice turns always speak; typed chat never does. Tests no longer flip the saved "text only" setting.
- Agent tasks run quietly (no card unless they need you), with an "auto-approve" setting (risky shell commands still ask).
- Buddy cursor: red, evenly rounded like HeyClicky's, moves in lockstep with the pointer, hides with it when idle or typing.
- Warmer, conversational personality in voice, chat and agent replies.

## 0.11.1 — Full test sweep fixes
- Web search works on used-up free keys (DuckDuckGo fallback when Gemini search grounding is out of quota).
- One shared, persisted memory of used-up models (voice, chat, tasks, search) — no more waiting on them every request.
- Backup model: 12 s stall watchdog + one fresh retry instead of a 30 s hang.
- Math cleanup no longer touches inline code or Windows paths; "do it anyway" task safety net only fires when the reply really carries out the command.
- Natural voice survives headphone/speaker changes; frees its model after 10 idle minutes and reloads when you start talking.
- Memory facts are no longer double-dated (which also broke the 7-day expiry).
- Voice transcripts fix the app's own name ("side cake" → "Sidekick").
- New: open_path agent tool; typed chat auto-attaches the screen when the message is about it; resize grips on the notch panel.

## 0.11.2
- Calendar & Reminders access (granted; Settings → General shows status with an "allow" button).
- Always-on "Concise answers" and "Fact checker" skills switched off; keyword skills stay on (they only apply when relevant).
- PROFILE.md is sectioned: About me, Work & projects, Preferences, People, Interests & habits. Old flat files are migrated on the next update.

## 0.11.3
- One-word answers work: short clips are padded to 1.5 s for Whisper (and retried as English if empty). Measured: "yes / yeah / no / okay / do it / yeah sure" 1/24 → 24/24, including quiet speech.
- Yes/no detection matches whole words and phrases (Hindi too); "now"/"know"/"book" no longer count as answers.
- Saying yes to an offer ("want me to open…?" → "yeah sure") always starts the task.
- Notch messages show in full on a strip below the camera notch (two lines for long ones) instead of being cut at 32 characters and hidden.

## 0.11.4 — Open things in the app you asked for
- open_url / open_path take an app ("open github on chrome" opens Chrome, not the default browser); a browser named in the task is honoured even if the model forgets it; missing apps are reported instead of silently using another one.
- App lookup understands short names and aliases (chrome, vs code, word, edge…) and finds apps anywhere via Spotlight.
- Bare domains ("github.com") open as https links.
- Test hook fix: an optimized-build crash in the talk probe (array ternary in an async function) — pattern not used in app code.

## 0.11.5 — Better listening and typing
- Whisper gets vocabulary hints: names read off the screen while you speak (Vision OCR, ~90 ms), names from memory and the personal dictionary. Measured on spoken test sentences: "Ravi Sharma", "Priya Mehta", "WhatsApp", "Rahul" now spelled right (were "raw sharma", "VHARTS app", "Rahool"). One-word answers skip hints (still 24/24).
- Agent typing: one character per event from a private event source with no modifier flags, after held modifiers are released — no more all-caps or shortcut keystrokes; works in apps that read only the first character of a multi-character event.
- ALL-CAPS text from the model is typed in normal case ("Ravi Sharma", "Hey") unless the user asked for capitals; typed text is shown in the task steps.
- Talk/agent prompts know transcripts can mishear names and short words; agents retry searches with shorter/similar spellings.

## 0.11.6 — "Correct what I wrote" replaces instead of appending
- New [REPLACE] action: corrections replace your selection, or the whole field you were writing in, instead of being typed next to it.
- The focused field's text (never password fields) is read when you press the talk keys and given to the model; the prompt asks for minimal fixes only (misspellings + grammar, same words/meaning/tone).
- Chromium/Electron apps (Chrome, the Claude app, Slack, VS Code…): accessibility is switched on for the app so its fields can be read; otherwise select-all + paste in that field.
- Only replaces in the app you spoke from; if you switched apps, the corrected text goes to the clipboard instead.
- Fixed synthetic shortcuts (⌘A, ⌘V, agent key presses) releasing with modifiers still "held" — this left ⌘/⇧ stuck (likely cause of earlier all-caps typing) and stalled pastes.
