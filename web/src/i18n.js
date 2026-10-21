// Équivalent web de macos/Sources/FusionCore/I18n.swift : le texte français sert de clé.
// La table est celle de l'appli : i18n/strings.json, {texte_fr: [en, it, es]}.
import TR from "../../i18n/strings.json";

export const LANGS = { fr: "Français", en: "English", it: "Italiano", es: "Español" };
const INDEX = { en: 0, it: 1, es: 2 };
const THOUSANDS = { fr: " ", en: ",", it: ".", es: "." };
const DECIMAL = { fr: ",", en: ".", it: ",", es: "," };
const UNITS = { fr: ["Ko", "Mo", "Go", "To"], en: ["KB", "MB", "GB", "TB"], it: ["KB", "MB", "GB", "TB"], es: ["KB", "MB", "GB", "TB"] };

let lang = "fr";

export const getLang = () => lang;
export const setLang = (code) => (lang = code in LANGS ? code : "fr");

/** Première langue prise en charge parmi celles du navigateur (comme la langue du Mac dans l'appli). */
export function systemLang(preferred = navigator.languages || [navigator.language], fallback = "en") {
  for (const code of preferred) {
    const c = (code || "").slice(0, 2).toLowerCase();
    if (c in LANGS) return c;
  }
  return fallback;
}

export function L(text, kw = {}) {
  let out = text;
  if (lang !== "fr") out = TR[text]?.[INDEX[lang]] || text;
  return out.replace(/\{(\w+)\}/g, (m, k) => (k in kw ? kw[k] : m));
}

/** Singulier ou pluriel selon n (en français, 0 et 1 sont au singulier). */
export function P(n, one, many, kw = {}) {
  const singular = lang === "fr" ? n <= 1 : n === 1;
  return L(singular ? one : many, { ...kw, n: fmtInt(n) });
}

export const fmtInt = (n) => String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, THOUSANDS[lang]);

export function fmtSize(n) {
  if (n < 1000) return P(n, "{n} octet", "{n} octets");
  const units = UNITS[lang];
  for (const unit of units) {
    n /= 1000;
    if (n < 1000 || unit === units[units.length - 1]) return `${n.toFixed(1).replace(".", DECIMAL[lang])} ${unit}`;
  }
}
