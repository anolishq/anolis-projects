#!/usr/bin/env bash
#
# install-run-heartbeat.sh: install the run heartbeat on the runtime host.
#
# Copies scripts/run_heartbeat.py to /usr/local/libexec/anolis/ and the
# service and timer to /etc/systemd/system/, then reloads systemd. It does not
# enable the timer: do that when the run starts,
#
#   sudo systemctl enable --now run-heartbeat.timer
#
# and disable it when the run ends. It needs /etc/anolis/heartbeat.env, root
# only, holding the check's ping URL as HEARTBEAT_URL=...; it refuses to
# install without it rather than install a heartbeat that cannot ping.
#
#   sudo bash projects/bioreactor-v1/host/install-run-heartbeat.sh
#
# PREFIX (default /) lets the test install into a temporary root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
ENV_FILE="${PREFIX%/}/etc/anolis/heartbeat.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "install-run-heartbeat: ${ENV_FILE} is missing. Create it, root only (0600), with HEARTBEAT_URL=<the check's ping URL>." >&2
  exit 2
fi
if ! grep -q '^HEARTBEAT_URL=.' "${ENV_FILE}"; then
  echo "install-run-heartbeat: ${ENV_FILE} has no HEARTBEAT_URL=... line." >&2
  exit 2
fi
mode="$(stat -c '%a' "${ENV_FILE}")"
if [[ "${mode}" != "600" && "${mode}" != "400" ]]; then
  echo "install-run-heartbeat: ${ENV_FILE} is mode ${mode}; make it 0600, since it holds the ping URL." >&2
  exit 2
fi

install -D -m 0755 "${HERE}/../scripts/run_heartbeat.py" "${PREFIX%/}/usr/local/libexec/anolis/run_heartbeat.py"
install -D -m 0644 "${HERE}/run-heartbeat.service" "${PREFIX%/}/etc/systemd/system/run-heartbeat.service"
install -D -m 0644 "${HERE}/run-heartbeat.timer" "${PREFIX%/}/etc/systemd/system/run-heartbeat.timer"
"${SYSTEMCTL}" daemon-reload
echo "install-run-heartbeat: installed. Check once with: sudo systemctl start run-heartbeat.service; journalctl -u run-heartbeat -n 5"
echo "install-run-heartbeat: when the run starts: sudo systemctl enable --now run-heartbeat.timer"
