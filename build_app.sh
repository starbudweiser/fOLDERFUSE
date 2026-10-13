#!/bin/bash
# Compile l'application macOS "fOLDERFUSE.app" à la racine du projet
# et supprime tous les fichiers/dossiers temporaires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="fOLDERFUSE"
ENTRY="src/fusion_dossiers.py"
ICON="assets/icon.icns"
VENV=".venv"
TMP_DIR=".build_tmp"

[[ -f "$ENTRY" ]] || { echo "❌ Introuvable : $ENTRY" >&2; exit 1; }
[[ -f "$ICON" ]]  || { echo "❌ Introuvable : $ICON" >&2; exit 1; }

# Environnement virtuel
if [[ ! -x "$VENV/bin/python" ]]; then
    echo "→ Création de l'environnement virtuel"
    python3 -m venv "$VENV"
fi
PY="$VENV/bin/python"

echo "→ Installation des dépendances"
"$PY" -m pip install --quiet -r requirements.txt pyinstaller

cleanup() {
    rm -rf "$TMP_DIR" dist build ./*.spec
    find . -path "./$VENV" -prune -o -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find . -path "./$VENV" -prune -o -name ".DS_Store" -type f -delete 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$APP_NAME.app"

echo "→ Compilation"
"$PY" -m PyInstaller \
    --noconfirm \
    --windowed \
    --name "$APP_NAME" \
    --icon "$ROOT/$ICON" \
    --distpath "$TMP_DIR/dist" \
    --workpath "$TMP_DIR/work" \
    --specpath "$TMP_DIR" \
    "$ROOT/$ENTRY"

mv "$TMP_DIR/dist/$APP_NAME.app" "$ROOT/$APP_NAME.app"
"$(cd "$ROOT/.." && pwd)/_tools/sign_app.sh" "$ROOT/$APP_NAME.app"  # signature stable (_tools)

echo "✓ Application créée : $ROOT/$APP_NAME.app"
