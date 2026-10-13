"""Vérifie que chaque texte passé à L()/N_()/P() possède une traduction complète."""
import ast
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "src"
sys.path.insert(0, str(ROOT))

import i18n  # noqa: E402

FIELD_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}")


def collect_keys() -> set:
    keys = set()
    for path in ROOT.glob("*.py"):
        if path.name.startswith(("test_", ".")) or path.name in ("i18n_strings.py", "socle_qt.py"):
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)):
                continue
            nargs = {"L": 1, "N_": 1, "P": 3}.get(node.func.id)
            if not nargs:
                continue
            for arg in node.args[:nargs]:
                if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                    keys.add(arg.value)
    return keys


class TestI18n(unittest.TestCase):
    def test_all_keys_translated(self):
        from i18n_strings import TR
        missing = sorted(k for k in collect_keys() if k not in TR)
        self.assertEqual(missing, [], f"{len(missing)} clé(s) sans traduction")
        for k, tr in TR.items():
            self.assertEqual(len(tr), 3, k)
            for lang, t in zip(("en", "it", "es"), tr):
                self.assertTrue(t.strip(), f"{lang} vide : {k}")
                self.assertEqual(set(FIELD_RE.findall(k)), set(FIELD_RE.findall(t)), f"{lang} : {k}")
                self.assertEqual(k.count("%p%"), t.count("%p%"), f"{lang} : {k}")

    def test_no_stale_keys(self):
        from i18n_strings import TR
        stale = sorted(set(TR) - collect_keys())
        self.assertEqual(stale, [], "clés orphelines dans TR")

    def test_switch_and_formats(self):
        try:
            i18n.set_lang("en")
            self.assertEqual(i18n.L("Annuler"), "Cancel")
            self.assertEqual(i18n.fmt_size(12_400_000_000), "12.4 GB")
            self.assertEqual(i18n.P(1, "{n} fichier", "{n} fichiers"), "1 file")
            self.assertEqual(i18n.P(0, "{n} fichier", "{n} fichiers"), "0 files")
            self.assertEqual(i18n.fmt_int(12345), "12,345")
            i18n.set_lang("it")
            self.assertEqual(i18n.fmt_size(12_400_000_000), "12,4 GB")
            self.assertEqual(i18n.fmt_int(12345), "12.345")
            i18n.set_lang("es")
            self.assertEqual(i18n.L("Annuler"), "Cancelar")
        finally:
            i18n.set_lang("fr")
        self.assertEqual(i18n.fmt_size(12_400_000_000), "12,4 Go")
        self.assertEqual(i18n.P(0, "{n} fichier", "{n} fichiers"), "0 fichier")
        self.assertEqual(i18n.fmt_size(1), "1 octet")

    def test_system_lang(self):
        self.assertEqual(i18n.system_lang(["it-IT", "en-US"]), "it")
        self.assertEqual(i18n.system_lang(["de-DE", "es-ES"]), "es")
        self.assertEqual(i18n.system_lang(["de-DE"]), "en")
        self.assertEqual(i18n.system_lang([]), "en")


if __name__ == "__main__":
    unittest.main()
