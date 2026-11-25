import AppKit

/// Something on the pasteboard that belongs in the vault as a file rather than as text.
enum PastedAttachment {
    /// A file copied in Finder.
    case file(URL)
    /// Image bytes: a screenshot, or "Copy Image" in a browser.
    case data(Data, ext: String)

    /// Nil means this is an ordinary paste.
    static func read(from pasteboard: NSPasteboard) -> [PastedAttachment]? {
        // Files first: Finder also puts the file's name and icon on the pasteboard.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.allSatisfy { Attachments.types.contains($0.pathExtension.lowercased()) } ? urls.map { .file($0) } : nil
        }
        // Apps that copy rich text often add a picture of it. Real words win; a bare
        // address next to an image is what browsers add for "Copy Image".
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, text.range(of: #"^(https?|data):\S+$"#, options: .regularExpression) == nil { return nil }
        if let png = pasteboard.data(forType: .png) { return [.data(png, ext: "png")] }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return [.data(jpeg, ext: "jpg")] }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { return [.data(png, ext: "png")] }
        return nil
    }
}

/// Saves pasted files where Obsidian would, following the vault's `.obsidian/app.json`.
enum Attachments {
    static let types: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "tif", "tiff",
                                     "pdf", "mp3", "wav", "m4a", "ogg", "flac", "mp4", "mov", "webm"]

    enum SaveError: LocalizedError {
        case outsideVault(String)

        var errorDescription: String? {
            switch self {
            case .outsideVault(let folder): "Obsidian’s attachment folder “\(folder)” is outside this vault, so nothing was saved."
            }
        }
    }

    /// The "Files and links" settings. Obsidian leaves out any you haven't changed.
    private struct Settings: Decodable {
        var attachmentFolderPath: String?
        var useMarkdownLinks: Bool?
        var newLinkFormat: String?

        init(root: URL) {
            let file = root.appendingPathComponent(".obsidian/app.json")
            if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Settings.self, from: data) { self = decoded }
        }

        /// Vault-relative. Unset or "/" is the vault root, "./" is beside the note,
        /// "./name" is a folder beside the note, anything else is a folder in the vault.
        func folder(for notePath: String) -> String {
            let setting = attachmentFolderPath ?? "/"
            let beside = (notePath as NSString).deletingLastPathComponent
            if setting == "." || setting.hasPrefix("./") {
                return [beside, String(setting.dropFirst(2))].flatMap(components).joined(separator: "/")
            }
            return components(setting).joined(separator: "/")
        }

        private func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
    }

    /// Writes the attachment (or finds it, if it's already in the vault) and returns its
    /// vault-relative path with the Markdown that embeds it from `notePath`.
    static func save(_ item: PastedAttachment, root: URL, notePath: String, existing: [String], now: Date = .now) throws -> (path: String, link: String) {
        let settings = Settings(root: root)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        func relative(_ url: URL) -> String? {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        if case .file(let url) = item, let path = relative(url) {
            return (path, link(to: path, from: notePath, existing: existing, settings: settings))
        }

        let folder = settings.folder(for: notePath)
        guard !folder.split(separator: "/").contains("..") else { throw SaveError.outsideVault(folder) }
        let directory = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
        // Check the nearest folder that exists before creating any: a symlink could lead out.
        var ancestor = directory
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.pathComponents.count > 1 { ancestor.deleteLastPathComponent() }
        let anchor = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        guard anchor == base || anchor.hasPrefix(prefix) else { throw SaveError.outsideVault(folder) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data: Data, stem: String, ext: String
        switch item {
        case .data(let bytes, let kind):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMddHHmmss"
            (data, stem, ext) = (bytes, "Pasted image " + formatter.string(from: now), kind)
        case .file(let url):
            (data, stem, ext) = (try Data(contentsOf: url), url.deletingPathExtension().lastPathComponent, url.pathExtension)
        }
        for number in 0..<1000 {
            let name = stem + (number == 0 ? "" : " \(number)") + "." + ext
            do {
                try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
            let path = folder.isEmpty ? name : folder + "/" + name
            return (path, link(to: path, from: notePath, existing: existing, settings: settings))
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func link(to path: String, from notePath: String, existing: [String], settings: Settings) -> String {
        let name = (path as NSString).lastPathComponent
        let target: String
        switch settings.newLinkFormat {
        case "absolute":
            target = path
        case "relative":
            var from = notePath.split(separator: "/").dropLast().map(String.init)
            var to = path.split(separator: "/").map(String.init)
            while !from.isEmpty, to.count > 1, from[0] == to[0] { from.removeFirst(); to.removeFirst() }
            target = (Array(repeating: "..", count: from.count) + to).joined(separator: "/")
        default:
            // "Shortest": the bare name, unless another file shares it.
            let taken = existing.contains { $0 != path && ($0 as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
            target = taken ? path : name
        }
        guard settings.useMarkdownLinks == true else { return "![[\(target)]]" }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))
        return "![](\(target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target))"
    }
}
