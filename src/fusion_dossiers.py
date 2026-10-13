import sys, os, time, threading, json
from pathlib import Path
from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QPushButton, QLabel, QMenu,
    QFileDialog, QHBoxLayout, QProgressBar, QMessageBox, QFrame, QSizePolicy
)
from PyQt6.QtGui import QActionGroup
from PyQt6.QtCore import Qt, QThread, QTimer, QTranslator, QLibraryInfo, QLocale, pyqtSignal

import socle_qt
import copy_engine
import i18n
from i18n import L, N_, P, fmt_size

# Couleur de marque de fOLDERFUSE (orange pastel) et ses textes (contraste ≥ 7:1)
BRAND_BG = "#f39c4a"
BRAND_TEXT = "#1a1a1a"
BRAND_TEXT_MUTED = "#3d2410"
BRAND_HOVER = "rgba(26, 26, 26, 0.12)"

# Points animés après le pourcentage : montrent que la fusion tourne même si le % stagne
ACTIVITY_FRAMES = ("● ○ ○", "○ ● ○", "○ ○ ●", "○ ● ○")
ACTIVITY_INTERVAL_MS = 250

# Mesure de l'avancement et délai sans progression avant de signaler un blocage possible
PROGRESS_INTERVAL_MS = 200
STALL_SECONDS = 30

# Symbole devant chaque statut : la couleur ne porte jamais seule l'information (Socle)
STATUS_SYMBOLS = {"success": "✓", "warning": "!", "danger": "✕"}

# Réglages (langue choisie) : même emplacement que les autres applis
CONFIG_FILE = Path.home() / "Library" / "Application Support" / "fOLDERFUSE" / "config.json"
AUTO = "auto"  # langue du système


def load_config() -> dict:
    try:
        data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}  # config absente ou corrompue -> valeurs par défaut


def save_config(data: dict) -> None:
    try:
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    except OSError as e:
        print(f"Config save failed: {e}", file=sys.stderr)


def detect_system_lang() -> str:
    """Langue de l'interface du Mac (Réglages > Général > Langue et région)."""
    return i18n.system_lang(QLocale.system().uiLanguages())


def free_space(path: str) -> int | None:
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize
    except OSError:
        return None


def is_inside(path: str, folder: str) -> bool:
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder.rstrip(os.sep) + os.sep)


def size_and_count(total: int, count: int) -> str:
    """« 12,4 Go · 1 284 fichiers »."""
    return f"{fmt_size(total)} · {P(count, '{n} fichier', '{n} fichiers')}"


class SizeThread(QThread):
    """Taille de la source, calculée en arrière-plan dès qu'elle est choisie."""
    result = pyqtSignal(str, object, object)  # dossier, octets, nombre de fichiers

    def __init__(self, folder):
        super().__init__()
        self.folder = folder
        self.totals = [0, 0]  # mis à jour en direct par copy_engine.measure
        self._stop = False

    def stop(self):
        self._stop = True

    def run(self):
        try:
            total, count = copy_engine.measure(self.folder, lambda: self._stop, self.totals)
        except copy_engine.Stopped:
            return
        self.result.emit(self.folder, total, count)


class AnalyseThread(QThread):
    """Contrôles préalables et inventaire (copy_engine.scan) hors du fil de l'interface."""
    result = pyqtSignal(object)
    failed = pyqtSignal(str)

    def __init__(self, src, dest):
        super().__init__()
        self.src = src
        self.dest = dest
        self._stop = False

    def stop(self):
        self._stop = True

    def run(self):
        try:
            if not os.path.isdir(self.src):
                self.failed.emit(L("Le dossier source est introuvable.\nVérifiez que son volume est bien connecté."))
                return
            if not os.path.isdir(self.dest):
                self.failed.emit(L("Le dossier de destination est introuvable.\n"
                                   "Vérifiez que son volume est bien connecté."))
                return
            if is_inside(self.dest, self.src):
                self.failed.emit(L("La destination se trouve dans le dossier source.\n"
                                   "Choisissez une destination située en dehors de la source."))
                return
            if not os.access(self.dest, os.W_OK):
                self.failed.emit(L("Impossible d'écrire dans le dossier de destination.\n"
                                   "Vérifiez vos droits sur ce dossier ou choisissez-en un autre."))
                return
            self.result.emit(copy_engine.scan(self.src, self.dest, lambda: self._stop))
        except copy_engine.Stopped:
            pass
        except Exception as e:
            self.failed.emit(L("Impossible d'analyser les dossiers : {e}", e=e))


