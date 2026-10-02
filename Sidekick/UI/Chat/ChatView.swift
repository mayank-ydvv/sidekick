import SwiftUI
import UniformTypeIdentifiers

/// Parsed markdown is cached per message so scrolling never re-parses.
@MainActor
enum MarkdownCache {
    private static var cache: [Int64: (Int, [MDBlock])] = [:]
    static func blocks(_ m: MessageRecord) -> [MDBlock] {
        guard let id = m.id else { return Markdown.parse(m.text) }
        if let (len, b) = cache[id], len == m.text.utf16.count { return b }
        let b = Markdown.parse(m.text)
        if cache.count > 2000 { cache.removeAll() }
        cache[id] = (m.text.utf16.count, b)
        return b
    }
}

/// Palette for the notch chat.
enum Palette {
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let sidebar = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let field = Color.white.opacity(0.08)
    static let userBubbleTop = Color(red: 0.76, green: 0.85, blue: 1.0)
    static let userBubbleBottom = Color(red: 0.62, green: 0.76, blue: 1.0)
    static let userText = Color(red: 0.07, green: 0.11, blue: 0.2)
    static let replyBubble = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let selected = LinearGradient(colors: [Color(red: 0.74, green: 0.84, blue: 1.0), Color(red: 0.6, green: 0.75, blue: 1.0)],
                                         startPoint: .top, endPoint: .bottom)
    static let talkPill = LinearGradient(colors: [Color(red: 0.72, green: 0.83, blue: 1.0), Color(red: 0.45, green: 0.62, blue: 0.98)],
                                         startPoint: .top, endPoint: .bottom)
    static let unread = Color(red: 0.2, green: 0.5, blue: 1.0)
}

/// The notch chat: collapsible sidebar + messages + input bar.
struct ChatView: View {
    let ctx: ChatContext
    @Environment(\.notchPeek) private var isPeek
    @Environment(\.notchPoppedOut) private var poppedOut
    @Namespace private var selection
    @FocusState private var searchFocused: Bool

