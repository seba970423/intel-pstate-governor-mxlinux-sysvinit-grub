#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in install.sh uninstall.sh status.sh lib/*.sh src/apply-governor; do bash -n "$script"; done
sh -n init.d/intel-pstate-governor
python3 -m py_compile src/grubedit.py
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/grub" <<'EOC'
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash" # leave this comment
GRUB_CMDLINE_LINUX="foo=bar"
# GRUB_CMDLINE_LINUX_DEFAULT="ignored"
EOC
python3 src/grubedit.py add "$work/grub" intel_pstate=passive
python3 src/grubedit.py check "$work/grub" intel_pstate=passive
python3 src/grubedit.py add "$work/grub" intel_pstate=passive
[[ "$(grep -o intel_pstate=passive "$work/grub" | wc -l)" == 1 ]]
python3 src/grubedit.py remove "$work/grub" intel_pstate=passive
if python3 src/grubedit.py check "$work/grub" intel_pstate=passive; then exit 1; fi
grep -F 'quiet splash" # leave this comment' "$work/grub" >/dev/null
grep -F 'foo=bar' "$work/grub" >/dev/null
bash tests/test-governors.sh
bash tests/test-module-recovery.sh
printf 'All static/GRUB editor tests passed.\n'
