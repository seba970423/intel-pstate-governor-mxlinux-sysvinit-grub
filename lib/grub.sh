#!/usr/bin/env bash
# Only handle /etc/default/grub on MX Linux; never touch other bootloaders.
SCRIPT_DIR=${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
GRUB_EDIT="$SCRIPT_DIR/src/grubedit.py"
parameter_in_grub() { python3 "$GRUB_EDIT" check "$GRUB_DEFAULT" "$KERNEL_PARAMETER"; }

change_grub() {
    local action=$1 backup
    if [[ "$action" == add ]] && parameter_in_grub; then
        info "$KERNEL_PARAMETER is already in GRUB defaults; not claiming ownership."
        return 0
    fi
    if [[ "$action" == remove ]] && ! parameter_in_grub; then
        info "$KERNEL_PARAMETER already absent from GRUB defaults."
        return 0
    fi
    if (( DRY_RUN )); then
        info "Would back up $GRUB_DEFAULT, $action $KERNEL_PARAMETER, and run update-grub"
        return 0
    fi
    backup=$(backup_file "$GRUB_DEFAULT" "grub-before-$action")
    info "GRUB backup: $backup"
    if ! python3 "$GRUB_EDIT" "$action" "$GRUB_DEFAULT" "$KERNEL_PARAMETER"; then
        die 'GRUB defaults edit failed. No regeneration attempted.'
    fi
    if ! update-grub; then
        warn 'update-grub failed. Restoring GRUB defaults from the backup.'
        cp -a -- "$backup" "$GRUB_DEFAULT"
        update-grub || warn 'GRUB regeneration still failed; investigate before rebooting.'
        die 'GRUB changes rolled back.'
    fi
}
