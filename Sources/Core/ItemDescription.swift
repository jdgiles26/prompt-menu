import AppKit
import PDFKit
import SQLite3
import Vision

// Turns anything chosen in Finder into text a small model can explain. Text is sent as it is; a folder,
// database or binary file has no useful text of its own, so it's described: layout, tables, or type
// and readable fragments. What it is comes from its contents, never its name, because a .db may not
// be a database and a file with no extension may be anything.
//
// Everything here only reads, and is bounded in time and size: it runs while Finder waits. Results
// go to the local model and nowhere else.

private let folderTimeLimit: TimeInterval = 2
private let databaseTimeLimit: TimeInterval = 3
private let toolTimeLimit: TimeInterval = 3
private let maxFolderEntries = 20_000
private let maxListedPerFolder = 30
// Enough of a binary to find what it says about itself, even when the text limit is small.
private let minimumSniffBytes = 64 * 1024

// Walked past, because what's in them is generated and would bury everything else.
private let foldersNotWalked: Set<String> = [
    ".git", ".hg", ".svn", "node_modules", "bower_components", ".build", "build", "dist", "target", "DerivedData", "Pods",
    "__pycache__", ".venv", "venv", ".tox", ".cache", ".next", ".gradle", ".idea",
]
private let ignoredNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]
// The files that say what a folder is, best first. Matched without case.
private let tellingFiles = [
    "readme", "readme.md", "readme.txt", "readme.rst", "claude.md", "agents.md", "package.json", "package.swift", "pyproject.toml",
    "cargo.toml", "go.mod", "pom.xml", "build.gradle", "gemfile", "requirements.txt", "makefile", "dockerfile", "docker-compose.yml",
    "compose.yaml", "info.plist", "index.html",
]
// Never read as part of a folder: the user chose the folder, not these. A database's matching columns are hidden the same way.
private let secretNamePattern = "(?i)(^\\.env|secret|credential|passw|token|cookie|api.?key|private.?key|session|\\.pem$|\\.key$|\\.p12$|\\.pfx$|id_rsa|id_ed25519|\\.netrc|\\.npmrc|\\.pgpass|keychain)"

private func isSecretName(_ name: String) -> Bool { name.range(of: secretNamePattern, options: .regularExpression) != nil }

private func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String { "\(count) \(count == 1 ? noun : plural ?? noun + "s")" }

private func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

private func dateText(_ time: time_t) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
}

// One item, in at most `limit` characters. Throws only when it can't be looked at, or has nothing in it.
func describeItem(_ path: String, limit: Int) throws -> String {
    let name = (path as NSString).lastPathComponent
    var info = stat()
    guard stat(path, &info) == 0 else {
        throw errno == EPERM || errno == EACCES ? RewriteError.protectedFile(name) : RewriteError.unreadableFile(name)
    }
    switch info.st_mode & S_IFMT {
    case S_IFDIR: return try describeFolder(path, limit: limit, deadline: Date(timeIntervalSinceNow: folderTimeLimit))
    case S_IFREG: return try describeFile(path, name: name, info: info, limit: limit)
    default: return String("File: \(name)\n\nThis is a \(specialKind(info.st_mode)), a connection the system uses rather than a file with contents, so nothing was read from it.".prefix(limit))
    }
}

private func specialKind(_ mode: mode_t) -> String {
    switch mode & S_IFMT {
    case S_IFIFO: return "named pipe"
    case S_IFSOCK: return "socket"
    case S_IFCHR, S_IFBLK: return "device"
    default: return "special file"
    }
}

// MARK: Files