class FusionThread(QThread):
    """Exécute copy_engine.FusionEngine ; l'interface lit l'avancement sur self.engine."""
    # status : "success", "partial" (terminée avec des erreurs), "stopped", "failed"
    done = pyqtSignal(str, str, object)
    problem = pyqtSignal(str)

    def __init__(self, src, dest, inventory):
        super().__init__()
        self._decision = "skip"
        self._decided = threading.Event()
        self.engine = copy_engine.FusionEngine(src, dest, inventory, on_problem=self._ask)

    def _ask(self, message: str) -> str:
        """Appelé depuis un fil de copie : attend la réponse de l'interface."""
        self._decided.clear()
        self.problem.emit(message)
        self._decided.wait()
        return self._decision

    def resolve(self, choice: str):
        """Réponse à un problème : "skip", "skip_all" ou "stop"."""
        self._decision = choice
        self._decided.set()

    def stop(self):
        self.engine.stop()
        self.resolve("stop")

    def run(self):
        try:
            status = self.engine.run()
        except Exception as e:
            self.done.emit("failed", L("Erreur inattendue : {e}", e=e), list(self.engine.errors))
            return
        messages = {
            "success": L("Fusion terminée avec succès."),
            "partial": "",
            "stopped": L("Fusion arrêtée. Les fichiers déjà copiés restent dans la destination."),
            "failed": self.engine.fatal_message or L("La fusion a échoué."),
        }
        self.done.emit(status, messages[status], list(self.engine.errors))


_qt_translator = None


def install_qt_translation(app: QApplication, code: str) -> None:
    """Traduit les textes fournis par Qt (« Montrer les détails… », etc.) dans la langue active."""
    global _qt_translator
    if _qt_translator is not None:
        app.removeTranslator(_qt_translator)
    _qt_translator = QTranslator(app)
    if _qt_translator.load(QLocale(code), "qtbase", "_",
                           QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)):
        app.installTranslator(_qt_translator)


def flat_style(app: QApplication) -> None:
    """Style plat (aplats de couleur, aucun contour) pour les éléments propres à l'appli,
    ajouté après la feuille Socle générée."""
    c, m = socle_qt.c, socle_qt.m
    app.setStyleSheet(app.styleSheet() + f"""
/* Sélecteurs de dossier */
QPushButton[variant="picker"], QPushButton[variant="picker"][filled="true"] {{
    background-color: {c('surface-raised')}; border: none; border-radius: {m('radius-md')}px; padding: 0;
}}
QPushButton[variant="picker"]:hover, QPushButton[variant="picker"][filled="true"]:hover {{ background-color: {c('surface-hover')}; }}
QPushButton[variant="picker"]:pressed {{ background-color: {c('surface-selected')}; }}
QPushButton[variant="picker"]:focus {{ border: 2px solid {c('focus-ring')}; }}
QPushButton[variant="picker"]:disabled {{ background-color: {c('surface')}; }}
QPushButton[variant="picker"] QLabel[role="heading"] {{ color: {c('text-strong')}; }}

/* Boutons principaux : aplat, sans contour */
QPushButton[variant="primary"] {{ border: none; }}
QPushButton[variant="primary"]:focus {{ border: 2px solid {c('focus-ring')}; }}
QPushButton[variant="stop"] {{
    min-height: {m('size-control-lg')}px; padding: 0 {m('space-4')}px; border: none;
    background-color: {c('control-strong')}; color: {c('text-strong')};
}}
QPushButton[variant="stop"]:hover {{ background-color: {c('control-hover')}; }}
QPushButton[variant="stop"]:pressed {{ background-color: {c('control-pressed')}; }}
QPushButton[variant="stop"]:focus {{ border: 2px solid {c('focus-ring')}; }}
QPushButton[variant="stop"]:disabled {{ color: {c('text-disabled')}; }}

/* Barre de progression : aplats, aucun contour */
QProgressBar {{
    background-color: {c('control')}; color: {c('text-strong')}; border: none;
    border-radius: {m('radius')}px; min-height: {m('size-control-lg')}px; max-height: {m('size-control-lg')}px;
    text-align: center;
}}
QProgressBar::chunk {{ background-color: {c('accent-fill')}; border: none; border-radius: {m('radius')}px; }}
QProgressBar[status="success"] {{ background-color: {c('success-bg')}; color: {c('success-soft')}; border: none; }}
QProgressBar[status="success"]::chunk {{ background-color: {c('success-bg')}; }}
QProgressBar[status="warning"] {{ background-color: {c('warning-bg')}; color: {c('warning-soft')}; border: none; }}
QProgressBar[status="warning"]::chunk {{ background-color: {c('warning-bg')}; }}
QProgressBar[status="stalled"] {{ background-color: {c('warning-bg')}; color: {c('warning-soft')}; border: none; }}
QProgressBar[status="stalled"]::chunk {{ background-color: {c('accent-fill')}; }}
QProgressBar[status="danger"] {{ background-color: {c('danger-bg')}; color: {c('danger-soft')}; border: none; }}
QProgressBar[status="danger"]::chunk {{ background-color: {c('danger-bg')}; }}
""")


