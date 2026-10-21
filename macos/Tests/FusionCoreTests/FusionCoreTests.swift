import Darwin
import Foundation
import Testing
@testable import FusionCore

// MARK: - Outils

/// Dossier temporaire supprimé à la fin du test (verrous retirés d'abord).
final class TempDir {
    let path: String
    init() {
        path = NSTemporaryDirectory() + "fOLDERFUSE-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit {
        if let items = FileManager.default.enumerator(atPath: path) {
            for case let rel as String in items { lchflags(path + "/" + rel, 0) }
        }
        try? FileManager.default.removeItem(atPath: path)
    }
    func write(_ rel: String, _ data: Data) {
        let full = path + "/" + rel
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: full))
    }
    func write(_ rel: String, _ text: String) { write(rel, Data(text.utf8)) }
    func read(_ rel: String) -> Data? { FileManager.default.contents(atPath: path + "/" + rel) }
    func mkdir(_ rel: String) {
        try! FileManager.default.createDirectory(atPath: path + "/" + rel, withIntermediateDirectories: true)
    }
    func all() -> [String] {
        (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? []).sorted()
    }
}

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func withLang<T>(_ code: String, _ body: () throws -> T) rethrows -> T {
    let old = I18n.lang
    I18n.setLang(code)
    defer { I18n.setLang(old) }
    return try body()
}

// MARK: - Traductions

