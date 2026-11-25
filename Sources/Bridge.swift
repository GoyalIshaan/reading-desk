import Combine
import Foundation

/// A small local bridge so an external agent (a script, Codex, Claude) can read
/// the open tabs and reorganize them into shelves.
///
/// The app is always the single writer of its own data. The bridge just:
///  • exports a JSON snapshot of tabs + shelves + each tab's current shelf to
///    `~/Library/Application Support/dev.readingdesk.mac/state.json`
///  • watches `…/commands/` for little JSON instruction files, applies them to
///    the live app, deletes them, and records the result back into the snapshot.
///
/// Nothing in `DeskBridge` reaches the network; it's all local files the user owns.
/// (`ShelfAgent` below does: it sends tab titles and URLs to Claude.)
@MainActor
final class DeskBridge {
    private unowned let library: Library
    private let directory: URL
    private let stateURL: URL
    private let commandsDir: URL
    private var cancellable: AnyCancellable?
    private var timer: Timer?
    private var writeScheduled = false
    private var log: [[String: Any]] = []

    init(library: Library) {
        self.library = library
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.readingdesk.mac", isDirectory: true)
        stateURL = directory.appendingPathComponent("state.json")
        commandsDir = directory.appendingPathComponent("commands", isDirectory: true)
        try? FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
    }

