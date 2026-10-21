// Moteur de fusion de fOLDERFUSE, indépendant de l'interface.
//
// La copie de chaque fichier passe par copyfile(3), la fonction système qu'utilisent le Finder
// et ditto : clone APFS instantané quand source et destination sont sur le même volume, sinon
// copie des données avec toutes les métadonnées (droits, dates, ACL, attributs étendus, ressources).
//
// Fiabilité :
// - chaque fichier est écrit dans un fichier temporaire du dossier cible, puis renommé d'un coup :
//   un fichier de destination n'est jamais laissé à moitié écrit ;
// - une erreur sur un fichier n'arrête pas la fusion (sauf volume plein ou déconnecté) ;
// - la taille de chaque fichier copié est vérifiée ;
// - l'arrêt est possible à tout moment, y compris au milieu d'un gros fichier.
//
// Performance :
// - les petits fichiers sont copiés en parallèle (le coût par fichier domine) ;
// - les gros fichiers sont copiés un par un (le débit du disque domine), par blocs de 8 Mo,
//   avec suivi de l'avancement et arrêt immédiat ;
// - l'inventaire lit chaque dossier une seule fois (getattrlistbulk, comme le Finder),
//   plusieurs dossiers à la fois.

import Darwin
import Foundation
import Synchronization

// MARK: - copyfile(3)

let COPYFILE_ACL_: UInt32 = 1 << 0
let COPYFILE_STAT_: UInt32 = 1 << 1
let COPYFILE_XATTR_: UInt32 = 1 << 2
let COPYFILE_DATA_: UInt32 = 1 << 3
let COPYFILE_METADATA_ = COPYFILE_ACL_ | COPYFILE_STAT_ | COPYFILE_XATTR_
let COPYFILE_ALL_ = COPYFILE_METADATA_ | COPYFILE_DATA_
let COPYFILE_EXCL_: UInt32 = 1 << 17
let COPYFILE_NOFOLLOW_SRC_: UInt32 = 1 << 18
let COPYFILE_CLONE_: UInt32 = 1 << 24        // clone APFS si possible, sinon copie normale
let COPYFILE_CLONE_FORCE_: UInt32 = 1 << 25  // clone APFS uniquement (échoue sinon)

let FILE_FLAGS = COPYFILE_CLONE_ | COPYFILE_ALL_ | COPYFILE_EXCL_ | COPYFILE_NOFOLLOW_SRC_
let CLONE_ONLY_FLAGS = COPYFILE_CLONE_FORCE_ | COPYFILE_ALL_ | COPYFILE_EXCL_ | COPYFILE_NOFOLLOW_SRC_
let META_FLAGS = COPYFILE_METADATA_ | COPYFILE_NOFOLLOW_SRC_

/// Erreur système (errno) ; `path` est le chemin relatif concerné quand il est connu.
public struct SysError: Error {
    public let code: Int32
    public init(_ code: Int32 = errno) { self.code = code }
}

func copyFile(_ src: String, _ dst: String, _ flags: UInt32) throws {
    if copyfile(src, dst, nil, copyfile_flags_t(flags)) != 0 { throw SysError() }
}

// MARK: - Réglages

public enum Tuning {
    public static let largeFile: Int64 = 8 * 1024 * 1024  // au-delà : copie séquentielle par blocs
    public static let block = 8 * 1024 * 1024             // blocs de lecture/écriture des gros fichiers
    public static let workers = 8                         // copies (et lectures de dossiers) simultanées
    public static let fileCost: Int64 = 64 * 1024         // coût fixe d'un fichier pour la progression
}

public let TEMP_PREFIX = ".fOLDERFUSE-"  // fichiers temporaires (supprimés en cas d'échec ou d'arrêt)
public let TEMP_SUFFIX = ".tmp"

let ERROR_MESSAGES: [Int32: String] = [
    EACCES: N_("accès refusé"),
    EPERM: N_("opération non autorisée (fichier verrouillé ?)"),
    ENOENT: N_("fichier introuvable"),
    ENOSPC: N_("espace disque insuffisant"),
    EIO: N_("erreur de lecture ou d'écriture (disque défectueux ou déconnecté ?)"),
    ENAMETOOLONG: N_("nom de fichier trop long"),
    EROFS: N_("volume en lecture seule"),
    ENXIO: N_("volume déconnecté"),
    EISDIR: N_("un dossier du même nom existe dans la destination"),
    ENOTDIR: N_("un fichier du même nom bloque ce dossier dans la destination"),
    EEXIST: N_("un élément du même nom existe déjà"),
    EDQUOT: N_("quota disque dépassé"),
    EBADMSG: N_("copie incomplète (taille différente de l'original)"),
]
let FATAL_ERRNOS: Set<Int32> = [ENOSPC, EDQUOT, EROFS]