    var body: some View {
        if isPeek {
            PeekView(ctx: ctx)
        } else {
            HStack(spacing: 0) {
                if ctx.ui.sidebarVisible {
                    Sidebar(ctx: ctx, selection: selection, searchFocused: $searchFocused)
                        .frame(width: 290)
                        .background(Palette.sidebar)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Group {
                    if let topic = ctx.ui.viewingNote {
                        NoteView(ctx: ctx, topic: topic)
                    } else {
                        VStack(spacing: 0) {
                            Header(ctx: ctx, poppedOut: poppedOut)
                                .modifier(Stagger(visible: ctx.ui.contentVisible || poppedOut, index: 0))
                            MessageList(ctx: ctx)
                                .modifier(Stagger(visible: ctx.ui.contentVisible || poppedOut, index: 1))
                            InputBar(ctx: ctx)
                                .modifier(Stagger(visible: ctx.ui.contentVisible || poppedOut, index: 2))
                        }
                    }
                }
                .background(Palette.panel)
            }
            .animation(Motion.smooth, value: ctx.ui.sidebarVisible)
            .background(shortcuts)
        }
    }

    /// Hidden buttons that carry the keyboard shortcuts.
    private var shortcuts: some View {
        Group {
            Button("") { ctx.ui.viewingNote = nil; ctx.store.newChat() }.keyboardShortcut("n", modifiers: .command)
            Button("") { ctx.ui.sidebarVisible = true; searchFocused = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { ctx.store.selectAdjacent(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { ctx.store.selectAdjacent(1) }.keyboardShortcut("]", modifiers: .command)
            Button("") { ctx.ui.sidebarVisible.toggle() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { ctx.openSettings() }.keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Header → messages → input bar fade in 30 ms apart.
private struct Stagger: ViewModifier {
    let visible: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 4)
            .animation(Motion.fade.delay(Double(index) * 0.03), value: visible)
    }
}

// MARK: Rows

/// Avatar for a conversation: the buddy's cloud, a waveform for voice chats, a chat bubble otherwise.
struct ConversationAvatar: View {
    let ctx: ChatContext
    let conversation: ConversationRecord?
    var size: CGFloat = 40
    var body: some View {
        if let b = ctx.buddies.buddy(conversation?.buddyId) {
            BuddyAvatarView(preset: b.avatar, size: size)
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.36), Color(red: 0.12, green: 0.13, blue: 0.2)],
                                             startPoint: .top, endPoint: .bottom))
                if conversation?.kind == "voice" {
                    Image(systemName: "waveform").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(Color(red: 0.4, green: 0.95, blue: 1))
                } else {
                    Image(systemName: "bubble.left.fill").font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [Color(red: 0.72, green: 0.86, blue: 1), Color(red: 0.45, green: 0.68, blue: 1)],
                                                        startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: size, height: size)
        }
    }
}

/// Messages-style row: unread dot, avatar, name + badge, time, one-line preview, optional thumbnail.
struct ConversationRow<Avatar: View>: View {
    let name: String
    let time: String
    let preview: String
    var badge: Int = 0
    var unread = false
    var selected = false
    var thumbnail: URL? = nil
    var compact = false
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(unread ? Palette.unread : .clear).frame(width: 7, height: 7)
            avatar()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: compact ? 13 : 14, weight: .semibold)).lineLimit(1)
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? Color.black.opacity(0.12) : Color.white.opacity(0.12)))
                    }
                    Spacer(minLength: 4)
                    Text(time).font(.system(size: 11.5)).foregroundStyle(selected ? Palette.userText.opacity(0.7) : .secondary).lineLimit(1)
                }
                Text(preview.isEmpty ? " " : preview).font(.system(size: compact ? 12 : 12.5))
                    .foregroundStyle(selected ? Palette.userText.opacity(0.75) : .secondary).lineLimit(1)
            }
            if let thumbnail {
                Image(nsImage: NSWorkspace.shared.icon(forFile: thumbnail.path)).resizable().scaledToFit()
                    .frame(width: 30, height: 36)
                    .rotationEffect(.degrees(4))
                    .onDrag { NSItemProvider(contentsOf: thumbnail) ?? NSItemProvider() }
                    .help(thumbnail.lastPathComponent)
            }
        }
        .foregroundStyle(selected ? Palette.userText : .primary)
        .padding(.vertical, compact ? 5 : 7).padding(.trailing, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    let ctx: ChatContext
    let selection: Namespace.ID
    var searchFocused: FocusState<Bool>.Binding
    @State private var hovered: Int64?
    @State private var renaming: ConversationRecord?
    @State private var renameText = ""
    @State private var confirmDelete: ConversationRecord?

    var body: some View {
        @Bindable var store = ctx.store
        VStack(alignment: .leading, spacing: 10) {
            Text(ctx.settings.data.pushToTalk.symbols)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .padding(.leading, 14).padding(.top, 6)
                .accessibilityLabel("sidekick")
            HStack(spacing: 8) {
                Button { ctx.ui.sidebarVisible = false } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless).accessibilityLabel("hide sidebar")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Search", text: $store.searchText).textFieldStyle(.plain).font(.system(size: 13)).focused(searchFocused)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
                Button { ctx.ui.viewingNote = nil; ctx.store.newChat() } label: { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)) }
                    .buttonStyle(.borderless)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.field))
                    .accessibilityLabel("new chat")
            }
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if ctx.store.searchText.isEmpty {
                        ForEach(ctx.buddies.buddies.filter { !$0.archived || ctx.store.showArchived }) { b in buddyRow(b) }
                    }
                    ForEach(ctx.store.grouped, id: \.0) { section, items in
                        Text(section.rawValue).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.leading, 26)
                        ForEach(items) { c in row(c) }
                    }
                    if !ctx.wiki.topics.isEmpty {
                        Text("notes").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 26)
                        ForEach(ctx.wiki.topics.filter { ctx.store.searchText.isEmpty || $0.localizedCaseInsensitiveContains(ctx.store.searchText) }, id: \.self) { t in
                            Label(t, systemImage: "doc.text").font(.system(size: 12.5)).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6).padding(.leading, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(ctx.ui.viewingNote == t ? Color.white.opacity(0.1) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(Motion.snappy) { ctx.ui.viewingNote = t } }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .animation(Motion.snappy, value: ctx.store.visibleConversations.map(\.id))
            }
            .scrollIndicators(.never)

            Toggle("show archived", isOn: $store.showArchived).toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            Divider().opacity(0.3)
            HStack(spacing: 10) {
                let name = ctx.memory.userName ?? "you"
                Text(String(name.prefix(1)).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Circle().fill(Color(red: 0.5, green: 0.34, blue: 0.76)))
                Text(name.uppercased()).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer()
                Button { ctx.openSettings() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.borderless).accessibilityLabel("settings")
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .padding(.top, 8)
        .alert("rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("title", text: $renameText)
            Button("save") { if let r = renaming { ctx.store.rename(r, to: renameText) }; renaming = nil }
            Button("cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("delete this chat?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("delete", role: .destructive) { if let c = confirmDelete { ctx.store.delete(c) }; confirmDelete = nil }
        } message: { Text("this can't be undone.") }
        .onChange(of: renaming != nil || confirmDelete != nil) { _, open in ctx.ui.menuOpen = open }
    }

    private func selectionBackground(_ selected: Bool, hovered: Bool) -> some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.selected)
                    .matchedGeometryEffect(id: "selection", in: selection)
            } else if hovered {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05))
            }
        }
    }

    private func buddyRow(_ b: BuddyRecord) -> some View {
        let conv = ctx.store.conversation(forBuddy: b.id)
        let isSelected = conv?.id != nil && conv?.id == ctx.store.selectedId
        return ConversationRow(name: b.name, time: conv.map { ChatStore.shortTime($0.updatedAt) } ?? "",
                               preview: conv.map(ctx.store.preview).flatMap { $0.isEmpty ? nil : $0 } ?? b.rolePrompt,
                               unread: conv?.unread == true, selected: isSelected, compact: true) {
            BuddyAvatarView(preset: b.avatar, size: 38)
        }
        .background(selectionBackground(isSelected, hovered: hovered == conv?.id && conv != nil))
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovered = h ? conv?.id : nil } }
        .onTapGesture { withAnimation(Motion.snappy) { ctx.ui.viewingNote = nil; ctx.store.selectedId = conv?.id } }
        .contextMenu {
            Button(b.archived ? "unarchive" : "archive") { ctx.buddies.setArchived(b, !b.archived) }
            Button("open folder") { NSWorkspace.shared.open(URL(fileURLWithPath: b.folderPath)) }
        }
    }

    private func row(_ c: ConversationRecord) -> some View {
        let isSelected = c.id == ctx.store.selectedId
        return ConversationRow(name: c.title, time: ChatStore.shortTime(c.updatedAt), preview: ctx.store.preview(c),
                               unread: c.unread, selected: isSelected, compact: true) {
            ConversationAvatar(ctx: ctx, conversation: c, size: 38)
        }
        .opacity(c.archived ? 0.6 : 1)
        .background(selectionBackground(isSelected, hovered: hovered == c.id))
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovered = h ? c.id : nil } }
        .onTapGesture { withAnimation(Motion.snappy) { ctx.ui.viewingNote = nil; ctx.store.selectedId = c.id } }
        .contextMenu {
            Button("rename") { renameText = c.title; renaming = c }
            Button(c.archived ? "unarchive" : "archive") { withAnimation(Motion.snappy) { ctx.store.setArchived(c, !c.archived) } }
            Divider()
            Button("delete…", role: .destructive) { confirmDelete = c }
        }
    }
}