class FusionApp(QWidget):
    def __init__(self, config: dict | None = None):
        super().__init__()

        self.config = config if config is not None else {}
        self.source = ""
        self.destination = ""
        self.analysis = None
        self.size_thread = None
        self._old_size_threads = []
        self.worker = None
        self.running = False

        # Textes affichés, gardés sous forme de clés pour être retraduits à la volée
        self._src_size = None            # (octets, fichiers, définitif)
        self._status = ("none", N_("En attente de sélection..."), {})
        self._activity_key = None        # gabarit animé de la barre (None : texte de statut)

        self.setWindowTitle("fOLDERFUSE")
        self.build_ui()

        self._activity_frame = 0
        self.activity_timer = QTimer(self)
        self.activity_timer.setInterval(ACTIVITY_INTERVAL_MS)
        self.activity_timer.timeout.connect(self._tick_activity)

        self.size_timer = QTimer(self)
        self.size_timer.setInterval(300)
        self.size_timer.timeout.connect(self._tick_source_size)

        self.progress_timer = QTimer(self)
        self.progress_timer.setInterval(PROGRESS_INTERVAL_MS)
        self.progress_timer.timeout.connect(self._poll_progress)

        self.apply_texts()

    # --- Construction ---

    def _make_picker(self):
        """Bouton de sélection de dossier : titre + chemin choisi (ou invite) + détail, centrés."""
        btn = socle_qt.variant(QPushButton(), "picker")
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        btn.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        box = QVBoxLayout(btn)
        box.setContentsMargins(socle_qt.m("space-3"), socle_qt.m("space-3"), socle_qt.m("space-3"), socle_qt.m("space-3"))
        box.setSpacing(socle_qt.m("space-1"))

        heading = socle_qt.role(QLabel(), "heading")
        path = socle_qt.role(QLabel(), "muted")
        detail = socle_qt.role(QLabel(" "), "subtle")
        for lbl in (heading, path, detail):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            box.addWidget(lbl)
        return btn, heading, path, detail

    def _make_language_button(self) -> QPushButton:
        """Drapeau de la langue active, en haut à droite de l'en-tête ; ouvre le choix de la langue."""
        btn = QPushButton()
        btn.setObjectName("LangButton")
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        btn.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        btn.setFixedSize(30, 26)
        btn.clicked.connect(self._open_language_menu)
        return btn

    def build_ui(self):
        layout = QVBoxLayout()
        layout.setSpacing(socle_qt.m("space-3"))
        layout.setContentsMargins(*[socle_qt.m("space-3")] * 4)

        # En-tête : orange pastel propre à l'appli (couleur de marque, hors palette Socle)
        header = QFrame()
        header.setObjectName("BrandBar")
        header.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)
        header.setStyleSheet(f"""
            QFrame#BrandBar {{ background-color: {BRAND_BG}; border: none; border-radius: {socle_qt.m("radius-md")}px; }}
            QFrame#BrandBar QLabel {{ background: transparent; color: {BRAND_TEXT}; }}
            QFrame#BrandBar QLabel[role="meta"] {{ color: {BRAND_TEXT_MUTED}; }}
            QPushButton#LangButton {{ background: transparent; border: none; border-radius: {socle_qt.m("radius")}px;
                                      padding: 0; min-height: 0; font-size: 18px; }}
            QPushButton#LangButton:hover {{ background: {BRAND_HOVER}; }}
            QPushButton#LangButton:focus {{ border: 2px solid {BRAND_TEXT}; }}
        """)
        head = QHBoxLayout(header)
        head.setContentsMargins(socle_qt.m("space-2"), socle_qt.m("space-2"), socle_qt.m("space-2"), socle_qt.m("space-2"))
        head.setSpacing(0)
        titles = QVBoxLayout()
        titles.setSpacing(2)
        self.lbl_title = socle_qt.role(QLabel("fOLDERFUSE"), "heading")
        self.lbl_tagline = socle_qt.role(QLabel(), "meta")
        for lbl in (self.lbl_title, self.lbl_tagline):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            titles.addWidget(lbl)
        self.btn_lang = self._make_language_button()
        # Espace symétrique à gauche pour que les titres restent centrés
        head.addSpacing(self.btn_lang.width())
        head.addLayout(titles, 1)
        head.addWidget(self.btn_lang, 0, Qt.AlignmentFlag.AlignTop)
        layout.addWidget(header)

        # Sélection dossiers : source à gauche, destination à droite
        button_layout = QHBoxLayout()
        button_layout.setSpacing(socle_qt.m("space-2"))
        self.btn_src, self.lbl_src_title, self.lbl_src_path, self.lbl_src_detail = self._make_picker()
        self.btn_dest, self.lbl_dest_title, self.lbl_dest_path, self.lbl_dest_detail = self._make_picker()
        self.btn_src.clicked.connect(self.choose_src)
        self.btn_dest.clicked.connect(self.choose_dest)
        button_layout.addWidget(self.btn_src)
        button_layout.addWidget(self.btn_dest)
        layout.addLayout(button_layout)

        # Bouton FUSIONNER (devient ARRÊTER pendant l'analyse et la copie)
        self.btn_fuse = socle_qt.variant(QPushButton(), "primary")
        self.btn_fuse.setFocusPolicy(Qt.FocusPolicy.TabFocus)
        self.btn_fuse.clicked.connect(self._on_fuse_clicked)
        layout.addWidget(self.btn_fuse)

        # Barre de progression
        self.progress = QProgressBar()
        self.progress.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.progress.setRange(0, 100)
        self.progress.setValue(0)
        layout.addWidget(self.progress)

        self.setLayout(layout)
        self.setFixedWidth(540)
        self._fitted = False

    def showEvent(self, event):
        super().showEvent(event)
        if not self._fitted:
            self._fitted = True
            self._fit_height()

    def _fit_height(self):
        """Hauteur des sélecteurs puis de la fenêtre, une fois les polices de la feuille de style
        appliquées (un QPushButton ne tient pas compte de son layout interne)."""
        for btn in (self.btn_src, self.btn_dest):
            for lbl in btn.findChildren(QLabel):
                lbl.ensurePolished()
        picker_height = max(b.layout().sizeHint().height() for b in (self.btn_src, self.btn_dest))
        for btn in (self.btn_src, self.btn_dest):
            # Par feuille de style : la min-height de Socle l'emporterait sur setMinimumHeight()
            btn.setStyleSheet(f"QPushButton {{ min-height: {picker_height}px; max-height: {picker_height}px; }}")
        self.layout().activate()
        self.setFixedHeight(self.sizeHint().height())

    # --- Langue ---

    def _open_language_menu(self):
        menu = QMenu(self)
        group = QActionGroup(menu)
        chosen = self.config.get("language", AUTO)
        system = detect_system_lang()
        auto = menu.addAction(L("Automatique ({lang})", lang=f"{i18n.FLAGS[system]} {i18n.LANGS[system]}"))
        auto.setData(AUTO)
        menu.addSeparator()
        actions = [auto]
        for code, name in i18n.LANGS.items():
            act = menu.addAction(f"{i18n.FLAGS[code]}  {name}")
            act.setData(code)
            actions.append(act)
        for act in actions:
            act.setCheckable(True)
            act.setChecked(act.data() == chosen)
            group.addAction(act)
        picked = menu.exec(self.btn_lang.mapToGlobal(self.btn_lang.rect().bottomLeft()))
        if picked is not None:
            self.set_language(picked.data())

    def set_language(self, choice: str):
        """Change la langue (code ou AUTO), la mémorise et retraduit l'interface."""
        self.config["language"] = choice
        save_config(self.config)
        code = detect_system_lang() if choice == AUTO else choice
        i18n.set_lang(code)
        install_qt_translation(QApplication.instance(), code)
        self.apply_texts()

    def apply_texts(self):
        """(Re)traduit tous les textes visibles dans la langue active."""
        code = i18n.get_lang()
        self.btn_lang.setText(i18n.FLAGS[code])
        self.btn_lang.setToolTip(L("Langue : {name}", name=i18n.LANGS[code]))
        self.lbl_tagline.setText(L("Les fichiers de même nom sont remplacés dans la destination."))
        self.lbl_src_title.setText(L("SOURCE"))
        self.lbl_dest_title.setText(L("DESTINATION"))
        if not self.source:
            self.lbl_src_path.setText(L("Choisir un dossier"))
        if not self.destination:
            self.lbl_dest_path.setText(L("Choisir un dossier"))
        self._render_source_size()
        self._update_free_space()
        self.btn_fuse.setText(L("ARRÊTER") if self.running else L("FUSIONNER"))
        if self._activity_key is not None:
            self._tick_activity()
        else:
            self._render_status()

    # --- Sélection des dossiers ---

    def _set_path(self, label: QLabel, button: QPushButton, folder: str):
        label.setText(self._format_path(folder))
        socle_qt.role(label, "path")
        button.setProperty("filled", True)
        socle_qt.variant(button, "picker")
        button.setToolTip(folder)

    def _format_path(self, path: str, max_chars: int = 30) -> str:
        if not path:
            return ""
        if len(path) <= max_chars:
            return path
        half = (max_chars - 3) // 2
        return f"{path[:half]}...{path[-half:]}"

    def _measure_source(self):
        """Lance le calcul de la taille de la source (le précédent est abandonné)."""
        if self.size_thread is not None:
            self.size_thread.stop()
            self._old_size_threads = [t for t in self._old_size_threads if t.isRunning()] + [self.size_thread]
        self._src_size = None
        self._render_source_size()
        self.size_thread = SizeThread(self.source)
        self.size_thread.result.connect(self._show_source_size)
        self.size_thread.start()
        self.size_timer.start()

    def _tick_source_size(self):
        """Affichage en direct pendant le calcul : « 12,4 Go · 45 000 fichiers... »."""
        t = self.size_thread
        if t is None or not t.isRunning():
            self.size_timer.stop()
            return
        total, count = t.totals
        if count:
            self._src_size = (total, count, False)
            self._render_source_size()

    def _show_source_size(self, folder: str, total: int, count: int):
        if folder == self.source:
            self.size_timer.stop()
            self._src_size = (total, count, True)
            self._render_source_size()

    def _render_source_size(self):
        if not self.source:
            self.lbl_src_detail.setText(" ")
        elif self._src_size is None:
            self.lbl_src_detail.setText(L("Calcul de la taille..."))
        else:
            total, count, final = self._src_size
            self.lbl_src_detail.setText(size_and_count(total, count) + ("" if final else "..."))

    def _update_free_space(self):
        free = free_space(self.destination) if self.destination else None
        self.lbl_dest_detail.setText(L("{size} libres sur le volume", size=fmt_size(free))
                                     if free is not None else " ")

    def choose_src(self):
        folder = QFileDialog.getExistingDirectory(self, L("Dossier source"), self.source)
        if folder:
            self.source = folder
            self._set_path(self.lbl_src_path, self.btn_src, folder)
            self._measure_source()
            self._update_status()

    def choose_dest(self):
        folder = QFileDialog.getExistingDirectory(self, L("Dossier de destination"), self.destination)
        if folder:
            self.destination = folder
            self._set_path(self.lbl_dest_path, self.btn_dest, folder)
            self._update_free_space()
            self._update_status()

    # --- Barre de progression ---

    def _set_status(self, status: str, key: str = None, value: int = None, **kw):
        """Statut de la barre (aplat de couleur) + texte (clé française), précédé du symbole du statut."""
        socle_qt.status(self.progress, status)
        if value is not None:
            self.progress.setValue(value)
        if key is not None:
            self._activity_key = None
            self._status = (status, key, kw)
            self._render_status()

    def _render_status(self):
        status, key, kw = self._status
        text = L(key, **kw) if kw else L(key)
        symbol = STATUS_SYMBOLS.get(status)
        self.progress.setFormat(f"{symbol}  {text}" if symbol else text)

    def _update_status(self):
        if self.source and self.destination:
            key = N_("Prêt à fusionner")
        elif self.source:
            key = N_("Sélectionnez la destination...")
        elif self.destination:
            key = N_("Sélectionnez la source...")
        else:
            key = N_("En attente de sélection...")
        self._set_status("none", key, 0)

    def _start_activity(self, key: str):
        """Texte animé de la barre ; `key` contient {frame} (et éventuellement %p%)."""
        self._activity_key = key
        self._activity_frame = 0
        self._tick_activity()
        self.activity_timer.start()

    def _tick_activity(self):
        frame = ACTIVITY_FRAMES[self._activity_frame % len(ACTIVITY_FRAMES)]
        self._activity_frame += 1
        self.progress.setFormat(L(self._activity_key, frame=frame, s=STALL_SECONDS))

    # --- Dialogues ---

    def _ask(self, icon, title: str, text: str, buttons, default: int = 0, detail: str = "") -> int:
        """Dialogue à boutons libellés dans la langue active ; renvoie l'index du bouton choisi."""
        box = QMessageBox(icon, title, text, parent=self)
        made = [box.addButton(label, role) for label, role in buttons]
        box.setDefaultButton(made[default])
        box.setEscapeButton(made[default])
        if detail:
            box.setDetailedText(detail)
        box.exec()
        return made.index(box.clickedButton()) if box.clickedButton() in made else default

    def _ok(self, icon, title: str, text: str, detail: str = ""):
        self._ask(icon, title, text, [(L("OK"), QMessageBox.ButtonRole.AcceptRole)], detail=detail)

    # --- Déroulement ---

    def _set_running(self, running: bool):
        self.running = running
        self.btn_src.setEnabled(not running)
        self.btn_dest.setEnabled(not running)
        self.btn_fuse.setEnabled(True)
        self.btn_fuse.setText(L("ARRÊTER") if running else L("FUSIONNER"))
        socle_qt.variant(self.btn_fuse, "stop" if running else "primary")

    def _on_fuse_clicked(self):
        if self.running:
            self.stop_fusion()
        else:
            self.start_fusion()

    def start_fusion(self):
        if not self.source or not self.destination:
            self._ok(QMessageBox.Icon.Warning, L("Attention"),
                     L("Veuillez choisir un dossier source et un dossier de destination."))
            return

        self._set_running(True)
        self._set_status("none", value=0)
        self._start_activity(N_("Analyse des dossiers  {frame}"))

        self.analysis = AnalyseThread(self.source, self.destination)
        self.analysis.result.connect(self._analysis_done)
        self.analysis.failed.connect(self._analysis_failed)
        self.analysis.start()

    def _analysis_failed(self, message: str):
        self.activity_timer.stop()
        self._set_running(False)
        self._set_status("danger", N_("Fusion impossible"), 0)
        self._ok(QMessageBox.Icon.Critical, L("Fusion impossible"), message)

    def _analysis_done(self, inv: dict):
        self.activity_timer.stop()
        if not self.running:  # analyse arrêtée entre-temps
            return
        self._update_free_space()
        self._show_source_size(self.source, inv["total"], inv["count"])

        lines = [L("À copier : {what}", what=f"{fmt_size(inv['total'])} "
                                              f"({P(inv['count'], '{n} fichier', '{n} fichiers')})")]
        if inv["overwritten"]:
            lines.append(P(inv["overwritten"],
                           "Dont {n} fichier de même nom remplacé ({size} actuellement)",
                           "Dont {n} fichiers de même nom remplacés ({size} actuellement)",
                           size=fmt_size(inv["overwritten_bytes"])))
        if inv["free"] is not None:
            lines.append(L("Espace libre sur la destination : {size}", size=fmt_size(inv["free"])))
        if inv["same_volume"]:
            lines.append(L("Même volume : les fichiers sont clonés, sans occuper d'espace supplémentaire."))
        problems = len(inv["unreadable"]) + len(inv["skipped"])
        if problems:
            lines.append(P(problems,
                           "{n} élément de la source ne pourra pas être copié (illisible).",
                           "{n} éléments de la source ne pourront pas être copiés (illisibles)."))
        summary = "\n".join(lines)

        # Contrôle de l'espace disponible (inutile sur un même volume : clones APFS)
        if inv["free"] is not None and not inv["same_volume"] and inv["needed"] > inv["free"]:
            choice = self._ask(
                QMessageBox.Icon.Warning, L("Espace insuffisant"),
                L("Il faut environ {needed} sur le volume de destination, il reste {free}.\n\n"
                  "Libérez au moins {missing} ou choisissez une autre destination.\n"
                  "Si la fusion est lancée quand même, elle s'arrêtera quand le volume sera plein.",
                  needed=fmt_size(inv["needed"]), free=fmt_size(inv["free"]),
                  missing=fmt_size(inv["needed"] - inv["free"])),
                [(L("Annuler"), QMessageBox.ButtonRole.RejectRole),
                 (L("Fusionner quand même"), QMessageBox.ButtonRole.AcceptRole)],
            )
            if choice != 1:
                self._set_running(False)
                self._set_status("warning", N_("Espace insuffisant"), 0)
                return

        # Fenêtre d'avertissement avant d'écraser
        message = L("Fusionner le contenu de :\n{src}\n\nVers la racine du dossier :\n{dest}\n\n{summary}\n\n"
                    "Les fichiers existants portant le même nom seront remplacés. "
                    "Le dossier source n'est pas modifié.",
                    src=self.source, dest=self.destination, summary=summary)
        choice = self._ask(
            QMessageBox.Icon.Question, L("Confirmation de fusion"), message,
            [(L("Annuler"), QMessageBox.ButtonRole.RejectRole),
             (L("Fusionner"), QMessageBox.ButtonRole.AcceptRole)],
        )
        if choice != 1:
            self._set_running(False)
            self._set_status("none", N_("Fusion annulée"), 0)
            return

        self.worker = FusionThread(self.source, self.destination, inv)
        self.worker.problem.connect(self._on_problem)
        self.worker.done.connect(self._fusion_done)
        self._last_units = -1
        self._last_change = time.monotonic()
        self._stalled = False
        self.worker.start()
        self._start_activity("%p%  {frame}")
        self.progress_timer.start()

    def _poll_progress(self):
        """Avancement lu sur le moteur, et surveillance des blocages."""
        if self.worker is None:
            return
        engine = self.worker.engine
        units = engine.progress_units()
        self.progress.setValue(min(99, int(units * 100 / engine.total_units)))

        now = time.monotonic()
        if units != self._last_units or engine.paused:
            self._last_units, self._last_change = units, now
            if self._stalled:
                self._stalled = False
                if not engine.stopping:
                    self._activity_key = "%p%  {frame}"
                self._set_status("none")
        elif not self._stalled and now - self._last_change >= STALL_SECONDS:
            self._stalled = True
            self._activity_key = N_("%p%  {frame}  ! Aucune progression depuis {s} s")
            self._set_status("stalled")
            self._tick_activity()

    def stop_fusion(self):
        if self.worker is None or not self.worker.isRunning():
            # Arrêt pendant l'analyse
            if self.analysis is not None:
                self.analysis.stop()
            self.activity_timer.stop()
            self._set_running(False)
            self._set_status("none", N_("Fusion annulée"), 0)
            return
        choice = self._ask(
            QMessageBox.Icon.Question, L("Arrêter la fusion"),
            L("Arrêter la fusion maintenant ?\n\nLes fichiers déjà copiés restent dans la destination ; "
              "le fichier en cours de copie n'est pas conservé."),
            [(L("Continuer la fusion"), QMessageBox.ButtonRole.RejectRole),
             (L("Arrêter"), QMessageBox.ButtonRole.DestructiveRole)],
        )
        if choice == 1 and self.worker is not None:
            self.btn_fuse.setEnabled(False)
            self._activity_key = N_("Arrêt en cours  {frame}")
            self.worker.stop()

    def _on_problem(self, message: str):
        self.activity_timer.stop()
        self._set_status("stalled")
        self.progress.setFormat(L("%p%  ! En pause"))
        choice = self._ask(
            QMessageBox.Icon.Warning, L("Problème de copie"),
            L("Un élément n'a pas pu être copié :\n{message}\n\n"
              "La fusion est en pause. Les autres fichiers peuvent être copiés normalement.", message=message),
            [(L("Ignorer et continuer"), QMessageBox.ButtonRole.AcceptRole),
             (L("Ignorer tous les problèmes"), QMessageBox.ButtonRole.AcceptRole),
             (L("Arrêter la fusion"), QMessageBox.ButtonRole.DestructiveRole)],
        )
        if self.worker is None:
            return
        if choice == 2:
            self.btn_fuse.setEnabled(False)
            self._activity_key = N_("Arrêt en cours  {frame}")
        self._set_status("none")
        self.worker.resolve(("skip", "skip_all", "stop")[choice])
        self.activity_timer.start()

    def _fusion_done(self, status: str, message: str, errors: list):
        self.activity_timer.stop()
        self.progress_timer.stop()
        self._set_running(False)
        self._update_free_space()
        self.worker = None
        detail = "\n".join(errors)

        if status == "success":
            self._set_status("success", N_("Fusion terminée"), 100)
        elif status == "partial":
            n = len(errors)
            self._set_status("warning", N_("Terminée avec {n} problème") if n <= 1 else N_("Terminée avec {n} problèmes"),
                             100, n=i18n.fmt_int(n))
            self._ok(QMessageBox.Icon.Warning, L("Fusion terminée avec des problèmes"),
                     P(n, "La fusion est terminée, mais {n} élément n'a pas pu être copié.\n"
                          "Tous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails.",
                          "La fusion est terminée, mais {n} éléments n'ont pas pu être copiés.\n"
                          "Tous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails."),
                     detail=detail)
        elif status == "stopped":
            self._set_status("warning", N_("Fusion arrêtée"))
            self._ok(QMessageBox.Icon.Information, L("Fusion arrêtée"), message, detail=detail)
        else:
            self._set_status("danger", N_("Erreur de fusion"), 0)
            self._ok(QMessageBox.Icon.Critical, L("Erreur"), message, detail=detail)

    def closeEvent(self, event):
        """Ne ferme pas la fenêtre en laissant une copie tourner en arrière-plan."""
        if self.worker is not None and self.worker.isRunning():
            choice = self._ask(
                QMessageBox.Icon.Question, L("Fusion en cours"),
                L("Une fusion est en cours. L'arrêter et quitter ?\n\n"
                  "Les fichiers déjà copiés restent dans la destination."),
                [(L("Continuer la fusion"), QMessageBox.ButtonRole.RejectRole),
                 (L("Arrêter et quitter"), QMessageBox.ButtonRole.DestructiveRole)],
            )
            if choice != 1:
                event.ignore()
                return
            self.worker.stop()
            self.worker.wait(30000)
        if self.analysis is not None and self.analysis.isRunning():
            self.analysis.stop()
            self.analysis.wait(10000)
        for t in [self.size_thread, *self._old_size_threads]:
            if t is not None and t.isRunning():
                t.stop()
                t.wait(10000)
        event.accept()


def init_language(app: QApplication, config: dict) -> None:
    """Langue choisie par l'utilisateur, sinon celle du système (anglais si non prise en charge)."""
    choice = config.get("language", AUTO)
    code = choice if choice in i18n.LANGS else detect_system_lang()
    i18n.set_lang(code)
    install_qt_translation(app, code)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    config = load_config()
    init_language(app, config)
    socle_qt.apply(app)
    flat_style(app)
    window = FusionApp(config)
    window.show()
    sys.exit(app.exec())
