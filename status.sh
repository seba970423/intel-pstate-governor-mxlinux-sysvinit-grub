#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/grub.sh"

configured=$(configured_governor)
active=$(active_governors)
available=$(available_governors 2>/dev/null | paste -sd, - || echo unavailable)
if parameter_in_grub 2>/dev/null; then grub_state=present; else grub_state=absent; fi
if autostart_enabled; then startup=enabled; else startup=disabled; fi
printf '\nIntel P-state Governor — MX SysVinit / GRUB\n'
printf '  MX Linux:           %s\n' "$(is_mx_linux && echo yes || echo no)"
printf '  Init system:        %s\n' "$(is_sysvinit && echo SysVinit || echo other)"
printf '  Live environment:   %s\n' "$(is_live_environment && echo yes || echo no)"
printf '  CPU:                %s\n' "$(cpu_model)"
printf '  Scaling driver:     %s\n' "$(current_driver)"
printf '  intel_pstate mode:  %s\n' "$(intel_mode)"
printf '  Kernel arg active:  %s\n' "$(parameter_active && echo yes || echo no)"
printf '  GRUB default arg:   %s\n' "$grub_state"
printf '  Configured governor:%s\n' " $configured"
printf '  Active governor(s): %s\n' "$active"
printf '  Common governors:   %s\n' "$available"
if [[ "$configured" == ondemand || "$configured" == conservative ]] &&
   ! governor_available "$configured"; then
    if loadable_governor "$configured"; then
        printf '  Governor module:    %s (loadable, not registered)\n' "cpufreq_$configured"
    else
        printf '  Governor module:    %s (unavailable)\n' "cpufreq_$configured"
    fi
fi
printf '  SysVinit autostart: %s\n' "$startup"
if [[ -n "$(conflicting_managers || :)" ]]; then
    printf '  Potential conflicts: %s\n' "$(conflicting_managers | paste -sd, -)"
fi
if [[ "$configured" != 'not configured' && "$active" == "$configured" && "$startup" == enabled ]]; then
    ok 'Configured governor is active and SysVinit autostart is enabled.'
    exit 0
fi
warn 'Governor is not fully configured/active, or SysVinit startup is disabled.'
exit 1
