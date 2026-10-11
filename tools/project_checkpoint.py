"""Byte-exact, content-addressed checkpoints. No tokens/config/local.json exported.
Run before edits: python tools/project_checkpoint.py create --label TASK
Verify: python tools/project_checkpoint.py verify CHECKPOINT_DIRECTORY
Restore to a separate directory: python tools/project_checkpoint.py export CHECKPOINT DIRECTORY
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / '.local-backups' / 'project-versions'
EXCLUDE = {'.git', '.dart_tool', 'build', '.local-backups', '.idea', '__pycache__',
           'node_modules', '.venv', '.tools', 'source_assets'}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def read_checkpoint(path):
    manifest = json.loads((path / 'manifest.json').read_text(encoding='utf-8'))
    for name, info in manifest['files'].items():
        if Path(name).is_absolute() or '..' in Path(name).parts or '\\' in name:
            raise ValueError('Unsafe path')
        data = (STORE / 'objects' / info['sha256']).read_bytes()
        if len(data) != info['size'] or digest(data) != info['sha256']:
            raise ValueError('Corrupt object: ' + name)
    return manifest

def create(label):
    objects = STORE / 'objects'
    objects.mkdir(parents=True, exist_ok=True)
    files = {}
    new_bytes = 0
    for p in sorted(ROOT.rglob('*')):
        rel = p.relative_to(ROOT)
        if not p.is_file() or any(part in EXCLUDE for part in rel.parts):
            continue
        if rel.as_posix() == 'config/local.json' or p.suffix.lower() in {'.zip', '.rar', '.log', '.pyc'}:
            continue
        # Administrative financial exports are private data, even when a user
        # places a downloaded file in the project root instead of .local-backups.
        if p.suffix.lower() in {'.json', '.csv'} and p.name.upper().startswith(('PRE_BACKUP_', 'VERIFIED_ADMIN')):
            continue
        if any(part in {'.aws', '.codex', '.agents'} for part in rel.parts):
            continue
        data = p.read_bytes()
        if p.suffix.lower() == '.json':
            try:
                value = json.loads(data)
                if isinstance(value, list) and len(value) == 1:
                    value = value[0]
                if isinstance(value, dict) and ('backup_json' in value or
                        ('canonical_data' in value and 'data_sha256' in value)):
                    continue
            except (ValueError, UnicodeError):
                pass
        sha = digest(data)
        target = objects / sha
        if not target.exists():
            temporary = objects / (sha + '.tmp')
            temporary.write_bytes(data)
            os.replace(temporary, target)
            new_bytes += len(data)
        files[rel.as_posix()] = {'sha256': sha, 'size': len(data)}
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    path = STORE / 'checkpoints' / stamp
    path.mkdir(parents=True)
    (path / 'manifest.json').write_text(json.dumps({'format': 1, 'time': stamp,
        'label': label, 'new_bytes': new_bytes, 'files': files}, ensure_ascii=False, indent=2), encoding='utf-8')
    read_checkpoint(path)
    print(json.dumps({'checkpoint': str(path), 'files': len(files), 'new_bytes': new_bytes}))
    return path

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['create', 'verify', 'export'])
    parser.add_argument('path', nargs='?')
    parser.add_argument('destination', nargs='?')
    parser.add_argument('--label', default='Before changes')
    args = parser.parse_args()
    if args.action == 'create':
        create(args.label)
    else:
        path = Path(args.path).resolve()
        manifest = read_checkpoint(path)
        if args.action == 'export':
            destination = Path(args.destination).resolve()
            if destination.exists() and any(destination.iterdir()):
                raise ValueError('Export requires an empty directory')
            for name, info in manifest['files'].items():
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(STORE / 'objects' / info['sha256'], target)
        print('Verified ' + str(len(manifest['files'])) + ' files')
