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
# When a reboot is needed it also writes /run/reboot-required, the Debian
# convention that tools (the anolis workbench among them) read to say a reboot
# is pending. /run is tmpfs, so the reboot clears it.
#
# Usage: sudo ./prep-raspberrypi-os.sh [--check]
#   --check   report what is missing and change nothing; exit 1 if anything is.
#
# Overridable for testing: CONFIG_TXT, MODULES_LOAD_DIR, I2C_NODE, ANOLIS_PREFIX,
# REBOOT_FLAG.

set -euo pipefail

readonly ANOLIS_USER="anolis"
readonly ANOLIS_PREFIX="${ANOLIS_PREFIX:-/opt/anolis}"
readonly I2C_NODE="${I2C_NODE:-/dev/i2c-1}"
readonly MODULES_LOAD_DIR="${MODULES_LOAD_DIR:-/etc/modules-load.d}"
readonly REBOOT_FLAG="${REBOOT_FLAG:-/run/reboot-required}"
# This machine's config.txt lines: key -> value.
readonly -a CONFIG_KEYS=("dtparam=i2c_arm" "dtparam=i2c_arm_baudrate" "core_freq_min")
readonly -a CONFIG_VALUES=("on" "50000" "500")

CHECK=0
CHANGED=0
MISSING=0
REBOOT=0

ok()   { printf '  ok      %s\n' "$*"; }
todo() { printf '  %-7s %s\n' "$([[ ${CHECK} -eq 1 ]] && echo missing || echo set)" "$*"; MISSING=1; }

case "${1:-}" in
    --check) CHECK=1 ;;
    "") ;;
    *) echo "usage: $0 [--check]" >&2; exit 64 ;;
esac

if [[ ${EUID} -ne 0 && ${CHECK} -eq 0 ]]; then
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

# Print the value a key has where it applies to every Pi: before the first
# [filter] or under [all]. config.txt is last-match-wins, so the last such line
# is the one in effect. A key under [pi4], [cm4] and the like is not counted: it
# would not apply to every board this card might boot. Prints nothing if unset.
config_value() {
    local file="$1" key="$2"
    awk -v key="${key}" '
        BEGIN { applies = 1 }
        { sub(/\r$/, "") }
        /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); applies = (s == "[all]"); next }
        applies && index($0, key "=") == 1 { v = substr($0, length(key) + 2); sub(/[[:space:]]*#.*$/, "", v) }
        END { if (v != "") print v }
    ' "${file}"
}

# Set key=value in config.txt: rewrite every line where it applies to every Pi
# (so no earlier or later one overrides it), or append it under [all].
config_set() {
    local file="$1" key="$2" value="$3" tmp
    tmp=$(mktemp)
    awk -v key="${key}" -v value="${value}" '
        BEGIN { applies = 1 }
        { sub(/\r$/, "") }
        /^[[:space:]]*\[/ { started = 1; s = $0; gsub(/[[:space:]]/, "", s); applies = (s == "[all]"); last = s; print; next }
        applies && index($0, key "=") == 1 { print key "=" value; done = 1; next }
        { print }
        END {
            if (!done) {
                if (started && last != "[all]") print "[all]"
                print key "=" value
            }
        }
    ' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

echo "bioreactor-v1 host prep ($([[ ${CHECK} -eq 1 ]] && echo check only || echo apply))"

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
if grep -qsE '^[[:space:]]*i2c[-_]dev([[:space:]]|$)' /etc/modules "${MODULES_LOAD_DIR}"/*.conf; then
    ok "i2c-dev loaded at boot"
else
    todo "i2c-dev loaded at boot (${MODULES_LOAD_DIR}/i2c-dev.conf)"
    if [[ ${CHECK} -eq 0 ]]; then
        mkdir -p "${MODULES_LOAD_DIR}"
        echo i2c-dev > "${MODULES_LOAD_DIR}/i2c-dev.conf"
        CHANGED=1
    fi
fi
if [[ -d /sys/module/i2c_dev ]]; then
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
