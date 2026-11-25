import SwiftUI

struct NotesPane: View {
    @ObservedObject var vault: Vault
    let source: BrowserTab
    @State private var query = ""
    @State private var noteTitle = ""
    @State private var creating = false
    @State private var confirmingReload = false
    @FocusState private var titleFocused: Bool

    private var matches: [Note] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? vault.notes : vault.notes.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if vault.root != nil {
                    DeskIcon("list.bullet", help: "Browse notes") { vault.showPicker.toggle() }
                }
                Text(vault.root?.lastPathComponent ?? "Obsidian")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, vault.root == nil ? 6 : 0)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if vault.root != nil {
                    DeskIcon("plus", help: "New note") {
                        noteTitle = String(source.displayTitle.prefix(120))
                        creating = true
                    }
                    .disabled(vault.busy)
                    Menu {
                        Button("Refresh notes") { Task { await vault.refresh() } }
                        Button("Choose another vault…") { Task { await vault.chooseFolder() } }
                        Button("Open in Obsidian") { vault.openInObsidian() }
                        if vault.selection != nil {
                            Button("Reload note from disk…") { requestReload() }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Note actions")
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .frame(height: 40)
            SurfaceRule()
            if let error = vault.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                    if vault.isDirty {
                        HStack {
                            Button("Copy draft") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vault.text, forType: .string)
                            }.buttonStyle(DeskButtonStyle())
                            Button("Reload…") { requestReload() }.buttonStyle(DeskButtonStyle())
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                SurfaceRule()
            }
            if vault.root == nil {
                connect
            } else if vault.showPicker || vault.selection == nil {
                picker
            } else if let note = vault.selection {
                editor(note)
            }
        }
        .background(Theme.paper)
        .task { await vault.refresh() }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New note").font(Theme.display(25))
                TextField("Note title", text: $noteTitle).focused($titleFocused).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        creating = false
                        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await vault.create(title, source: source) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24).frame(width: 380)
            .onAppear { titleFocused = true }
        }
        .confirmationDialog("Reload this note from disk?", isPresented: $confirmingReload) {
            Button("Discard draft and reload", role: .destructive) { Task { await vault.reload() } }
        } message: {
            Text("Your unsaved changes will be discarded.")
        }
    }

    private func requestReload() {
        if vault.isDirty { confirmingReload = true }
        else { Task { await vault.reload() } }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "folder").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
            Text("Connect a vault").font(Theme.display(27))
            Text("Open your Obsidian folder to read and edit Markdown beside the page.")
                .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let suggested = vault.suggested {
                Button("Use Dev vault") { Task { await vault.use(suggested) } }
                    .buttonStyle(DeskButtonStyle(prominent: true)).disabled(vault.busy)
            }
            Button("Choose folder…") { Task { await vault.chooseFolder() } }
                .buttonStyle(DeskButtonStyle()).disabled(vault.busy)
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Find a note", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
            .padding(12)
            if vault.busy && vault.notes.isEmpty {
                ProgressView().controlSize(.small).padding(12)
                Spacer()
            } else if matches.isEmpty {
                Text(query.isEmpty ? "This vault has no Markdown notes." : "No matching notes.")
                    .foregroundStyle(Theme.muted).padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { note in
                            Button {
                                Task { await vault.open(note) }
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(note.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        if note.path.contains("/") {
                                            Text(note.path).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(vault.busy)
                            .background(vault.selection == note ? Theme.panel : .clear)
                            SurfaceRule().padding(.leading, 13)
                        }
                    }
                }
            }
        }
    }

    private func editor(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name).font(Theme.display(19)).lineLimit(1)
                    Text(note.path).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(vault.preview ? "Edit" : "Preview") { vault.preview.toggle() }
                    .buttonStyle(DeskButtonStyle())
            }
            .padding(12)
            SurfaceRule()
            if vault.preview {
                MarkdownPreview(text: vault.text, vault: vault)
            } else {
                TextEditor(text: Binding(get: { vault.text }, set: { vault.edit($0) }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .foregroundStyle(Theme.ink)
                    .disabled(vault.busy)
                    .accessibilityLabel("Markdown editor")
            }
            SurfaceRule()
            HStack {
                Text(vault.status).font(.caption).foregroundStyle(vault.error == nil ? Theme.muted : Theme.error)
                    .accessibilityIdentifier("save-status")
                Spacer()
                Button("Save") { Task { await vault.flush() } }
                    .buttonStyle(DeskButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!vault.isDirty || vault.busy)
            }
            .padding(.horizontal, 12).frame(height: 40)
        }
    }
}

private struct MarkdownPreview: View {
    let text: String
    let vault: Vault
    private static let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "desk-note" {
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
                if let note = vault.resolve(target) { Task { await vault.open(note) } }
                return .handled
            }
            if ["http", "https", "mailto", "obsidian"].contains(url.scheme ?? "") { return .systemAction }
            return .discarded
        })
    }

    private struct Line {
        let content: String
        let inCode: Bool
    }

    private var lines: [Line] {
        var inCode = false
        var visible: [Line] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            else { visible.append(Line(content: line, inCode: inCode)) }
        }
        return visible
    }

    @ViewBuilder private func lineView(_ line: Line) -> some View {
        let value = line.content
        if line.inCode {
            Text(verbatim: value.isEmpty ? " " : value)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.panel)
        } else if value.isEmpty {
            Color.clear.frame(height: 9)
        } else {
            let level = value.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), value.dropFirst(level).first == " " {
                Text(inline(String(value.dropFirst(level + 1))))
                    .font(Theme.display(level == 1 ? 24 : level == 2 ? 19 : 16))
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            } else if value == "---" {
                SurfaceRule().padding(.vertical, 7)
            } else {
                let formatted = value.hasPrefix("- [ ] ") ? "☐ " + value.dropFirst(6) :
                    value.hasPrefix("- [x] ") ? "☑ " + value.dropFirst(6) :
                    value.hasPrefix("- ") ? "•  " + value.dropFirst(2) : value
                Text(inline(String(formatted))).font(.system(size: 13))
                    .lineSpacing(3).padding(.vertical, 2).textSelection(.enabled)
            }
        }
    }

    private func inline(_ value: String) -> AttributedString {
        var processed = value
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in Self.wiki.matches(in: value, range: range).reversed() {
            guard let token = Range(match.range, in: processed), let targetRange = Range(match.range(at: 1), in: processed) else { continue }
            let target = String(processed[targetRange])
            let alias = Range(match.range(at: 2), in: processed).map { String(processed[$0]) } ?? target
            var components = URLComponents()
            components.scheme = "desk-note"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "name", value: target)]
            if let url = components.url {
                let safeAlias = alias.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                processed.replaceSubrange(token, with: "[\(safeAlias)](<\(url.absoluteString)>)")
            }
        }
        return (try? AttributedString(markdown: processed, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
}