public func describe(_ code: Int32) -> String {
    if let known = ERROR_MESSAGES[code] { return L(known) }
    return String(cString: strerror(code))
}

func describe(_ error: Error) -> String {
    if let e = error as? SysError { return describe(e.code) }
    return error.localizedDescription
}

/// « chemin : raison », ponctuation propre à chaque langue.
public func problem(_ path: String, _ reason: String) -> String {
    L("{path} : {reason}", ["path": path, "reason": reason])
}

/// Comparaison des noms comme APFS par défaut : insensible à la casse et à la normalisation.
func nameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
}

public struct Stopped: Error { public init() {} }

func join(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }

// MARK: - Lecture rapide des dossiers
//
// getattrlistbulk(2) (l'appel qu'utilise le Finder) renvoie le nom, le type et la taille de toutes
// les entrées d'un dossier en quelques appels système, au lieu d'un lstat() par fichier.

public enum Kind { case file, dir, link, other }

public struct Entry {
    public let name: String
    public let kind: Kind
    public let size: Int64
}

private let ATTR_CMN_NAME_: UInt32 = 0x0000_0001
private let ATTR_CMN_OBJTYPE_: UInt32 = 0x0000_0008
private let ATTR_CMN_RETURNED_ATTRS_: UInt32 = 0x8000_0000
private let ATTR_FILE_DATALENGTH_: UInt32 = 0x0000_0200
private let FSOPT_PACK_INVAL_ATTRS_: UInt64 = 0x0000_0008
private let BULK_BUFFER = 256 * 1024
// Types d'objets (enum vtype)
private let VREG_: UInt32 = 1, VDIR_: UInt32 = 2, VLNK_: UInt32 = 5

/// Entrées d'un dossier (nom, type, taille), liens symboliques non suivis.
public func listDir(_ path: String) throws -> [Entry] {
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    if fd < 0 { throw SysError() }
    defer { close(fd) }

    var attrs = attrlist()
    attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attrs.commonattr = ATTR_CMN_RETURNED_ATTRS_ | ATTR_CMN_NAME_ | ATTR_CMN_OBJTYPE_
    attrs.fileattr = ATTR_FILE_DATALENGTH_

    let buf = UnsafeMutableRawPointer.allocate(byteCount: BULK_BUFFER, alignment: 8)
    defer { buf.deallocate() }
    var entries: [Entry] = []
    while true {
        let n = getattrlistbulk(fd, &attrs, buf, BULK_BUFFER, FSOPT_PACK_INVAL_ATTRS_)
        if n < 0 {
            let code = errno
            if [ENOTSUP, EINVAL, ENOSYS].contains(code) && entries.isEmpty { return try listDirSlow(path) }
            throw SysError(code)
        }
        if n == 0 { break }
        var off = 0
        for _ in 0..<n {
            // longueur (u32), attributs renvoyés (5 × u32), nom (attrreference_t : décalage i32 +
            // longueur u32), type (u32), taille des données (off_t)
            let length = Int(buf.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            let nameOff = Int(buf.loadUnaligned(fromByteOffset: off + 24, as: Int32.self))
            let nameLen = Int(buf.loadUnaligned(fromByteOffset: off + 28, as: UInt32.self))
            let type = buf.loadUnaligned(fromByteOffset: off + 32, as: UInt32.self)
            let size = buf.loadUnaligned(fromByteOffset: off + 36, as: Int64.self)
            let namePtr = (buf + off + 24 + nameOff).assumingMemoryBound(to: UInt8.self)
            let name = String(decoding: UnsafeBufferPointer(start: namePtr, count: max(0, nameLen - 1)), as: UTF8.self)
            let kind: Kind = type == VREG_ ? .file : type == VDIR_ ? .dir : type == VLNK_ ? .link : .other
            entries.append(Entry(name: name, kind: kind, size: kind == .dir ? 0 : size))
            off += length
        }
    }
    return entries
}

/// Repli pour un système de fichiers qui ne gère pas getattrlistbulk.
func listDirSlow(_ path: String) throws -> [Entry] {
    guard let dir = opendir(path) else { throw SysError() }
    defer { closedir(dir) }
    var entries: [Entry] = []
    while let ent = readdir(dir) {
        let name = withUnsafeBytes(of: ent.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if name == "." || name == ".." { continue }
        var st = stat()
        guard lstat(path + "/" + name, &st) == 0 else { continue }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: entries.append(Entry(name: name, kind: .dir, size: 0))
        case S_IFLNK: entries.append(Entry(name: name, kind: .link, size: st.st_size))
        case S_IFREG: entries.append(Entry(name: name, kind: .file, size: st.st_size))
        default: entries.append(Entry(name: name, kind: .other, size: 0))
        }
    }
    return entries
}

/// Parcourt une arborescence en parallèle (les lectures disque se recouvrent).
/// `visit(relDir)` traite un dossier et renvoie ses sous-dossiers (chemins relatifs).
func walk(_ visit: @escaping (String) throws -> [String], shouldStop: @escaping () -> Bool,
          workers: Int = Tuning.workers) throws {
    var queue = [""]
    var pending = 1
    var failure: Error?
    let cv = NSCondition()

    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while true {
            cv.lock()
            while queue.isEmpty && pending > 0 && failure == nil { cv.wait() }
            if failure != nil || queue.isEmpty {
                cv.broadcast()
                cv.unlock()
                return
            }
            let rel = queue.removeLast()
            cv.unlock()
            do {
                if shouldStop() { throw Stopped() }
                let subdirs = try visit(rel)
                cv.lock()
                queue.append(contentsOf: subdirs)
                pending += subdirs.count - 1
                cv.broadcast()
                cv.unlock()
            } catch {
                // Arrêt demandé ou erreur inattendue : tout s'arrête
                cv.lock()
                if failure == nil { failure = error }
                cv.broadcast()
                cv.unlock()
                return
            }
        }
    }
    if let failure { throw failure }
}

