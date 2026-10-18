#!/usr/bin/env bash
# Shared logic for the MX Linux / SysVinit / GRUB edition.
PROJECT=intel-pstate-governor
CONFIG_FILE=/etc/intel-pstate-governor.conf
HELPER_FILE=/usr/local/libexec/intel-pstate-governor/apply-governor
INIT_SCRIPT=/etc/init.d/intel-pstate-governor
STATE_DIR=/var/lib/intel-pstate-governor-mx
STATE_FILE=$STATE_DIR/state
BACKUP_DIR=$STATE_DIR/backups
LOG_FILE=/var/log/intel-pstate-governor-mx.log
GRUB_DEFAULT=/etc/default/grub
KERNEL_PARAMETER=intel_pstate=passive
DRY_RUN=${DRY_RUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
ok() { printf '[ OK ] %s\n' "$*"; }
run() { if (( DRY_RUN )); then printf '[DRY ]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
confirm() {
    (( ASSUME_YES )) && return 0
    local answer
    read -r -p "$1 [y/N] " answer || return 1
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}
require_root() { (( EUID == 0 )) || die 'Run with sudo (root permissions required).'; }

is_mx_linux() {
    [[ -e /etc/mx-version ]] && return 0
    [[ -r /etc/os-release ]] || return 1
    # os-release is a distributor-owned file; avoid sourcing untrusted shell code.
    grep -Eq '^(ID=mx|PRETTY_NAME="?MX([ -]| Linux))' /etc/os-release
}
is_sysvinit() {
    [[ ! -d /run/systemd/system ]] || return 1
    [[ -r /proc/1/comm ]] || return 1
    case "$(</proc/1/comm)" in init|sysvinit) return 0 ;; *) return 1 ;; esac
}
is_live_environment() {
    [[ -e /run/live/medium || -e /lib/live/mount/medium || -e /live/boot-dev || -e /run/mx-live ]] && return 0
    grep -Eq '(^|[[:space:]])(boot=live|from=usb|from=all|live-media=)' /proc/cmdline && return 0
    case "$(findmnt -n -o FSTYPE / 2>/dev/null || :)" in overlay|aufs|squashfs) return 0 ;; esac
    return 1
}
require_target() {
    is_mx_linux || die 'This edition supports MX Linux only.'
    is_sysvinit || die 'This edition requires booting with SysVinit (not systemd).'
    if is_live_environment; then
        die 'Live USB detected. Install MX Linux onto the SSD before modifying its GRUB or startup scripts.'
    fi
    [[ -f "$GRUB_DEFAULT" ]] || die 'GRUB defaults not found at /etc/default/grub.'
    command -v update-grub >/dev/null || die 'Debian/MX update-grub command is missing.'
    [[ -f /boot/grub/grub.cfg ]] || die 'Installed GRUB configuration /boot/grub/grub.cfg not found.'
    command -v update-rc.d >/dev/null || die 'SysVinit update-rc.d command is missing.'
    [[ ! -f /etc/systemd/system/intel-pstate-governor.service ]] || die 'Existing systemd edition detected. Remove it before using the MX edition.'
}

cpu_vendor() { awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo; }
cpu_model() { awk -F: '/model name/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo; }
current_driver() {
    local p
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_driver; do
        [[ -r "$p" ]] && { cat "$p"; return; }
    done
    echo unavailable
}
intel_mode() { [[ -r /sys/devices/system/cpu/intel_pstate/status ]] && cat /sys/devices/system/cpu/intel_pstate/status || echo unavailable; }
active_governors() {
    local p
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        [[ -r "$p" ]] && cat "$p"
    done | sort -u | paste -sd, -
}
available_governors() {
    local p gov first=1
    local -A shared=() available=()
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors; do
        [[ -r "$p" ]] || continue
        available=()
        for gov in $(<"$p"); do available["$gov"]=1; done
        if (( first )); then
            for gov in "${!available[@]}"; do shared["$gov"]=1; done
            first=0
        else
            for gov in "${!shared[@]}"; do
                [[ -v available["$gov"] ]] || unset 'shared[$gov]'
            done
        fi
    done
    (( first == 0 )) || return 1
    printf '%s\n' "${!shared[@]}" | sort
}
governor_available() { available_governors | grep -Fxq "$1"; }
# Only advertise a currently absent generic governor if the kernel can
# actually supply its module; passive mode does not automatically load it.
loadable_governor() {
    local module
    case "$1" in
        ondemand|conservative) module="cpufreq_$1" ;;
        *) return 1 ;;
    esac
    command -v modprobe >/dev/null 2>&1 || return 1
    modprobe -n -q "$module" >/dev/null 2>&1
}

configured_governor() {
    [[ -r "$CONFIG_FILE" ]] || { echo 'not configured'; return; }
    local line gov
    line=$(grep -E '^GOVERNOR=[a-zA-Z0-9_-]+$' "$CONFIG_FILE" | head -n 1 || :)
    gov=${line#GOVERNOR=}
    [[ -n "$gov" ]] && echo "$gov" || echo 'invalid configuration'
}
parameter_active() { grep -Eq '(^|[[:space:]])intel_pstate=passive([[:space:]]|$)' /proc/cmdline; }
state_read() {
    local k=$1
    [[ -r "$STATE_FILE" ]] || return 1
    sed -n "s/^${k}=//p" "$STATE_FILE" | tail -n 1
}
state_write() {
    local key=$1 value=$2 temp
    [[ "$key" =~ ^[A-Z_]+$ && "$value" =~ ^[a-zA-Z0-9_.,:/+-]*$ ]] || die 'Invalid state key/value.'
    if (( DRY_RUN )); then info "Would record $key=$value"; return; fi
    mkdir -p "$STATE_DIR"
    temp=$(mktemp "$STATE_DIR/.state.XXXXXXXX")
    if [[ -f "$STATE_FILE" ]]; then grep -v "^$key=" "$STATE_FILE" > "$temp" || :; fi
    printf '%s=%s\n' "$key" "$value" >> "$temp"
    chmod 0600 "$temp"; mv -f "$temp" "$STATE_FILE"
}
backup_file() {
    local source=$1 label=$2 dest
    dest="$BACKUP_DIR/${label}-$(date +%Y%m%d-%H%M%S)-$$.bak"
    if (( DRY_RUN )); then info "Would back up $source to $dest"; else
        mkdir -p "$BACKUP_DIR"
        cp -a -- "$source" "$dest"
    fi
    printf '%s\n' "$dest"
}
conflicting_managers() {
    local service
    for service in tlp cpufrequtils cpupower tuned auto-cpufreq power-profiles-daemon; do
        if compgen -G "/etc/rc[2345].d/S*${service}" > /dev/null ||
           pgrep -x "$service" > /dev/null 2>&1; then
            printf '%s\n' "$service"
        fi
    done
}
autostart_enabled() {
    [[ -x "$INIT_SCRIPT" ]] || return 1
    local i
    for i in /etc/rc{2,3,4,5}.d/S*intel-pstate-governor; do
        [[ -L "$i" ]] && return 0
    done
    return 1
}