private func describeFile(_ path: String, name: String, info: stat, limit: Int) throws -> String {
    // Enough for the cut below, without reading a huge file whole: a character is at most 4 bytes.
    let readLimit = max(limit * 4, minimumSniffBytes)
    // open() rather than FileHandle(forReadingAtPath:), whose nil can't tell "macOS refused" from "gone".
    // Non-blocking, so a file that turns into a pipe between the stat and here can't hang the app.
    let descriptor = open(path, O_RDONLY | O_NONBLOCK)
    guard descriptor >= 0 else {
        throw errno == EPERM || errno == EACCES ? RewriteError.protectedFile(name) : RewriteError.unreadableFile(name)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    // read(upToCount:) throws on an I/O error (a drive pulled mid-read); readData raises an
    // Objective-C exception that Swift can't catch.
    guard let head = try? handle.read(upToCount: readLimit) ?? Data() else { throw RewriteError.unreadableFile(name) }
    guard !head.isEmpty else { throw RewriteError.emptyFile(name) }

    func finished(_ body: String) -> String { String("File: \(name)\n\n\(body)".prefix(limit)) }

    if head.starts(with: Array("SQLite format 3\0".utf8)), let database = describeDatabase(path, name: name, size: Int64(info.st_size), limit: limit) { return database }
    if let plist = decodedPropertyList(path, head: head, size: Int64(info.st_size)) { return finished(plist) }
    if let document = documentText(path, head: head, size: Int64(info.st_size), limit: limit) { return finished(document) }
    if let text = readableText(head, wasCut: head.count == readLimit) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw RewriteError.emptyFile(name) }
        return finished(body)
    }
    if let image = imageDescription(path, info: info) { return finished(image) }
    return finished(fileProfile(path, handle: handle, head: head, info: info, limit: limit))
}

// An image's size and the text in it, recognized on this Mac by Vision (no network). The text model
// can't see pictures, so this is what it gets: enough for a screenshot of an error or a scanned page.
private func imageDescription(_ path: String, info: stat) -> String? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), CGImageSourceGetCount(source) > 0,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let type = toolOutput("/usr/bin/file", ["--brief", path], maxBytes: 1000)?.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = ["This is an image. Only its text could be read; what it otherwise shows can't be seen."]
    lines.append("Type: \(type?.isEmpty == false ? type! : "image")")
    lines.append("Size: \(image.width) × \(image.height) pixels, \(sizeText(Int64(info.st_size)))")
    lines.append("Modified: \(dateText(info.st_mtimespec.tv_sec))")
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    lines.append(text.isEmpty ? "No text was found in it." : "\nText in it, top to bottom:\n" + text.joined(separator: "\n"))
    return lines.joined(separator: "\n")
}

// Text in any encoding worth trying, or nil if this isn't text.
private func readableText(_ data: Data, wasCut: Bool) -> String? {
    if let text = decodedText(data, wasCut: wasCut), !text.contains("\u{0}") { return text }
    // Old single-byte encodings have no marker. Text in one has no NULs, almost no control characters,
    // and mostly plain letters; compressed or compiled data fails at least one of these.
    let controls = data.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D].contains($0) }.count
    let high = data.filter { $0 >= 0x80 }.count
    guard !data.contains(0), controls * 100 <= data.count, high * 100 < data.count * 30 else { return nil }
    return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
}

// UTF-8, or UTF-16 with its byte order mark. A read that stopped early may have ended inside a
// character; only then are its last bytes dropped.
private func decodedText(_ data: Data, wasCut: Bool) -> String? {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        return String(data: wasCut ? data.prefix(data.count & ~1) : data, encoding: .utf16)
    }
    var contents = String(data: data, encoding: .utf8)
    for drop in 1...3 where contents == nil && wasCut { contents = String(data: data.dropLast(drop), encoding: .utf8) }
    return contents
}

private func decodedPropertyList(_ path: String, head: Data, size: Int64) -> String? {
    guard head.starts(with: Array("bplist".utf8)), size <= 8 * 1024 * 1024,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
          let text = String(data: xml, encoding: .utf8) else { return nil }
    // Without the XML declaration and doctype, which only use up the limit.
    let body = text.components(separatedBy: "\n").filter { !$0.hasPrefix("<?xml") && !$0.hasPrefix("<!DOCTYPE") }
    return "This is a binary property list (settings data). Decoded:\n\n" + body.joined(separator: "\n")
}

