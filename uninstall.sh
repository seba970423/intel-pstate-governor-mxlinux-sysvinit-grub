#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grub.sh"
REMOVE_PARAMETER=ask
PURGE_STATE=0
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --keep-kernel-parameter) REMOVE_PARAMETER=no ;;
        --remove-kernel-parameter) REMOVE_PARAMETER=yes ;;
        --purge-state) PURGE_STATE=1 ;;
        -h|--help)
            echo 'Usage: sudo ./uninstall.sh [--dry-run] [--yes] [--keep-kernel-parameter|--remove-kernel-parameter] [--purge-state]'
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done
require_root
require_target
[[ "$(state_read INIT_SYSTEM || :)" == sysvinit && "$(state_read BOOTLOADER || :)" == grub ]] ||
    die 'No installation state for the MX SysVinit / GRUB edition. Refusing to remove unowned files.'
owned=$(state_read PARAMETER_ADDED || echo 0)
if [[ "$REMOVE_PARAMETER" == ask ]]; then
    if [[ "$owned" == 1 ]] && parameter_in_grub; then
        if confirm "Remove the $KERNEL_PARAMETER argument added by this tool?"; then REMOVE_PARAMETER=yes; else REMOVE_PARAMETER=no; fi
    else
        REMOVE_PARAMETER=no
    fi
fi
if [[ "$REMOVE_PARAMETER" == yes && "$owned" != 1 ]]; then
    die 'This installation did not add that kernel argument. Refusing to remove a user-owned GRUB setting.'
fi
printf '\nMX SysVinit Intel P-state Governor uninstall\n'
printf '  Remove init startup and governor configuration\n'
printf '  GRUB kernel argument: %s\n' "$([[ "$REMOVE_PARAMETER" == yes ]] && echo remove || echo preserve)"
(( PURGE_STATE )) && echo '  Purge saved state and backups'
confirm 'Proceed with removal?' || die 'Cancelled.'
if [[ "$REMOVE_PARAMETER" == yes ]]; then
    change_grub remove || die 'Kernel parameter removal failed; preserving installed files.'
fi
if [[ -e "$INIT_SCRIPT" ]]; then
    run update-rc.d -f intel-pstate-governor remove || die 'Unable to remove SysVinit startup links.'
fi
run rm -f "$INIT_SCRIPT" "$HELPER_FILE" "$CONFIG_FILE"
run rmdir "$(dirname "$HELPER_FILE")" 2>/dev/null || :
if (( PURGE_STATE )); then
    run rm -rf -- "$STATE_DIR"
    run rm -f -- "$LOG_FILE"
else
    state_write PARAMETER_ADDED 0
    state_write UNINSTALLED 1
fi
ok 'Uninstall completed. The currently active governor is left unchanged until a future governor change or reboot.'
if [[ "$REMOVE_PARAMETER" == yes ]]; then
    info 'Reboot required to stop using intel_pstate=passive.'
    if (( ! DRY_RUN )) && confirm 'Reboot now?'; then exec shutdown -r now; fi
fi
