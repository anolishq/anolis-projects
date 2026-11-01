#!/usr/bin/env bash
#
# prep-raspberrypi-os.test.sh: runs prep-raspberrypi-os.sh against fixture
# config.txt files in a temp directory. Every host path the script touches is
# overridden into that directory, and modprobe, useradd, usermod, id and getent
# are stubs that keep their state there, so nothing on the machine running the
# test is read for its answer or changed.
#
#   bash projects/bioreactor-v1/host/prep-raspberrypi-os.test.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/prep-raspberrypi-os.sh"
FAILED=0
PI4="Raspberry Pi 4 Model B Rev 1.5"

fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }
pass() { printf 'PASS %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# new_host <name> <model>: a fake host under ${tmp}/<name>, with an empty
# config.txt, the device-tree model, an I2C node and stub commands.
new_host() {
  local h="${tmp}/$1"
  mkdir -p "${h}/boot" "${h}/modules-load.d" "${h}/sys-module" "${h}/stub" "${h}/state"
  : >"${h}/boot/config.txt"
  : >"${h}/etc-modules"
  : >"${h}/dev-i2c-1"
  : >"${h}/state/calls"
  printf '%s\0' "$2" >"${h}/model"
  # useradd and usermod record the user and its groups; id and getent answer
  # from that record; modprobe loads i2c_dev into the fake /sys/module.
  cat >"${h}/stub/useradd" <<'STUB'
#!/usr/bin/env bash
echo "useradd $*" >>"${STATE}/calls"; touch "${STATE}/user"
STUB
  cat >"${h}/stub/usermod" <<'STUB'
#!/usr/bin/env bash
echo "usermod $*" >>"${STATE}/calls"; echo "$2" >>"${STATE}/groups"
STUB
  cat >"${h}/stub/id" <<'STUB'
#!/usr/bin/env bash
[[ -e "${STATE}/user" ]] || exit 1
if [[ "${1:-}" == "-nG" ]]; then echo "anolis $(tr '\n' ' ' <"${STATE}/groups" 2>/dev/null)"; fi
exit 0
STUB
  cat >"${h}/stub/getent" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"${h}/stub/modprobe" <<'STUB'
#!/usr/bin/env bash
echo "modprobe $*" >>"${STATE}/calls"; mkdir -p "${SYS_MODULE_DIR}/i2c_dev"
STUB
  chmod +x "${h}/stub/"*
}

# prep <name> [args...]: run the script against host <name>; output goes to
# ${tmp}/<name>/out.log and the exit status to ${tmp}/<name>/rc.
prep() {
  local h="${tmp}/$1"
  shift
  local rc=0
  env -i PATH="${h}/stub:/usr/bin:/bin" STATE="${h}/state" ALLOW_NON_ROOT=1 \
    CONFIG_TXT="${h}/boot/config.txt" MODEL_FILE="${h}/model" \
    MODULES_LOAD_DIR="${h}/modules-load.d" ETC_MODULES="${h}/etc-modules" \
    SYS_MODULE_DIR="${h}/sys-module" I2C_NODE="${h}/dev-i2c-1" \
    REBOOT_FLAG="${h}/reboot-required" ANOLIS_PREFIX="${h}/opt-anolis" \
    bash "${SCRIPT}" "$@" >"${h}/out.log" 2>&1 || rc=$?
  echo "${rc}" >"${h}/rc"
}

rc() { cat "${tmp}/$1/rc"; }
cfg() { echo "${tmp}/$1/boot/config.txt"; }
sum() { sha256sum "$1" | awk '{print $1}'; }
# count <file> <exact line>: how many lines of <file> are exactly <line>.
count() { grep -cxF -- "$2" "$1" || true; }

# 1. A fresh host: apply sets everything, backs up config.txt, asks for a
#    reboot; a second run changes nothing.
new_host fresh "${PI4}"
printf '%s\n' '# stock' 'dtparam=audio=on' '[cm4]' 'otg_mode=1' '[all]' >"$(cfg fresh)"
chmod 644 "$(cfg fresh)"
before="$(sum "$(cfg fresh)")"
prep fresh
if [[ "$(rc fresh)" == 0 ]]; then pass "apply on a fresh Pi 4 exits 0"; else fail "apply exited $(rc fresh): $(tail -5 "${tmp}/fresh/out.log")"; fi
for line in dtparam=i2c_arm=on dtparam=i2c_arm_baudrate=50000 core_freq_min=500; do
  if [[ "$(count "$(cfg fresh)" "${line}")" == 1 ]]; then pass "config.txt has ${line} once"; else fail "config.txt has ${line} $(count "$(cfg fresh)" "${line}") times"; fi
done
if [[ "$(tail -1 "$(cfg fresh)")" == core_freq_min=500 && "$(count "$(cfg fresh)" '[all]')" == 1 ]]; then
  pass "the keys go under the existing [all]"
else
  fail "the keys are not under the one [all]: $(cat "$(cfg fresh)")"
fi
if [[ -f "$(cfg fresh).host-prep.bak" && "$(sum "$(cfg fresh).host-prep.bak")" == "${before}" ]]; then
  pass "the backup is the original config.txt, byte for byte"
else
  fail "no backup, or it differs from the original"
fi
if [[ "$(stat -c %a "$(cfg fresh)")" == 644 ]]; then pass "config.txt keeps mode 644"; else fail "config.txt mode is now $(stat -c %a "$(cfg fresh)")"; fi
if [[ -f "${tmp}/fresh/reboot-required" ]]; then pass "a reboot is flagged"; else fail "no reboot flag"; fi
if [[ "$(cat "${tmp}/fresh/modules-load.d/i2c-dev.conf" 2>/dev/null)" == i2c-dev ]]; then pass "i2c-dev loads at boot"; else fail "no modules-load.d/i2c-dev.conf"; fi
if grep -q '^useradd ' "${tmp}/fresh/state/calls" 2>/dev/null && grep -q '^usermod ' "${tmp}/fresh/state/calls" 2>/dev/null; then
  pass "the anolis user is created and given the bus group"
else
  fail "useradd/usermod not called: $(cat "${tmp}/fresh/state/calls" 2>/dev/null)"
fi
after="$(sum "$(cfg fresh)")"
calls="$(wc -l <"${tmp}/fresh/state/calls")"
rm -f "${tmp}/fresh/reboot-required"
prep fresh
if [[ "$(rc fresh)" == 0 && "$(sum "$(cfg fresh)")" == "${after}" && "$(wc -l <"${tmp}/fresh/state/calls")" == "${calls}" ]] \
  && grep -q 'nothing to do' "${tmp}/fresh/out.log" && [[ ! -e "${tmp}/fresh/reboot-required" ]]; then
  pass "a second run changes nothing"
else
  fail "the second run changed something: $(cat "${tmp}/fresh/out.log")"
fi
prep fresh --check
if [[ "$(rc fresh)" == 0 ]]; then pass "--check exits 0 after apply"; else fail "--check exited $(rc fresh) after apply: $(cat "${tmp}/fresh/out.log")"; fi

# 2. --check on an unprepared host exits 1 and changes nothing.
new_host check "${PI4}"
printf '%s\n' 'dtparam=audio=on' >"$(cfg check)"
before="$(sum "$(cfg check)")"
prep check --check
if [[ "$(rc check)" == 1 && "$(sum "$(cfg check)")" == "${before}" && ! -e "$(cfg check).host-prep.bak" && ! -s "${tmp}/check/state/calls" ]]; then
  pass "--check on an unprepared host exits 1 and changes nothing"
else
  fail "--check exited $(rc check) or changed the host"
fi

# 3. A combined dtparam line keeps its other parameters (#105).
new_host combined "${PI4}"
printf '%s\n' 'dtparam=i2c_arm=off,spi=on' 'dtparam=audio=on' >"$(cfg combined)"
prep combined
if [[ "$(count "$(cfg combined)" 'dtparam=i2c_arm=on,spi=on')" == 1 ]]; then
  pass "dtparam=i2c_arm=off,spi=on becomes dtparam=i2c_arm=on,spi=on"
else
  fail "the combined line lost a parameter: $(cat "$(cfg combined)")"
fi
if grep -qE '^dtparam=i2c_arm=on$' "$(cfg combined)"; then fail "i2c_arm was also added on a line of its own"; else pass "no second i2c_arm line"; fi
new_host combined-ok "${PI4}"
printf '%s\n' 'dtparam=spi=on,i2c_arm=on' >"$(cfg combined-ok)"
prep combined-ok --check
if grep -qE '^ +ok +.*dtparam=i2c_arm=on$' "${tmp}/combined-ok/out.log"; then
  pass "--check reads i2c_arm=on from dtparam=spi=on,i2c_arm=on"
else
  fail "--check did not read i2c_arm from a combined line: $(cat "${tmp}/combined-ok/out.log")"
fi

# 4. An indented key is rewritten in place, not duplicated (#105). Whether the
#    firmware honours an indented line is undocumented, so it never reads as set.
new_host indented "${PI4}"
printf '%s\n' '  core_freq_min=500' 'dtparam=audio=on' >"$(cfg indented)"
prep indented --check
if grep -qE 'core_freq_min=500' "${tmp}/indented/out.log" && ! grep -qE '^ +ok +.*core_freq_min' "${tmp}/indented/out.log"; then
  pass "--check does not count an indented core_freq_min as set"
else
  fail "--check counted an indented key: $(cat "${tmp}/indented/out.log")"
fi
prep indented
if [[ "$(grep -c 'core_freq_min' "$(cfg indented)")" == 1 && "$(head -1 "$(cfg indented)")" == core_freq_min=500 ]]; then
  pass "the indented line is rewritten unindented, in place, once"
else
  fail "core_freq_min after apply: $(grep -n core_freq_min "$(cfg indented)")"
fi

# 5. A key under [pi4] alone does not count; apply adds it under [all] and
#    leaves the [pi4] line alone.
new_host filtered "${PI4}"
printf '%s\n' '[pi4]' 'core_freq_min=500' >"$(cfg filtered)"
prep filtered
if [[ "$(count "$(cfg filtered)" core_freq_min=500)" == 2 && "$(sed -n 2p "$(cfg filtered)")" == core_freq_min=500 ]] \
  && grep -qxF '[all]' "$(cfg filtered)"; then
  pass "a [pi4]-only key is added again under [all]; the [pi4] line stays"
else
  fail "filtered config after apply: $(cat "$(cfg filtered)")"
fi

# 6. An existing backup is never overwritten.
new_host rebackup "${PI4}"
printf '%s\n' 'dtparam=audio=on' >"$(cfg rebackup)"
echo 'older backup' >"$(cfg rebackup).host-prep.bak"
prep rebackup
if [[ "$(cat "$(cfg rebackup).host-prep.bak")" == 'older backup' ]]; then pass "an existing backup is kept"; else fail "the existing backup was overwritten"; fi

# 7. Apply refuses a board other than a Pi 4 before changing anything, unless
#    told --any-board.
new_host pi5 "Raspberry Pi 5 Model B Rev 1.0"
printf '%s\n' 'dtparam=audio=on' >"$(cfg pi5)"
before="$(sum "$(cfg pi5)")"
prep pi5
if [[ "$(rc pi5)" != 0 && "$(sum "$(cfg pi5)")" == "${before}" && ! -e "$(cfg pi5).host-prep.bak" && ! -s "${tmp}/pi5/state/calls" ]] \
  && grep -q 'Raspberry Pi 5' "${tmp}/pi5/out.log"; then
  pass "apply refuses a Pi 5, names it, and changes nothing"
else
  fail "apply on a Pi 5 exited $(rc pi5) or changed the host: $(cat "${tmp}/pi5/out.log")"
fi
prep pi5 --any-board
if [[ "$(rc pi5)" == 0 && "$(count "$(cfg pi5)" core_freq_min=500)" == 1 ]]; then
  pass "--any-board applies on a Pi 5"
else
  fail "--any-board on a Pi 5 exited $(rc pi5): $(cat "${tmp}/pi5/out.log")"
fi

# 8. An unknown argument is a usage error.
new_host usage "${PI4}"
prep usage --bogus
if [[ "$(rc usage)" == 64 ]]; then pass "an unknown argument exits 64"; else fail "an unknown argument exited $(rc usage)"; fi

exit "${FAILED}"
