#!/usr/bin/env bash
# Host prep for bioreactor-v1 on 64-bit Raspberry Pi OS (Debian 13 based), on a
# Raspberry Pi 4. Run it before anolis's install.sh, and reboot if it says so.
#
# anolis deploys software; it does not set up the host's hardware
# (anolishq/anolis#318). This script does that for this machine:
#
#   - I2C bus 1 enabled (dtparam=i2c_arm=on) and the i2c-dev module loaded;
#   - the bus clock this machine's boards need: 50 kHz, with the VPU core clock
#     pinned. On a Pi 4 the I2C clock is divided from the core clock, which the
#     firmware scales, so i2c_arm_baudrate is only a ceiling unless
#     core_freq_min=500. The gen1 AVR slices lost retried writes at 98 kHz and
#     returned corrupted reads at 66-79 kHz; 49.7 kHz was clean (feastorg/CRUMBS#97);
#   - the anolis service user, created the way install.sh would create it, and
#     made a member of the group that owns the I2C device node.
#
# Idempotent: a second run changes nothing. install.sh's preflight then checks
# the result through each provider's --check-host.
#
# The values above were measured on a Pi 4, so apply refuses any other board
# (read from the device-tree model) unless given --any-board. Before its first
# change to config.txt it copies the file to config.txt.host-prep.bak, and
# never overwrites that copy; each change is written to a new file beside
# config.txt and renamed over it, so config.txt is never truncated in place.
#
# When a reboot is needed it also writes /run/reboot-required, the Debian
# convention that tools (the anolis workbench among them) read to say a reboot
# is pending. /run is tmpfs, so the reboot clears it.
#
# Usage: sudo ./prep-raspberrypi-os.sh [--check] [--any-board]
#   --check       report what is missing and change nothing; exit 1 if anything is.
#   --any-board   apply on a board that is not a Pi 4.
#
# Overridable for testing: CONFIG_TXT, MODEL_FILE, MODULES_LOAD_DIR, ETC_MODULES,
# SYS_MODULE_DIR, I2C_NODE, ANOLIS_PREFIX, REBOOT_FLAG, and ALLOW_NON_ROOT=1 to
# apply without root.

set -euo pipefail

readonly ANOLIS_USER="anolis"
readonly ANOLIS_PREFIX="${ANOLIS_PREFIX:-/opt/anolis}"
readonly I2C_NODE="${I2C_NODE:-/dev/i2c-1}"
readonly MODEL_FILE="${MODEL_FILE:-/proc/device-tree/model}"
readonly MODULES_LOAD_DIR="${MODULES_LOAD_DIR:-/etc/modules-load.d}"
readonly ETC_MODULES="${ETC_MODULES:-/etc/modules}"
readonly SYS_MODULE_DIR="${SYS_MODULE_DIR:-/sys/module}"
readonly REBOOT_FLAG="${REBOOT_FLAG:-/run/reboot-required}"
readonly BOARD="Raspberry Pi 4 Model B"
# This machine's config.txt lines: key -> value.
readonly -a CONFIG_KEYS=("dtparam=i2c_arm" "dtparam=i2c_arm_baudrate" "core_freq_min")
readonly -a CONFIG_VALUES=("on" "50000" "500")

CHECK=0
ANY_BOARD=0
CHANGED=0
MISSING=0
REBOOT=0

ok()   { printf '  ok      %s\n' "$*"; }
todo() { printf '  %-7s %s\n' "$([[ ${CHECK} -eq 1 ]] && echo missing || echo set)" "$*"; MISSING=1; }

for arg in "$@"; do
    case "${arg}" in
        --check) CHECK=1 ;;
        --any-board) ANY_BOARD=1 ;;
        *) echo "usage: $0 [--check] [--any-board]" >&2; exit 64 ;;
    esac
done

if [[ ${EUID} -ne 0 && ${CHECK} -eq 0 && "${ALLOW_NON_ROOT:-}" != 1 ]]; then
    echo "run as root: sudo $0" >&2
    exit 1
fi

config_txt() {
    if [[ -n "${CONFIG_TXT:-}" ]]; then
        echo "${CONFIG_TXT}"
    elif [[ -f /boot/firmware/config.txt ]]; then
        echo /boot/firmware/config.txt
    elif [[ -f /boot/config.txt ]]; then
        echo /boot/config.txt
    fi
}