// MARK: Header

private struct Header: View {
    let ctx: ChatContext
    let poppedOut: Bool
    @State private var editingTitle = false
    @State private var title = ""

    var body: some View {
        @Bindable var s = ctx.settings
        ZStack {
            HStack(spacing: 12) {
                if !ctx.ui.sidebarVisible {
                    Button { ctx.ui.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).accessibilityLabel("show sidebar")
                }
                Spacer()
                Menu {
                    Picker("model", selection: $s.data.modelTier) {
                        Text("auto").tag(ModelTier.auto)
                        Text("fast").tag(ModelTier.fast)
                        Text("smart").tag(ModelTier.smart)
                    }
                } label: { Image(systemName: "bolt.horizontal.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("model: \(s.data.modelTier.rawValue)")
                if !poppedOut {
                    Button { ctx.ui.pinned.toggle() } label: { Image(systemName: ctx.ui.pinned ? "pin.fill" : "pin") }
                        .buttonStyle(.borderless).accessibilityLabel(ctx.ui.pinned ? "unpin" : "pin")
                    Button { ctx.controller?.popOut() } label: { Image(systemName: "rectangle.on.rectangle") }
                        .buttonStyle(.borderless).accessibilityLabel("pop out")
                    Button { ctx.controller?.close() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("close")
                } else {
                    Button { ctx.controller?.tuckBack() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.borderless).accessibilityLabel("tuck back into the notch")
                }
            }
            // Centered avatar + name pill.
            VStack(spacing: 4) {
                ConversationAvatar(ctx: ctx, conversation: ctx.store.selected, size: 34)
                if editingTitle, let c = ctx.store.selected {
                    TextField("title", text: $title, onCommit: { ctx.store.rename(c, to: title); editingTitle = false })
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).frame(width: 200)
                } else {
                    HStack(spacing: 3) {
                        Text(ctx.store.selected?.title ?? "Sidekick").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .onTapGesture(count: 2) { title = ctx.store.selected?.title ?? ""; editingTitle = ctx.store.selected != nil }
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
    }
}

// MARK: Messages

private struct BottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MessageList: View {
    let ctx: ChatContext
    @State private var atBottom = true
    @State private var pulse = false
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if ctx.store.messages.isEmpty && ctx.store.streaming == nil {
                            EmptyState(ctx: ctx)
                        }
                        ForEach(ctx.store.messages) { m in
                            MessageRow(ctx: ctx, message: m)
                                .id(m.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if let s = ctx.store.streaming {
                            StreamingRow(streaming: s).id("streaming")
                        }
                        if let n = ctx.store.modelNote, ctx.store.streaming == nil {
                            Text(n).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                        }
                        if let e = ctx.store.errorText {
                            Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomKey.self, value: g.frame(in: .named("chat")).maxY)
                            })
                    }
                    .padding(.horizontal, 26).padding(.vertical, 12)
                    .animation(Motion.fade, value: ctx.store.messages.count)
                }
                .coordinateSpace(name: "chat")
                .background(GeometryReader { g in Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { _, h in viewport = h } })
                .onPreferenceChange(BottomKey.self) { maxY in
                    let bottom = maxY <= viewport + 40
                    if bottom != atBottom { atBottom = bottom; ctx.ui.userScrolledUp = !bottom }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                             .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: ctx.store.streaming?.text.count) { _, _ in
                    if atBottom { proxy.scrollTo("bottom", anchor: .bottom) }   // auto-follow only at the bottom
                }
                .onChange(of: ctx.store.messages.count) { _, _ in
                    withAnimation(Motion.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: ctx.store.selectedId) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                }

                if !atBottom {
                    Button {
                        withAnimation(Motion.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
                        pulse = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pulse = false }
                    } label: {
                        Label("jump to latest", systemImage: "arrow.down").font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(pulse ? 0.6 : 0.15), lineWidth: pulse ? 2 : 1).scaleEffect(pulse ? 1.15 : 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(Motion.snappy, value: pulse)
                }
            }
            .animation(Motion.fade, value: atBottom)
        }
    }
}

private struct EmptyState: View {
    let ctx: ChatContext
    var body: some View {
        let app = NSWorkspace.shared.frontmostApplication
        VStack(alignment: .leading, spacing: 14) {
            Text("hey \(ctx.memory.userName ?? "there"), what are we doing today?")
                .font(.system(size: 20, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Suggestions.forApp(app?.bundleIdentifier, name: app?.localizedName), id: \.self) { s in
                    Button { ctx.store.send(s, includeScreen: s.contains("screen") || s.contains("this")) } label: {
                        Text(s).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.replyBubble))
                    }
                    .buttonStyle(PressableStyle(plain: true))
                }
            }
        }
        .padding(.top, 24)
    }
}

