#!/bin/bash
# Compile fOLDERFUSE (version Swift, dossier macos/) : « fOLDERFUSE.app » à la racine du projet.
# Appelé par _tools/build_all.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/macos/build_app.sh" "$@"
