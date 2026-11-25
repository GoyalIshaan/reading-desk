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
/// Nothing here reaches the network; it's all local files the user owns.
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
        let categories = library.categories.map { category -> [String: Any] in
            ["id": category.id, "name": category.name, "isDefault": category.isOther,
             "sites": category.domains, "keywords": category.keywords]
        }
        let tabs = library.tabs.map { tab -> [String: Any] in
            let category = library.category(for: tab)
            let manual = library.assignments[tab.address] != nil
            let bySite = library.siteRules[tab.site] != nil
            return [
                "id": tab.id, "title": tab.displayTitle, "url": tab.address, "site": tab.site,
                "category": category.id, "categoryName": category.name,
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
            guard let name = command["name"] as? String else { return record(op, "error", "missing name") }
            let category = library.ensureCategory(named: name, symbol: command["icon"] as? String)
            record(op, "ok", "\(category.name) [\(category.id)]")
        case "refresh":
            library.refresh()
            record(op, "ok")
        default:
            record(op.isEmpty ? "?" : op, "error", "unknown op")
        }
    }
}