// MARK: - Inventaire

public struct Inventory: @unchecked Sendable {
    public var files: [(rel: String, size: Int64)] = []
    public var dirs: [String] = []
    public var skipped: [String] = []     // éléments spéciaux non copiés (tubes, sockets, périphériques)
    public var unreadable: [String] = []  // éléments source illisibles
    public var total: Int64 = 0
    public var overwritten = 0
    public var overwrittenBytes: Int64 = 0
    public var needed: Int64 = 0
    public var free: Int64?
    public var sameVolume = false
    public var count: Int { files.count }
    public init() {}
}

/// Inventaire de la source et des éléments qu'elle remplacera dans la destination.
/// Chaque dossier (source et destination) est lu une seule fois, en parallèle. Les fichiers
/// temporaires laissés par une fusion interrompue sont supprimés au passage.
public func scan(src: String, dest: String, shouldStop: @escaping () -> Bool = { false }) throws -> Inventory {
    var inv = Inventory()
    var failedDirs = Set<String>()
    var largestOverwrite: Int64 = 0
    let lock = NSLock()

    try walk({ relDir in
        let srcDir = relDir.isEmpty ? src : src + "/" + relDir
        let destDir = relDir.isEmpty ? dest : dest + "/" + relDir

        var existing: [String: (Kind, Int64)] = [:]
        if let entries = try? listDir(destDir) {
            for e in entries {
                if e.name.hasPrefix(TEMP_PREFIX) && e.name.hasSuffix(TEMP_SUFFIX) {
                    removeQuietly(destDir + "/" + e.name)
                    continue
                }
                existing[nameKey(e.name)] = (e.kind, e.size)
            }
        }

        let entries: [Entry]
        do {
            entries = try listDir(srcDir)
        } catch {
            lock.withLock {
                inv.unreadable.append(problem(relDir.isEmpty ? "." : relDir, describe(error)))
                failedDirs.insert(relDir)
            }
            return []
        }

        var files: [(rel: String, size: Int64)] = [], dirs: [String] = [], skipped: [String] = []
        var overwritten = 0, overwrittenBytes: Int64 = 0, largest: Int64 = 0
        for e in entries {
            let rel = join(relDir, e.name)
            switch e.kind {
            case .dir:
                dirs.append(rel)
                continue
            case .other:
                skipped.append(problem(rel, L("élément spécial non copié")))
                continue
            case .file, .link:
                files.append((rel, e.size))
            }
            if let old = existing[nameKey(e.name)], old.0 != .dir {
                overwritten += 1
                overwrittenBytes += old.1
                largest = max(largest, e.size)
            }
        }
        lock.withLock {
            inv.files.append(contentsOf: files)
            inv.dirs.append(contentsOf: dirs)
            inv.skipped.append(contentsOf: skipped)
            inv.overwritten += overwritten
            inv.overwrittenBytes += overwrittenBytes
            largestOverwrite = max(largestOverwrite, largest)
        }
        return dirs
    }, shouldStop: shouldStop)

    inv.files.sort { $0.rel < $1.rel }
    // Dossiers parents avant leurs sous-dossiers
    let slash = UInt8(ascii: "/")
    var keyed: [(depth: Int, path: String)] = []
    for d in inv.dirs where !failedDirs.contains(d) {
        keyed.append((d.utf8.filter { $0 == slash }.count, d))
    }
    keyed.sort { a, b in a.depth != b.depth ? a.depth < b.depth : a.path < b.path }
    inv.dirs = keyed.map { $0.path }
    inv.skipped.sort()
    inv.unreadable.sort()
    inv.total = inv.files.reduce(0) { $0 + $1.size }
    // Un fichier remplacé coexiste un instant avec sa nouvelle version
    inv.needed = max(inv.total - inv.overwrittenBytes, 0) + largestOverwrite
    inv.free = freeSpace(dest)
    inv.sameVolume = sameVolume(src, dest)
    return inv
}