/// Grey reply bubble.
private struct ReplyBubble<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.replyBubble))
            .frame(maxWidth: 560, alignment: .leading)
    }
}

private struct StreamingRow: View {
    let streaming: StreamingMessage
    @State private var caret = true
    @State private var started = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if streaming.text.isEmpty {
                TypingDots()
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    Text("thinking · \(Int(t.date.timeIntervalSince(started)))s").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ReplyBubble {
                    VStack(alignment: .leading, spacing: 6) {
                        MarkdownView(blocks: streaming.md.blocks)
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(caret ? 0.8 : 0)).frame(width: 7, height: 14)
                            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { caret.toggle() } }
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

/// Grey typing bubble with three bouncing dots.
private struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color.white.opacity(0.75)).frame(width: 7, height: 7)
                    .offset(y: sin(phase + Double(i) * 0.9) * 2.5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Capsule().fill(Palette.replyBubble))
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
        .accessibilityLabel("thinking")
    }
}

private struct MessageRow: View {
    let ctx: ChatContext
    let message: MessageRecord
    @State private var hovering = false
    @State private var editing = false
    @State private var editText = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
            if message.role == "user" {
                if editing {
                    VStack(alignment: .trailing) {
                        TextEditor(text: $editText).font(.system(size: 13.5)).frame(minHeight: 60, maxHeight: 160)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(RoundedRectangle(cornerRadius: 12).fill(Palette.field))
                        HStack {
                            Button("cancel") { editing = false }
                            Button("send") { ctx.store.edit(message, newText: editText); editing = false }.keyboardShortcut(.defaultAction)
                        }.controlSize(.small)
                    }
                } else {
                    Text(message.text)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.userText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(LinearGradient(colors: [Palette.userBubbleTop, Palette.userBubbleBottom], startPoint: .top, endPoint: .bottom))
                        )
                        .overlay(alignment: .bottomTrailing) {
                            // Little tail.
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9))
                                .foregroundStyle(Palette.userBubbleBottom).rotationEffect(.degrees(-35)).offset(x: 2, y: 5)
                        }
                        .frame(maxWidth: 480, alignment: .trailing)
                }
            } else {
                ReplyBubble { MarkdownView(blocks: MarkdownCache.blocks(message)) }
            }
            actions.opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.1), value: hovering)
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(message.createdAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.tertiary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                withAnimation(Motion.snappy) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(Motion.snappy) { copied = false } }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace)) }
                .accessibilityLabel("copy")
            if message.role == "user" {
                Button { editText = message.text; editing = true } label: { Image(systemName: "pencil") }.accessibilityLabel("edit")
            } else {
                Button { ctx.store.regenerate() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("regenerate")
                Button { ctx.readAloud(Markdown.plainText(message.text)) } label: { Image(systemName: "speaker.wave.2") }.accessibilityLabel("read aloud")
                Button {
                    ctx.wiki.save(topic: ctx.store.selected?.title ?? "notes", content: message.text)
                } label: { Image(systemName: "note.text.badge.plus") }.accessibilityLabel("save to notes").help("save to notes")
                Button { ctx.store.setFeedback(message, message.feedback == 1 ? nil : 1) } label: {
                    Image(systemName: message.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                }.accessibilityLabel("good reply")
                Button { ctx.store.setFeedback(message, message.feedback == -1 ? nil : -1) } label: {
                    Image(systemName: message.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }.accessibilityLabel("bad reply")
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

// MARK: Input

struct InputBar: View {
    let ctx: ChatContext
    var compact = false
    @State private var attachments: [ChatAttachment] = []
    @State private var includeScreen = false
    @State private var recording = false
    @State private var shake: CGFloat = 0
    @State private var flash = false
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachments) { a in
                            HStack(spacing: 4) {
                                Image(systemName: a.isImage ? "photo" : "doc").font(.system(size: 10))
                                Text(a.name).font(.system(size: 11)).lineLimit(1)
                                Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).accessibilityLabel("remove \(a.name)")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Palette.field))
                        }
                    }
                }
            }
            if compact || typing || !ctx.store.draft.isEmpty || !attachments.isEmpty || ctx.store.isStreaming {
                textInput
            } else {
                talkFirst
            }
        }
        .padding(.horizontal, compact ? 12 : 22).padding(.bottom, compact ? 10 : 14).padding(.top, 4)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let a = ChatAttachment.load(url) else { return }
                    DispatchQueue.main.async { attachments.append(a); typing = true }
                }
            }
            return true
        }
        .onPasteCommand(of: [.png, .tiff, .fileURL]) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, let a = ChatAttachment.load(url) else { return }
                        DispatchQueue.main.async { attachments.append(a) }
                    }
                } else {
                    p.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                        guard let data else { return }
                        DispatchQueue.main.async { attachments.append(ChatAttachment(name: "pasted image.png", mimeType: "image/png", data: data)) }
                    }
                }
            }
        }
        .onChange(of: ctx.store.errorText) { _, e in if e != nil { shakeIt() } }
        .onChange(of: ctx.ui.wantsTyping) { _, want in
            if want, !compact { typing = true; DispatchQueue.main.async { focused = true } }
        }
        .onAppear { if ctx.ui.wantsTyping, !compact { typing = true } }
    }

    /// Default: a big hold-to-talk pill + a small "Type…" pill.
    private var talkFirst: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                HoldToTalkPill(ctx: ctx, recording: $recording)
                Text(recording ? "Release to send" : "or hold \(ctx.settings.data.pushToTalk.symbols) anywhere")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { withAnimation(Motion.snappy) { typing = true }; focused = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard").font(.system(size: 12))
                    Text("Type…").font(.system(size: 13.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(width: 170, height: 44)
                .background(Capsule().fill(Palette.field))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            }
            .buttonStyle(PressableStyle(plain: true))
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }

    private var textInput: some View {
        @Bindable var store = ctx.store
        return HStack(alignment: .bottom, spacing: 10) {
            if !compact {
                MicButton(ctx: ctx, recording: $recording)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !compact {
                    Button(action: attach) { Image(systemName: "paperclip") }
                        .buttonStyle(.borderless).accessibilityLabel("attach files")
                    Button {
                        includeScreen.toggle()
                        flash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { flash = false }
                    } label: {
                        Image(systemName: includeScreen ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")
                            .foregroundStyle(includeScreen ? Color.accentColor : .secondary)
                            .scaleEffect(flash ? 1.25 : 1).animation(Motion.bouncy, value: flash)
                    }
                    .buttonStyle(.borderless)
                    .help("include my screen")
                    .accessibilityLabel(includeScreen ? "screen included" : "include my screen")
                }
                TextField(compact ? "ask anything…" : "Message \(ctx.store.selected?.title ?? "Sidekick")…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...(compact ? 1 : 8))
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }   // Shift+Enter = newline
                        submit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if !compact, ctx.store.draft.isEmpty { withAnimation(Motion.snappy) { typing = false } }
                        return .ignored
                    }
                    .onChange(of: focused) { _, f in ctx.ui.inputFocused = f }
                if !ctx.store.isStreaming {
                    Button(action: submit) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.25)))
                    }
                    .buttonStyle(.borderless)
                    .disabled(ctx.store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .accessibilityLabel("send")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(Palette.field))
            .overlay(Capsule().strokeBorder(focused ? Palette.userBubbleBottom.opacity(0.8) : Color.white.opacity(0.12), lineWidth: focused ? 1.5 : 1))
            .offset(x: shake)
            if ctx.store.isStreaming {
                Button { ctx.store.cancel() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13)).foregroundStyle(.black)
                        .frame(width: 34, height: 34).background(Circle().fill(Color.white))
                }
                .buttonStyle(.borderless).accessibilityLabel("stop generating")
            }
        }
        .onAppear { if !compact { focused = true } }
    }

    private func submit() {
        let text = ctx.store.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return shakeIt() }
        guard !ctx.store.isStreaming else { return shakeIt() }   // keep the draft + attachments
        if compact { ctx.controller?.open(.compact, focus: true) }
        ctx.store.send(text, attachments: attachments, includeScreen: includeScreen)
        attachments = []
        includeScreen = false
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        ctx.ui.menuOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            ctx.ui.menuOpen = false
            guard resp == .OK else { return }
            attachments += panel.urls.compactMap(ChatAttachment.load)
        }
    }

    /// Gentle 3-oscillation, 8 pt shake for errors.
    private func shakeIt() {
        guard !Motion.reduceMotion else { return }
        let steps: [CGFloat] = [8, -8, 6, -6, 3, 0]
        for (i, v) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) { withAnimation(.easeInOut(duration: 0.05)) { shake = v } }
        }
    }
}

