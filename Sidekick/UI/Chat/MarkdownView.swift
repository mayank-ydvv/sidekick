import AppKit
import SwiftUI

/// Renders parsed markdown blocks. Inline styling (bold, italic, code, links) uses AttributedString.
struct MarkdownView: View {
    let blocks: [MDBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                BlockView(block: b)
            }
        }
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MDBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 19 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let t):
            Text(inline(t)).font(.system(size: 13.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(item)).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + i).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(item)).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(inline(t)).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
        case .code(let lang, let code, _):
            CodeBlockView(language: lang, code: code)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }
}

func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation(Motion.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(Motion.snappy) { copied = false } }
                } label: {
                    Label(copied ? "copied" : "copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("copy code")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(Motion.fade, value: code.count / 80)   // height grows smoothly as code streams in
    }

    private var highlighted: AttributedString {
        let ns = NSMutableAttributedString(string: code, attributes: [.foregroundColor: NSColor(white: 0.9, alpha: 1)])
        for (r, kind) in SyntaxHighlighter.spans(code, language: language) {
            let c: NSColor
            switch kind {
            case .keyword: c = NSColor(red: 0.98, green: 0.47, blue: 0.67, alpha: 1)
            case .string: c = NSColor(red: 0.66, green: 0.86, blue: 0.5, alpha: 1)
            case .comment: c = NSColor(white: 0.55, alpha: 1)
            case .number: c = NSColor(red: 0.95, green: 0.72, blue: 0.4, alpha: 1)
            }
            ns.addAttribute(.foregroundColor, value: c, range: r)
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(code)
    }
}

private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, h in Text(inline(h)).fontWeight(.semibold) } }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in Text(inline(c)) } }
                }
            }
            .font(.system(size: 12.5))
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}
