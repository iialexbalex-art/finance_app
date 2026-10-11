"""Full current snapshot -> real boto3/loopback fixture -> ZIP -> clean Store.

No production database writes, live S3, payment or production restore. Report
has counts/hashes/resource metrics only; all financial files stay private.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
sys.path.insert(0, str(ROOT / 'tools'))
from backup_store import Store, canonical, file_hash
from backup_s3 import S3Store
from backup_runtime import OperationGate
from benchmark_backup_export import memory_metrics, one_cpu
from s3_test_endpoint import LocalS3Endpoint


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--job-file', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    stage = Path(args.output_dir).resolve()
    stage.mkdir(parents=True, exist_ok=True)
    if any(stage.iterdir()): raise ValueError('Empty private output directory required')
    ref = json.loads(Path(args.job_file).read_text(encoding='utf-8'))
    original = Store(ref['store'])
    manifest, payload = original.read(ref['owner'], ref['identifier'])
    job = {'id': ref['identifier'], 'captured_at': manifest['captured_at'], 'release': manifest['release'], 'payload': payload}
    report = {'measured_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(), 'platform': platform.platform(),
              'single_cpu_affinity': one_cpu(), 'production_database_written': False, 'real_timeweb_tested': False,
              'test_endpoint': 'loopback S3 protocol fixture with real boto3 SDK; test credentials; no TLS/provider test',
              'limits': 'No Ubuntu VM/cgroup 2 GiB limit. Process memory includes local test endpoint, excludes OS page cache.',
              'phases': []}
    stop = threading.Event()
    peaks = {'temporary_logical_bytes': 0, 'samples': 0}
    def sample():
        while not stop.wait(.02):
            paths = list(stage.glob('*.zip')) + list(stage.rglob('.tmp/op-*/*'))
            total = 0
            for path in paths:
                try:
                    if path.is_file(): total += path.stat().st_size
                except FileNotFoundError: pass
            peaks['temporary_logical_bytes'] = max(peaks['temporary_logical_bytes'], total)
            peaks['samples'] += 1
    monitor = threading.Thread(target=sample); monitor.start()
    def phase(name, action):
        started = time.perf_counter()
        result = action()
        report['phases'].append({'name': name, 'elapsed_seconds': time.perf_counter() - started, 'memory': memory_metrics()})
        return result
    try:
        with LocalS3Endpoint(stage / 'fixture-s3') as endpoint:
            store = S3Store(stage / 'first-cache', 'private-fixture', client=endpoint.client())
            gate = OperationGate(store.root)
            store.deadline_check = gate.check_deadline
            with gate:
                phase('private_conditional_probe', store.check_storage)
                # Existing CAS is linked, not recopied. First S3 PUT still sends
                # every unique original once to the isolated endpoint.
                package = store.root / 'package-objects'; package.mkdir(exist_ok=True)
                unique = {v['sha256']: v['size'] for v in manifest['release']['files'].values()}
                for digest in unique:
                    os.link(original.object_path(ref['owner'], digest), package / digest)
                def register():
                    return sum(store.register_package_file(package / digest)[2] for digest in unique)
                report['first_original_put_bytes'] = phase('first_original_upload_and_readback', register)
                report['first_snapshot_new_bytes'] = phase('first_snapshot_upload_and_readback', lambda: store.save(ref['owner'], job))[1]
                original_puts = len([k for k in endpoint.storage.puts if '/package-objects/' in k])
                phase('second_snapshot_no_original_upload', lambda: store.save(ref['owner'], dict(job, id=str(uuid.uuid4()))))
                after = len([k for k in endpoint.storage.puts if '/package-objects/' in k])
                if after != original_puts: raise ValueError('Original upload duplicated')
                report['second_snapshot_original_put_count'] = after - original_puts
            clean = S3Store(stage / 'fresh-cache', 'private-fixture', client=endpoint.client())
            with OperationGate(clean.root):
                report['archive_bytes'] = phase('fresh_cache_download_and_standalone_zip',
                    lambda: clean.export(ref['owner'], ref['identifier'], stage / 'export.zip'))
            target = Store(stage / 'clean-restore')
            restored_manifest, restored, added = phase('standalone_zip_import_clean_store',
                lambda: target.import_zip(ref['owner'], stage / 'export.zip'))
            if canonical(restored) != canonical(payload) or canonical(restored_manifest) != canonical(manifest):
                raise ValueError('Standalone archive changed data')
            for digest, size in unique.items():
                if file_hash(target.object_path(ref['owner'], digest)) != (digest, size): raise ValueError('Original changed')
            report.update(counts=manifest['counts'], files=len(manifest['release']['files']), unique_originals=len(unique),
                          data_sha256=manifest['data_sha256'], archive_sha256=file_hash(stage / 'export.zip')[0],
                          clean_import_original_bytes=added, all_checks_passed=True, snapshot_time=manifest['captured_at'])
            (stage / 'fixture-s3-index.json').write_text(json.dumps(endpoint.storage.metadata), encoding='utf-8')
    finally:
        stop.set(); monitor.join()
    report.update(sampled_peak_temporary_logical_bytes=peaks['temporary_logical_bytes'], disk_samples=peaks['samples'],
                  disk_sample_interval_seconds=.02, memory_after=memory_metrics())
    (stage / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
