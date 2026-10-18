#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source lib/common.sh
source lib/governor-modules.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
printf 'performance schedutil\n' > "$work/available"
marker="$work/loaded"
governor_available() { [[ -f "$marker" ]]; }

# Successful opt-in loads the module and verifies availability.
cat > "$work/bin/modprobe" <<'EOF_MOD'
#!/bin/sh
[ "$1" = cpufreq_ondemand ] || exit 1
: > "$TEST_MODULE_MARKER"
EOF_MOD
chmod +x "$work/bin/modprobe"
TEST_MODULE_MARKER="$marker" PATH="$work/bin:$PATH" ensure_governor_module ondemand passive > "$work/success.out"
[[ -f "$marker" ]]
grep -F 'ondemand is available on all CPUFreq policies' "$work/success.out" >/dev/null
rm -f "$marker"

# Dry-run must not execute modprobe or mutate anything.
DRY_RUN=1 TEST_MODULE_MARKER="$marker" PATH="$work/bin:$PATH" ensure_governor_module ondemand passive > "$work/dry.out"
[[ ! -e "$marker" ]]
grep -F 'Would load cpufreq_ondemand' "$work/dry.out" >/dev/null
DRY_RUN=0

# Failed modprobe for a present module: fail closed, never call apt.
cat > "$work/bin/modprobe" <<'EOF_MOD'
#!/bin/sh
if [ "$1" = -n ]; then exit 0; fi
exit 7
EOF_MOD
cat > "$work/bin/apt-get" <<'EOF_APT'
#!/bin/sh
: > "$TEST_MODULE_MARKER"
EOF_APT
chmod +x "$work/bin/modprobe" "$work/bin/apt-get"
if (TEST_MODULE_MARKER="$marker" PATH="$work/bin:$PATH"; export TEST_MODULE_MARKER PATH; ensure_governor_module ondemand passive) > "$work/fail.out" 2>&1; then
    echo 'ERROR: expected modprobe failure' >&2; exit 1
fi
[[ ! -e "$marker" ]]
grep -F 'present but failed to load' "$work/fail.out" >/dev/null

# Missing module, no verifiable matching package: fail closed, no apt.
cat > "$work/bin/modprobe" <<'EOF_MOD'
#!/bin/sh
exit 7
EOF_MOD
# shellcheck disable=SC2317
matching_kernel_image_package() { return 1; }
# shellcheck disable=SC2317
module_kernel_config() { echo m; }
if (TEST_MODULE_MARKER="$marker" PATH="$work/bin:$PATH"; export TEST_MODULE_MARKER PATH; ensure_governor_module ondemand passive) > "$work/missing.out" 2>&1; then
    echo 'ERROR: expected missing-module failure' >&2; exit 1
fi
[[ ! -e "$marker" ]]
grep -F 'Nothing installed' "$work/missing.out" >/dev/null
printf 'Governor module opt-in, dry-run and fail-closed tests passed.\n'

# Safe exact-kernel recovery path: simulation must show only the matched package.
# No real package installation or host module operations occur in these tests.
(
    set -euo pipefail
    rm -f "$marker"
    module_kernel_config() { echo m; }
    matching_kernel_image_package() { echo 'linux-image-test=1.2.3'; }
    confirm_kernel_reinstall() { return 0; }
    governor_available() { [[ -f "$marker" ]]; }
    modprobe() {
        if [[ "$1" == -n ]]; then return 1; fi
        [[ -f "$marker" ]]
    }
    apt-get() {
        if [[ "$1" == -s ]]; then
            printf 'Inst linux-image-test [1.2.3] (1.2.3 mock)\n'
        else
            : > "$marker"
        fi
    }
    depmod() { :; }
    ensure_governor_module ondemand passive > "$work/repair.out"
    [[ -f "$marker" ]]
    grep -F 'after exact-kernel package repair' "$work/repair.out" >/dev/null
)
# Unrelated package changes in the preview must fail closed.
(
    set -euo pipefail
    rm -f "$marker"
    module_kernel_config() { echo m; }
    matching_kernel_image_package() { echo 'linux-image-test=1.2.3'; }
    confirm_kernel_reinstall() { return 0; }
    modprobe() { return 1; }
    apt-get() {
        if [[ "$1" == -s ]]; then
            printf 'Inst linux-image-test [1.2.3] (1.2.3 mock)\nInst unrelated [0] (9 mock)\n'
        else
            : > "$marker"
        fi
    }
    if (ensure_governor_module ondemand passive) > "$work/unsafe.out" 2>&1; then
        echo 'ERROR: expected rejection of unrelated apt changes' >&2; exit 1
    fi
    [[ ! -e "$marker" ]]
    grep -F 'Refusing.' "$work/unsafe.out" >/dev/null
)
printf 'Exact package reinstall simulation and unsafe APT rejection passed.\n'