/// Totaux mis à jour en direct pendant measure().
public final class Totals: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var files = 0
    public init() {}
    func add(_ b: Int64, _ n: Int) { lock.withLock { bytes += b; files += n } }
    public var value: (bytes: Int64, files: Int) { lock.withLock { (bytes, files) } }
}

/// Taille totale et nombre de fichiers d'un dossier, liens symboliques non suivis.
/// Les dossiers illisibles sont ignorés.
@discardableResult
public func measure(_ src: String, totals: Totals = Totals(), shouldStop: @escaping () -> Bool = { false }) throws
    -> (bytes: Int64, files: Int) {
    try walk({ relDir in
        guard let entries = try? listDir(relDir.isEmpty ? src : src + "/" + relDir) else { return [] }
        var subdirs: [String] = []
        var size: Int64 = 0, count = 0
        for e in entries {
            switch e.kind {
            case .dir: subdirs.append(join(relDir, e.name))
            case .file, .link: size += e.size; count += 1
            case .other: break
            }
        }
        totals.add(size, count)
        return subdirs
    }, shouldStop: shouldStop)
    return totals.value
}

public func freeSpace(_ path: String) -> Int64? {
    var st = statvfs()
    guard statvfs(path, &st) == 0 else { return nil }
    return Int64(st.f_bavail) * Int64(st.f_frsize)
}

func sameVolume(_ a: String, _ b: String) -> Bool {
    var sa = stat(), sb = stat()
    return stat(a, &sa) == 0 && stat(b, &sb) == 0 && sa.st_dev == sb.st_dev
}

public func isDirectory(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}

// MARK: - Copie

/// Barrière : les copies attendent pendant qu'un problème est soumis à l'utilisateur.
final class Gate: @unchecked Sendable {
    private let cv = NSCondition()
    private var isOpen = true
    func open() { cv.withLock { isOpen = true; cv.broadcast() } }
    func close() { cv.withLock { isOpen = false } }
    func wait() { cv.withLock { while !isOpen { cv.wait() } } }
}

public enum Decision: Sendable { case skip, skipAll, stop }
public enum Outcome: Sendable { case success, partial, stopped, failed }

/// Fusionne `src` dans `dest` à partir d'un inventaire produit par scan().
///
/// onProblem(message) est appelé (depuis un fil de copie) à chaque fichier en échec, sauf après
/// « skipAll ». Les autres copies se mettent en pause le temps de la réponse.
public final class FusionEngine: @unchecked Sendable {
    let src: String
    let dest: String
    let inv: Inventory
    let onProblem: (String) -> Decision
    let workers: Int