/// Big blue pill: press and hold to talk, release to send.
private struct HoldToTalkPill: View {
    let ctx: ChatContext
    @Binding var recording: Bool
    @State private var level: Float = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: recording ? "waveform" : "mic.fill").font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(recording ? "Listening…" : "Hold \(ctx.settings.data.pushToTalk.titled) to talk")
                .font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Palette.userText)
        .padding(.horizontal, 22).frame(height: 44)
        .background(Capsule().fill(Palette.talkPill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
        .shadow(color: Palette.userBubbleBottom.opacity(recording ? 0.7 : 0.35), radius: recording ? 12 + CGFloat(level) * 10 : 6)
        .scaleEffect(recording ? 1.03 : 1)
        .animation(Motion.snappy, value: recording)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !recording { recording = true; ctx.micStart() } }
            .onEnded { _ in
                recording = false
                Task {
                    if let t = await ctx.micStop(), !t.isEmpty { ctx.store.send(t) }   // release to send
                }
            })
        .task(id: recording) {
            guard recording else { level = 0; return }
            while !Task.isCancelled, recording {
                level = ctx.micLevel()
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        .accessibilityLabel("hold to talk; release to send")
    }
}

private struct MicButton: View {
    let ctx: ChatContext
    @Binding var recording: Bool
    @State private var level: Float = 0

