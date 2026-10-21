// Réplique web de src/fusion_dossiers.py : mêmes textes (mêmes clés de traduction), mêmes états,
// fusion simulée.
import "./style.css";
import { L, P, fmtInt, fmtSize, LANGS, getLang, setLang, systemLang } from "./i18n.js";

const $ = (sel) => document.querySelector(sel);

const state = { source: "", destination: "", running: false, stopRequested: false, srcSize: null };

const els = {
  dest: $("#pick-dest"),
  src: $("#pick-src"),
  destDetail: $("#pick-dest .picker__detail"),
  srcDetail: $("#pick-src .picker__detail"),
  fuse: $("#fuse"),
  progress: $("#progress"),
  chunk: $("#progress .progress__chunk"),
  label: $("#progress .progress__label"),
  lang: $("#sim-lang"),
  simError: $("#sim-error"),
  simStall: $("#sim-stall"),
  simSpace: $("#sim-space"),
};

// Chemins d'exemple proposés à la place du sélecteur de dossier macOS
const SAMPLE_PATHS = {
  dest: ["/Users/stephan/Documents/Projets", "/Volumes/SKYRIM/Mods/Data", "/Users/stephan/Desktop/Archive 2026"],
  src: ["/Users/stephan/Downloads/Mise à jour", "/Volumes/SKYRIM/Mods/Patch FR/Data", "/Users/stephan/Desktop/Nouveaux fichiers"],
};
const sampleIndex = { dest: 0, src: 0 };

// Chiffres simulés de l'analyse
const SIM = { files: 1284, total: 48.6e9, overwritten: 56, overwrittenBytes: 3.1e9, free: 941e9, freeLow: 22.4e9 };
const SIM_ERRORS = [
  ["Textures/armor/cuirasse.dds", "accès refusé"],
  ["Meshes/clutter", "accès refusé"],
  ["Sound/fx/porte.wav", "fichier introuvable"],
];
const problem = (path, reason) => L("{path} : {reason}", { path, reason: L(reason) });

// Points animés après le pourcentage : montrent que la fusion tourne même si le % stagne
const ACTIVITY_FRAMES = ["● ○ ○", "○ ● ○", "○ ○ ●", "○ ● ○"];
const ACTIVITY_INTERVAL_MS = 250;
const STALL_SECONDS = 30;
// key : gabarit (clé de traduction) avec %p% et {frame} ; status : texte fixe (clé + paramètres)
const activity = { frame: 0, pct: 0, key: null, timer: null };
let status = { kind: "none", key: "En attente de sélection...", kw: {} };

// Symbole devant chaque statut : la couleur ne porte jamais seule l'information (Socle)
const STATUS_SYMBOLS = { success: "✓", warning: "!", danger: "✕" };

// --- Barre de progression ---

function renderActivity() {
  const frame = ACTIVITY_FRAMES[activity.frame++ % ACTIVITY_FRAMES.length];
  els.label.textContent = L(activity.key, { frame, s: STALL_SECONDS }).replace("%p%", activity.pct);
  els.chunk.style.width = `${activity.pct}%`;
}

function startActivity(key) {
  activity.key = key;
  activity.frame = 0;
  stopActivity();
  renderActivity();
  activity.timer = setInterval(renderActivity, ACTIVITY_INTERVAL_MS);
}

function stopActivity() {
  clearInterval(activity.timer);
  activity.timer = null;
}

function setBarStatus(kind) {
  for (const s of ["success", "warning", "stalled", "danger"]) els.progress.classList.toggle(`is-${s}`, kind === s);
}

function renderStatus() {
  const text = L(status.key, status.kw).replace("%p%", activity.pct);
  const symbol = STATUS_SYMBOLS[status.kind];
  els.label.textContent = symbol ? `${symbol}  ${text}` : text;
}

function setProgress(value, key, kind = "none", kw = {}) {
  activity.key = null;
  activity.pct = value;
  status = { kind, key, kw };
  els.chunk.style.width = `${value}%`;
  els.progress.setAttribute("aria-valuenow", value);
  setBarStatus(kind);
  renderStatus();
}

function updateStatus() {
  if (state.source && state.destination) setProgress(0, "Prêt à fusionner");
  else if (state.source) setProgress(0, "Sélectionnez la destination...");
  else if (state.destination) setProgress(0, "Sélectionnez la source...");
  else setProgress(0, "En attente de sélection...");
}

