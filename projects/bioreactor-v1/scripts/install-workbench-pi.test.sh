#!/usr/bin/env bash
#
# install-workbench-pi.test.sh: checks which anolis-workbench version
# install-workbench-pi.sh asks pip for (#104). It runs the script with
# --no-launch, HOME in a temp directory, and a stub python3 whose fake venv
# records every pip call. Nothing is installed and nothing reaches PyPI.
#
#   bash projects/bioreactor-v1/scripts/install-workbench-pi.test.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/install-workbench-pi.sh"
FAILED=0

fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }
pass() { printf 'PASS %s\n' "$*"; }

# run_bootstrap <tmp dir> [ENV=VALUE...]: run the script against stubs; pip's
# arguments go to <tmp dir>/pip.log, its output to <tmp dir>/out.log.
run_bootstrap() {
  local tmp="$1"
  shift
  mkdir -p "${tmp}/stub" "${tmp}/home"
  cat >"${tmp}/stub/python3" <<'STUB'
#!/usr/bin/env bash
# python3 -c '...' (import checks) and -V succeed; -m venv DIR builds a fake venv.
if [[ "${1:-}" == "-V" ]]; then echo "Python 3.13.5"; exit 0; fi
if [[ "${1:-}" == "-c" ]]; then exit 0; fi
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  mkdir -p "$3/bin"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "${PIP_LOG}" >"$3/bin/pip"
  printf '#!/usr/bin/env bash\necho "anolis-workbench 0.0.0-stub"\n' >"$3/bin/anolis-workbench"
  for cmd in anolis-provision anolis-package anolis-validate; do cp "$3/bin/anolis-workbench" "$3/bin/${cmd}"; done
  chmod +x "$3"/bin/*
  exit 0
fi
exit 1
STUB
  chmod +x "${tmp}/stub/python3"
  env -i PATH="${tmp}/stub:/usr/bin:/bin" HOME="${tmp}/home" PIP_LOG="${tmp}/pip.log" "$@" \
    bash "${SCRIPT}" --no-launch >"${tmp}/out.log" 2>&1
}

# The version the script pins, from its WORKBENCH_VERSION line.
PIN="$(sed -n 's/^WORKBENCH_VERSION="\([^"]*\)"$/\1/p' "${SCRIPT}")"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# 1. By default, the pinned version and only that.
if [[ -z "${PIN}" ]]; then
  fail "install-workbench-pi.sh pins no WORKBENCH_VERSION"
else
  pass "pins anolis-workbench ${PIN}"
fi
run_bootstrap "${tmp}/default" || fail "the bootstrap exited non-zero: $(tail -5 "${tmp}/default/out.log")"
if grep -qx "install --quiet anolis-workbench==${PIN}" "${tmp}/default/pip.log" 2>/dev/null && [[ -n "${PIN}" ]]; then
  pass "pip installs anolis-workbench==${PIN}"
else
  fail "pip was not asked for anolis-workbench==${PIN}: $(cat "${tmp}/default/pip.log" 2>/dev/null)"
fi
if grep -E 'anolis-workbench($| )' "${tmp}/default/pip.log" >/dev/null 2>&1; then
  fail "pip was asked for an unpinned anolis-workbench"
else
  pass "no unpinned anolis-workbench install"
fi

# 2. Another version only when asked for, and said so.
run_bootstrap "${tmp}/override" ANOLIS_WORKBENCH_VERSION=0.25.0 \
  || fail "the bootstrap with an override exited non-zero: $(tail -5 "${tmp}/override/out.log")"
if grep -qx "install --quiet anolis-workbench==0.25.0" "${tmp}/override/pip.log" 2>/dev/null; then
  pass "ANOLIS_WORKBENCH_VERSION=0.25.0 installs anolis-workbench==0.25.0"
else
  fail "the override did not reach pip: $(cat "${tmp}/override/pip.log" 2>/dev/null)"
fi
if grep -q "ANOLIS_WORKBENCH_VERSION" "${tmp}/override/out.log"; then
  pass "the override is named in the output"
else
  fail "the override is not named in the output"
fi

exit "${FAILED}"
