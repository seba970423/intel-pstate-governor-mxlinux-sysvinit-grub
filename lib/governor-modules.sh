#!/usr/bin/env bash
# Optional CPUFreq governor module support for MX Linux SysVinit / GRUB.
# No package operation is performed without a separate, explicit confirmation.

governor_module() {
    case "$1" in
        ondemand) printf 'cpufreq_ondemand\n' ;;
        conservative) printf 'cpufreq_conservative\n' ;;
        *) return 1 ;;
    esac
}

# Return m, y, n, or unknown from the matching *running* kernel config.
module_kernel_config() {
    local kconfig="/boot/config-$(uname -r)" symbol="CONFIG_CPU_FREQ_GOV_${1^^}" value
    if [[ -r "$kconfig" ]]; then
        value=$(grep -E "^${symbol}=[ym]$" "$kconfig" | tail -n 1 || :)
        [[ -n "$value" ]] && { printf '%s\n' "${value#*=}"; return; }
        grep -Fxq "# $symbol is not set" "$kconfig" && { echo n; return; }
    fi
    echo unknown
}

# Identify only the exact Debian/MX kernel image *owning the running kernel*.
# Installing a different kernel would not fix a missing governor for the current boot.
matching_kernel_image_package() {
    local kernel pkg status installed candidate
    kernel=$(uname -r)
    command -v dpkg-query >/dev/null 2>&1 || return 1
    command -v apt-cache >/dev/null 2>&1 || return 1
    command -v apt-get >/dev/null 2>&1 || return 1
    pkg=$(dpkg-query -S "/boot/vmlinuz-$kernel" 2>/dev/null | awk -F ': ' '/^linux-image-[A-Za-z0-9+._-]+: / {print $1; exit}')
    [[ "$pkg" =~ ^linux-image-[A-Za-z0-9+._-]+$ ]] || return 1
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null) || return 1
    [[ "$status" == ii* ]] || return 1
    installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null) || return 1
    [[ "$installed" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || return 1
    candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '$1=="Candidate:" {print $2;exit}')
    [[ "$candidate" == "$installed" ]] || return 1
    printf '%s=%s\n' "$pkg" "$installed"
}

# Unlike normal installation confirmation, package reinstall requires its own
# interactive consent even if --yes was given for the governor configuration.
confirm_kernel_reinstall() {
    local answer
    [[ -t 0 ]] || { warn 'Interactive approval is required before reinstalling kernel packages.'; return 1; }
    read -r -p "$1 [y/N] " answer || return 1
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ensure_governor_module() {
    local wanted=$1 mode=$2 module config package
    module=$(governor_module "$wanted") || die "No loadable module is known for governor '$wanted'."
    if (( DRY_RUN )); then
        info "Would load $module and verify $wanted (dry-run; no module or package changes)."
        return 0
    fi
    command -v modprobe >/dev/null 2>&1 || die "modprobe not found. Install kmod before continuing."
    if modprobe "$module"; then
        ok "$module loaded successfully (or already built into the kernel)."
    else
        # A failed probe can indicate hardware/config/permissions problems.
        # Only propose reinstall if the module files are actually missing.
        if modprobe -n -q "$module" >/dev/null 2>&1; then
            die "$module is present but failed to load. Check the modprobe error above; no package changes made."
        fi
        config=$(module_kernel_config "$wanted")
        if [[ "$config" == n || "$config" == y ]]; then
            die "Running kernel config reports $module=$config. Reinstalling a package cannot enable a disabled governor."
        fi
        warn "$module could not be found for running kernel $(uname -r)."
        package=$(matching_kernel_image_package || :)
        [[ -n "$package" ]] || die 'No safe, exact-version kernel image repair was identified. Nothing installed. Use the MX kernel tools to inspect the running kernel package.'
        warn "Repair option: reinstall EXACT installed kernel package $package."
        warn 'This invokes APT/dpkg kernel hooks and may regenerate initramfs; it requires a working repository. It will not switch kernels.'
        if ! confirm_kernel_reinstall "Reinstall $package to recover the missing $module module?"; then
            die 'Kernel package reinstall declined. No packages changed.'
        fi
        # Preview the precise reinstall and refuse transactions that would
        # install/upgrade/remove anything else. Never auto-switch kernels.
        local preview package_name
        package_name=${package%%=*}
        if ! preview=$(apt-get -s --no-remove --no-upgrade --no-install-recommends --reinstall install "$package" 2>&1); then
            warn "$preview"
            die 'APT cannot safely preview an exact kernel reinstall; nothing installed.'
        fi
        if ! printf '%s\n' "$preview" | awk -v expected="$package_name" '
            $1 == "Inst" {installs++; if ($2 != expected) bad=1}
            $1 == "Remv" {bad=1}
            END {exit !(installs == 1 && !bad)}'; then
            warn "$preview"
            die 'APT preview would change packages other than the exact running kernel image (or has no reinstall action). Refusing.'
        fi
        if ! apt-get --no-remove --no-upgrade --no-install-recommends --reinstall install "$package"; then
            die 'Matching kernel package reinstall failed. Inspect APT output before rebooting.'
        fi
        command -v depmod >/dev/null 2>&1 && depmod -a "$(uname -r)" || :
        modprobe "$module" || die "Kernel image was reinstalled but $module still cannot load."
        ok "$module now loads after exact-kernel package repair."
    fi
    if [[ "$mode" == passive ]]; then
        governor_available "$wanted" || die "$module loaded, but $wanted is still unavailable on at least one CPUFreq policy."
        ok "$wanted is available on all CPUFreq policies."
    else
        info "$module is loaded; $wanted will be verified after the intel_pstate=passive reboot."
    fi
}
