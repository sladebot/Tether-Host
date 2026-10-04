#!/usr/bin/env python3
"""Bundle qemu-img and its non-system dylibs for a self-contained local build.
Run on Apple silicon with Homebrew qemu installed. Receipts, formulae and
available license files accompany the binaries for dependency provenance.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source = Path(os.environ.get('TETHER_QEMU_IMG', shutil.which('qemu-img') or '/opt/homebrew/bin/qemu-img')).resolve()
destination = Path(sys.argv[1])
if not source.is_file():
    raise SystemExit('Install the build dependency with brew install qemu, or set TETHER_QEMU_IMG.')
destination.mkdir(parents=True, exist_ok=True)
licenses = destination / 'Notices'
licenses.mkdir(exist_ok=True)
queue = [source]
seen = {}
records = []
while queue:
    original = queue.pop(0).resolve()
    if original in seen:
        continue
    target = destination / original.name
    if any(p.name == original.name and p != original for p in seen):
        raise SystemExit(f'Conflicting dylib name: {original.name}')
    shutil.copy2(original, target)
    target.chmod(0o755)
    seen[original] = target
    links = subprocess.check_output(['/usr/bin/otool', '-L', str(original)], text=True).splitlines()[1:]
    for line in links:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/usr/lib/', '/System/')):
            continue
        path = Path(dependency).resolve()
        if path == original:
            subprocess.run(['/usr/bin/install_name_tool', '-id', '@loader_path/' + original.name, str(target)], check=True)
            continue
        if not path.is_file():
            raise SystemExit(f'Unresolved dependency: {dependency}')
        subprocess.run(['/usr/bin/install_name_tool', '-change', dependency, '@loader_path/' + path.name, str(target)], check=True)
        queue.append(path)
    parts = original.parts
    if 'Cellar' in parts:
        index = parts.index('Cellar')
        root = Path(*parts[:index + 3])
        package = parts[index + 1] + '-' + parts[index + 2]
        notice = licenses / package
        if not notice.exists():
            notice.mkdir()
            for candidate in root.iterdir():
                if candidate.is_file() and (candidate.name.lower().startswith(('license', 'copying', 'copyright')) or candidate.name == 'INSTALL_RECEIPT.json'):
                    shutil.copy2(candidate, notice / candidate.name)
            if (root / '.brew').is_dir():
                shutil.copytree(root / '.brew', notice / 'formula')
        records.append({'binary': original.name, 'package': package})
# This standalone preview converter is ad-hoc signed. Hardened runtime's library
# validation requires a real Team ID for its non-system dylibs. The Developer ID
# release pipeline must re-sign all tools with its team and hardened runtime.
for target in seen.values():
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(target)], check=True)
(licenses / 'dependencies.json').write_text(json.dumps(records, indent=2) + '\n')
subprocess.run([str(destination / source.name), '--version'], check=True)
