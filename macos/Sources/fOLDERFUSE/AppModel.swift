// Logique de l'interface : choix des dossiers, taille de la source, analyse, confirmation,
// fusion (moteur FusionCore dans un fil à part), problèmes de copie, blocages, fin.

import AppKit
import FusionCore
import Observation
import Synchronization

// Points animés après le pourcentage : montrent que la fusion tourne même si le % stagne
let ACTIVITY_FRAMES = ["● ○ ○", "○ ● ○", "○ ○ ●", "○ ● ○"]
let ACTIVITY_INTERVAL = 0.25
// Mesure de l'avancement et délai sans progression avant de signaler un blocage possible
let PROGRESS_INTERVAL = 0.2
let STALL_SECONDS = 30.0
// Symbole devant chaque statut : la couleur ne porte jamais seule l'information (Socle)
let STATUS_SYMBOLS: [BarStatus: String] = [.success: "✓", .warning: "!", .danger: "✕"]

/// Drapeau d'arrêt partagé avec un fil de calcul.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    func stop() { flag.store(true, ordering: .relaxed) }
    var stopped: Bool { flag.load(ordering: .relaxed) }
}

/// Exécute FusionEngine dans un fil à part ; transmet les problèmes à l'interface et attend sa réponse.
final class FusionRunner: @unchecked Sendable {
    private(set) var engine: FusionEngine!
    private let decided = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var decision: Decision = .skip
    private var waiting = false
    let finished = DispatchSemaphore(value: 0)

    init(src: String, dest: String, inventory: Inventory, ask: @escaping @Sendable (String) -> Void) {
        engine = FusionEngine(src: src, dest: dest, inventory: inventory) { [unowned self] message in
            lock.withLock { waiting = true }
            ask(message)
            decided.wait()
            return lock.withLock { decision }
        }
    }

    /// Réponse à un problème.
    func resolve(_ choice: Decision) {
        lock.withLock {
            guard waiting else { return }
            waiting = false
            decision = choice
            decided.signal()
        }
    }

    func stop() {
        engine.stop()
        resolve(.stop)
    }

