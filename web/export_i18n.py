"""Exporte la table de traductions de l'appli (src/i18n_strings.py) pour la preview web.

Lancé automatiquement avant `npm run dev` (script « predev ») : la preview utilise
exactement les mêmes textes que l'appli, sans copie à maintenir à la main.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "src"))
from i18n_strings import TR  # noqa: E402

out = HERE / "src" / "i18n.json"
out.write_text(json.dumps({k: list(v) for k, v in TR.items()}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
print(f"{len(TR)} traductions exportées vers {out.relative_to(HERE)}")
