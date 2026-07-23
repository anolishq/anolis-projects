#!/usr/bin/env bash
#
# install-workbench-pi.sh — one-shot bootstrap for the anolis-workbench on a
# fresh Raspberry Pi OS (Bookworm). The workbench has no ARM desktop build, so
# on the Pi it runs as a local Python server you reach in a browser at :3010.
#
# It installs into an isolated venv (Bookworm marks the system Python
# "externally managed" — PEP 668 — so a bare `pip install` is refused), from the
# pure-python wheel published on PyPI (`anolis_workbench-<ver>-py3-none-any`).
#
# Usage (on the Pi):
#   bash install-workbench-pi.sh            # install + launch
#   bash install-workbench-pi.sh --no-launch
#
set -euo pipefail

VENV="${HOME}/.local/share/anolis-workbench/venv"
BIN_LINK="${HOME}/.local/bin/anolis-workbench"
LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

log() { printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m→ %s\033[0m\n' "$*"; }

# 1. Prereqs: python3 + venv + pip. python3-venv/pip aren't always present on Lite.
if ! command -v python3 >/dev/null; then
  echo "python3 not found — install it first (sudo apt install python3)"; exit 1
fi
if ! python3 -c 'import venv' 2>/dev/null || ! python3 -c 'import ensurepip' 2>/dev/null; then
  warn "installing python3-venv + python3-pip (sudo)"
  sudo apt-get update -qq && sudo apt-get install -y python3-venv python3-pip
fi
log "python3 $(python3 -V 2>&1 | awk '{print $2}')"

# 2. Isolated venv + the workbench from PyPI (pure-python wheel → works on ARM).
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --quiet --upgrade pip
warn "installing anolis-workbench from PyPI…"
"${VENV}/bin/pip" install --quiet --upgrade anolis-workbench
VER="$("${VENV}/bin/anolis-workbench" --version 2>/dev/null || echo '?')"
log "anolis-workbench ${VER} installed at ${VENV}"

# 3. Put a launcher on PATH so the user can just type `anolis-workbench`.
mkdir -p "$(dirname "${BIN_LINK}")"
ln -sf "${VENV}/bin/anolis-workbench" "${BIN_LINK}"
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) : ;;
  *) warn "add ~/.local/bin to PATH:  echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc && source ~/.bashrc" ;;
esac
log "launcher: ${BIN_LINK}  (serves http://127.0.0.1:3010)"

# 4. Launch (opens the default browser at :3010; the Pi needs a desktop session).
if [[ "${LAUNCH}" == "1" ]]; then
  warn "launching — a browser should open at http://127.0.0.1:3010 (Ctrl-C to stop the server)"
  exec "${VENV}/bin/anolis-workbench"
else
  echo "Run it later with:  ${BIN_LINK}   (then open http://127.0.0.1:3010)"
fi