    var body: some View {
        Image(systemName: recording ? "waveform" : "mic.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.userText)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Palette.talkPill))
            .overlay(Circle().stroke(Palette.userBubbleBottom.opacity(recording ? 0.8 : 0), lineWidth: 3).scaleEffect(1 + CGFloat(level) * 0.5))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !recording { recording = true; ctx.micStart() } }
                .onEnded { _ in
                    recording = false
                    Task {
                        if let t = await ctx.micStop(), !t.isEmpty {
                            ctx.store.draft += (ctx.store.draft.isEmpty ? "" : " ") + t
                        }
                    }
                })
            // Level polling runs only while recording (no idle timer).
            .task(id: recording) {
                guard recording else { level = 0; return }
                while !Task.isCancelled, recording {
                    level = ctx.micLevel()
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
            }
            .help("hold to talk")
            .accessibilityLabel("hold to dictate into the message")
    }
}

/// Press scale 0.97 + hover fade, per the motion spec.
struct PressableStyle: ButtonStyle {
    var plain = false
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .padding(.horizontal, plain ? 0 : 8).padding(.vertical, plain ? 0 : 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(plain ? 0 : (hover ? 0.1 : 0.06))))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

// MARK: Peek

/// Hover preview: a short messages list (suggestions, buddies, recent chats) and a one-line input.
private struct PeekView: View {
    let ctx: ChatContext
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(ctx.settings.data.pushToTalk.symbols).font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button { ctx.controller?.open(.compact, focus: true) } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(.borderless).accessibilityLabel("open chats")
                Button { ctx.openSettings() } label: { Image(systemName: "gearshape.fill") }
                    .buttonStyle(.borderless).accessibilityLabel("settings")
            }
            .padding(.horizontal, 22).padding(.top, 2)
            if !ctx.suggester.cards.isEmpty { SuggestionCards(ctx: ctx) }
            ScrollView {
                VStack(spacing: 0) {
                    if !ctx.suggester.cards.isEmpty {
                        ConversationRow(name: "Suggestions", time: "", preview: ctx.suggester.cards.first?.title ?? "",
                                        badge: ctx.suggester.cards.count, unread: true) { SuggestionsAvatar(size: 40) }
                        Divider().opacity(0.25).padding(.leading, 62)
                    }
                    ForEach(rows, id: \.id) { r in
                        r.view
                            .onTapGesture {
                                ctx.store.selectedId = r.conversationId
                                ctx.controller?.open(.compact, focus: true)
                            }
                        Divider().opacity(0.25).padding(.leading, 62)
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 2)
    }

    private struct PeekRow { let id: String; let conversationId: Int64?; let date: Date; let view: AnyView }

    /// Buddies + recent chats, newest first.
    private var rows: [PeekRow] {
        var out: [PeekRow] = []
        for b in ctx.buddies.active {
            let conv = ctx.store.conversation(forBuddy: b.id)
            let preview = conv.map(ctx.store.preview).flatMap { $0.isEmpty ? nil : $0 } ?? b.rolePrompt
            out.append(PeekRow(id: "b\(b.id ?? 0)", conversationId: conv?.id, date: conv?.updatedAt ?? b.createdAt, view: AnyView(
                ConversationRow(name: b.name, time: conv.map { ChatStore.shortTime($0.updatedAt) } ?? "", preview: preview,
                                unread: conv?.unread == true, thumbnail: ctx.buddies.newestFiles(b, limit: 1).first) {
                    BuddyAvatarView(preset: b.avatar, size: 40)
                })))
        }
        for c in ctx.store.conversations.filter({ $0.kind != "buddy" && !$0.archived }).prefix(4) {
            out.append(PeekRow(id: "c\(c.id ?? 0)", conversationId: c.id, date: c.updatedAt, view: AnyView(
                ConversationRow(name: c.title, time: ChatStore.shortTime(c.updatedAt), preview: ctx.store.preview(c), unread: c.unread) {
                    ConversationAvatar(ctx: ctx, conversation: c, size: 40)
                })))
        }
        return out.sorted { $0.date > $1.date }
    }
}

