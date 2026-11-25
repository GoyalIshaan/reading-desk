import SwiftUI

struct NotesPane: View {
    @ObservedObject var vault: Vault
    @ObservedObject var renderer: NoteRenderer
    @ObservedObject var index: NoteIndex
    let source: BrowserTab
    @State private var query = ""
    @State private var noteTitle = ""
    @State private var creating = false
    @State private var confirmingReload = false
    @FocusState private var titleFocused: Bool

    /// Notes you've already written that point at this page, its own note first.
    private var related: [Note] {
        index.refs(for: source.address).compactMap { vault.note(atPath: $0.path) }
    }

    private var matches: [Note] {
        let search = query.trimmed
        return search.isEmpty ? vault.notes : vault.notes.filter { $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let error = vault.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(Theme.sans(12)).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                    if vault.isDirty {
                        HStack(spacing: 14) {
                            TextAction(title: "Copy draft") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vault.text, forType: .string)
                            }
                            TextAction(title: "Reload from disk…") { requestReload() }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Hairline()
            }
            if vault.root == nil {
                connect
            } else if vault.showPicker || vault.selection == nil {
                picker
            } else if let note = vault.selection {
                earlierNotes(besides: note)
                ZStack(alignment: .bottomTrailing) {
                    if vault.preview {
                        NoteWebView(renderer: renderer)
                            .onAppear { renderer.show(note, text: vault.text) }
                            .onChange(of: vault.text) { _, text in renderer.show(note, text: text) }
                            .onChange(of: note) { _, next in renderer.show(next, text: vault.text) }
                    } else {
                        MarkdownEditor(text: vault.text) { vault.edit($0) }
                            .id(note.id)
                    }
                    if vault.isDirty || vault.status != "Saved" {
                        Text(vault.status).font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .accessibilityIdentifier("save-status")
                    }
                }
            }
        }
        .background(Theme.notes)
        .background {
            ShortcutButton("Toggle source mode", "e") { if vault.selection != nil { vault.preview.toggle() } }
            ShortcutButton("Save", "s") { Task { await vault.flush() } }
        }
        .task {
            renderer.vault = vault
            await vault.refresh()
        }
        .sheet(isPresented: $creating) { newNoteSheet }
        .confirmationDialog("Reload this note from disk?", isPresented: $confirmingReload) {
            Button("Discard draft and reload", role: .destructive) { Task { await vault.reload() } }
        } message: {
            Text("Your unsaved changes will be discarded.")
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            if vault.root != nil {
                DeskIcon(vault.showPicker ? "doc.text" : "sidebar.left", help: vault.showPicker ? "Back to note" : "All notes") {
                    if vault.selection != nil || !vault.showPicker { vault.showPicker.toggle() }
                }
                .disabled(vault.showPicker && vault.selection == nil)
            }
            breadcrumb.padding(.leading, 4)
            Spacer(minLength: 6)
            if vault.root != nil {
                if vault.selection != nil && !vault.showPicker {
                    DeskIcon(vault.preview ? "chevron.left.forwardslash.chevron.right" : "text.book.closed",
                             help: vault.preview ? "Source mode (⌘E)" : "Live preview (⌘E)") {
                        vault.preview.toggle()
                    }
                }
                DeskIcon("square.and.pencil", help: "New note for this page") {
                    noteTitle = String(source.displayTitle.prefix(120))
                    creating = true
                }
                .disabled(vault.busy)
                Menu {
                    Button("Refresh notes") { Task { await vault.refresh() } }
                    Button("Choose another vault…") { Task { await vault.chooseFolder() } }
                    Button("Open in Obsidian") { vault.openInObsidian() }
                    if let note = vault.selection, !vault.showPicker, !vault.isSourceNote(note, for: source) {
                        Button("Save this page’s highlights here") { vault.linkSelection(to: source) }
                    }
                    if vault.selection != nil { Button("Reload note from disk…") { requestReload() } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.ink3).frame(width: 26, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Note actions")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    @ViewBuilder private var breadcrumb: some View {
        if let root = vault.root {
            HStack(spacing: 5) {
                Text(root.lastPathComponent).foregroundStyle(Theme.ink3)
                if let note = vault.selection, !vault.showPicker {
                    let parts = note.path.split(separator: "/").map(String.init)
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        Text("/").foregroundStyle(Theme.ink4)
                        Text(index == parts.count - 1 ? part.replacingOccurrences(of: ".md", with: "") : part)
                            .foregroundStyle(index == parts.count - 1 ? Theme.ink : Theme.ink3)
                    }
                }
            }
            .font(Theme.sans(12, .medium))
            .lineLimit(1)
            .truncationMode(.head)
        } else {
            Text("Obsidian").font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink3)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your notes, beside the page.").font(Theme.serif(30)).foregroundStyle(Theme.ink)
            Text("Connect an Obsidian vault to read and write Markdown here. Callouts, links, embeds and math render the way Obsidian renders them.")
                .font(Theme.sans(13)).lineSpacing(3).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let suggested = vault.suggested {
                    Button("Use “\(suggested.lastPathComponent)” vault") { Task { await vault.use(suggested) } }
                        .buttonStyle(DeskButtonStyle(.primary)).disabled(vault.busy)
                }
                Button("Choose folder…") { Task { await vault.chooseFolder() } }
                    .buttonStyle(DeskButtonStyle(.outline)).disabled(vault.busy)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                noteTitle = String(source.displayTitle.prefix(120))
                creating = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New note for this page").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.accent)
                    Text(source.displayTitle).font(Theme.serif(18)).foregroundStyle(Theme.ink).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.rule))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.top, 14)

