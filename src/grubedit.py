#!/usr/bin/env python3
"""Conservatively add/remove one kernel command-line token from /etc/default/grub."""
import os
import re
import stat
import sys
import tempfile

PATTERN = re.compile(r'^(\s*)(GRUB_CMDLINE_LINUX(?:_DEFAULT)?)(\s*=\s*)(["\'])(.*?)\4(\s*(?:#.*)?)$')


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('check', 'add', 'remove'):
        raise SystemExit('Usage: grubedit.py check|add|remove FILE TOKEN')
    action, path, token = sys.argv[1:]
    if not re.fullmatch(r'[A-Za-z0-9_=.-]+', token):
        raise SystemExit('Invalid kernel argument')
    with open(path, encoding='utf-8') as fh:
        lines = fh.readlines()
    candidates = []
    for i, line in enumerate(lines):
        m = PATTERN.fullmatch(line.rstrip('\n'))
        if m:
            candidates.append((i, m))
    if not candidates:
        raise SystemExit('No quoted GRUB_CMDLINE_LINUX variable found; refusing to guess')
    contains = any(token in m.group(5).split() for _, m in candidates)
    if action == 'check':
        return 0 if contains else 1
    if action == 'add':
        if contains:
            return 0
        target_i, target_m = next(((i, m) for i, m in candidates if m.group(2) == 'GRUB_CMDLINE_LINUX_DEFAULT'), candidates[0])
        words = target_m.group(5).split()
        words.append(token)
        replacements = [(target_i, target_m, ' '.join(words))]
    else:
        if not contains:
            return 0
        replacements = [(i, m, ' '.join(w for w in m.group(5).split() if w != token))
                        for i, m in candidates if token in m.group(5).split()]
    for i, m, updated in replacements:
        lines[i] = ''.join((m.group(1), m.group(2), m.group(3), m.group(4),
                            updated, m.group(4), m.group(6), '\n'))
    metadata = os.stat(path)
    directory = os.path.dirname(os.path.abspath(path))
    descriptor, temp_path = tempfile.mkstemp(prefix='.grub-intel-pstate-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as out:
            out.writelines(lines)
            out.flush()
            os.fsync(out.fileno())
        os.chmod(temp_path, stat.S_IMODE(metadata.st_mode))
        os.chown(temp_path, metadata.st_uid, metadata.st_gid)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
