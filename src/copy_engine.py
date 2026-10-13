"""Moteur de fusion de fOLDERFUSE (macOS uniquement), indépendant de l'interface.

La copie de chaque fichier passe par copyfile(3), la fonction système qu'utilisent
le Finder et ditto : clone APFS instantané quand source et destination sont sur le
même volume, sinon copie des données avec toutes les métadonnées (droits, dates,
ACL, attributs étendus, ressources).

Fiabilité :
- chaque fichier est écrit dans un fichier temporaire du dossier cible, puis renommé
  d'un coup : un fichier de destination n'est jamais laissé à moitié écrit ;
- une erreur sur un fichier n'arrête pas la fusion (sauf volume plein ou déconnecté) ;
- la taille de chaque fichier copié est vérifiée ;
- l'arrêt est possible à tout moment, y compris au milieu d'un gros fichier.

Performance :
- les petits fichiers sont copiés en parallèle (le coût par fichier domine) ;
- les gros fichiers sont copiés un par un (le débit du disque domine), par blocs de 8 Mo :
  aussi rapide que ditto, avec suivi de l'avancement et arrêt immédiat ;
- l'inventaire lit chaque dossier une seule fois (getattrlistbulk, comme le Finder),
  plusieurs dossiers à la fois.
"""
import ctypes
import errno
import os
import struct
import subprocess
import threading
import unicodedata
import uuid
from concurrent.futures import ThreadPoolExecutor

from i18n import L, N_

# --- copyfile(3) ----------------------------------------------------------------

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)

COPYFILE_ACL = 1 << 0
COPYFILE_STAT = 1 << 1
COPYFILE_XATTR = 1 << 2
COPYFILE_DATA = 1 << 3
COPYFILE_METADATA = COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR
COPYFILE_ALL = COPYFILE_METADATA | COPYFILE_DATA
COPYFILE_EXCL = 1 << 17
COPYFILE_NOFOLLOW_SRC = 1 << 18
COPYFILE_CLONE = 1 << 24        # clone APFS si possible, sinon copie normale
COPYFILE_CLONE_FORCE = 1 << 25  # clone APFS uniquement (échoue sinon)

FILE_FLAGS = COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC
CLONE_ONLY_FLAGS = COPYFILE_CLONE_FORCE | COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC
META_FLAGS = COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC

_copyfile = _libc.copyfile
_copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
_copyfile.restype = ctypes.c_int


def copyfile(src: str, dst: str, flags: int) -> None:
    """copyfile(3) ; lève OSError en cas d'échec. Libère le GIL pendant l'appel."""
    if _copyfile(os.fsencode(src), os.fsencode(dst), None, flags) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))

# --- Réglages -------------------------------------------------------------------

LARGE_FILE = 8 * 1024 * 1024    # au-delà : copie séquentielle par blocs
BLOCK = 8 * 1024 * 1024         # taille des blocs de lecture/écriture des gros fichiers
WORKERS = 8                     # copies simultanées de petits fichiers
FILE_COST = 64 * 1024           # coût fixe d'un fichier, en octets équivalents, pour la progression
TEMP_PREFIX = ".fOLDERFUSE-"    # fichiers temporaires (supprimés en cas d'échec ou d'arrêt)
TEMP_SUFFIX = ".tmp"

ERROR_MESSAGES = {
    errno.EACCES: N_("accès refusé"),
    errno.EPERM: N_("opération non autorisée (fichier verrouillé ?)"),
    errno.ENOENT: N_("fichier introuvable"),
    errno.ENOSPC: N_("espace disque insuffisant"),
    errno.EIO: N_("erreur de lecture ou d'écriture (disque défectueux ou déconnecté ?)"),
    errno.ENAMETOOLONG: N_("nom de fichier trop long"),
    errno.EROFS: N_("volume en lecture seule"),
    errno.ENXIO: N_("volume déconnecté"),
    errno.EISDIR: N_("un dossier du même nom existe dans la destination"),
    errno.ENOTDIR: N_("un fichier du même nom bloque ce dossier dans la destination"),
    errno.EEXIST: N_("un élément du même nom existe déjà"),
    errno.EDQUOT: N_("quota disque dépassé"),
    errno.EBADMSG: N_("copie incomplète (taille différente de l'original)"),
}
FATAL_ERRNOS = {errno.ENOSPC, errno.EDQUOT, errno.EROFS}


def describe(err: OSError) -> str:
    known = ERROR_MESSAGES.get(err.errno)
    return L(known) if known else (err.strerror or str(err))


