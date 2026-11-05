import Cocoa
import SQLite3

// Request (2026-11-05): Explain This for Me must run on "folders, non file extension saved files,
// .db files and any file and any folder". Each test names the part of that request it covers.

private func write(_ text: String, _ name: String, in dir: String) throws -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func makeDatabase(_ path: String, _ sql: String) {
    var db: OpaquePointer?
    check(sqlite3_open(path, &db) == SQLITE_OK, "test database should open")
    check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "test database should build")
    sqlite3_close(db)
}

// "folders": the layout, what's in it, and the files that say what it is.
func testExplainFolder() throws {
    let root = try makeTempFolder()
    let dir = (root as NSString).appendingPathComponent("my-project")
    _ = try write("# Billing service\nCharges customers monthly.", "README.md", in: dir)
    _ = try write("func charge() {}", "src/main.swift", in: dir)
    _ = try write("ref: refs/heads/main", ".git/HEAD", in: dir)
    _ = try write("module.exports = 'vendored-code'", "node_modules/left/index.js", in: dir)
    _ = try write("API_KEY=super-secret-value", ".env", in: dir)
    let text = try explainInput(files: [dir])
    check(text.hasPrefix("Folder: my-project\n"), "starts by naming the folder: \(text.prefix(60))")
    check(text.contains("Billing service"), "the README says what the folder is")
    check(text.contains("main.swift"), "the layout lists nested files")
    check(text.contains("node_modules"), "generated folders are named")
    check(!text.contains("index.js"), "but not walked")
    check(!text.contains("HEAD"), ".git isn't walked")
    check(text.contains(".env"), "a secret file's name is listed")
    check(!text.contains("super-secret-value"), "its contents are never read from a folder")

    // Found on a real ~/.ssh: a private key can have any name, so the name check isn't enough.
    let keys = (root as NSString).appendingPathComponent("keys")
    _ = try write("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----", "github_work", in: keys)
    _ = try write("Host example\n  User me", "config", in: keys)
    let listed = try explainInput(files: [keys])
    check(listed.contains("github_work"), "a key's name is listed")
    check(!listed.contains("b3BlbnNzaC1rZXk"), "its contents never go to the model from a folder")
    check(listed.contains("Host example"), "other files are still sampled")
}

func testExplainFolderEdges() throws {
    let root = try makeTempFolder()
    let empty = (root as NSString).appendingPathComponent("empty")
    try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
    checkThrows(.emptyFile("empty")) { _ = try explainInput(files: [empty]) }

    let locked = (root as NSString).appendingPathComponent("locked")
    _ = try write("x", "a.txt", in: locked)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
    checkThrows(.protectedFile("locked")) { _ = try explainInput(files: [locked]) }

    // A link back to its own parent must not loop, and isn't followed.
    let loop = (root as NSString).appendingPathComponent("loop")
    _ = try write("hello", "a.txt", in: loop)
    try FileManager.default.createSymbolicLink(atPath: (loop as NSString).appendingPathComponent("back"), withDestinationPath: loop)
    let looped = try explainInput(files: [loop])
    check(looped.contains("back ->"), "a link is shown as a link: \(looped)")
    checkEqual(looped.components(separatedBy: "a.txt").count > 1, true)

    // A huge folder stays inside the model's limit and says it's partial.
    let big = (root as NSString).appendingPathComponent("big")
    try FileManager.default.createDirectory(atPath: big, withIntermediateDirectories: true)
    for i in 0..<1500 { FileManager.default.createFile(atPath: (big as NSString).appendingPathComponent("file-\(i).log"), contents: Data("x".utf8)) }
    let large = try explainInput(files: [big])
    check(large.count <= maxInputCharacters, "kept to the limit, got \(large.count)")
    check(large.contains("1500 files"), "the summary still counts everything")
    check(large.contains("more"), "and says some weren't listed")

    // A walk that runs out of time stops and says so, rather than holding up Finder.
    let quick = try describeFolder(big, limit: 2000, deadline: Date(timeIntervalSinceNow: -1))
    check(quick.contains("Stopped early"), "a timed-out walk says it's partial: \(quick.prefix(200))")
}

// "non file extension saved files": judged by what's inside, not by the name.
func testExplainFileWithoutExtension() throws {
    let dir = try makeTempFolder()
    let makefile = try write("all:\n\tswiftc main.swift", "Makefile", in: dir)
    checkEqual(try explainInput(files: [makefile]), "File: Makefile\n\nall:\n\tswiftc main.swift")
    // Saved in an old encoding: still text.
    let legacy = (dir as NSString).appendingPathComponent("notes")
    try Data("caf".utf8 + [0xE9] + Data(" au lait".utf8)).write(to: URL(fileURLWithPath: legacy))
    checkEqual(try explainInput(files: [legacy]), "File: notes\n\ncafé au lait")
}

