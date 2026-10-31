#!/usr/bin/env bash
#
# install-workbench-pi.sh — one-shot bootstrap for the anolis-workbench on a
# fresh Raspberry Pi OS (Debian 13, Trixie). The workbench has no ARM desktop
# build, so on the Pi it runs as a local Python server you reach in a browser at
# :3010.
#
# It installs into an isolated venv (Raspberry Pi OS marks the system Python
# "externally managed" — PEP 668 — so a bare `pip install` is refused), from the
# pure-python wheel published on PyPI (`anolis_workbench-<ver>-py3-none-any`).
#
# It installs the workbench version this project revision pins below (#104).
# To install another, set ANOLIS_WORKBENCH_VERSION; the guide was not walked
# with it.
#
# Usage (on the Pi):
#   bash install-workbench-pi.sh            # install + launch
#   bash install-workbench-pi.sh --no-launch
#   ANOLIS_WORKBENCH_VERSION=0.25.0 bash install-workbench-pi.sh
#
set -euo pipefail

# renovate: datasource=pypi depName=anolis-workbench
WORKBENCH_VERSION="0.28.0"

VENV="${HOME}/.local/share/anolis-workbench/venv"
BIN_DIR="${HOME}/.local/bin"
BIN_LINK="${BIN_DIR}/anolis-workbench"
# Every command the anolis-workbench package installs.
COMMANDS=(anolis-workbench anolis-provision anolis-package anolis-validate)
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
VERSION="${ANOLIS_WORKBENCH_VERSION:-${WORKBENCH_VERSION}}"
if [[ "${VERSION}" != "${WORKBENCH_VERSION}" ]]; then
  warn "ANOLIS_WORKBENCH_VERSION=${VERSION}: installing it in place of the pinned ${WORKBENCH_VERSION}"
fi
warn "installing anolis-workbench ${VERSION} from PyPI…"
"${VENV}/bin/pip" install --quiet "anolis-workbench==${VERSION}"
# --version prints "anolis-workbench <version>".
VER="$("${VENV}/bin/anolis-workbench" --version 2>/dev/null || echo 'anolis-workbench ?')"
log "${VER} installed at ${VENV}"

# 3. Put every command on PATH from this venv, so they are one install at one
#    version. A pipx install of the workbench (its README's other route) links
#    the same names into ~/.local/bin; these links replace them.
mkdir -p "${BIN_DIR}"
for cmd in "${COMMANDS[@]}"; do
  ln -sf "${VENV}/bin/${cmd}" "${BIN_DIR}/${cmd}"
done
log "on PATH from this venv: ${COMMANDS[*]}"
if command -v pipx >/dev/null && pipx list --short 2>/dev/null | grep -qE '^anolis-workbench( |$)'; then
  warn "pipx also has anolis-workbench installed; ~/.local/bin now points at this venv. Remove the pipx copy with: pipx uninstall anolis-workbench"
fi
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