    func start(done: @escaping @Sendable (Outcome) -> Void) {
        let engine = engine!
        Thread.detachNewThread { [finished] in
            let outcome = engine.run()
            finished.signal()
            done(outcome)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var source = ""
    var destination = ""
    var sourceDetail = ""
    var destinationDetail = ""
    var running = false
    var fuseEnabled = true
    var progress = 0
    var status: BarStatus = .none
    var progressText = L("En attente de sélection...")

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var sizeStop: StopFlag?
    @ObservationIgnored private var sizeTotals: Totals?
    @ObservationIgnored private var analysisStop: StopFlag?
    @ObservationIgnored private var runner: FusionRunner?
    @ObservationIgnored private var activityKey: String?   // gabarit animé de la barre ({frame}, %p%)
    @ObservationIgnored private var activityFrame = 0
    @ObservationIgnored private var activityTimer: Timer?
    @ObservationIgnored private var sizeTimer: Timer?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var lastUnits: Int64 = -1
    @ObservationIgnored private var lastChange = Date()
    @ObservationIgnored private var stalled = false

    var fusionRunning: Bool { runner != nil }

    // MARK: Minuteries (actives aussi pendant les dialogues)

    private func repeating(_ interval: Double, _ body: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    // MARK: Sélection des dossiers

    private func pickFolder(_ title: String, _ current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = title
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        return panel.runModal() == .OK ? panel.url?.path(percentEncoded: false) : nil
    }

    func chooseSource() {
        guard let folder = pickFolder(L("Dossier source"), source) else { return }
        source = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        measureSource()
        updateStatus()
    }

    func chooseDestination() {
        guard let folder = pickFolder(L("Dossier de destination"), destination) else { return }
        destination = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        updateFreeSpace()
        updateStatus()
    }

    /// Calcule la taille de la source en arrière-plan (le calcul précédent est abandonné),
    /// avec affichage en direct : « 12,4 Go · 45 000 fichiers... ».
    private func measureSource() {
        sizeStop?.stop()
        sizeTimer?.invalidate()
        let stop = StopFlag(), totals = Totals(), folder = source
        sizeStop = stop
        sizeTotals = totals
        sourceDetail = L("Calcul de la taille...")
        sizeTimer = repeating(0.3) { [weak self] in
            guard let self, self.sizeTotals === totals else { return }
            let v = totals.value
            if v.files > 0 { self.sourceDetail = sizeAndCount(v.bytes, v.files) + "..." }
        }
        Thread.detachNewThread {
            guard let result = try? measure(folder, totals: totals, shouldStop: { stop.stopped }) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.showSourceSize(folder, result.bytes, result.files) }
            }
        }
    }

    private func showSourceSize(_ folder: String, _ bytes: Int64, _ files: Int) {
        guard folder == source else { return }
        sizeTimer?.invalidate()
        sizeTotals = nil
        sourceDetail = sizeAndCount(bytes, files)
    }

    private func updateFreeSpace() {
        guard !destination.isEmpty, let free = freeSpace(destination) else {
            destinationDetail = ""
            return
        }
        destinationDetail = L("{size} libres sur le volume", ["size": fmtSize(free)])
    }

    // MARK: Barre de progression

    private func setStatus(_ s: BarStatus, _ key: String? = nil, value: Int? = nil, _ kw: [String: Any] = [:]) {
        status = s
        if let value { progress = value }
        if let key {
            activityKey = nil
            let text = L(key, kw)
            progressText = STATUS_SYMBOLS[s].map { "\($0)  \(text)" } ?? text
        }
    }

    private func updateStatus() {
        let key: String
        if !source.isEmpty && !destination.isEmpty { key = N_("Prêt à fusionner") }
        else if !source.isEmpty { key = N_("Sélectionnez la destination...") }
        else if !destination.isEmpty { key = N_("Sélectionnez la source...") }
        else { key = N_("En attente de sélection...") }
        setStatus(.none, key, value: 0)
    }

    private func startActivity(_ key: String) {
        activityKey = key
        activityFrame = 0
        tickActivity()
        activityTimer?.invalidate()
        activityTimer = repeating(ACTIVITY_INTERVAL) { [weak self] in self?.tickActivity() }
    }

    private func stopActivity() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func tickActivity() {
        guard let key = activityKey else { return }
        let frame = ACTIVITY_FRAMES[activityFrame % ACTIVITY_FRAMES.count]
        activityFrame += 1
        progressText = L(key, ["frame": frame, "s": Int(STALL_SECONDS)])
            .replacingOccurrences(of: "%p%", with: "\(progress)%")
    }

    // MARK: Dialogues

    /// Dialogue à boutons libellés dans la langue active ; renvoie l'index du bouton choisi.
    /// Le premier bouton est celui par défaut (Entrée).
    private func ask(_ style: NSAlert.Style, _ title: String, _ text: String, _ buttons: [String],
                     destructive: Int? = nil, detail: String = "") async -> Int {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        for (i, label) in buttons.enumerated() {
            let b = alert.addButton(withTitle: label)
            if i == destructive { b.hasDestructiveAction = true }
        }
        if !detail.isEmpty { alert.accessoryView = detailsView(detail) }
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil, window.isVisible {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? index : 0
    }

    private func ok(_ style: NSAlert.Style, _ title: String, _ text: String, detail: String = "") async {
        _ = await ask(style, title, text, [L("OK")], detail: detail)
    }

    /// Liste des problèmes, en texte sélectionnable et défilant.
    private func detailsView(_ detail: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = Socle.T.mono.nsFont
        text.textColor = NSColor(Socle.C.text)
        text.backgroundColor = NSColor(Socle.C.bgSunken)
        text.textContainerInset = NSSize(width: Socle.M.space2, height: Socle.M.space2)
        text.autoresizingMask = [.width]
        text.string = detail
        scroll.documentView = text
        return scroll
    }

    // MARK: Déroulement

    private func setRunning(_ value: Bool) {
        running = value
        fuseEnabled = true
    }

    func fuseClicked() {
        if running { Task { await stopFusion() } } else { Task { await startFusion() } }
    }

    private func startFusion() async {
        if source.isEmpty || destination.isEmpty {
            await ok(.warning, L("Attention"), L("Veuillez choisir un dossier source et un dossier de destination."))
            return
        }
        setRunning(true)
        setStatus(.none, value: 0)
        startActivity(N_("Analyse des dossiers  {frame}"))

        let stop = StopFlag(), src = source, dest = destination
        analysisStop = stop
        let result: Result<Inventory, AnalysisError> = await withCheckedContinuation { cont in
            Thread.detachNewThread { cont.resume(returning: analyse(src: src, dest: dest, stop: stop)) }
        }
        stopActivity()
        guard running, analysisStop === stop, !stop.stopped else { return }  // analyse arrêtée entre-temps
        analysisStop = nil
        switch result {
        case .failure(let e):
            if case .message(let message) = e {
                setRunning(false)
                setStatus(.danger, N_("Fusion impossible"), value: 0)
                await ok(.critical, L("Fusion impossible"), message)
            }
        case .success(let inv):
            await confirmAndRun(inv)
        }
    }

    private func confirmAndRun(_ inv: Inventory) async {
        updateFreeSpace()
        showSourceSize(source, inv.total, inv.count)

        var lines = [L("À copier : {what}",
                       ["what": "\(fmtSize(inv.total)) (\(P(inv.count, "{n} fichier", "{n} fichiers")))"])]
        if inv.overwritten > 0 {
            lines.append(P(inv.overwritten, "Dont {n} fichier de même nom remplacé ({size} actuellement)",
                           "Dont {n} fichiers de même nom remplacés ({size} actuellement)",
                           ["size": fmtSize(inv.overwrittenBytes)]))
        }
        if let free = inv.free {
            lines.append(L("Espace libre sur la destination : {size}", ["size": fmtSize(free)]))
        }
        if inv.sameVolume {
            lines.append(L("Même volume : les fichiers sont clonés, sans occuper d'espace supplémentaire."))
        }
        let problems = inv.unreadable.count + inv.skipped.count
        if problems > 0 {
            lines.append(P(problems, "{n} élément de la source ne pourra pas être copié (illisible).",
                           "{n} éléments de la source ne pourront pas être copiés (illisibles)."))
        }
        let summary = lines.joined(separator: "\n")

        // Contrôle de l'espace disponible (inutile sur un même volume : clones APFS)
        if let free = inv.free, !inv.sameVolume, inv.needed > free {
            let choice = await ask(
                .warning, L("Espace insuffisant"),
                L("Il faut environ {needed} sur le volume de destination, il reste {free}.\n\nLibérez au moins {missing} ou choisissez une autre destination.\nSi la fusion est lancée quand même, elle s'arrêtera quand le volume sera plein.",
                  ["needed": fmtSize(inv.needed), "free": fmtSize(free), "missing": fmtSize(inv.needed - free)]),
                [L("Annuler"), L("Fusionner quand même")])
            if choice != 1 {
                setRunning(false)
                setStatus(.warning, N_("Espace insuffisant"), value: 0)
                return
            }
        }

        // Fenêtre d'avertissement avant d'écraser
        let choice = await ask(
            .informational, L("Confirmation de fusion"),
            L("Fusionner le contenu de :\n{src}\n\nVers la racine du dossier :\n{dest}\n\n{summary}\n\nLes fichiers existants portant le même nom seront remplacés. Le dossier source n'est pas modifié.",
              ["src": source, "dest": destination, "summary": summary]),
            [L("Annuler"), L("Fusionner")])
        if choice != 1 {
            setRunning(false)
            setStatus(.none, N_("Fusion annulée"), value: 0)
            return
        }

        let runner = FusionRunner(src: source, dest: destination, inventory: inv) { message in
            Task { @MainActor in await self.onProblem(message) }
        }
        self.runner = runner
        lastUnits = -1
        lastChange = Date()
        stalled = false
        runner.start { outcome in
            Task { @MainActor in await self.fusionDone(outcome) }
        }
        startActivity("%p%  {frame}")
        progressTimer = repeating(PROGRESS_INTERVAL) { [weak self] in self?.pollProgress() }
    }

    /// Avancement lu sur le moteur, et surveillance des blocages.
    private func pollProgress() {
        guard let engine = runner?.engine else { return }
        let units = engine.progressUnits()
        progress = min(99, Int(units * 100 / max(engine.totalUnits, 1)))

        let now = Date()
        if units != lastUnits || engine.paused {
            lastUnits = units
            lastChange = now
            if stalled {
                stalled = false
                if !engine.stopping { activityKey = "%p%  {frame}" }
                setStatus(.none)
            }
        } else if !stalled && now.timeIntervalSince(lastChange) >= STALL_SECONDS {
            stalled = true
            activityKey = N_("%p%  {frame}  ! Aucune progression depuis {s} s")
            setStatus(.stalled)
            tickActivity()
        }
    }

    private func stopFusion() async {
        guard let runner else {
            // Arrêt pendant l'analyse
            analysisStop?.stop()
            analysisStop = nil
            stopActivity()
            setRunning(false)
            setStatus(.none, N_("Fusion annulée"), value: 0)
            return
        }
        let choice = await ask(
            .informational, L("Arrêter la fusion"),
            L("Arrêter la fusion maintenant ?\n\nLes fichiers déjà copiés restent dans la destination ; le fichier en cours de copie n'est pas conservé."),
            [L("Continuer la fusion"), L("Arrêter")], destructive: 1)
        if choice == 1 && self.runner === runner {
            fuseEnabled = false
            activityKey = N_("Arrêt en cours  {frame}")
            runner.stop()
        }
    }

    private func onProblem(_ message: String) async {
        guard let runner else { return }
        stopActivity()
        setStatus(.stalled)
        progressText = L("%p%  ! En pause").replacingOccurrences(of: "%p%", with: "\(progress)%")
        let choice = await ask(
            .warning, L("Problème de copie"),
            L("Un élément n'a pas pu être copié :\n{message}\n\nLa fusion est en pause. Les autres fichiers peuvent être copiés normalement.",
              ["message": message]),
            [L("Ignorer et continuer"), L("Ignorer tous les problèmes"), L("Arrêter la fusion")], destructive: 2)
        guard self.runner === runner else { return }
        if choice == 2 {
            fuseEnabled = false
            activityKey = N_("Arrêt en cours  {frame}")
        }
        setStatus(.none)
        runner.resolve([Decision.skip, .skipAll, .stop][choice])
        activityTimer?.invalidate()
        activityTimer = repeating(ACTIVITY_INTERVAL) { [weak self] in self?.tickActivity() }
    }

    private func fusionDone(_ outcome: Outcome) async {
        guard let runner else { return }
        let engine = runner.engine!
        stopActivity()
        progressTimer?.invalidate()
        self.runner = nil
        setRunning(false)
        updateFreeSpace()
        let errors = engine.errors
        let detail = errors.joined(separator: "\n")

        switch outcome {
        case .success:
            setStatus(.success, N_("Fusion terminée"), value: 100)
        case .partial:
            let n = errors.count
            setStatus(.warning, n <= 1 ? N_("Terminée avec {n} problème") : N_("Terminée avec {n} problèmes"),
                      value: 100, ["n": fmtInt(n)])
            await ok(.warning, L("Fusion terminée avec des problèmes"),
                     P(n, "La fusion est terminée, mais {n} élément n'a pas pu être copié.\nTous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails.",
                       "La fusion est terminée, mais {n} éléments n'ont pas pu être copiés.\nTous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails."),
                     detail: detail)
        case .stopped:
            setStatus(.warning, N_("Fusion arrêtée"))
            await ok(.informational, L("Fusion arrêtée"),
                     L("Fusion arrêtée. Les fichiers déjà copiés restent dans la destination."), detail: detail)
        case .failed:
            setStatus(.danger, N_("Erreur de fusion"), value: 0)
            await ok(.critical, L("Erreur"), engine.fatalMessage ?? L("La fusion a échoué."), detail: detail)
        }
    }

    // MARK: Fermeture

    /// Fusion en cours : demande confirmation, puis l'arrête proprement avant de quitter.
    func confirmQuit() async -> Bool {
        guard let runner else { return true }
        let choice = await ask(
            .informational, L("Fusion en cours"),
            L("Une fusion est en cours. L'arrêter et quitter ?\n\nLes fichiers déjà copiés restent dans la destination."),
            [L("Continuer la fusion"), L("Arrêter et quitter")], destructive: 1)
        guard choice == 1 else { return false }
        runner.stop()
        waitUntilStopped(runner)
        cancelBackgroundWork()
        return true
    }

    func cancelBackgroundWork() {
        sizeStop?.stop()
        analysisStop?.stop()
    }
}

/// Attend la fin de la copie (le fichier en cours est abandonné), 30 s au plus.
private func waitUntilStopped(_ runner: FusionRunner) {
    _ = runner.finished.wait(timeout: .now() + 30)
}

enum AnalysisError: Error {
    case stopped
    case message(String)
}

/// Contrôles préalables et inventaire, hors du fil de l'interface.
func analyse(src: String, dest: String, stop: StopFlag) -> Result<Inventory, AnalysisError> {
    if !isDirectory(src) {
        return .failure(.message(L("Le dossier source est introuvable.\nVérifiez que son volume est bien connecté.")))
    }
    if !isDirectory(dest) {
        return .failure(.message(L("Le dossier de destination est introuvable.\nVérifiez que son volume est bien connecté.")))
    }
    if isInside(dest, src) {
        return .failure(.message(L("La destination se trouve dans le dossier source.\nChoisissez une destination située en dehors de la source.")))
    }
    if access(dest, W_OK) != 0 {
        return .failure(.message(L("Impossible d'écrire dans le dossier de destination.\nVérifiez vos droits sur ce dossier ou choisissez-en un autre.")))
    }
    do {
        return .success(try scan(src: src, dest: dest, shouldStop: { stop.stopped }))
    } catch is Stopped {
        return .failure(.stopped)
    } catch {
        return .failure(.message(L("Impossible d'analyser les dossiers : {e}", ["e": error.localizedDescription])))
    }
}

func isInside(_ path: String, _ folder: String) -> Bool {
    let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let f = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
    return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
}

/// « 12,4 Go · 1 284 fichiers ».
func sizeAndCount(_ bytes: Int64, _ count: Int) -> String {
    "\(fmtSize(bytes)) · \(P(count, "{n} fichier", "{n} fichiers"))"
}
