#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/sys/policy0" "$work/sys/policy1" "$work/bin"
for policy in "$work/sys"/policy*; do
  printf 'performance schedutil\n' > "$policy/scaling_available_governors"
  printf 'schedutil\n' > "$policy/scaling_governor"
done
printf 'GOVERNOR=ondemand\n' > "$work/conf"
sed -e "s|/etc/intel-pstate-governor.conf|$work/conf|g" \
    -e "s|/sys/devices/system/cpu/cpufreq/policy\*|$work/sys/policy*|g" \
    src/apply-governor > "$work/apply"
cat > "$work/bin/modprobe" <<'MODPROBE'
#!/bin/sh
[ "$1" = cpufreq_ondemand ] || exit 1
for policy in "$TEST_CPUFREQ_ROOT"/policy*; do
  printf 'performance schedutil ondemand\n' > "$policy/scaling_available_governors"
done
MODPROBE
chmod +x "$work/bin/modprobe" "$work/apply"
TEST_CPUFREQ_ROOT="$work/sys" PATH="$work/bin:$PATH" "$work/apply"
for p in "$work/sys"/policy*; do
  [[ "$(cat "$p/scaling_governor")" == ondemand ]] || exit 1
done
# Ensure missing modules fail rather than falling back to schedutil.
for p in "$work/sys"/policy*; do
  printf 'performance schedutil\n' > "$p/scaling_available_governors"
  printf 'schedutil\n' > "$p/scaling_governor"
done
cat > "$work/bin/modprobe" <<'MODPROBE'
#!/bin/sh
exit 1
MODPROBE
if TEST_CPUFREQ_ROOT="$work/sys" PATH="$work/bin:$PATH" "$work/apply" > "$work/out" 2>&1; then
    echo 'ERROR: expected failure when cpufreq_ondemand is unavailable' >&2
    exit 1
fi
for p in "$work/sys"/policy*; do
  [[ "$(cat "$p/scaling_governor")" == schedutil ]] || exit 1
done
printf 'Module loading/failure tests passed.\n'