# config.txt is last-match-wins. A key here is a property ("core_freq_min") or
# a base device-tree parameter ("dtparam=i2c_arm"); one dtparam line may carry
# several, comma-separated ("dtparam=i2c_arm=on,spi=on"), and each is matched
# on its own. A key counts where it applies to every Pi: before the first
# [filter] or under [all]. One under [pi4], [cm4] and the like would not apply
# to every board this card might boot. How the firmware treats an indented line
# is undocumented, so an indented key never reads as set, and setting a key
# rewrites it unindented.
#
# mode=get prints the key's value in effect (nothing if unset); mode=set prints
# the file with every line that sets the key rewritten to value, or with
# key=value appended under [all] if no line does.
CONFIG_AWK=$(cat <<'AWK'
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    BEGIN {
        applies = 1
        prop = key; param = ""
        if (index(key, "dtparam=") == 1) { prop = "dtparam"; param = substr(key, 9) }
    }
    { sub(/\r$/, "") }
    /^[[:space:]]*\[/ {
        started = 1; s = $0; gsub(/[[:space:]]/, "", s); applies = (s == "[all]"); last = s
        if (mode == "set") print
        next
    }
    {
        indented = ($0 ~ /^[[:space:]]/)
        body = trim($0)
        if (!applies || index(body, prop "=") != 1) { if (mode == "set") print; next }
        comment = ""
        if (match(body, /[[:space:]]+#/)) { comment = substr(body, RSTART); body = substr(body, 1, RSTART - 1) }
        rest = substr(body, length(prop) + 2)
        if (param == "") {
            v = rest; ind = indented; found = 1
            if (mode == "set") { print prop "=" value comment; done = 1 }
            next
        }
        n = split(rest, items, ","); hit = 0; out = ""
        for (i = 1; i <= n; i++) {
            item = trim(items[i]); eq = index(item, "=")
            name = eq ? substr(item, 1, eq - 1) : item
            if (name == param) {
                v = eq ? substr(item, eq + 1) : ""; ind = indented; found = 1; hit = 1
                item = param "=" value
            }
            out = out (i > 1 ? "," : "") item
        }
        if (mode == "set") { if (hit) { print "dtparam=" out comment; done = 1 } else print }
        next
    }
    END {
        if (mode == "get") { if (found && v != "") print (ind ? v " (indented)" : v) }
        else if (!done) {
            if (started && last != "[all]") print "[all]"
            print key "=" value
        }
    }
AWK
)
readonly CONFIG_AWK

config_value() {
    awk -v mode=get -v key="$2" "${CONFIG_AWK}" "$1"
}

# Write the new config.txt beside the old one and rename it over it, so a
# failure part-way leaves the old file whole. The new file takes the old one's
# mode; on the FAT boot partition chmod may fail, and the mount options decide
# the mode there anyway.
config_set() {
    local file="$1" key="$2" value="$3" tmp
    if [[ ! -e "${file}.host-prep.bak" ]]; then
        cp "${file}" "${file}.host-prep.bak"
        echo "  backup  ${file}.host-prep.bak"
    fi
    tmp=$(mktemp "${file}.XXXXXX")
    chmod --reference="${file}" "${tmp}" 2>/dev/null || true
    if ! awk -v mode=set -v key="${key}" -v value="${value}" "${CONFIG_AWK}" "${file}" > "${tmp}"; then
        rm -f "${tmp}"
        return 1
    fi
    sync
    mv -f "${tmp}" "${file}"
    sync
}

echo "bioreactor-v1 host prep ($([[ ${CHECK} -eq 1 ]] && echo check only || echo apply))"

# --- board: the values here were measured on a Pi 4 -----------------------------
# The braces put the redirect under 2>/dev/null too: a missing file fails the
# redirect itself, before tr runs.
model=$( { tr -d '\0' < "${MODEL_FILE}"; } 2>/dev/null || true)
if [[ "${model}" == "${BOARD}"* ]]; then
    ok "board: ${model}"
elif [[ ${CHECK} -eq 1 || ${ANY_BOARD} -eq 1 ]]; then
    echo "  note    board: ${model:-unknown}, not a ${BOARD}; these values were measured on one"
else
    echo "  board: ${model:-unknown}, not a ${BOARD}. This script's I2C clock values were" >&2
    echo "  measured on a Pi 4; rerun with --any-board to apply them here anyway." >&2
    exit 1
fi

# --- config.txt: I2C on, 50 kHz, core clock pinned -----------------------------
cfg=$(config_txt)
if [[ -z "${cfg}" ]]; then
    echo "  cannot find config.txt (/boot/firmware or /boot); is this Raspberry Pi OS?" >&2
    exit 1
fi
for i in "${!CONFIG_KEYS[@]}"; do
    key="${CONFIG_KEYS[$i]}" want="${CONFIG_VALUES[$i]}"
    have=$(config_value "${cfg}" "${key}")
    if [[ "${have}" == "${want}" ]]; then
        ok "${cfg}: ${key}=${want}"
        continue
    fi
    todo "${cfg}: ${key}=${want}${have:+ (was ${have})}"
    if [[ ${CHECK} -eq 0 ]]; then
        config_set "${cfg}" "${key}" "${want}"
        CHANGED=1
        REBOOT=1
    fi
done

# --- i2c-dev at boot and now ----------------------------------------------------
if grep -qsE '^[[:space:]]*i2c[-_]dev([[:space:]]|$)' "${ETC_MODULES}" "${MODULES_LOAD_DIR}"/*.conf; then
    ok "i2c-dev loaded at boot"
else
    todo "i2c-dev loaded at boot (${MODULES_LOAD_DIR}/i2c-dev.conf)"
    if [[ ${CHECK} -eq 0 ]]; then
        mkdir -p "${MODULES_LOAD_DIR}"
        echo i2c-dev > "${MODULES_LOAD_DIR}/i2c-dev.conf"
        CHANGED=1
    fi
fi
if [[ -d "${SYS_MODULE_DIR}/i2c_dev" ]]; then
    ok "i2c-dev loaded now"
else
    todo "i2c-dev loaded now"
    if [[ ${CHECK} -eq 0 ]]; then
        modprobe i2c-dev
        CHANGED=1
    fi
fi

# --- the anolis user and its access to the bus ----------------------------------
if id "${ANOLIS_USER}" &>/dev/null; then
    ok "user ${ANOLIS_USER} exists"
else
    todo "user ${ANOLIS_USER} (system user, home ${ANOLIS_PREFIX}, as install.sh creates it)"
    if [[ ${CHECK} -eq 0 ]]; then
        useradd --system --shell /usr/sbin/nologin --home-dir "${ANOLIS_PREFIX}" "${ANOLIS_USER}"
        CHANGED=1
    fi
fi

# The group that owns the node is the platform's (Raspberry Pi OS's udev rule
# gives /dev/i2c-* to "i2c"). Read it from the node when it exists; before the
# first reboot it may not, so fall back to the platform's name.
if [[ -e "${I2C_NODE}" ]]; then
    group=$(stat -c %G "${I2C_NODE}")
else
    group="i2c"
    REBOOT=1
fi
if ! getent group "${group}" &>/dev/null; then
    echo "  group ${group} does not exist; expected Raspberry Pi OS's udev rules for ${I2C_NODE}" >&2
    exit 1
fi
if id "${ANOLIS_USER}" &>/dev/null && id -nG "${ANOLIS_USER}" | tr ' ' '\n' | grep -qx "${group}"; then
    ok "${ANOLIS_USER} in group ${group} (owner of ${I2C_NODE})"
else
    todo "${ANOLIS_USER} in group ${group} (owner of ${I2C_NODE})"
    if [[ ${CHECK} -eq 0 ]]; then
        usermod -aG "${group}" "${ANOLIS_USER}"
        CHANGED=1
    fi
fi

# --- result --------------------------------------------------------------------
if [[ ${CHECK} -eq 1 ]]; then
    if [[ ${MISSING} -eq 1 ]]; then
        echo "host prep needed: run without --check"
        exit 1
    fi
    echo "host prep: nothing to do"
    exit 0
fi
[[ ${CHANGED} -eq 1 ]] || echo "host prep: nothing to do"
if [[ ${REBOOT} -eq 1 ]]; then
    echo '*** System restart required ***' > "${REBOOT_FLAG}"
    echo "REBOOT REQUIRED before installing: sudo reboot"
elif [[ ${CHANGED} -eq 1 ]]; then
    echo "host prep done; if anolis is already installed, restart it: sudo systemctl restart anolis-runtime"
fi