    public let totalUnits: Int64
    private let lock = NSLock()
    private let problemLock = NSLock()
    private let gate = Gate()
    private var doneUnits: Int64 = 0
    private var inflight: [Int: Int64] = [:]   // fil -> octets copiés du fichier en cours
    private var _errors: [String]
    private let stopFlag = Atomic<Bool>(false)
    private let pausedFlag = Atomic<Bool>(false)
    private var ignoreAll = false
    private var fatal: String?
    private var blockedDirs = Set<String>()
    private var createdDirs: [String] = []
    /// Clone APFS des gros fichiers quand c'est possible (désactivé par les tests de la copie par blocs).
    var cloneLarge = true

    public init(src: String, dest: String, inventory: Inventory, workers: Int = Tuning.workers,
                onProblem: @escaping (String) -> Decision = { _ in .skip }) {
        self.src = src
        self.dest = dest
        self.inv = inventory
        self.onProblem = onProblem
        self.workers = max(1, workers)
        _errors = inventory.unreadable + inventory.skipped
        totalUnits = inventory.total + Tuning.fileCost * Int64(max(inventory.count, 1))
    }

    // MARK: Commandes

    public func stop() {
        stopFlag.store(true, ordering: .relaxed)
        gate.open()
    }

    public var stopping: Bool { stopFlag.load(ordering: .relaxed) }
    public var paused: Bool { pausedFlag.load(ordering: .relaxed) }
    public var errors: [String] { lock.withLock { _errors } }
    public var fatalMessage: String? { lock.withLock { fatal } }

    public func progressUnits() -> Int64 {
        lock.withLock { doneUnits + inflight.values.reduce(0, +) }
    }

    // MARK: Déroulement

