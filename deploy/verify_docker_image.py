"""CI checks for the actual runtime image, without reaching Supabase or DNS."""
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def run(*args, **kwargs):
    return subprocess.check_output(args, **kwargs).decode().strip()


def check(image, archive):
    info = json.loads(run('docker', 'image', 'inspect', image))[0]
    assert (info['Os'], info['Architecture']) == ('linux', 'amd64')
    subprocess.run(['docker', 'run', '--rm', '--entrypoint', 'sh', image, '-c',
                    'set -eu; command -v wget; test ! -e /opt/flutter; test ! -e /app; '
                    '! command -v git && ! command -v dart && ! command -v flutter'], check=True)
    run('docker', 'create', '--name', 'finance-audit', image)
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'srv'
            subprocess.run(['docker', 'cp', 'finance-audit:/srv', str(root)], check=True)
            manifest = json.loads(Path('asset-audit.json').read_text())
            for name, digest in manifest['sha256'].items():
                target = root / 'assets' / name
                assert target.is_file(), 'Bundled asset missing: ' + name
                assert hashlib.sha256(target.read_bytes()).hexdigest() == digest, 'Asset altered: ' + name
            assert not list(root.rglob('*.dart'))
            assert not list(root.rglob('*.map'))
            assert not (root / 'config' / 'local.json').exists()
    finally:
        run('docker', 'rm', 'finance-audit')
    subprocess.run(['docker', 'image', 'save', '--output', archive, image], check=True)
    patterns = [rb'sb_secret_[A-Za-z0-9_-]{16,}', rb'(?<![A-Za-z0-9_])AKIA[A-Z0-9]{16}(?![A-Za-z0-9_])',
                rb'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
                rb'postgres(?:ql)?://[^\s/:]+:[^\s@]+@',
                rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----']
    scanned = 0
    with tarfile.open(archive) as outer:
        manifests = json.load(outer.extractfile('manifest.json'))
        layer_names = {name for item in manifests for name in item['Layers']}
        for member in outer:
            if not member.isfile() or member.name not in layer_names:
                continue
            with tarfile.open(fileobj=outer.extractfile(member), mode='r|*') as layer:
                for entry in layer:
                    if not entry.isfile():
                        continue
                    name = entry.name.lstrip('./')
                    assert not name.endswith('.dart') and '/.git/' not in '/' + name
                    assert not name.startswith(('opt/flutter/', 'app/'))
                    assert name not in ('srv/config/local.json', 'root/.aws/credentials')
                    scanned += 1
                    stream = layer.extractfile(entry)
                    tail = b''
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        data = tail + chunk
                        assert not any(re.search(p, data) for p in patterns), 'Potential secret in layer file: ' + name
                        tail = data[-8192:]
    assert scanned > 0, 'No runtime layers were scanned'
    print('PASS: linux/amd64 runtime; all bundled assets byte-identical; no SDK/Dart/Git; %s layer files scanned for secret patterns' % scanned)


if __name__ == '__main__':
    check(sys.argv[1], sys.argv[2])
