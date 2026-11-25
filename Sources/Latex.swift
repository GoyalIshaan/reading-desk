import CryptoKit
import Foundation

/// Compiles math KaTeX can't handle, and ```tikz blocks, with the Mac's own TeX
/// installation: latex → DVI → dvisvgm → SVG. Results are cached by source.
enum Latex {
    enum Mode: String { case inline, display, tikz }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let searchPaths = ["/Library/TeX/texbin", "/usr/local/texlive/2026/bin/universal-darwin",
                                      "/usr/local/texlive/2025/bin/universal-darwin", "/opt/homebrew/bin", "/usr/local/bin"]

    static var available: Bool { tool("latex") != nil && tool("dvisvgm") != nil }

    private static func tool(_ name: String) -> URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static let cache: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.readingdesk.mac/latex", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Deduplicates concurrent compilations of the same equation so identical blocks
    /// don't compile twice or race on the same temp directory.
    private actor Flight {
        private var tasks: [String: Task<Result<String, Failure>, Never>] = [:]

        func run(_ key: String, work: @escaping @Sendable () -> Result<String, Failure>) async -> Result<String, Failure> {
            if let existing = tasks[key] { return await existing.value }
            let task = Task.detached(priority: .userInitiated, operation: work)
            tasks[key] = task
            let result = await task.value
            tasks[key] = nil
            return result
        }
    }

    private static let flight = Flight()

    static func render(_ source: String, mode: Mode) async -> Result<String, Failure> {
        let key = SHA256.hash(data: Data(("v2" + mode.rawValue + "\u{0}" + source).utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cache.appendingPathComponent(key + ".svg")
        if let svg = try? String(contentsOf: cached, encoding: .utf8) { return .success(svg) }
        guard let latex = tool("latex"), let dvisvgm = tool("dvisvgm") else {
            return .failure(Failure(message: "No TeX installation found."))
        }
        return await flight.run(key) {
            if let svg = try? String(contentsOf: cached, encoding: .utf8) { return .success(svg) }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("readingdesk-tex-" + UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try Data(document(source, mode: mode).utf8).write(to: work.appendingPathComponent("doc.tex"))
            } catch {
                return .failure(Failure(message: error.localizedDescription))
            }
            let compiled = run(latex, ["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "doc.tex"], in: work, timeout: 40)
            guard compiled.status == 0 else {
                let lines = compiled.output.split(separator: "\n").filter { $0.hasPrefix("!") || $0.hasPrefix("l.") }
                return .failure(Failure(message: lines.prefix(3).joined(separator: "\n").nonEmpty ?? "LaTeX failed."))
            }
            let converted = run(dvisvgm, ["--no-fonts", "--exact-bbox", "--zoom=1.25", "--optimize", "-o", "doc.svg", "doc.dvi"], in: work, timeout: 30)
            guard converted.status == 0, var svg = try? String(contentsOf: work.appendingPathComponent("doc.svg"), encoding: .utf8) else {
                return .failure(Failure(message: "dvisvgm couldn’t convert the output."))
            }
            if let start = svg.range(of: "<svg") { svg = String(svg[start.lowerBound...]) }
            try? svg.write(to: cached, atomically: true, encoding: .utf8)
            return .success(svg)
        }
    }

    /// TikZ's default backend writes PostScript, which dvisvgm can't turn into SVG
    /// without Ghostscript. This driver makes PGF emit SVG directly.
    private static let driver = "\\def\\pgfsysdriver{pgfsys-dvisvgm.def}\n"

    private static func document(_ source: String, mode: Mode) -> String {
        driver + body(source, mode: mode)
    }

    private static func body(_ source: String, mode: Mode) -> String {
        let preamble = """
        \\documentclass[preview,border=1pt]{standalone}
        \\usepackage{amsmath,amssymb,amsfonts,mathtools,bm}
        \\usepackage{tikz,tikz-cd}
        \\usetikzlibrary{arrows.meta,positioning,calc,shapes,decorations.pathreplacing,patterns}
        \\usepackage{pgfplots}
        \\pgfplotsset{compat=newest}

        """
        switch mode {
        case .inline:
            return preamble + "\\begin{document}$\(source)$\\end{document}\n"
        case .display:
            let environment = source.range(of: #"\\begin\{(align|gather|multline|equation|flalign|alignat|eqnarray)\*?\}"#, options: .regularExpression) != nil
            return preamble + "\\begin{document}\n" + (environment ? source : "\\[\n\(source)\n\\]") + "\n\\end{document}\n"
        case .tikz:
            if source.contains("\\documentclass") { return source }
            if source.contains("\\begin{document}") { return "\\documentclass[tikz,border=4pt]{standalone}\n" + source }
            let body = source.contains("\\begin{tikz") ? source : "\\begin{tikzpicture}\n\(source)\n\\end{tikzpicture}"
            return preamble + "\\begin{document}\n\(body)\n\\end{document}\n"
        }
    }

    private static func run(_ tool: URL, _ arguments: [String], in directory: URL, timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":") + ":/usr/bin:/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
