"""Build/verify an explicit allowlist deploy ZIP without secrets or user data."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    'server/backup_store.py', 'server/backup_s3.py', 'server/backup_runtime.py', 'server/backup_worker.py',
    'server/environment.example', 'server/s3-user-policy.example.json',
    'server/finance-backups.service', 'server/finance-backups-once.service', 'server/nginx.example.conf',
    'server/requirements.txt', 'server/test_backups.py', 'server/test_s3_runtime.py', 'server/s3_test_endpoint.py',
    'server/VERIFY_018.sql', 'server/VERIFY_018.txt',
    'BACKUPS_SETUP.md', 'BACKUPS_S3_SETUP.md', 'BACKUPS_SERVER_PREFLIGHT.md', 'BACKUPS_RESULT.txt',
    'tools/benchmark_backup_export.py', 'tools/benchmark_backup_s3.py', 'tools/package_backup_server.py',
    'backups-preflight/EXPORT_BENCHMARK_20261007.json', 'backups-preflight/S3_BENCHMARK_20261007.json',
    'backups-preflight/LINUX_S3_WHEELS_20261007.json', 'backups-preflight/S3_TESTS_20261007.json',
]

def main():
    contents = {name: (ROOT / name).read_bytes() for name in FILES}
    checksums = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    checksums_text = ''.join(digest + '  ' + name + '\n' for name, digest in checksums.items()).encode()
    destination = ROOT / 'backups-server-deploy.zip'
    temporary = ROOT / 'backups-server-deploy.tmp'
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in contents.items(): archive.writestr(name, data)
            archive.writestr('FILES_SHA256.txt', checksums_text)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() or set(archive.namelist()) != set(FILES) | {'FILES_SHA256.txt'}:
                raise ValueError('Deploy ZIP integrity mismatch')
            for name, digest in checksums.items():
                if hashlib.sha256(archive.read(name)).hexdigest() != digest:
                    raise ValueError('Deploy file checksum mismatch')
        temporary.replace(destination)
    finally: temporary.unlink(missing_ok=True)
    report = {'created_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(), 'archive': destination.name,
              'bytes': destination.stat().st_size, 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
              'files': checksums, 'all_archive_checks_passed': True,
              'contains_secrets_or_financial_data': False, 'contains_migration_installer': False}
    (ROOT / 'backups-preflight/SERVER_PACKAGE_20261007.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'files'}))

if __name__ == '__main__': main()