            if query.isEmpty, !related.isEmpty {
                Text("ON THIS PAGE").font(Theme.mono(10, .medium)).foregroundStyle(Theme.ink4)
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 2)
                ForEach(related) { note in
                    NoteRow(note: note, selected: vault.selection == note) { Task { await vault.open(note) } }
                }
                Hairline().padding(.top, 6)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                TextField("Find a note", text: $query).textFieldStyle(.plain).font(Theme.sans(13))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .overlay(Capsule().strokeBorder(Theme.rule))
            .padding(14)

            if vault.busy && vault.notes.isEmpty {
                ProgressView().controlSize(.small).padding(16)
                Spacer()
            } else if matches.isEmpty {
                Text(query.isEmpty ? "This vault has no notes yet." : "No matching notes.")
                    .font(Theme.serif(17, italic: true)).foregroundStyle(Theme.ink3).padding(16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { note in NoteRow(note: note, selected: vault.selection == note) { Task { await vault.open(note) } } }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var newNoteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New note").font(Theme.serif(28))
            TextField("Title", text: $noteTitle)
                .focused($titleFocused)
                .textFieldStyle(.plain)
                .font(Theme.sans(14))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule))
            Text("Saved to Reading Desk/ in your vault, with a link back to this page.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.ink3)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }.buttonStyle(DeskButtonStyle(.outline)).keyboardShortcut(.cancelAction)
                Button("Create") {
                    creating = false
                    let title = noteTitle.trimmed
                    Task { await vault.create(title, source: source) }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(noteTitle.trimmed.isEmpty)
            }
        }
        .padding(26).frame(width: 420)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .onAppear { titleFocused = true }
    }

    /// A slim reminder above an unrelated note: you've written about this page before.
    @ViewBuilder private func earlierNotes(besides note: Note) -> some View {
        let others = related.filter { $0 != note }
        if !others.isEmpty, !related.contains(note) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                Text(others.count == 1 ? "You have a note on this page:" : "\(others.count) earlier notes on this page:")
                    .font(Theme.sans(12)).foregroundStyle(Theme.ink3)
                if others.count == 1, let only = others.first {
                    TextAction(title: only.name) { Task { await vault.open(only) } }.lineLimit(1)
                } else {
                    Menu {
                        ForEach(others) { other in Button(other.name) { Task { await vault.open(other) } } }
                    } label: {
                        Text("Open…").font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink2)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 32)
            .background(Theme.surface)
            Hairline()
        }
    }

    private func requestReload() {
        if vault.isDirty { confirmingReload = true }
        else { Task { await vault.reload() } }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    private var folder: String? {
        guard let slash = note.path.lastIndex(of: "/") else { return nil }
        return String(note.path[..<slash])
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.name).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let folder { Text(folder).font(Theme.mono(10)).foregroundStyle(Theme.ink4).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if note.modified > .distantPast {
                    Text(note.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(selected || hovered ? Theme.surface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
