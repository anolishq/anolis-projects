#!/usr/bin/env bash
#
# run_heartbeat.test.sh: checks what run_heartbeat.py pings, against a stub
# runtime and a stub heartbeat endpoint on 127.0.0.1, and what
# host/install-run-heartbeat.sh installs into a temporary root with a stub
# systemctl. Nothing reaches the network.
#
#   bash projects/bioreactor-v1/scripts/run_heartbeat.test.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/run_heartbeat.py"
INSTALL="${HERE}/../host/install-run-heartbeat.sh"
TMP="$(mktemp -d)"
FAILED=0
STUB_PID=""
trap 'if [[ -n "${STUB_PID}" ]]; then kill "${STUB_PID}" 2>/dev/null || true; fi; rm -rf -- "${TMP}"' EXIT

fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }
pass() { printf 'PASS %s\n' "$*"; }

# The stub serves ${TMP}/status.json and ${TMP}/health.json to a request with
# the right token, and records each ping's path and body in ${TMP}/pings.
cat >"${TMP}/stub.py" <<'STUB'
import http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        files = {"/v0/runtime/status": "status.json", "/v0/providers/health": "health.json"}
        if self.headers.get("Authorization") != "Bearer t0k" or self.path not in files:
            self.send_response(401); self.end_headers(); return
        body = (root / files[self.path]).read_bytes()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with (root / "pings").open("a") as f:
            f.write(f"{self.path} {body}\n")
        self.send_response(200); self.end_headers()
server = http.server.HTTPServer(("127.0.0.1", 0), H)
(root / "port").write_text(str(server.server_address[1]))
server.serve_forever()
STUB
python3 "${TMP}/stub.py" "${TMP}" &
STUB_PID=$!
for _ in $(seq 50); do [[ -s "${TMP}/port" ]] && break; sleep 0.1; done
PORT="$(cat "${TMP}/port")"
BASE="http://127.0.0.1:${PORT}"

healthy_status='{"mode":"AUTO","estop":{"latched":false},"device_loss_latched":[]}'
healthy_health='{"providers":[{"provider_id":"bread0","state":"AVAILABLE","devices":[{"device_id":"dcmt0","health":"OK","reported":{"metrics":{"watchdog_tripped":"false"}}}]}]}'

# run_case <name> <status json> <health json> <expected exit> <expected last ping line, or "">
run_case() {
  local name="$1" status="$2" health="$3" want_exit="$4" want_ping="$5" got_exit=0
  printf '%s' "${status}" >"${TMP}/status.json"
  printf '%s' "${health}" >"${TMP}/health.json"
  : >"${TMP}/pings"
  HEARTBEAT_URL="${PING_URL:-${BASE}/ping/abc}" ANOLIS_API_TOKEN=t0k ANOLIS_API="${API:-${BASE}}" \
    python3 "${SCRIPT}" >"${TMP}/out" 2>&1 || got_exit=$?
  local got_ping
  got_ping="$(tail -n 1 "${TMP}/pings")"
  if [[ "${got_exit}" == "${want_exit}" && "${got_ping}" == "${want_ping}" ]]; then
    pass "${name}"
  else
    fail "${name}: exit ${got_exit} (want ${want_exit}), ping '${got_ping}' (want '${want_ping}'); output: $(cat "${TMP}/out")"
  fi
}

run_case "healthy run pings ok" "${healthy_status}" "${healthy_health}" 0 "/ping/abc ok"
run_case "a mode other than AUTO is a fail" \
  '{"mode":"FAULT","estop":{"latched":false},"device_loss_latched":[]}' "${healthy_health}" 0 "/ping/abc/fail mode=FAULT"
run_case "a latched software stop and device-loss latch are a fail" \
  '{"mode":"AUTO","estop":{"latched":true},"device_loss_latched":["bread0/rlht0","adafruit0/room0"]}' "${healthy_health}" 0 \
  "/ping/abc/fail software stop latched; device loss latched: adafruit0/room0, bread0/rlht0"
run_case "a tripped watchdog, an unhealthy device and an unavailable provider are a fail" "${healthy_status}" \
  '{"providers":[{"provider_id":"bread0","state":"AVAILABLE","devices":[{"device_id":"dcmt0","health":"STALE","reported":{"metrics":{"watchdog_tripped":"true"}}}]},{"provider_id":"ezo0","state":"UNAVAILABLE","devices":[]}]}' \
  0 "/ping/abc/fail bread0/dcmt0 health=STALE; bread0/dcmt0 watchdog tripped; ezo0 state=UNAVAILABLE"
API="http://127.0.0.1:9" run_case "a runtime that does not answer is a fail" "${healthy_status}" "${healthy_health}" 0 \
  "$(printf '/ping/abc/fail runtime not answering: ')$(HEARTBEAT_URL=x ANOLIS_API_TOKEN=x python3 -c 'import urllib.request
try: urllib.request.urlopen("http://127.0.0.1:9/v0/runtime/status", timeout=10)
except Exception as e: print(e)')"
PING_URL="http://127.0.0.1:9/ping" run_case "a ping that cannot be sent exits 1" "${healthy_status}" "${healthy_health}" 1 ""

got_exit=0
env -u HEARTBEAT_URL ANOLIS_API_TOKEN=t0k python3 "${SCRIPT}" >/dev/null 2>&1 || got_exit=$?
if [[ "${got_exit}" == 2 ]]; then pass "no HEARTBEAT_URL exits 2"; else fail "no HEARTBEAT_URL: exit ${got_exit}, want 2"; fi

# The installer, into a temporary root.
ROOT="${TMP}/root"
mkdir -p "${ROOT}/etc/anolis"
printf '#!/usr/bin/env bash\necho "$*" >>%s\n' "${TMP}/systemctl.log" >"${TMP}/systemctl"
chmod +x "${TMP}/systemctl"
install_rc() { local rc=0; PREFIX="${ROOT}" SYSTEMCTL="${TMP}/systemctl" bash "${INSTALL}" >"${TMP}/install.out" 2>&1 || rc=$?; echo "${rc}"; }

if [[ "$(install_rc)" == 2 && ! -e "${ROOT}/etc/systemd/system/run-heartbeat.timer" ]]; then
  pass "install refuses without heartbeat.env"
else
  fail "install without heartbeat.env: $(cat "${TMP}/install.out")"
fi
printf 'HEARTBEAT_URL=https://example.invalid/ping/abc\n' >"${ROOT}/etc/anolis/heartbeat.env"
chmod 0644 "${ROOT}/etc/anolis/heartbeat.env"
if [[ "$(install_rc)" == 2 ]] && grep -q 'mode 644' "${TMP}/install.out"; then
  pass "install refuses a world-readable heartbeat.env"
else
  fail "install with a 0644 heartbeat.env: $(cat "${TMP}/install.out")"
fi
chmod 0600 "${ROOT}/etc/anolis/heartbeat.env"
if [[ "$(install_rc)" == 0 ]] &&
  cmp -s "${SCRIPT}" "${ROOT}/usr/local/libexec/anolis/run_heartbeat.py" &&
  [[ -f "${ROOT}/etc/systemd/system/run-heartbeat.service" && -f "${ROOT}/etc/systemd/system/run-heartbeat.timer" ]] &&
  [[ "$(cat "${TMP}/systemctl.log")" == "daemon-reload" ]]; then
  pass "install copies the script and units, reloads systemd, and enables nothing"
else
  fail "install: $(cat "${TMP}/install.out"); systemctl: $(cat "${TMP}/systemctl.log" 2>/dev/null)"
fi

exit "${FAILED}"