def problem(path: str, reason: str) -> str:
    """« chemin : raison », ponctuation propre à chaque langue."""
    return L("{path} : {reason}", path=path, reason=reason)


def name_key(name: str) -> str:
    """Comparaison des noms comme APFS par défaut : insensible à la casse et à la normalisation."""
    return unicodedata.normalize("NFC", name).casefold()


class Stopped(Exception):
    pass


class Fatal(Exception):
    pass


# --- Lecture rapide des dossiers ---------------------------------------------------
#
# getattrlistbulk(2) (l'appel qu'utilise le Finder) renvoie le nom, le type et la taille
# de toutes les entrées d'un dossier en quelques appels système, au lieu d'un lstat()
# par fichier : environ 10 fois plus rapide que os.scandir() + stat() sur un gros dossier.

class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16),
                ("commonattr", ctypes.c_uint32), ("volattr", ctypes.c_uint32),
                ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32),
                ("forkattr", ctypes.c_uint32)]


_getattrlistbulk = _libc.getattrlistbulk
_getattrlistbulk.argtypes = [ctypes.c_int, ctypes.POINTER(_AttrList), ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint64]
_getattrlistbulk.restype = ctypes.c_int

ATTR_CMN_NAME = 0x00000001
ATTR_CMN_OBJTYPE = 0x00000008
ATTR_CMN_RETURNED_ATTRS = 0x80000000
ATTR_FILE_DATALENGTH = 0x00000200
FSOPT_PACK_INVAL_ATTRS = 0x00000008
# Chaque entrée : longueur (u32), attributs renvoyés (5 × u32), nom (attrreference_t :
# décalage i32 + longueur u32), type (u32), taille des données (off_t)
_ATTRS = _AttrList(5, 0, ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE, 0, 0,
                   ATTR_FILE_DATALENGTH, 0)
_ENTRY = struct.Struct("<I20xiIIq")
_BULK_BUFFER = 256 * 1024
_tls = threading.local()

# Types d'objets (enum vtype)
VREG, VDIR, VLNK = 1, 2, 5
KIND_FILE, KIND_DIR, KIND_LINK, KIND_OTHER = "f", "d", "l", "o"
_KINDS = {VREG: KIND_FILE, VDIR: KIND_DIR, VLNK: KIND_LINK}


def list_dir(path: str) -> list:
    """Entrées d'un dossier : [(nom, type, taille)], type parmi KIND_*. Lève OSError."""
    buf = getattr(_tls, "buf", None)
    if buf is None:
        buf = _tls.buf = ctypes.create_string_buffer(_BULK_BUFFER)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    entries = []
    try:
        while True:
            n = _getattrlistbulk(fd, ctypes.byref(_ATTRS), buf, _BULK_BUFFER, FSOPT_PACK_INVAL_ATTRS)
            if n < 0:
                code = ctypes.get_errno()
                if code in (errno.ENOTSUP, errno.EINVAL, errno.ENOSYS) and not entries:
                    return _list_dir_slow(path)
                raise OSError(code, os.strerror(code), path)
            if n == 0:
                break
            raw = buf.raw
            off = 0
            for _ in range(n):
                length, name_off, name_len, objtype, size = _ENTRY.unpack_from(raw, off)
                start = off + 24 + name_off
                name = os.fsdecode(raw[start:start + name_len - 1])
                entries.append((name, _KINDS.get(objtype, KIND_OTHER), size))
                off += length
    finally:
        os.close(fd)
    return entries


def _list_dir_slow(path: str) -> list:
    """Repli pour un système de fichiers qui ne gère pas getattrlistbulk."""
    entries = []
    with os.scandir(path) as it:
        for e in it:
            try:
                if e.is_dir(follow_symlinks=False):
                    entries.append((e.name, KIND_DIR, 0))
                elif e.is_symlink():
                    entries.append((e.name, KIND_LINK, e.stat(follow_symlinks=False).st_size))
                elif e.is_file(follow_symlinks=False):
                    entries.append((e.name, KIND_FILE, e.stat(follow_symlinks=False).st_size))
                else:
                    entries.append((e.name, KIND_OTHER, 0))
            except OSError:
                pass
    return entries


