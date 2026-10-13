"""Internationalisation : français (source), anglais, italien, espagnol.

Même principe que les autres applis (sKYCRASH) : le texte français sert de clé.
L("Texte {x}", x=1) renvoie la traduction de la langue active, ou le français si elle
manque. Les traductions vivent dans i18n_strings.TR sous la forme {texte_fr: (en, it, es)}.
Module sans dépendance Qt (utilisé aussi par le moteur de copie).
"""
from __future__ import annotations

LANGS = {"fr": "Français", "en": "English", "it": "Italiano", "es": "Español"}
FLAGS = {"fr": "🇫🇷", "en": "🇬🇧", "it": "🇮🇹", "es": "🇪🇸"}
_INDEX = {"en": 0, "it": 1, "es": 2}
_lang = "fr"

# Séparateurs des nombres et unités de taille (décimales, comme le Finder)
_THOUSANDS = {"fr": "\u00a0", "en": ",", "it": ".", "es": "."}
_DECIMAL = {"fr": ",", "en": ".", "it": ",", "es": ","}
_UNITS = {
    "fr": ("Ko", "Mo", "Go", "To"),
    "en": ("KB", "MB", "GB", "TB"),
    "it": ("KB", "MB", "GB", "TB"),
    "es": ("KB", "MB", "GB", "TB"),
}


def system_lang(preferred: list[str], default: str = "en") -> str:
    """Première langue prise en charge parmi les langues préférées du système
    (codes « fr-FR », « en_US »…), sinon `default`."""
    for code in preferred:
        code = (code or "")[:2].lower()
        if code in LANGS:
            return code
    return default


def set_lang(code: str) -> str:
    global _lang
    _lang = code if code in LANGS else "fr"
    return _lang


def get_lang() -> str:
    return _lang


def N_(text: str) -> str:
    """Marque un texte à traduire sans le traduire (déclarations au niveau module)."""
    return text


def L(text: str, **kw) -> str:
    """Traduit `text` (clé française) et applique str.format(**kw) si des paramètres sont fournis."""
    out = text
    if _lang != "fr":
        try:
            from i18n_strings import TR
            tr = TR.get(text)
            if tr:
                out = tr[_INDEX[_lang]] or text
        except ImportError:
            pass
    if not kw:
        return out
    try:
        return out.format(**kw)
    except (KeyError, IndexError, ValueError):
        return text.format(**kw)


def P(n: int, one: str, many: str, **kw) -> str:
    """Singulier ou pluriel selon `n` (en français, 0 et 1 sont au singulier).
    `{n}` reçoit le nombre formaté selon la langue."""
    singular = n <= 1 if _lang == "fr" else n == 1
    return L(one if singular else many, n=fmt_int(n), **kw)


def fmt_int(n: int) -> str:
    """12345 → « 12 345 » (fr), « 12,345 » (en), « 12.345 » (it, es)."""
    return f"{n:,}".replace(",", _THOUSANDS[_lang])


def fmt_size(n: float) -> str:
    """Taille lisible en unités décimales : « 12,4 Go », « 12.4 GB »…"""
    if n < 1000:
        return P(int(n), "{n} octet", "{n} octets")
    for unit in _UNITS[_lang]:
        n /= 1000
        if n < 1000 or unit == _UNITS[_lang][-1]:
            return f"{n:.1f}".replace(".", _DECIMAL[_lang]) + f" {unit}"