@Suite(.serialized) struct I18nTests {
    @Test func formats() {
        withLang("fr") {
            #expect(fmtInt(1_234_567) == "1\u{00a0}234\u{00a0}567")
            #expect(fmtSize(483_100_000_000) == "483,1 Go")
            #expect(fmtSize(1) == "1 octet")
            #expect(P(0, "{n} fichier", "{n} fichiers") == "0 fichier")
        }
        withLang("en") {
            #expect(fmtInt(621_723) == "621,723")
            #expect(fmtSize(483_100_000_000) == "483.1 GB")
            #expect(P(0, "{n} fichier", "{n} fichiers") == "0 files")
            #expect(P(1, "{n} fichier", "{n} fichiers") == "1 file")
        }
        withLang("it") { #expect(fmtInt(621_723) == "621.723") }
    }

    @Test func parametersReplacedOnce() {
        withLang("fr") {
            #expect(L("{path} : {reason}", ["path": "a{reason}", "reason": "x"]) == "a{reason} : x")
        }
    }

    @Test func systemLanguage() {
        #expect(I18n.systemLang(["de-DE", "it-IT"]) == "it")
        #expect(I18n.systemLang(["de-DE"]) == "en")
        #expect(I18n.systemLang(["fr_FR"]) == "fr")
    }

    /// Chaque texte des sources Swift a sa traduction, avec les mêmes paramètres dans chaque langue.
    @Test func everyKeyTranslated() throws {
        let table = try JSONDecoder().decode([String: [String]].self,
                                             from: Data(contentsOf: projectRoot.appending(path: "i18n/strings.json")))
        let placeholders = try Regex(#"\{\w+\}|%p%"#)
        for (key, values) in table {
            #expect(values.count == 3 && values.allSatisfy { !$0.isEmpty }, "\(key)")
            let ref = Set(key.matches(of: placeholders).map { String(key[$0.range]) })
            for v in values {
                #expect(Set(v.matches(of: placeholders).map { String(v[$0.range]) }) == ref, "\(key) → \(v)")
            }
        }
        // Textes passés à L(…), N_(…) et P(…, …, …) dans les sources
        let call = try Regex(#"\b(?:L|N_|P)\((?:[^"()]*?,\s*)?"((?:[^"\\]|\\.)*)"(?:\s*,\s*"((?:[^"\\]|\\.)*)")?"#)
        let sources = projectRoot.appending(path: "macos/Sources")
        var used = Set<String>()
        for case let url as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "Strings.swift" {
            let text = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for m in text.matches(of: call) {
                for i in 1...2 {
                    guard let r = m.output[i].range else { continue }
                    let raw = String(text[r]).replacingOccurrences(of: "\\n", with: "\n")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                    if !raw.contains("\\(") { used.insert(raw) }
                }
            }
        }
        let untranslated = used.subtracting(table.keys).subtracting(["%p%  {frame}", "OK"])
        #expect(untranslated.isEmpty, "Sans traduction : \(untranslated.sorted())")
        #expect(used.count > 60)
    }
}

// MARK: - Moteur

@Suite(.serialized) struct EngineTests {
    @Test func listDirReadsNamesTypesSizes() throws {
        let t = TempDir()
        t.write("a.txt", "hello")
        t.write("é è/b.bin", Data(count: 1234))
        symlink("a.txt", t.path + "/lien")
        let entries = try listDir(t.path).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["a.txt", "lien", "é è"])
        #expect(entries[0].kind == .file && entries[0].size == 5)
        #expect(entries[1].kind == .link)
        #expect(entries[2].kind == .dir)
        let total = try measure(t.path)
        #expect(total.files == 3 && total.bytes == 5 + 1234 + entries[1].size)
    }

    @Test func fullMerge() throws {
        let src = TempDir(), dest = TempDir()
        src.write("racine.txt", "nouveau")
        src.write("dossier/sous/petit.txt", "petit")
        src.write("dossier/gros.bin", Data((0..<(9 * 1024 * 1024)).map { UInt8($0 % 251) }))
        src.mkdir("vide")
        dest.write("racine.txt", "ancien contenu plus long")
        dest.write("dossier/garde.txt", "garde")
        dest.write("dossier/.fOLDERFUSE-0123456789ab.tmp", "reste d'une fusion interrompue")

        let inv = try scan(src: src.path, dest: dest.path)
        #expect(inv.count == 3)
        #expect(inv.overwritten == 1)
        #expect(inv.dirs == ["dossier", "vide", "dossier/sous"])
        #expect(dest.read("dossier/.fOLDERFUSE-0123456789ab.tmp") == nil)

        let engine = FusionEngine(src: src.path, dest: dest.path, inventory: inv)
        engine.cloneLarge = false  // copie par blocs, comme entre deux volumes
        #expect(engine.run() == .success)
        #expect(engine.progressUnits() == engine.totalUnits)
        #expect(dest.read("racine.txt") == Data("nouveau".utf8))
        #expect(dest.read("dossier/garde.txt") == Data("garde".utf8))
        #expect(dest.read("dossier/gros.bin") == src.read("dossier/gros.bin"))
        #expect(dest.read("dossier/sous/petit.txt") == Data("petit".utf8))
        #expect(isDirectory(dest.path + "/vide"))
        #expect(!dest.all().contains { $0.contains(TEMP_PREFIX) })
    }

    /// Fichier verrouillé dans la source : la copie garde le verrou, sans fichier temporaire restant.
    @Test func lockedFiles() throws {
        let src = TempDir(), dest = TempDir()
        src.write("verrou.txt", "v2")
        src.write("gros-verrou.bin", Data(count: 9 * 1024 * 1024))
        chflags(src.path + "/verrou.txt", UInt32(UF_IMMUTABLE))
        chflags(src.path + "/gros-verrou.bin", UInt32(UF_IMMUTABLE))
        let engine = FusionEngine(src: src.path, dest: dest.path, inventory: try scan(src: src.path, dest: dest.path))
        engine.cloneLarge = false
        #expect(engine.run() == .success, "\(engine.errors)")
        var st = stat()
        lstat(dest.path + "/verrou.txt", &st)
        #expect(st.st_flags & UInt32(UF_IMMUTABLE) != 0)
        #expect(dest.all() == ["gros-verrou.bin", "verrou.txt"])
    }

    /// Un problème n'arrête pas la fusion : il est signalé, les autres fichiers sont copiés.
    @Test func problemsAreReportedAndSkipped() throws {
        let src = TempDir(), dest = TempDir()
        src.write("bloque/x.txt", "x")       // « bloque » est un fichier dans la destination
        src.write("conflit", "fichier")      // « conflit » est un dossier dans la destination
        src.write("ok.txt", "ok")
        dest.write("bloque", "je suis un fichier")
        dest.mkdir("conflit")
        var asked: [String] = []
        let engine = FusionEngine(src: src.path, dest: dest.path,
                                  inventory: try scan(src: src.path, dest: dest.path)) { message in
            asked.append(message)
            return .skip
        }
        #expect(engine.run() == .partial)
        #expect(engine.errors.count == 2)
        #expect(asked.count == 2)
        #expect(dest.read("ok.txt") == Data("ok".utf8))
        #expect(!dest.all().contains { $0.contains(TEMP_PREFIX) })
    }

    @Test func skipAllAsksOnce() throws {
        let src = TempDir(), dest = TempDir()
        for i in 0..<5 {
            src.write("c\(i)", "f")
            dest.mkdir("c\(i)")
        }
        var asked = 0
        let engine = FusionEngine(src: src.path, dest: dest.path,
                                  inventory: try scan(src: src.path, dest: dest.path)) { _ in
            asked += 1
            return .skipAll
        }
        #expect(engine.run() == .partial)
        #expect(asked == 1 && engine.errors.count == 5)
    }

    @Test func stopLeavesNoTemporaryFile() throws {
        let src = TempDir(), dest = TempDir()
        for i in 0..<3 { src.write("gros\(i).bin", Data(count: 64 * 1024 * 1024)) }
        let engine = FusionEngine(src: src.path, dest: dest.path, inventory: try scan(src: src.path, dest: dest.path))
        engine.cloneLarge = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { engine.stop() }
        let outcome = engine.run()
        #expect(outcome == .stopped || outcome == .success)
        #expect(!dest.all().contains { $0.contains(TEMP_PREFIX) })
    }

    @Test func destinationInsideSourceIsDetectedBySameVolume() throws {
        let t = TempDir()
        t.mkdir("a")
        #expect(sameVolume(t.path, t.path + "/a"))
        #expect(freeSpace(t.path) ?? 0 > 0)
    }
}