def _walk(visit, should_stop, workers=WORKERS):
    """Parcourt une arborescence en parallèle (les lectures disque se recouvrent).
    visit(rel_dir) traite un dossier et renvoie ses sous-dossiers (chemins relatifs)."""
    queue = [""]
    pending = [1]
    failure = []
    cv = threading.Condition()

    def worker():
        while True:
            with cv:
                while not queue and pending[0] and not failure:
                    cv.wait()
                if failure or not queue:
                    cv.notify_all()
                    return
                rel_dir = queue.pop()
            try:
                if should_stop():
                    raise Stopped()
                subdirs = visit(rel_dir)
            except BaseException as e:  # arrêt demandé ou erreur inattendue : tout s'arrête
                with cv:
                    failure.append(e)
                    cv.notify_all()
                return
            with cv:
                queue.extend(subdirs)
                pending[0] += len(subdirs) - 1
                cv.notify_all()

    threads = [threading.Thread(target=worker, name="inventaire", daemon=True) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if failure:
        raise failure[0]


# --- Inventaire -------------------------------------------------------------------

def scan(src: str, dest: str, should_stop=lambda: False) -> dict:
    """Inventaire de la source et des éléments qu'elle remplacera dans la destination.

    Chaque dossier (source et destination) est lu une seule fois, en parallèle. Les fichiers
    temporaires laissés par une fusion interrompue sont supprimés au passage.
    """
    files = []          # (chemin relatif, taille)
    dirs = []           # chemins relatifs des sous-dossiers
    skipped = []        # éléments spéciaux non copiés (tubes, sockets, périphériques)
    unreadable = []     # éléments source illisibles
    failed_dirs = set()  # dossiers source illisibles, à ne pas créer
    stats = {"overwritten": 0, "overwritten_bytes": 0, "largest_overwrite": 0}
    lock = threading.Lock()

    def visit(rel_dir):
        src_dir = os.path.join(src, rel_dir) if rel_dir else src
        dest_dir = os.path.join(dest, rel_dir) if rel_dir else dest

        existing = {}
        try:
            for name, kind, size in list_dir(dest_dir):
                if name.startswith(TEMP_PREFIX) and name.endswith(TEMP_SUFFIX):
                    _remove_quietly(os.path.join(dest_dir, name))
                    continue
                existing[name_key(name)] = (kind, size)
        except OSError:
            pass

        try:
            entries = list_dir(src_dir)
        except OSError as err:
            with lock:
                unreadable.append(problem(rel_dir or ".", describe(err)))
                failed_dirs.add(rel_dir)
            return []

        my_files, my_dirs, my_skipped = [], [], []
        overwritten = overwritten_bytes = largest = 0
        for name, kind, size in entries:
            rel = os.path.join(rel_dir, name) if rel_dir else name
            if kind == KIND_DIR:
                my_dirs.append(rel)
                continue
            if kind == KIND_OTHER:
                my_skipped.append(problem(rel, L("élément spécial non copié")))
                continue
            my_files.append((rel, size))
            old = existing.get(name_key(name))
            if old is not None and old[0] != KIND_DIR:
                overwritten += 1
                overwritten_bytes += old[1]
                largest = max(largest, size)
        with lock:
            files.extend(my_files)
            dirs.extend(my_dirs)
            skipped.extend(my_skipped)
            stats["overwritten"] += overwritten
            stats["overwritten_bytes"] += overwritten_bytes
            stats["largest_overwrite"] = max(stats["largest_overwrite"], largest)
        return my_dirs

    _walk(visit, should_stop)

    files.sort()
    dirs = sorted((d for d in dirs if d not in failed_dirs), key=lambda d: (d.count(os.sep), d))
    total = sum(size for _, size in files)
    try:
        free = os.statvfs(dest)
        free = free.f_bavail * free.f_frsize
    except OSError:
        free = None
    return {
        "files": files,
        "dirs": dirs,
        "skipped": sorted(skipped),
        "unreadable": sorted(unreadable),
        "count": len(files),
        "total": total,
        "overwritten": stats["overwritten"],
        "overwritten_bytes": stats["overwritten_bytes"],
        # Un fichier remplacé coexiste un instant avec sa nouvelle version
        "needed": max(total - stats["overwritten_bytes"], 0) + stats["largest_overwrite"],
        "free": free,
        "same_volume": _same_volume(src, dest),
    }


def measure(src: str, should_stop=lambda: False, totals=None) -> tuple[int, int]:
    """Taille totale (octets) et nombre de fichiers d'un dossier, liens symboliques non suivis.
    Les dossiers illisibles sont ignorés. `totals` ([octets, fichiers]) est mis à jour
    au fil du calcul, pour un affichage en direct."""
    if totals is None:
        totals = [0, 0]
    lock = threading.Lock()

    def visit(rel_dir):
        path = os.path.join(src, rel_dir) if rel_dir else src
        try:
            entries = list_dir(path)
        except OSError:
            return []
        subdirs = []
        size_sum = count = 0
        for name, kind, size in entries:
            if kind == KIND_DIR:
                subdirs.append(os.path.join(rel_dir, name) if rel_dir else name)
            elif kind != KIND_OTHER:
                size_sum += size
                count += 1
        with lock:
            totals[0] += size_sum
            totals[1] += count
        return subdirs

    _walk(visit, should_stop)
    return totals[0], totals[1]


def _same_volume(a: str, b: str) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False


# --- Copie ------------------------------------------------------------------------

class FusionEngine:
    """Fusionne `src` dans `dest` à partir d'un inventaire produit par scan().

    on_problem(message) -> "skip" | "skip_all" | "stop" est appelé (depuis un fil de copie)
    à chaque fichier en échec, sauf après « skip_all ». Les autres copies se mettent en
    pause le temps de la réponse.
    """

    def __init__(self, src, dest, inventory, on_problem=None, workers=WORKERS):
        self.src = src
        self.dest = dest
        self.inv = inventory
        self.on_problem = on_problem or (lambda message: "skip")
        self.workers = max(1, workers)

        self.errors = list(inventory.get("unreadable", [])) + list(inventory.get("skipped", []))
        self.total_units = inventory["total"] + FILE_COST * max(inventory["count"], 1)
        self._done_units = 0
        self._inflight = {}            # fil -> octets copiés du fichier en cours
        self._lock = threading.Lock()
        self._problem_lock = threading.Lock()
        self._resume = threading.Event()
        self._resume.set()
        self._stop = False
        self._fatal = None
        self._ignore_all = False
        self._blocked_dirs = set()
        self.paused = False

        self._buffer = bytearray(BLOCK)

    # --- Commandes ---

    def stop(self):
        self._stop = True
        self._resume.set()

    @property
    def stopping(self) -> bool:
        return self._stop

    def progress_units(self) -> int:
        with self._lock:
            return self._done_units + sum(self._inflight.values())

    # --- Déroulement ---

    def run(self) -> str:
        """Lance la fusion ; renvoie "success", "partial", "stopped" ou "failed"
        (avec self.fatal_message pour "failed")."""
        caffeinate = _prevent_sleep()
        try:
            self._make_dirs()
            files = self.inv["files"]
            small = [f for f in files if f[1] < LARGE_FILE]
            large = [f for f in files if f[1] >= LARGE_FILE]
            if small and not self._stop:
                with ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix="copie") as pool:
                    for _ in pool.map(self._copy_one, small):
                        pass
            for item in large:
                if self._stop:
                    break
                self._copy_one(item, large=True)
            if not self._stop:
                self._apply_dir_metadata()
        finally:
            if caffeinate is not None:
                caffeinate.terminate()

        if self._fatal:
            return "failed"
        if self._stop:
            return "stopped"
        return "partial" if self.errors else "success"

    @property
    def fatal_message(self):
        return self._fatal

    def _make_dirs(self):
        self._created_dirs = []
        for rel in self.inv["dirs"]:
            if self._stop:
                return
            if self._under_blocked(rel):
                continue
            path = os.path.join(self.dest, rel)
            try:
                os.mkdir(path)
                self._created_dirs.append(rel)
            except FileExistsError:
                if not os.path.isdir(path):
                    self._blocked_dirs.add(rel)
                    self._report(rel, OSError(errno.ENOTDIR, ""), blocking_dir=True)
            except OSError as err:
                self._blocked_dirs.add(rel)
                self._report(rel, err, blocking_dir=True)

    def _under_blocked(self, rel: str) -> bool:
        parent = os.path.dirname(rel)
        while parent:
            if parent in self._blocked_dirs:
                return True
            parent = os.path.dirname(parent)
        return False

    def _copy_one(self, item, large=False):
        rel, size = item
        self._resume.wait()
        if self._stop:
            return
        if self._under_blocked(rel):
            self._count_done(size)
            return

        src_path = os.path.join(self.src, rel)
        dst_path = os.path.join(self.dest, rel)
        tmp_path = os.path.join(os.path.dirname(dst_path), f"{TEMP_PREFIX}{uuid.uuid4().hex[:12]}{TEMP_SUFFIX}")
        try:
            if large:
                self._copy_large(src_path, tmp_path)
            else:
                copyfile(src_path, tmp_path, FILE_FLAGS)
            if self._stop:
                raise Stopped()
            # Vérification : la copie a la taille de l'original (relue si la source a changé depuis l'inventaire)
            copied = os.lstat(tmp_path).st_size
            if copied != size and copied != os.lstat(src_path).st_size:
                raise OSError(errno.EBADMSG, "copie incomplète")
            _rename_keeping_flags(tmp_path, dst_path)
        except Stopped:
            _remove_quietly(tmp_path)
        except OSError as err:
            _remove_quietly(tmp_path)
            self._report(rel, err)
        finally:
            with self._lock:
                self._inflight.pop(threading.get_ident(), None)
            self._count_done(size)

    def _copy_large(self, src_path, tmp_path):
        """Clone APFS si possible ; sinon copie par blocs de 8 Mo (avancement et arrêt
        à chaque bloc), puis métadonnées (droits, dates, ACL, attributs étendus)."""
        try:
            copyfile(src_path, tmp_path, CLONE_ONLY_FLAGS)
            return
        except OSError:
            _remove_quietly(tmp_path)
        tid = threading.get_ident()
        buf = self._buffer
        view = memoryview(buf)
        fin = os.open(src_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            fout = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                copied = 0
                while True:
                    if self._stop:
                        raise Stopped()
                    n = os.readv(fin, [buf])
                    if not n:
                        break
                    written = 0
                    while written < n:
                        written += os.write(fout, view[written:n])
                    copied += n
                    with self._lock:
                        self._inflight[tid] = copied
            finally:
                os.close(fout)
        finally:
            os.close(fin)
        copyfile(src_path, tmp_path, META_FLAGS)

    def _count_done(self, size):
        with self._lock:
            self._done_units += size + FILE_COST

    def _apply_dir_metadata(self):
        """Dates et droits des dossiers créés, des plus profonds aux plus hauts
        (écrire dans un dossier change sa date de modification)."""
        for rel in reversed(self._created_dirs):
            try:
                copyfile(os.path.join(self.src, rel), os.path.join(self.dest, rel), COPYFILE_METADATA)
            except OSError:
                pass  # sans gravité : le contenu est copié, seule la date du dossier diffère

    # --- Erreurs ---

    def _report(self, rel, err: OSError, blocking_dir=False):
        message = problem(rel, describe(err))
        if err.errno in FATAL_ERRNOS or not os.path.isdir(self.dest):
            if not os.path.isdir(self.dest):
                self._fatal = L("Le dossier de destination n'est plus accessible (volume déconnecté ?).")
            elif err.errno in (errno.ENOSPC, errno.EDQUOT):
                self._fatal = L("Le volume de destination est plein.\nLibérez de l'espace puis relancez "
                                "la fusion : les fichiers déjà copiés seront simplement remplacés.")
            else:
                self._fatal = L("Le volume de destination est en lecture seule.")
            with self._lock:
                self.errors.append(message)
            self.stop()
            return
        if not os.path.isdir(self.src):
            self._fatal = L("Le dossier source n'est plus accessible (volume déconnecté ?).")
            with self._lock:
                self.errors.append(message)
            self.stop()
            return

        with self._lock:
            self.errors.append(message)
        if self._ignore_all or self._stop:
            return
        # Un seul dialogue à la fois ; les autres copies attendent la réponse
        with self._problem_lock:
            if self._ignore_all or self._stop:
                return
            self._resume.clear()
            self.paused = True
            try:
                decision = self.on_problem(message)
            finally:
                self.paused = False
            if decision == "skip_all":
                self._ignore_all = True
            elif decision == "stop":
                self._stop = True
            self._resume.set()


def _rename_keeping_flags(tmp_path, dst_path):
    """Renomme la copie temporaire en fichier final. Un fichier verrouillé (Finder) ne peut
    pas être renommé : le verrou est retiré le temps du renommage, puis remis."""
    flags = os.lstat(tmp_path).st_flags
    if flags:
        os.lchflags(tmp_path, 0)
    os.rename(tmp_path, dst_path)
    if flags:
        os.lchflags(dst_path, flags)


def _remove_quietly(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except OSError:
        try:
            os.lchflags(path, 0)
            os.remove(path)
        except OSError:
            pass


def _prevent_sleep():
    """Empêche la mise en veille (système et disques) tant que l'appli tourne la fusion."""
    try:
        return subprocess.Popen(["/usr/bin/caffeinate", "-im", "-w", str(os.getpid())],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None
