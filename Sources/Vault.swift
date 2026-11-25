import SwiftUI

struct Note: Identifiable, Hashable {
    let url: URL
    let path: String
    var modified: Date = .distantPast

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

private actor VaultFiles {
    enum WriteError: LocalizedError {
        case conflict

        var errorDescription: String? {
            "This note changed on disk. Copy your draft, then reopen the note to load the latest version."
        }
    }

    static let attachmentTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "tif", "tiff",
                                               "pdf", "mp3", "wav", "m4a", "ogg", "flac", "mp4", "mov", "webm"]

    func index(_ root: URL) throws -> (notes: [Note], attachments: [String]) {
        let directory = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var notes: [Note] = []
        var attachments: [String] = []
        for case let url as URL in files {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || Self.attachmentTypes.contains(ext),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let location = url.resolvingSymlinksInPath().standardizedFileURL
            guard location.path.hasPrefix(prefix) else { continue }
            let relative = String(location.path.dropFirst(prefix.count))
            if ext == "md" {
                notes.append(Note(url: location, path: relative, modified: values.contentModificationDate ?? .distantPast))
            } else {
                attachments.append(relative)
            }
        }
        notes.sort { $0.modified > $1.modified }
        return (notes, attachments)
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ text: String, replacing original: String, at url: URL) throws {
        guard try read(url) == original else { throw WriteError.conflict }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func create(title: String, source: BrowserTab?, in root: URL) throws -> Note {
        let folder = root.appendingPathComponent("Reading Desk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let values = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
        let excluded = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
        let name = String(title.components(separatedBy: excluded).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let base = name.isEmpty || name.hasPrefix(".") ? "Untitled" : name
        let header = "# " + title.replacingOccurrences(of: "\n", with: " ") + "\n\n"
        // A `source` property ties the note to its page: highlights from that page land here,
        // and Reading Desk finds it again next time you open the page.
        let citation = source.flatMap { tab in
            tab.readableURL.map { url in
                let day = localDay()
                return "---\nsource: " + url.absoluteString + "\ncreated: " + day + "\ntags:\n  - reading-desk\n---\n"
            }
        } ?? ""
        for number in 1...1000 {
            let filename = base + (number == 1 ? "" : " \(number)") + ".md"
            let url = folder.appendingPathComponent(filename)
            do {
                try Data((citation + header).utf8).write(to: url, options: .withoutOverwriting)
                return Note(url: url, path: "Reading Desk/" + filename, modified: .now)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

@MainActor
final class Vault: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var notes: [Note] = []
    @Published private(set) var attachments: [String] = []
    @Published private(set) var selection: Note?
    @Published var text = ""
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published var showPicker = true
    @Published var preview = true

    private var savedText = ""
    private var autosave: Task<Void, Never>?
    private var saveTask: Task<Bool, Never>?
    private let files = VaultFiles()
    /// Which notes mention which pages, for highlights and "earlier notes on this page".
    let index = NoteIndex()

    var isDirty: Bool { selection != nil && savedText != text }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--vault"), arguments.indices.contains(flag + 1) {
            root = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        } else if let path = UserDefaults.standard.string(forKey: "vaultPath") {
            root = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    var suggested: URL? {
        let obsidian = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Dev", isDirectory: true)
        return FileManager.default.fileExists(atPath: obsidian.path) ? obsidian : nil
    }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root ?? suggested
        panel.prompt = "Use vault"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        await use(url)
    }

    func use(_ url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard await flush() else { return }
        do {
            let results = try await files.index(url)
            root = url
            notes = results.notes
            attachments = results.attachments
            selection = nil
            text = ""
            savedText = ""
            status = ""
            error = nil
            preview = false
            showPicker = true
            UserDefaults.standard.set(url.path, forKey: "vaultPath")
            Task { await index.rebuild(results.notes) }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard let root, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let results = try await files.index(root)
            notes = results.notes
            attachments = results.attachments
            if !isDirty { error = nil }
            Task { await index.rebuild(results.notes) }
        } catch { self.error = error.localizedDescription }
    }

    func open(_ note: Note) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard await flush() else { return }
        preview = true
        await read(note)
    }

    func reload() async {
        guard let selection, !busy else { return }
        autosave?.cancel()
        busy = true
        defer { busy = false }
        if let saveTask { _ = await saveTask.value }
        await read(selection)
    }

    private func read(_ note: Note) async {
        do {
            let content = try await files.read(note.url)
            text = content
            savedText = content
            selection = note
            status = "Saved"
            error = nil
            showPicker = false
        } catch { self.error = error.localizedDescription }
    }

    func create(_ title: String, source: BrowserTab?) async {
        guard let root, !busy else { return }
        busy = true
        defer { busy = false }
        guard await flush() else { return }
        do {
            let note = try await files.create(title: title, source: source, in: root)
            notes.insert(note, at: 0)
            if let source {
                index.add(note.path, isSource: true, for: source.address)
                if let key = SourceKey.key(for: source.address) { ReadingMemory.setNotePath(note.path, for: key) }
            }
            preview = false
            await read(note)
        } catch { self.error = error.localizedDescription }
    }

    func note(atPath path: String) -> Note? { notes.first { $0.path == path } }

    /// The note highlights from this page go into: the one you picked or created
    /// for it, else one whose `source` property points at it.
    func sourceNote(for tab: BrowserTab) -> Note? {
        guard let key = SourceKey.key(for: tab.address) else { return nil }
        if let path = ReadingMemory.notePath(for: key), let note = note(atPath: path) { return note }
        return index.refs(for: tab.address).first(where: \.isSource).flatMap { note(atPath: $0.path) }
    }

    /// Ties the open note to a page, so highlights from it land here.
    func linkSelection(to tab: BrowserTab) {
        guard let selection, let key = SourceKey.key(for: tab.address) else { return }
        ReadingMemory.setNotePath(selection.path, for: key)
        index.add(selection.path, isSource: true, for: tab.address)
    }

    func isSourceNote(_ note: Note, for tab: BrowserTab) -> Bool { sourceNote(for: tab) == note }

    /// Appends a quote to the page's note (creating the note if it has none) and
    /// leaves the note open in live preview, ready for the caret to land under it.
    func capture(_ block: String, from tab: BrowserTab) async -> Bool {
        guard root != nil else { return false }
        if notes.isEmpty { await refresh() }
        var note = sourceNote(for: tab)
        if note == nil {
            await create(String(tab.displayTitle.prefix(120)), source: tab)
            note = selection
        } else if let note, selection != note {
            await open(note)
        }
        guard let note, selection == note else { return false }
        var value = text
        while let last = value.last, last.isWhitespace { value.removeLast() }
        value += (value.isEmpty ? "" : "\n\n") + block + "\n\n"
        edit(value)
        if let key = SourceKey.key(for: tab.address) { ReadingMemory.setNotePath(note.path, for: key) }
        index.add(note.path, isSource: true, for: tab.address)
        preview = true
        showPicker = false
        return true
    }

    func edit(_ value: String) {
        text = value
        status = "Editing…"
        autosave?.cancel()
        autosave = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                _ = await self?.flush()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    @discardableResult
    func flush() async -> Bool {
        while let saveTask {
            if await saveTask.value == false { return false }
        }
        guard let note = selection, isDirty else {
            if selection != nil { status = "Saved" }
            return true
        }
        let value = text
        let baseline = savedText
        status = "Saving…"
        let task = Task {
            defer { saveTask = nil }
            do {
                try await files.write(value, replacing: baseline, at: note.url)
                savedText = value
                status = isDirty ? "Editing…" : "Saved"
                error = nil
                return true
            } catch {
                self.error = error.localizedDescription
                status = "Unsaved"
                return false
            }
        }
        saveTask = task
        return await task.value
    }

    func contents(of note: Note) async -> String? {
        if note == selection { return text }
        return try? await files.read(note.url)
    }

    /// Flips the checkbox on one line of the open note (from a click in reading view).
    func toggleTask(atLine line: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line),
              let range = lines[line].range(of: #"^([ \t]*[-*+][ \t]+|[ \t]*\d+[.)][ \t]+)\[(.)\]"#, options: .regularExpression) else { return }
        let marker = lines[line][range]
        let checked = marker.hasSuffix("[ ]") == false
        let replaced = marker.dropLast(3) + (checked ? "[ ]" : "[x]")
        lines[line].replaceSubrange(range, with: replaced)
        edit(lines.joined(separator: "\n"))
    }

    func resolve(_ link: String) -> Note? {
        let target = String(link.split(separator: "#", maxSplits: 1).first ?? "")
        let candidate = target.hasSuffix(".md") ? target : target + ".md"
        return notes.first { $0.path.caseInsensitiveCompare(candidate) == .orderedSame }
            ?? notes.first { $0.url.lastPathComponent.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    func openInObsidian() {
        guard let url = selection?.url ?? root else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let location = components.url { NSWorkspace.shared.open(location) }
    }
}