    func start() {
        // Re-export whenever the app's data changes (debounced).
        cancellable = library.objectWillChange.sink { [weak self] in self?.scheduleWrite() }
        processCommands()
        writeState()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processCommands() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Snapshot

    /// Write state.json right away, skipping the debounce. Call before running the sorter.
    func flush() { writeState() }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            writeScheduled = false
            writeState()
        }
    }

    private func writeState() {
        // Parents come before their children.
        let categories = library.tree.flattened().map { row -> [String: Any] in
            let category = row.category
            return ["id": category.id, "name": category.name, "isDefault": category.isOther,
                    "parent": category.parentID ?? NSNull(), "path": library.pathName(of: category.id),
                    "autoSort": library.autoSortShelves.contains(category.id),
                    "sites": category.domains, "keywords": category.keywords]
        }
        let tabs = library.tabs.map { tab -> [String: Any] in
            let category = library.category(for: tab)
            let manual = library.assignments[tab.address] != nil
            let bySite = library.siteRules[tab.site] != nil
            return [
                "id": tab.id, "title": tab.displayTitle, "url": tab.address, "site": tab.site,
                "category": category.id, "categoryName": category.name,
                "categoryPath": library.pathName(of: category.id),
                "assignedBy": manual ? "tab" : bySite ? "site" : "auto",
                "active": tab.active,
            ]
        }
        let state: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: .now),
            "appRunning": true,
            "source": library.sample ? "sample" : "helium",
            "tabCount": library.tabs.count,
            "commandsDir": commandsDir.path,
            "categories": categories,
            "tabs": tabs,
            "log": Array(log.suffix(25)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Atomic write so a reader never sees a half-written file.
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Commands

    private func processCommands() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: commandsDir, includingPropertiesForKeys: nil)
            else { return }
        let pending = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !pending.isEmpty else { return }
        for file in pending {
            if let data = try? Data(contentsOf: file) {
                let decoded = try? JSONSerialization.jsonObject(with: data)
                let commands = (decoded as? [[String: Any]]) ?? (decoded as? [String: Any]).map { [$0] } ?? []
                for command in commands { apply(command) }
            }
            try? FileManager.default.removeItem(at: file)
        }
        if library.loaded { writeState() }
    }

    private func record(_ op: String, _ status: String, _ detail: String? = nil) {
        var entry: [String: Any] = ["at": ISO8601DateFormatter().string(from: .now), "op": op, "status": status]
        if let detail { entry["detail"] = detail }
        log.append(entry)
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    private func apply(_ command: [String: Any]) {
        let op = (command["op"] as? String)?.lowercased() ?? ""
        func categoryID(_ key: String = "category") -> String? {
            guard let token = command[key] as? String else { return nil }
            return library.category(matching: token)?.id
        }
        switch op {
        case "assign":
            guard let url = command["url"] as? String else { return record(op, "error", "missing url") }
            guard let id = categoryID() else { return record(op, "error", "unknown category") }
            library.assign(address: url, to: id)
            record(op, "ok", "\(url) → \(id)")
        case "assignsite":
            guard let site = command["site"] as? String else { return record(op, "error", "missing site") }
            guard let id = categoryID() else { return record(op, "error", "unknown category") }
            library.fileSite(site, to: id)
            record(op, "ok", "\(site) → \(id)")
        case "auto":
            guard let url = command["url"] as? String else { return record(op, "error", "missing url") }
            library.assign(address: url, to: nil)
            record(op, "ok", url)
        case "ensurecategory":
            guard let raw = command["name"] as? String, !raw.trimmed.isEmpty else { return record(op, "error", "missing name") }
            // A name like "A › B" means "B inside A".
            let (pathParent, name) = Library.splitCreatePath(raw)
            let explicitParent = (command["parent"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0 }
            if pathParent != nil, explicitParent != nil {
                return record(op, "error", "give either a path as the name or a parent, not both")
            }
            var parentID: String?
            if let token = pathParent ?? explicitParent {
                guard let parent = library.category(matching: token) else { return record(op, "error", "unknown parent \(token)") }
                guard !parent.isOther else { return record(op, "error", "\(parent.name) can't hold other shelves") }
                parentID = parent.id
            }
            let category = library.ensureCategory(named: name, symbol: command["icon"] as? String, parentID: parentID)
            record(op, "ok", "\(library.pathName(of: category.id)) [\(category.id)]")
        case "refresh":
            library.refresh()
            record(op, "ok")
        default:
            record(op.isEmpty ? "?" : op, "error", "unknown op")
        }
    }
}

/// Runs `reading-desk organize` (bundled with the app) to have Claude file a shelf's
/// tabs into sub-shelves. The script applies its changes through the bridge.
enum ShelfAgent {
    struct Outcome {
        let succeeded: Bool
        /// Last line the script printed; shown as a toast.
        let message: String
        /// The script only prints "Filed …" when it actually moved something.
        var filedAny: Bool { succeeded && message.hasPrefix("Filed ") }
    }

    /// `urls` limits the run to those tabs; `maxNew` caps new sub-shelves (nil = script default).
    static func organize(shelfID: String, maxNew: Int? = nil, urls: [String] = []) async -> Outcome {
        guard let script = Bundle.main.url(forResource: "reading-desk", withExtension: nil) else {
            return Outcome(succeeded: false, message: "The sorting script is missing. Rebuild Reading Desk.")
        }
        return await Task.detached(priority: .userInitiated) { () -> Outcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "organize", "--shelf", shelfID]
                + (maxNew.map { ["--max-new", String($0)] } ?? [])
                + urls.flatMap { ["--url", $0] }
            // Apps launched from Finder get a bare PATH, so add where `claude` usually lives.
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                                   environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            process.environment = environment
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch {
                return Outcome(succeeded: false, message: "Couldn’t start the sorter: \(error.localizedDescription)")
            }
            // The script itself gives up after 5 min.
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 330, execute: timeout)
            defer { timeout.cancel() }
            let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            func lastLine(_ text: String) -> String? {
                text.split(whereSeparator: \.isNewline).last.map(String.init)
            }
            if process.terminationStatus == 0 { return Outcome(succeeded: true, message: lastLine(out) ?? "Sorting finished.") }
            if process.terminationReason == .uncaughtSignal {
                return Outcome(succeeded: false, message: "Sorting took too long and was stopped.")
            }
            return Outcome(succeeded: false, message: lastLine(err) ?? "Sorting failed.")
        }.value
    }
}