// --- Sélecteurs ---

function formatPath(path, maxChars = 32) {
  if (!path || path.length <= maxChars) return path;
  const half = Math.floor((maxChars - 3) / 2);
  return `${path.slice(0, half)}...${path.slice(-half)}`;
}

const freeSpace = () => (els.simSpace.checked ? SIM.freeLow : SIM.free);
const sizeAndCount = (total, count) => `${fmtSize(total)} · ${P(count, "{n} fichier", "{n} fichiers")}`;

function renderDetails() {
  els.destDetail.textContent = state.destination ? L("{size} libres sur le volume", { size: fmtSize(freeSpace()) }) : " ";
  if (!state.source) els.srcDetail.textContent = " ";
  else if (!state.srcSize) els.srcDetail.textContent = L("Calcul de la taille...");
  else els.srcDetail.textContent = sizeAndCount(...state.srcSize);
}

function setPath(button, folder) {
  button.querySelector(".picker__path").textContent = formatPath(folder);
  button.classList.add("is-filled");
  button.title = folder;
}

function choose(kind) {
  const list = SAMPLE_PATHS[kind];
  const folder = list[sampleIndex[kind]++ % list.length];
  if (kind === "dest") {
    state.destination = folder;
    setPath(els.dest, folder);
  } else {
    state.source = folder;
    state.srcSize = null;
    setPath(els.src, folder);
    // Taille calculée en arrière-plan, comme dans l'appli
    setTimeout(() => {
      if (state.source === folder) {
        state.srcSize = [SIM.total, SIM.files];
        renderDetails();
      }
    }, 600);
  }
  renderDetails();
  updateStatus();
}

// --- Langue ---
// Comme l'appli : langue du système (ici celle du navigateur), sans réglage dans l'interface.
// La barre « Preview » permet de simuler une autre langue système.

function setLanguage(choice) {
  setLang(choice === "auto" ? systemLang() : choice);
  applyTexts();
}

function buildLangSelect() {
  const sys = systemLang();
  els.lang.replaceChildren(
    new Option(`Système (${LANGS[sys]})`, "auto"),
    ...Object.entries(LANGS).map(([code, name]) => new Option(name, code)),
  );
}

function applyTexts() {
  const code = getLang();
  document.documentElement.lang = code;
  $(".brandbar__meta").textContent = L("Les fichiers de même nom sont remplacés dans la destination.");
  els.src.querySelector(".picker__title").textContent = L("SOURCE");
  els.dest.querySelector(".picker__title").textContent = L("DESTINATION");
  if (!state.source) els.src.querySelector(".picker__path").textContent = L("Choisir un dossier");
  if (!state.destination) els.dest.querySelector(".picker__path").textContent = L("Choisir un dossier");
  renderDetails();
  els.fuse.textContent = state.running ? L("ARRÊTER") : L("FUSIONNER");
  if (activity.key) renderActivity();
  else renderStatus();
}

// --- Dialogues ---

// Libellé fourni par Qt dans l'appli (traductions qtbase), absent de la table de l'appli
const QT_DETAILS = { fr: "Montrer les détails…", en: "Show Details…", it: "Mostra dettagli…", es: "Mostrar detalles…" };

// Renvoie une promesse résolue avec l'index du bouton cliqué.
// Le bouton `defaultIndex` reçoit le focus et répond à Échap, comme dans l'appli Qt.
function dialog({ title, body, buttons, defaultIndex = 0, details = "", danger = false }) {
  const modal = $("#modal");
  $("#modal-title").textContent = title;
  $("#modal-body").textContent = body;
  const det = $("#modal-details");
  det.hidden = !details;
  det.open = false;
  det.querySelector("summary").textContent = QT_DETAILS[getLang()];
  $("#modal-details-text").textContent = details;
  modal.querySelector(".sc-dialog").classList.toggle("sc-dialog--danger", danger);
  const actions = $("#modal-actions");
  actions.replaceChildren();
  return new Promise((resolve) => {
    const close = (index) => {
      modal.hidden = true;
      document.removeEventListener("keydown", onKey);
      resolve(index);
    };
    const onKey = (e) => e.key === "Escape" && close(defaultIndex);
    buttons.forEach((b, i) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `sc-btn sc-btn--${i === defaultIndex ? "primary" : "secondary"}`;
      btn.textContent = b;
      btn.addEventListener("click", () => close(i));
      actions.append(btn);
    });
    document.addEventListener("keydown", onKey);
    modal.hidden = false;
    actions.children[defaultIndex].focus();
  });
}

