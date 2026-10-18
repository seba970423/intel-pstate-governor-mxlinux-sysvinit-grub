# Intel P-state Governor — MX Linux (SysVinit / GRUB)

**v0.3 test build / experimental port.** This edition specifically targets an **installed MX Linux (Debian-based) system booted under SysVinit**, using **GRUB**. It does not support systemd, systemd-boot, Limine, or rEFInd. It is based on [seba970423/intel-pstate-governor-tool](https://github.com/seba970423/intel-pstate-governor-tool); the upstream main branch is unchanged.

## What it does

- Lets you choose one CPUFreq governor across all policies.
- Optionally adds `intel_pstate=passive` persistently in `/etc/default/grub` and regenerates GRUB using `update-grub`.
- Installs a **SysVinit** boot hook (`/etc/init.d/intel-pstate-governor`) using Debian `update-rc.d` — no `systemctl` calls.
- Installs an on-demand helper under `/usr/local/libexec` to apply the selected governor.
- When `ondemand` is absent, **warns and asks for `y`** before loading `cpufreq_ondemand`. If passive mode is not yet active, it loads the module now and verifies governor availability after reboot.
- If `modprobe` cannot find the module, it offers an **optional, separately confirmed repair** by reinstalling **only the exact matching installed kernel image package** via APT, and only if a simulated APT transaction changes no other packages. No automatic kernel upgrades or substitute governors.
- On every subsequent SysVinit boot, the startup helper loads `cpufreq_ondemand` or `cpufreq_conservative` as necessary before applying the configured governor. Does not choose a silent fallback.
- Reports current CPU mode, active governor, GRUB setting and SysVinit autostart status.
- Tracks whether **this tool** added the kernel parameter; uninstall removes only its own addition.
- Backs up GRUB before changes and rolls back `/etc/default/grub` if `update-grub` fails.
- Provides dry-run mode and clear refusal on live USBs or unsupported configurations.

## Important: live USB is read-only for this tool

The MX live environment is useful for **read-only status checks**. The installer intentionally refuses to edit GRUB or SysVinit startup files from a live USB. **Install MX Linux on the T590 SSD first**, reboot into **SysVinit**, and then use this edition. No changes are made to live USB bootloader configurations.

## Commands

```bash
./status.sh
sudo ./install.sh --dry-run --kernel-parameter --governor ondemand --yes
sudo ./install.sh
sudo ./uninstall.sh --dry-run
sudo ./uninstall.sh
```

For scripting:

```bash
sudo ./install.sh --kernel-parameter --governor ondemand --yes
```

The installer can select `ondemand` even when the kernel has not yet registered it. It explicitly warns and asks permission to load `cpufreq_ondemand`. When `intel_pstate` is already in passive mode, it verifies `ondemand` is now listed for every CPUFreq policy; otherwise it verifies after reboot. The SysVinit startup helper loads the module at subsequent boots and checks the governor applied successfully.

If `modprobe` cannot locate `cpufreq_ondemand`, the installer **does not guess which kernel to install**. It verifies the installed `linux-image-...` package owns `/boot/vmlinuz-$(uname -r)`, checks the exact installed version is available in APT, previews the transaction, then requests another interactive confirmation to reinstall just that version. If any of these checks fails, the installer stops without changing packages or the bootloader. A genuinely kernel-disabled `ondemand` governor cannot be repaired by reinstalling a kernel package.

The APT repair is intended for incomplete/broken module installations, **not** for installing a new kernel. It may invoke kernel/post-install hooks; accept it only with a backup and a working MX repository. `--yes` never skips this extra kernel-package confirmation.

For an existing v0.1/v0.2 installation, extract v0.3 and rerun `sudo ./install.sh` to update the SysVinit helper. It retains ownership of any GRUB parameter previously added and does not duplicate it. You no longer need to run `sudo modprobe cpufreq_ondemand` manually when the governor is missing.

Do not apply `intel_pstate=passive` automatically if you intentionally use a different Intel P-state mode. This edition will prompt by default.

## Compatibility and precautions

- Intel x86_64 and an active `intel_pstate` or `intel_cpufreq` scaling driver.
- MX Linux, SysVinit as PID 1, installed GRUB, Python 3, `update-grub`, `update-rc.d`.
- Other power managers such as TLP or cpufrequtils may override the governor; the tool only warns, never disables them.
- The installer refuses to overwrite unmanaged config/init files or coexist with the original systemd service.
- Re-running the installer retains boot parameter ownership, so a later uninstall cannot accidentally remove a user-owned parameter.
- The tool does **not** tune PL1/PL2, undervolt, or claim a performance increase.

## Restore or uninstall

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --keep-kernel-parameter
sudo ./uninstall.sh --purge-state
```

GRUB backups are kept in `/var/lib/intel-pstate-governor-mx/backups/` unless state is explicitly purged. Uninstall removes the SysVinit autostart and config. It does **not** overwrite unrelated modifications made to `/etc/default/grub` after installation.

## Project structure

- `install.sh`, `uninstall.sh`, `status.sh`
- `init.d/intel-pstate-governor` — SysVinit oneshot-style boot hook
- `src/apply-governor` — kernel CPUFreq interface
- `src/grubedit.py` — constrained GRUB parameter editor
- `lib/` — MX validation, state and GRUB backup/restore helpers
- `lib/governor-modules.sh` — confirmed kernel-module loading and guarded matching-kernel repair
- `tests/test.sh` — syntax, GRUB, module loading, dry-run and simulated package-repair tests (no root needed)

MIT license (see `LICENSE`).