    public func run() -> Outcome {
        // Empêche la mise en veille tant que la fusion tourne
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "fOLDERFUSE")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        makeDirs()
        let small = inv.files.filter { $0.size < Tuning.largeFile }
        let large = inv.files.filter { $0.size >= Tuning.largeFile }
        if !small.isEmpty && !stopping {
            let next = Atomic<Int>(0)
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                while !stopping {
                    let i = next.add(1, ordering: .relaxed).oldValue
                    if i >= small.count { break }
                    copyOne(small[i], worker: worker, large: false)
                }
            }
        }
        if !large.isEmpty {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Tuning.block, alignment: 16384)
            defer { buffer.deallocate() }
            for item in large {
                if stopping { break }
                copyOne(item, worker: 0, large: true, buffer: buffer)
            }
        }
        if !stopping { applyDirMetadata() }

        if fatalMessage != nil { return .failed }
        if stopping { return .stopped }
        return errors.isEmpty ? .success : .partial
    }

    private func makeDirs() {
        for rel in inv.dirs {
            if stopping { return }
            if underBlocked(rel) { continue }
            let path = dest + "/" + rel
            if mkdir(path, 0o777) == 0 {
                createdDirs.append(rel)
                continue
            }
            let code = errno
            if code == EEXIST {
                if !isDirectory(path) {
                    blockedDirs.insert(rel)
                    report(rel, ENOTDIR)
                }
            } else {
                blockedDirs.insert(rel)
                report(rel, code)
            }
        }
    }

    private func underBlocked(_ rel: String) -> Bool {
        if blockedDirs.isEmpty { return false }
        var parent = (rel as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if blockedDirs.contains(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    private func copyOne(_ item: (rel: String, size: Int64), worker: Int, large: Bool,
                         buffer: UnsafeMutableRawPointer? = nil) {
        gate.wait()
        if stopping { return }
        defer {
            lock.withLock {
                inflight[worker] = nil
                doneUnits += item.size + Tuning.fileCost
            }
        }
        if underBlocked(item.rel) { return }

        let srcPath = src + "/" + item.rel
        let dstPath = dest + "/" + item.rel
        let tmpPath = (dstPath as NSString).deletingLastPathComponent + "/" + TEMP_PREFIX
            + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() + TEMP_SUFFIX
        do {
            if large, let buffer {
                try copyLarge(srcPath, tmpPath, worker: worker, buffer: buffer)
            } else {
                try copyFile(srcPath, tmpPath, FILE_FLAGS)
            }
            if stopping { throw Stopped() }
            // Vérification : la copie a la taille de l'original (relue si la source a changé depuis l'inventaire)
            let copied = lsize(tmpPath)
            if copied != item.size && copied != lsize(srcPath) { throw SysError(EBADMSG) }
            try renameKeepingFlags(tmpPath, dstPath)
        } catch is Stopped {
            removeQuietly(tmpPath)
        } catch {
            removeQuietly(tmpPath)
            report(item.rel, (error as? SysError)?.code ?? EIO)
        }
    }

    /// Clone APFS si possible ; sinon copie par blocs de 8 Mo (avancement et arrêt à chaque bloc),
    /// puis métadonnées (droits, dates, ACL, attributs étendus).
    private func copyLarge(_ srcPath: String, _ tmpPath: String, worker: Int, buffer: UnsafeMutableRawPointer) throws {
        if cloneLarge {
            if (try? copyFile(srcPath, tmpPath, CLONE_ONLY_FLAGS)) != nil { return }
            removeQuietly(tmpPath)
        }

        let fin = open(srcPath, O_RDONLY | O_NOFOLLOW)
        if fin < 0 { throw SysError() }
        defer { close(fin) }
        let fout = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fout < 0 { throw SysError() }
        defer { close(fout) }
        var copied: Int64 = 0
        while true {
            if stopping { throw Stopped() }
            let n = read(fin, buffer, Tuning.block)
            if n < 0 {
                if errno == EINTR { continue }
                throw SysError()
            }
            if n == 0 { break }
            var written = 0
            while written < n {
                let w = write(fout, buffer + written, n - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw SysError()
                }
                written += w
            }
            copied += Int64(n)
            lock.withLock { inflight[worker] = copied }
        }
        try copyFile(srcPath, tmpPath, META_FLAGS)
    }

    /// Dates et droits des dossiers créés, des plus profonds aux plus hauts
    /// (écrire dans un dossier change sa date de modification).
    private func applyDirMetadata() {
        for rel in createdDirs.reversed() {
            // sans gravité en cas d'échec : le contenu est copié, seule la date du dossier diffère
            try? copyFile(src + "/" + rel, dest + "/" + rel, COPYFILE_METADATA_)
        }
    }

    // MARK: Erreurs

    private func report(_ rel: String, _ code: Int32) {
        let message = problem(rel, describe(code))
        let destGone = !isDirectory(dest)
        if FATAL_ERRNOS.contains(code) || destGone {
            let text: String
            if destGone {
                text = L("Le dossier de destination n'est plus accessible (volume déconnecté ?).")
            } else if code == ENOSPC || code == EDQUOT {
                text = L("Le volume de destination est plein.\nLibérez de l'espace puis relancez la fusion : les fichiers déjà copiés seront simplement remplacés.")
            } else {
                text = L("Le volume de destination est en lecture seule.")
            }
            lock.withLock {
                fatal = fatal ?? text
                _errors.append(message)
            }
            stop()
            return
        }
        if !isDirectory(src) {
            lock.withLock {
                fatal = fatal ?? L("Le dossier source n'est plus accessible (volume déconnecté ?).")
                _errors.append(message)
            }
            stop()
            return
        }

        lock.withLock { _errors.append(message) }
        if lock.withLock({ ignoreAll }) || stopping { return }
        // Un seul dialogue à la fois ; les autres copies attendent la réponse
        problemLock.withLock {
            if lock.withLock({ ignoreAll }) || stopping { return }
            gate.close()
            pausedFlag.store(true, ordering: .relaxed)
            let decision = onProblem(message)
            pausedFlag.store(false, ordering: .relaxed)
            switch decision {
            case .skipAll: lock.withLock { ignoreAll = true }
            case .stop: stopFlag.store(true, ordering: .relaxed)
            case .skip: break
            }
            gate.open()
        }
    }
}

func lsize(_ path: String) -> Int64 {
    var st = stat()
    return lstat(path, &st) == 0 ? st.st_size : -1
}

/// Renomme la copie temporaire en fichier final. Un fichier verrouillé (Finder) ne peut pas être
/// renommé : le verrou est retiré le temps du renommage, puis remis.
func renameKeepingFlags(_ tmp: String, _ dst: String) throws {
    var st = stat()
    guard lstat(tmp, &st) == 0 else { throw SysError() }
    let flags = st.st_flags
    if flags != 0 { lchflags(tmp, 0) }
    guard rename(tmp, dst) == 0 else {
        let code = errno
        if flags != 0 { lchflags(tmp, flags) }
        throw SysError(code)
    }
    if flags != 0 { lchflags(dst, flags) }
}

func removeQuietly(_ path: String) {
    if unlink(path) == 0 || errno == ENOENT { return }
    lchflags(path, 0)
    unlink(path)
}