// --- Déroulement simulé ---

function setRunning(running) {
  state.running = running;
  els.dest.disabled = running;
  els.src.disabled = running;
  els.fuse.disabled = false;
  els.fuse.textContent = running ? L("ARRÊTER") : L("FUSIONNER");
  els.fuse.classList.toggle("is-running", running);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function startFusion() {
  if (!state.source || !state.destination) {
    await dialog({ title: L("Attention"), body: L("Veuillez choisir un dossier source et un dossier de destination."), buttons: [L("OK")] });
    return;
  }

  // Analyse
  setRunning(true);
  state.stopRequested = false;
  setBarStatus("none");
  activity.pct = 0;
  startActivity("Analyse des dossiers  {frame}");
  await sleep(1200);
  stopActivity();
  if (!state.running) return;

  const free = freeSpace();
  const needed = SIM.total - SIM.overwrittenBytes + 4.2e9;
  state.srcSize = [SIM.total, SIM.files];
  renderDetails();
  const summary = [
    L("À copier : {what}", { what: `${fmtSize(SIM.total)} (${P(SIM.files, "{n} fichier", "{n} fichiers")})` }),
    P(SIM.overwritten, "Dont {n} fichier de même nom remplacé ({size} actuellement)",
      "Dont {n} fichiers de même nom remplacés ({size} actuellement)", { size: fmtSize(SIM.overwrittenBytes) }),
    L("Espace libre sur la destination : {size}", { size: fmtSize(free) }),
  ].join("\n");

  if (needed > free) {
    const choice = await dialog({
      title: L("Espace insuffisant"),
      body: L("Il faut environ {needed} sur le volume de destination, il reste {free}.\n\n" +
        "Libérez au moins {missing} ou choisissez une autre destination.\n" +
        "Si la fusion est lancée quand même, elle s'arrêtera quand le volume sera plein.",
      { needed: fmtSize(needed), free: fmtSize(free), missing: fmtSize(needed - free) }),
      buttons: [L("Annuler"), L("Fusionner quand même")],
    });
    if (choice !== 1) {
      setRunning(false);
      setProgress(0, "Espace insuffisant", "warning");
      return;
    }
  }

  const ok = await dialog({
    title: L("Confirmation de fusion"),
    body: L("Fusionner le contenu de :\n{src}\n\nVers la racine du dossier :\n{dest}\n\n{summary}\n\n" +
      "Les fichiers existants portant le même nom seront remplacés. Le dossier source n'est pas modifié.",
    { src: state.source, dest: state.destination, summary }),
    buttons: [L("Annuler"), L("Fusionner")],
  });
  if (ok !== 1) {
    setRunning(false);
    setProgress(0, "Fusion annulée");
    return;
  }

  // Copie simulée
  const errors = [];
  const errorAt = els.simError.checked ? [25, 48, 71] : [];
  let stallAt = els.simStall.checked ? 35 : null;
  const diskFullAt = needed > free ? Math.floor((free / needed) * 100) : null;
  let ignoreAll = false;
  let pct = 0;
  activity.pct = 0;
  startActivity("%p%  {frame}");

  while (pct < 100) {
    if (state.stopRequested) {
      return finish("stopped", L("Fusion arrêtée. Les fichiers déjà copiés restent dans la destination."), errors);
    }
    if (diskFullAt !== null && pct >= diskFullAt) {
      errors.push(problem("Textures/landscape/terrain.dds", "espace disque insuffisant"));
      return finish("failed", L("Le volume de destination est plein.\nLibérez de l'espace puis relancez la fusion : " +
        "les fichiers déjà copiés seront simplement remplacés."), errors);
    }
    if (stallAt !== null && pct >= stallAt) {
      // Blocage : plus rien n'avance pendant un moment (accéléré dans la preview)
      activity.key = "%p%  {frame}  ! Aucune progression depuis {s} s";
      setBarStatus("stalled");
      for (let i = 0; i < 20 && !state.stopRequested; i++) await sleep(200);
      if (!state.stopRequested) activity.key = "%p%  {frame}";
      setBarStatus("none");
      stallAt = null;
      continue;
    }
    if (errorAt.length && pct >= errorAt[0]) {
      errorAt.shift();
      const message = problem(...SIM_ERRORS[errors.length % SIM_ERRORS.length]);
      errors.push(message);
      if (!ignoreAll) {
        stopActivity();
        els.label.textContent = L("%p%  ! En pause").replace("%p%", activity.pct);
        setBarStatus("stalled");
        const choice = await dialog({
          title: L("Problème de copie"),
          body: L("Un élément n'a pas pu être copié :\n{message}\n\n" +
            "La fusion est en pause. Les autres fichiers peuvent être copiés normalement.", { message }),
          buttons: [L("Arrêter la fusion"), L("Ignorer tous les problèmes"), L("Ignorer et continuer")],
          defaultIndex: 2,
        });
        setBarStatus("none");
        if (choice === 0) state.stopRequested = true;
        if (choice === 1) ignoreAll = true;
        startActivity(state.stopRequested ? "Arrêt en cours  {frame}" : "%p%  {frame}");
      }
      continue;
    }
    await sleep(120);
    pct = Math.min(100, pct + 1 + Math.floor(Math.random() * 3));
    activity.pct = Math.min(pct, 99);
  }

  if (errors.length) return finish("partial", "", errors);
  return finish("success", L("Fusion terminée avec succès."), errors);
}

async function finish(result, message, errors) {
  stopActivity();
  setRunning(false);
  const details = errors.join("\n");
  const ok = [L("OK")];
  if (result === "success") {
    setProgress(100, "Fusion terminée", "success");
  } else if (result === "partial") {
    const n = errors.length;
    setProgress(100, n <= 1 ? "Terminée avec {n} problème" : "Terminée avec {n} problèmes", "warning", { n: fmtInt(n) });
    await dialog({
      title: L("Fusion terminée avec des problèmes"),
      body: P(n,
        "La fusion est terminée, mais {n} élément n'a pas pu être copié.\n" +
        "Tous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails.",
        "La fusion est terminée, mais {n} éléments n'ont pas pu être copiés.\n" +
        "Tous les autres fichiers ont été fusionnés.\n\nLa liste se trouve dans les détails."),
      buttons: ok,
      details,
    });
  } else if (result === "stopped") {
    setProgress(activity.pct, "Fusion arrêtée", "warning");
    await dialog({ title: L("Fusion arrêtée"), body: message, buttons: ok, details });
  } else {
    setProgress(0, "Erreur de fusion", "danger");
    await dialog({ title: L("Erreur"), body: message, buttons: ok, details, danger: true });
  }
}

async function stopFusion() {
  if (activity.key && !activity.key.includes("%p%")) {
    // Arrêt pendant l'analyse
    stopActivity();
    setRunning(false);
    setProgress(0, "Fusion annulée");
    return;
  }
  const choice = await dialog({
    title: L("Arrêter la fusion"),
    body: L("Arrêter la fusion maintenant ?\n\nLes fichiers déjà copiés restent dans la destination ; " +
      "le fichier en cours de copie n'est pas conservé."),
    buttons: [L("Continuer la fusion"), L("Arrêter")],
  });
  if (choice === 1 && state.running) {
    els.fuse.disabled = true;
    activity.key = "Arrêt en cours  {frame}";
    state.stopRequested = true;
  }
}

function reset() {
  stopActivity();
  state.stopRequested = true;
  state.source = "";
  state.destination = "";
  state.srcSize = null;
  for (const btn of [els.dest, els.src]) {
    btn.classList.remove("is-filled");
    btn.removeAttribute("title");
  }
  setRunning(false);
  applyTexts();
  updateStatus();
}

function toggleTheme() {
  const root = document.documentElement;
  const light = root.dataset.theme !== "light";
  root.dataset.theme = light ? "light" : "dark";
  $("#toggle-theme").textContent = light ? "Thème sombre" : "Thème clair";
}

els.dest.addEventListener("click", () => choose("dest"));
els.src.addEventListener("click", () => choose("src"));
els.fuse.addEventListener("click", () => (state.running ? stopFusion() : startFusion()));
els.simSpace.addEventListener("change", renderDetails);
els.lang.addEventListener("change", () => setLanguage(els.lang.value));
$("#reset").addEventListener("click", reset);
$("#toggle-theme").addEventListener("click", toggleTheme);

buildLangSelect();
setLang(systemLang());
applyTexts();