// PDFs and word processor files, whose text is what the reader wants. Chosen by contents or a fixed
// list of types, so a file can't reach the HTML importer, which could load remote resources.
private func documentText(_ path: String, head: Data, size: Int64, limit: Int) -> String? {
    let url = URL(fileURLWithPath: path)
    if head.starts(with: Array("%PDF-".utf8)), let pdf = PDFDocument(url: url), !pdf.isLocked {
        var text = ""
        for index in 0..<pdf.pageCount where text.count < limit {
            text += (pdf.page(at: index)?.string ?? "") + "\n"
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    let types: [String: NSAttributedString.DocumentType] = ["rtf": .rtf, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument]
    guard let type = types[url.pathExtension.lowercased()], size <= 32 * 1024 * 1024,
          let document = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else { return nil }
    let text = document.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

// What can be said about a file that isn't text: its type, details, and for an archive, what's inside.
private func fileProfile(_ path: String, handle: FileHandle, head: Data, info: stat, limit: Int) -> String {
    var lines = ["This file isn't text, so this is what could be found out about it, not its contents."]
    let type = toolOutput("/usr/bin/file", ["--brief", path], maxBytes: 1000)?.trimmingCharacters(in: .whitespacesAndNewlines)
    lines.append("Type: \(type?.isEmpty == false ? type! : "unknown")")
    lines.append("Size: \(sizeText(Int64(info.st_size)))")
    lines.append("Modified: \(dateText(info.st_mtimespec.tv_sec))")
    lines.append("First bytes: " + head.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
    if isArchive(head), let listing = toolOutput("/usr/bin/tar", ["-tf", path], maxBytes: limit * 2), !listing.isEmpty {
        lines.append("\nFiles inside:\n\(listing.trimmingCharacters(in: .whitespacesAndNewlines))")
        return lines.joined(separator: "\n")
    }
    // The end of a file often names what made it, so look there as well as at the start.
    var sample = head
    if Int64(info.st_size) > Int64(head.count) {
        let tailStart = max(Int64(head.count), Int64(info.st_size) - Int64(minimumSniffBytes))
        if (try? handle.seek(toOffset: UInt64(tailStart))) != nil, let tail = try? handle.read(upToCount: minimumSniffBytes) { sample += [0] + tail }
    }
    let fragments = readableFragments(sample)
    if !fragments.isEmpty { lines.append("\nReadable fragments:\n" + fragments.joined(separator: "\n")) }
    return lines.joined(separator: "\n")
}

private func isArchive(_ head: Data) -> Bool {
    let signatures: [[UInt8]] = [[0x50, 0x4B, 0x03, 0x04], [0x1F, 0x8B], [0x42, 0x5A, 0x68], [0xFD, 0x37, 0x7A, 0x58, 0x5A], [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]]
    return signatures.contains { head.starts(with: $0) } || (head.count > 262 && head[257..<262].elementsEqual("ustar".utf8))
}

// Runs of plain characters, like strings(1), in file order with repeats removed.
private func readableFragments(_ data: Data) -> [String] {
    var fragments: [String] = []
    var seen = Set<String>()
    var run: [UInt8] = []
    func flush() {
        if run.count >= 6, let text = String(bytes: run.prefix(200), encoding: .ascii), seen.insert(text).inserted { fragments.append(text) }
        run.removeAll(keepingCapacity: true)
    }
    for byte in data where fragments.count < 400 {
        if byte >= 0x20 && byte < 0x7F { run.append(byte) } else { flush() }
    }
    flush()
    return fragments
}

// A system tool's output, stopped at `maxBytes` or the time limit, whichever is first. The path is one
// argument and no shell is involved. Nil if it couldn't run or failed before printing anything.
private func toolOutput(_ tool: String, _ arguments: [String], maxBytes: Int) -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let timer = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + toolTimeLimit, execute: timer)
    var data = Data()
    while data.count < maxBytes, let chunk = try? output.fileHandleForReading.read(upToCount: maxBytes - data.count), !chunk.isEmpty {
        data += chunk
    }
    timer.cancel()
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
}

// MARK: Folders

private struct FolderEntry {
    let name: String
    let path: String
    let relative: String
    let depth: Int
    let isFolder: Bool
    let isLink: Bool
    let size: Int64
    let modified: time_t
    let isOnlineOnly: Bool
    var isWalked = true
    var isBlocked = false
    var children: [Int] = []
}

// `deadline` passes the time limit in, so a test can run out of time on purpose.
func describeFolder(_ path: String, limit: Int, deadline: Date) throws -> String {
    let name = (path as NSString).lastPathComponent
    let top: [String]
    do {
        top = try FileManager.default.contentsOfDirectory(atPath: path)
    } catch let error as NSError {
        let refused = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
        throw refused ? RewriteError.protectedFile(name) : RewriteError.unreadableFile(name)
    }

    // Breadth first, so running out of time still leaves the top of the folder, which says the most.
    var entries: [FolderEntry] = []
    var roots: [Int] = []
    var stoppedEarly = false
    func add(_ names: [String], to parent: Int?, under folder: String, relative: String, depth: Int) {
        for child in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !ignoredNames.contains(child) {
            // Inside the loop too: one folder can hold more than the rest of the walk, or be on a slow disk.
            if entries.count >= maxFolderEntries || (Date() >= deadline && !entries.isEmpty) {
                stoppedEarly = true
                return
            }
            let childPath = (folder as NSString).appendingPathComponent(child)
            var info = stat()
            guard lstat(childPath, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            // SF_DATALESS: an online-only file. Reading it would make macOS download it.
            let entry = FolderEntry(name: child, path: childPath, relative: relative.isEmpty ? child : relative + "/" + child, depth: depth,
                                    isFolder: kind == S_IFDIR, isLink: kind == S_IFLNK, size: Int64(info.st_size),
                                    modified: info.st_mtimespec.tv_sec, isOnlineOnly: info.st_flags & 0x4000_0000 != 0)
            entries.append(entry)
            if let parent { entries[parent].children.append(entries.count - 1) } else { roots.append(entries.count - 1) }
        }
    }
    add(top, to: nil, under: path, relative: "", depth: 0)
    guard !entries.isEmpty else { throw RewriteError.emptyFile(name) }

    var next = 0
    while next < entries.count, !stoppedEarly {
        if Date() >= deadline {
            stoppedEarly = entries[next...].contains { $0.isFolder }
            break
        }
        let entry = entries[next]
        if entry.isFolder {
            if foldersNotWalked.contains(entry.name) {
                entries[next].isWalked = false
            } else if let names = try? FileManager.default.contentsOfDirectory(atPath: entry.path) {
                add(names, to: next, under: entry.path, relative: entry.relative, depth: entry.depth + 1)
            } else {
                entries[next].isBlocked = true
            }
        }
        next += 1
    }

    var parts = ["Folder: \(name)", "", folderSummary(entries, stoppedEarly: stoppedEarly)]
    let summary = parts.joined(separator: "\n").count
    let samples = sampledFiles(entries, limit: (limit - summary) * 4 / 10)
    let layout = folderLayout(entries, roots: roots, limit: limit - summary - samples.count - 12)
    parts += ["", "Layout:", layout]
    if !samples.isEmpty { parts += ["", samples] }
    return String(parts.joined(separator: "\n").prefix(limit))
}

private func folderSummary(_ entries: [FolderEntry], stoppedEarly: Bool) -> String {
    let files = entries.filter { !$0.isFolder && !$0.isLink }
    let total = files.reduce(Int64(0)) { $0 + $1.size }
    var counts: [String: Int] = [:]
    for file in files {
        let type = (file.name as NSString).pathExtension.lowercased()
        counts[type.isEmpty ? "no extension" : "." + type, default: 0] += 1
    }
    let common = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    var lines = ["Contains \(counted(files.count, "file")) and \(counted(entries.filter(\.isFolder).count, "folder")), \(sizeText(total)) in all."]
    if !common.isEmpty { lines.append("Most common types: \(common).") }
    let largest = files.sorted { $0.size > $1.size }.prefix(3).map { "\($0.relative) (\(sizeText($0.size)))" }
    if !largest.isEmpty { lines.append("Largest: \(largest.joined(separator: ", ")).") }
    let recent = files.sorted { $0.modified > $1.modified }.prefix(3).map { "\($0.relative) (\(dateText($0.modified)))" }
    if !recent.isEmpty { lines.append("Most recently changed: \(recent.joined(separator: ", ")).") }
    if stoppedEarly { lines.append("Stopped early: this folder is too big to look through, so these numbers cover only part of it.") }
    return lines.joined(separator: "\n")
}

// As deep as fits: a shallow layout of everything beats a deep layout of the first subfolder.
private func folderLayout(_ entries: [FolderEntry], roots: [Int], limit: Int) -> String {
    func lines(_ indexes: [Int], indent: String, levels: Int) -> [String] {
        var result: [String] = []
        for index in indexes.prefix(maxListedPerFolder) {
            let entry = entries[index]
            if entry.isLink {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) ?? "?"
                result.append("\(indent)\(entry.name) -> \((target as NSString).lastPathComponent)")
            } else if entry.isFolder {
                let note = !entry.isWalked ? " (contents not listed)" : entry.isBlocked ? " (macOS blocked this folder)" : ""
                result.append("\(indent)\(entry.name)/\(note)")
                if levels > 1 { result += lines(entry.children, indent: indent + "  ", levels: levels - 1) }
                else if !entry.children.isEmpty { result.append("\(indent)  … \(entry.children.count) items") }
            } else {
                result.append("\(indent)\(entry.name)")
            }
        }
        if indexes.count > maxListedPerFolder { result.append("\(indent)… and \(indexes.count - maxListedPerFolder) more") }
        return result
    }
    for levels in stride(from: 5, to: 1, by: -1) {
        let text = lines(roots, indent: "", levels: levels).joined(separator: "\n")
        if text.count <= limit { return text }
    }
    let text = lines(roots, indent: "", levels: 1).joined(separator: "\n")
    return text.count <= limit ? text : String(text.prefix(max(0, limit - 10))) + "\n… and more"
}

// The start of the files most likely to say what the folder is, or if none are there, the newest near the top.
private func sampledFiles(_ entries: [FolderEntry], limit: Int) -> String {
    func rank(_ entry: FolderEntry) -> Int { tellingFiles.firstIndex(of: entry.name.lowercased()) ?? tellingFiles.count }
    let candidates = entries.filter { !$0.isFolder && !$0.isLink && !$0.isOnlineOnly && $0.depth <= 1 && $0.size > 0 && $0.size <= 1024 * 1024 && !isSecretName($0.name) }
        .sorted { (rank($0), $0.depth, $1.modified) < (rank($1), $1.depth, $0.modified) }
    var samples: [String] = []
    var used = 0
    let wanted = 4
    for entry in candidates.prefix(16) where samples.count < wanted {
        let share = (limit - used) / (wanted - samples.count)
        guard share > 80, let handle = FileHandle(forReadingAtPath: entry.path),
              let data = try? handle.read(upToCount: share * 4), !data.isEmpty else { continue }
        let text: String?
        if data.starts(with: Array("bplist".utf8)) { text = decodedPropertyList(entry.path, head: data, size: entry.size) }
        else { text = readableText(data, wasCut: data.count == share * 4) }
        // A private key can have any name, so look at what it is too.
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty, !body.contains("PRIVATE KEY-----") else { continue }
        let sample = String("File: \(entry.relative)\n\n\(body)".prefix(share))
        samples.append(sample)
        used += sample.count + 2
    }
    return samples.joined(separator: "\n\n")
}

// MARK: Databases

private final class QueryClock { var deadline = Date() }

// Tables, columns, row counts and a few rows, or nil if this isn't a working SQLite database.
private func describeDatabase(_ path: String, name: String, size: Int64, limit: Int) -> String? {
    // immutable=1: no locks, and no -wal, -shm or journal files appear beside the user's database. Changes
    // still in another app's write-ahead log aren't seen, which doesn't matter for explaining the structure.
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "?#%")
    guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2("file:\(encoded)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }

    // A query that runs too long is stopped, so a damaged or huge database can't hold up Finder.
    let clock = QueryClock()
    let finalDeadline = Date(timeIntervalSinceNow: databaseTimeLimit)
    sqlite3_progress_handler(db, 2000, { context in
        Unmanaged<QueryClock>.fromOpaque(context!).takeUnretainedValue().deadline < Date() ? 1 : 0
    }, Unmanaged.passUnretained(clock).toOpaque())
    func allow(_ seconds: TimeInterval) { clock.deadline = min(finalDeadline, Date(timeIntervalSinceNow: seconds)) }
    // So the file's own schema can't call functions on our behalf while it's being read.
    sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)

    func rows(_ sql: String, maxRows: Int = 1000) -> [[String?]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while result.count < maxRows {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return result.isEmpty ? nil : result }
            result.append((0..<sqlite3_column_count(statement)).map { databaseValue(statement, $0) })
        }
        return result
    }
    func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    allow(1)
    guard let schema = rows("SELECT type, name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", maxRows: 5000) else { return nil }
    func names(_ type: String) -> [String] { schema.filter { $0[0] == type }.compactMap { $0[1] } }
    let tableNames = names("table")

    struct Table { let name: String; let count: Int? }
    let tables: [Table] = tableNames.map { table in
        allow(0.3)
        return Table(name: table, count: rows("SELECT COUNT(*) FROM \(quoted(table))")?.first?[0].flatMap { Int($0) })
    }.sorted { ($0.count ?? -1, $1.name) > ($1.count ?? -1, $0.name) }

    var text = "Database: \(name)\n\nA SQLite database, \(sizeText(size)), with \(counted(tables.count, "table"))"
    let views = names("view"), triggers = names("trigger"), indexes = names("index")
    text += ", \(counted(views.count, "view")), \(counted(indexes.count, "index", plural: "indexes")) and \(counted(triggers.count, "trigger")). Biggest tables first; rows are a sample."
    if tables.isEmpty && views.isEmpty { text += "\nIt has no tables yet." }
    for (position, table) in tables.enumerated() {
        allow(0.3)
        let columns = rows("PRAGMA table_info(\(quoted(table.name)))")?.compactMap { row -> (name: String, type: String)? in
            guard row.count > 2, let column = row[1] else { return nil }
            return (column, row[2] ?? "")
        } ?? []
        let rowText = table.count.map { counted($0, "row") } ?? "rows not counted"
        var block = "\n\nTable \(table.name) (\(rowText))"
        block += "\nColumns: " + columns.map { $0.type.isEmpty ? $0.name : "\($0.name) \($0.type)" }.joined(separator: ", ")
        let sample = rows("SELECT * FROM \(quoted(table.name)) LIMIT 3", maxRows: 3) ?? []
        for row in sample {
            let values = zip(columns, row).map { column, value -> String in
                "\(column.name)=\(isSecretName(column.name) ? "(hidden)" : value ?? "NULL")"
            }
            block += "\n- " + values.joined(separator: ", ")
        }
        // Room is kept for the views and triggers line, and for saying what's left out.
        guard text.count + block.count <= limit - 200 else {
            text += "\n\n… and \(counted(tables.count - position, "more table", plural: "more tables")): " + tables[position...].map(\.name).joined(separator: ", ")
            break
        }
        text += block
    }
    if !views.isEmpty { text += "\n\nViews: " + views.joined(separator: ", ") }
    if !triggers.isEmpty { text += "\nTriggers: " + triggers.joined(separator: ", ") }
    return String(text.prefix(limit))
}

private func databaseValue(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    switch sqlite3_column_type(statement, column) {
    case SQLITE_NULL: return nil
    case SQLITE_BLOB: return "\(sqlite3_column_bytes(statement, column))-byte blob"
    default:
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(String(cString: text).prefix(80))
    }
}