// ".db files": tables, columns, counts and samples, and the database is left untouched.
func testExplainDatabase() throws {
    let dir = try makeTempFolder()
    let path = (dir as NSString).appendingPathComponent("shop.db")
    makeDatabase(path, """
    CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, password TEXT);
    INSERT INTO users VALUES (1, 'Ann', 'hunter2'), (2, 'Bob', 'letmein');
    CREATE TABLE "odd ""table" (photo BLOB);
    INSERT INTO "odd ""table" VALUES (x'00FF');
    CREATE VIEW names AS SELECT name FROM users;
    """)
    let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    let text = try explainInput(files: [path])
    check(text.hasPrefix("Database: shop.db\n"), "names the database: \(text.prefix(60))")
    check(text.contains("users") && text.contains("2 rows"), "tables with row counts: \(text)")
    check(text.contains("name TEXT"), "columns with types")
    check(text.contains("Ann"), "sample rows")
    check(!text.contains("hunter2"), "values of secret-looking columns stay out")
    check(text.contains("odd \"table"), "awkward table names work")
    check(text.contains("2-byte blob"), "blobs are described, not dumped")
    check(text.contains("names"), "views are listed")
    checkEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, before)
    let left = try FileManager.default.contentsOfDirectory(atPath: dir)
    checkEqual(left, ["shop.db"])

    check(text.contains("(1 row)") && !text.contains("1 rows"), "one row reads as one row: \(text)")
    check(text.contains("2 tables, 1 view,"), "and so do the totals: \(text)")

    // A SQLite file with no extension is found by its header.
    let bare = (dir as NSString).appendingPathComponent("History")
    try FileManager.default.copyItem(atPath: path, toPath: bare)
    check(try explainInput(files: [bare]).hasPrefix("Database: History\n"), "found by header, not by name")

    // A .db that isn't SQLite still gets an answer.
    let fake = (dir as NSString).appendingPathComponent("Thumbs.db")
    try Data([0xD0, 0xCF, 0x11, 0xE0, 0x00, 0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: fake))
    check(try explainInput(files: [fake]).contains("Size:"), "falls back to the file's details")
    // SQLite's header followed by rubbish doesn't throw either.
    let broken = (dir as NSString).appendingPathComponent("broken.db")
    try (Data("SQLite format 3".utf8) + [0] + Data(repeating: 0xAB, count: 2000)).write(to: URL(fileURLWithPath: broken))
    check(try explainInput(files: [broken]).contains("Size:"), "a damaged database falls back too")
}

// "any file": never a refusal for being the wrong kind of file.
func testExplainAnyFile() throws {
    let dir = try makeTempFolder()
    let binary = (dir as NSString).appendingPathComponent("tool.bin")
    try (Data([0x00, 0x01, 0x02]) + Data("license-server.example\0".utf8) + Data(repeating: 0, count: 64)).write(to: URL(fileURLWithPath: binary))
    let profile = try explainInput(files: [binary])
    check(profile.hasPrefix("File: tool.bin\n"), "names the file")
    check(profile.contains("Size:") && profile.contains("Type:"), "gives its details: \(profile)")
    check(profile.contains("license-server.example"), "and its readable fragments")

    let plist = (dir as NSString).appendingPathComponent("Settings")
    let data = try PropertyListSerialization.data(fromPropertyList: ["ThemeName": "Dark"], format: .binary, options: 0)
    try data.write(to: URL(fileURLWithPath: plist))
    let decoded = try explainInput(files: [plist])
    check(decoded.contains("ThemeName") && decoded.contains("Dark"), "binary plists are decoded: \(decoded)")

    let pdf = (dir as NSString).appendingPathComponent("report.pdf")
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.string = "Quarterly revenue grew"
    try view.dataWithPDF(inside: view.bounds).write(to: URL(fileURLWithPath: pdf))
    check(try explainInput(files: [pdf]).contains("Quarterly revenue"), "PDF text is extracted")

    let rtf = (dir as NSString).appendingPathComponent("letter.rtf")
    let styled = NSAttributedString(string: "Dear tenant")
    try styled.rtf(from: NSRange(location: 0, length: styled.length))!.write(to: URL(fileURLWithPath: rtf))
    checkEqual(try explainInput(files: [rtf]), "File: letter.rtf\n\nDear tenant")

    // An archive lists what's inside, without unpacking anything.
    let source = (dir as NSString).appendingPathComponent("payload")
    _ = try write("x", "inner-file.txt", in: source)
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-czf", (dir as NSString).appendingPathComponent("bundle.tgz"), "-C", dir, "payload"]
    try tar.run()
    tar.waitUntilExit()
    let listing = try explainInput(files: [(dir as NSString).appendingPathComponent("bundle.tgz")])
    check(listing.contains("inner-file.txt"), "archive contents are listed: \(listing)")

    // A named pipe must not hang the app, and isn't read.
    let pipe = (dir as NSString).appendingPathComponent("pipe")
    checkEqual(mkfifo(pipe, 0o644), 0)
    check(try explainInput(files: [pipe]).contains("named pipe"), "says what it is")
}

// "any file and any folder": a mixed selection shares the limit, and one bad item doesn't sink the rest.
func testExplainMixedSelection() throws {
    let dir = try makeTempFolder()
    let big = try write(String(repeating: "x", count: maxInputCharacters * 2), "big.txt", in: dir)
    let also = try write(String(repeating: "y", count: maxInputCharacters * 2), "also.txt", in: dir)
    let both = try explainInput(files: [big, also])
    check(both.contains("File: big.txt") && both.contains("File: also.txt"), "the second item isn't crowded out")
    check(both.count <= maxInputCharacters, "and the limit holds, got \(both.count)")

    let gone = (dir as NSString).appendingPathComponent("gone.txt")
    let partial = try explainInput(files: [big, gone])
    check(partial.contains("File: big.txt") && partial.contains("gone.txt"), "a missing item is mentioned, the rest still explained")
    checkThrows(.unreadableFile("gone.txt")) { _ = try explainInput(files: [gone, gone]) }

    // Choosing lots of items still gives a usable answer, and names what didn't fit.
    let many = try (0..<40).map { try write("note \($0)", "n\($0).txt", in: dir) }
    let crowd = try explainInput(files: many)
    check(crowd.contains("note 0") && crowd.contains("n39.txt"), "items past the limit are at least named")
    check(crowd.count <= maxInputCharacters, "limit holds")
}
