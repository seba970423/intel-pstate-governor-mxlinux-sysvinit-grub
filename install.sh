#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grub.sh"
source "$SCRIPT_DIR/lib/governor-modules.sh"

ADD_PARAMETER=ask
SELECTED_GOVERNOR=""
usage() {
    cat <<'HELP'
MX Linux SysVinit Intel P-state governor installer (GRUB only)
Usage: sudo ./install.sh [--dry-run] [--governor NAME] [--kernel-parameter|--no-kernel-parameter] [--yes] [--status]
Options:
  --dry-run              Preview without making any changes
  --kernel-parameter     Add intel_pstate=passive to /etc/default/grub
  --no-kernel-parameter  Leave GRUB unchanged
  --governor NAME        Choose governor without the numbered menu
  --yes                  Accept prompts (requires --governor)
  --status               Display current status without installing
HELP
}
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --kernel-parameter) ADD_PARAMETER=yes ;;
        --no-kernel-parameter) ADD_PARAMETER=no ;;
        --governor) shift; (($#)) || die '--governor requires a value'; SELECTED_GOVERNOR=$1 ;;
        --status) exec "$SCRIPT_DIR/status.sh" ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
require_root
require_target
[[ "$(uname -m)" == x86_64 && "$(cpu_vendor)" == GenuineIntel ]] || die 'An Intel x86_64 CPU is required.'
[[ "$(current_driver)" == intel_pstate || "$(current_driver)" == intel_cpufreq ]] ||
    die "Intel P-state CPUFreq driver is required (current: $(current_driver))."
command -v python3 >/dev/null || die 'python3 is required for safe GRUB editing.'
[[ ! -e "$CONFIG_FILE" || -e "$STATE_FILE" ]] || die "Unmanaged configuration exists: $CONFIG_FILE (refusing overwrite)."
[[ ! -e "$INIT_SCRIPT" || -e "$STATE_FILE" ]] || die "Unmanaged init script exists: $INIT_SCRIPT (refusing overwrite)."

printf '\nIntel P-state Governor — MX Linux / SysVinit / GRUB\n'
printf '  CPU:            %s\n' "$(cpu_model)"
printf '  Init:           SysVinit\n'
printf '  Bootloader:     GRUB (/etc/default/grub)\n'
printf '  Driver:         %s\n' "$(current_driver)"
printf '  Intel P-state:  %s\n' "$(intel_mode)"
printf '  Governor(s):   %s\n' "$(active_governors)"
printf '  Boot argument:  %s\n' "$(parameter_active && echo active || echo absent)"

conflicts=$(conflicting_managers || :)
if [[ -n "$conflicts" ]]; then
    warn 'Other governor/power-management tools may override this choice:'
    printf '  %s\n' "$conflicts"
    warn 'This installer will not disable or modify them.'
fi
if [[ "$ADD_PARAMETER" == ask ]]; then
    if parameter_in_grub; then
        ADD_PARAMETER=no
        info "$KERNEL_PARAMETER already appears in GRUB defaults."
    elif confirm 'Add intel_pstate=passive to GRUB for additional governors?'; then
        ADD_PARAMETER=yes
    else
        ADD_PARAMETER=no
    fi
fi

mapfile -t governors < <(available_governors)
((${#governors[@]})) || die 'No common CPUFreq governors found.'
# Offer ondemand even if its module is missing: the user may opt into
# loading it or an explicitly confirmed, exact-kernel package repair.
# Generic CPUFreq governors still require intel_pstate passive mode.
if [[ "$ADD_PARAMETER" == yes || "$(intel_mode)" == passive ]]; then
    if ! printf '%s\n' "${governors[@]}" | grep -Fxq ondemand; then
        governors+=(ondemand)
    fi
    if ! printf '%s\n' "${governors[@]}" | grep -Fxq conservative &&
       loadable_governor conservative; then
        governors+=(conservative)
    fi
fi
if [[ -z "$SELECTED_GOVERNOR" ]]; then
    (( ASSUME_YES == 0 )) || die '--yes requires --governor NAME.'
    printf '\nGovernor choices:\n'
    for i in "${!governors[@]}"; do
        printf '  %d. %s' "$((i+1))" "${governors[$i]}"
        if ! governor_available "${governors[$i]}"; then
            if [[ "${governors[$i]}" == ondemand ]]; then
                printf ' (unavailable; module check/confirmation required)'
            elif [[ "$(intel_mode)" == passive ]]; then
                printf ' (module loads on apply)'
            else
                printf ' (pending passive mode / reboot)'
            fi
        fi
        printf '\n'
    done
    read -r -p 'Choose a governor number: ' index || die 'No governor selected.'
    [[ "$index" =~ ^[0-9]+$ ]] && (( index > 0 && index <= ${#governors[@]} )) || die 'Invalid selection.'
    SELECTED_GOVERNOR=${governors[$((index-1))]}
fi
[[ "$SELECTED_GOVERNOR" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid governor name.'
printf '%s\n' "${governors[@]}" | grep -Fxq "$SELECTED_GOVERNOR" ||
    die "Governor '$SELECTED_GOVERNOR' is unavailable (or not a supported passive-mode candidate)."
MODULE_ACTION=no
if ! governor_available "$SELECTED_GOVERNOR"; then
    if ! governor_module "$SELECTED_GOVERNOR" >/dev/null 2>&1; then
        die "Governor '$SELECTED_GOVERNOR' is unavailable and no supported module can supply it."
    fi
    [[ "$(intel_mode)" == passive || "$ADD_PARAMETER" == yes ]] ||
        die "$SELECTED_GOVERNOR needs intel_pstate=passive; allow the GRUB change first."
    module=$(governor_module "$SELECTED_GOVERNOR")
    warn "The '$SELECTED_GOVERNOR' governor is currently unavailable."
    if loadable_governor "$SELECTED_GOVERNOR"; then
        info "Kernel module: $module (installed but not registered)."
    else
        warn "Kernel module: $module (not currently loadable; a matching-kernel repair may be needed)."
    fi
    if confirm "Load $module automatically now (and on future SysVinit boots)?"; then
        MODULE_ACTION=yes
    else
        die "Declined enabling $SELECTED_GOVERNOR. No changes were made."
    fi
fi
printf '\nPlanned changes:\n'
printf '  Governor:  %s\n' "$SELECTED_GOVERNOR"
printf '  Startup:   SysVinit /etc/init.d/intel-pstate-governor\n'
printf '  GRUB:      %s\n\n' "$([[ "$ADD_PARAMETER" == yes ]] && echo "ensure $KERNEL_PARAMETER" || echo unchanged)"
confirm 'Proceed with installation?' || die 'Cancelled.'

# Resolve missing module before modifying GRUB, init scripts or config.
# On active intel_pstate, loading now does not make ondemand selectable
# until passive mode is enabled and the machine has rebooted.
if [[ "$MODULE_ACTION" == yes ]]; then
    ensure_governor_module "$SELECTED_GOVERNOR" "$(intel_mode)"
fi

if [[ -f "$CONFIG_FILE" ]]; then backup_file "$CONFIG_FILE" config-before-reinstall >/dev/null; fi
run install -D -m 0755 "$SCRIPT_DIR/src/apply-governor" "$HELPER_FILE"
run install -D -m 0755 "$SCRIPT_DIR/init.d/intel-pstate-governor" "$INIT_SCRIPT"
if (( DRY_RUN )); then
    info "Would write GOVERNOR=$SELECTED_GOVERNOR to $CONFIG_FILE"
else
    config_tmp=$(mktemp)
    printf '# Managed by intel-pstate-governor (MX SysVinit edition)\nGOVERNOR=%s\n' "$SELECTED_GOVERNOR" > "$config_tmp"
    install -m 0644 "$config_tmp" "$CONFIG_FILE"
    rm -f "$config_tmp"
fi
run update-rc.d intel-pstate-governor defaults

owned=$(state_read PARAMETER_ADDED || echo 0)
if [[ "$ADD_PARAMETER" == yes ]]; then
    if parameter_in_grub; then
        info "$KERNEL_PARAMETER is already present; leaving its ownership unchanged."
    else
        change_grub add
        owned=1
    fi
fi
state_write PARAMETER_ADDED "$owned"
state_write SELECTED_GOVERNOR "$SELECTED_GOVERNOR"
state_write INIT_SYSTEM sysvinit
state_write BOOTLOADER grub

# Do not apply until a reboot when the passive-mode argument is not yet active.
# Otherwise run the same helper that SysVinit will use, including modprobe.
if [[ "$ADD_PARAMETER" != yes ]] || parameter_active; then
    if (( DRY_RUN )); then
        info 'Would apply selected governor to current CPUFreq policies.'
    elif "$INIT_SCRIPT" start; then
        ok "$SELECTED_GOVERNOR is active."
    else
        warn 'Governor application failed; boot configuration and installed files remain for inspection.'
    fi
else
    info 'Governor will be applied after the passive-mode reboot by the SysVinit helper.'
fi
ok 'Installation steps completed.'
if [[ "$ADD_PARAMETER" == yes ]] && ! parameter_active; then
    info 'Reboot required for intel_pstate=passive to take effect.'
    if (( ! DRY_RUN )) && confirm 'Reboot now?'; then
        exec shutdown -r now
    fi
else
    info 'No reboot required for the kernel parameter.'
fi
