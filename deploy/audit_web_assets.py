"""Fail before building if a bundled asset is absent, untracked or uncommitted."""
import hashlib
import json
import re
import subprocess
from pathlib import Path


def audit():
    tracked = set(subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0'))
    declared = set()
    for value in re.findall(r'^\s+- (assets/[^\n]+)$', Path('pubspec.yaml').read_text(), re.M):
        path = Path(value.strip())
        if value.endswith('/'):
            declared.update(p.as_posix() for p in path.iterdir() if p.is_file())
        else:
            declared.add(path.as_posix())
    referenced = set()
    for source in Path('lib').rglob('*.dart'):
        for value in re.findall(r'''["'](assets/[^"'\n]+)["']''', source.read_text(encoding='utf-8')):
            if '$' in value:
                raise ValueError('Unresolved dynamic asset path: ' + str(source))
            referenced.add(value)
    if referenced - declared:
        raise ValueError('Referenced assets not bundled: ' + str(sorted(referenced - declared)))
    entries = {}
    for name in sorted(declared):
        path = Path(name)
        if not path.is_file() or name not in tracked:
            raise ValueError('Missing/untracked asset: ' + name)
        subprocess.run(['git', 'cat-file', '-e', 'HEAD:' + name], check=True)
        if path.suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico'}:
            indexed = subprocess.check_output(['git', 'rev-parse', 'HEAD:' + name]).strip()
            local = subprocess.check_output(['git', 'hash-object', '--no-filters', name]).strip()
            if indexed != local:
                raise ValueError('Image differs from committed Git bytes: ' + name)
        entries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    result = {'referenced_images': len(referenced), 'bundled_files': len(entries),
              'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip(),
              'sha256': entries}
    print('PASS: %s referenced images and %s bundled files exist in Git HEAD' % (len(referenced), len(entries)))
    return result


if __name__ == '__main__':
    result = audit()
    Path('asset-audit.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