/// Proactive task cards (opt-in): approve runs it as an agent, adjust drops it into the chat box.
private struct SuggestionCards: View {
    let ctx: ChatContext
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ctx.suggester.cards) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Button("approve") { ctx.suggester.dismiss(c); ctx.runTask(c.task) }
                            Button("adjust") {
                                ctx.suggester.dismiss(c)
                                ctx.store.newChat(); ctx.store.draft = c.task
                                ctx.controller?.open(.compact, focus: true)
                            }
                            Button("dismiss") { withAnimation(Motion.snappy) { ctx.suggester.dismiss(c) } }
                        }
                        .font(.system(size: 10.5)).buttonStyle(.borderless)
                    }
                    .padding(8)
                    .frame(width: 190, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.replyBubble))
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 22)
        }
    }
}

/// A notes-wiki page.
private struct NoteView: View {
    let ctx: ChatContext
    let topic: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { withAnimation(Motion.snappy) { ctx.ui.viewingNote = nil } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).accessibilityLabel("back to chat")
                Text(topic).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("show in finder") { NSWorkspace.shared.activateFileViewerSelecting([ctx.wiki.url(for: topic)]) }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            ScrollView {
                MarkdownView(blocks: Markdown.parse(ctx.wiki.read(topic).replacingOccurrences(of: "[[", with: "**").replacingOccurrences(of: "]]", with: "**")))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26).padding(.bottom, 20)
            }
        }
    }
}
