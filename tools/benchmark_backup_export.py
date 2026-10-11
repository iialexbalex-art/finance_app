"""Measure the real Store export and ZIP validation without database writes.

Job JSON (private): {store: path, owner: UUID, identifier: snapshot UUID}.
Run with --job-file FILE --output-dir EMPTY_DIRECTORY. The report contains
only resource usage and aggregate counts, never financial rows or credentials.
No S3 operations or production restore are performed by this benchmark.
"""
import argparse
import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
from backup_store import Store, canonical, file_hash


def memory_metrics():
    if os.name == 'nt':
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [('cb', wintypes.DWORD), ('PageFaultCount', wintypes.DWORD)] + [
                (name, ctypes.c_size_t) for name in (
                    'PeakWorkingSetSize', 'WorkingSetSize', 'QuotaPeakPagedPoolUsage',
                    'QuotaPagedPoolUsage', 'QuotaPeakNonPagedPoolUsage',
                    'QuotaNonPagedPoolUsage', 'PagefileUsage', 'PeakPagefileUsage',
                    'PrivateUsage')]

        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        psapi = ctypes.WinDLL('psapi', use_last_error=True)
        psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
        value = Counters()
        value.cb = ctypes.sizeof(value)
        if not psapi.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(value), value.cb):
            raise ctypes.WinError(ctypes.get_last_error())
        return {'method': 'Windows GetProcessMemoryInfo',
                'peak_rss_bytes': value.PeakWorkingSetSize,
                'rss_bytes': value.WorkingSetSize,
                'peak_private_commit_bytes': value.PeakPagefileUsage,
                'private_commit_bytes': value.PrivateUsage}
    import resource
    value = resource.getrusage(resource.RUSAGE_SELF)
    return {'method': 'getrusage(RUSAGE_SELF).ru_maxrss',
            'peak_rss_bytes': int(value.ru_maxrss * (1 if sys.platform == 'darwin' else 1024))}


def one_cpu():
    if os.name == 'nt':
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetCurrentProcess.restype = wintypes.HANDLE
        kernel.GetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
        kernel.SetProcessAffinityMask.argtypes = [wintypes.HANDLE, ctypes.c_size_t]
        process, system = ctypes.c_size_t(), ctypes.c_size_t()
        handle = kernel.GetCurrentProcess()
        if not kernel.GetProcessAffinityMask(handle, ctypes.byref(process), ctypes.byref(system)):
            raise ctypes.WinError(ctypes.get_last_error())
        if not kernel.SetProcessAffinityMask(handle, process.value & -process.value):
            raise ctypes.WinError(ctypes.get_last_error())
        return True
    if hasattr(os, 'sched_getaffinity'):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
        return True
    return False


def allocated_size(path):
    if os.name == 'nt':
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetCompressedFileSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetCompressedFileSizeW.restype = wintypes.DWORD
        high = wintypes.DWORD()
        ctypes.set_last_error(0)
        low = kernel.GetCompressedFileSizeW(str(path), ctypes.byref(high))
        if low == 0xFFFFFFFF and ctypes.get_last_error():
            raise ctypes.WinError(ctypes.get_last_error())
        return (high.value << 32) | low
    stat = path.stat()
    return stat.st_blocks * 512 if hasattr(stat, 'st_blocks') else stat.st_size


def temporary_usage(stage, store, existing_files):
    # Export ZIP is in stage. Store.import_zip stages one original directly in
    # store.root. Exclude existing archives; never count the immutable CAS twice.
    paths = list(stage.glob('*.zip')) + list((store / '.tmp').rglob('*')) + [p for p in store.iterdir()
                                       if p.is_file() and p.name not in existing_files]
    logical = allocated = 0
    allocation_unavailable = False
    for path in paths:
        try:
            if not path.is_file(): continue
            logical += path.stat().st_size
            try:
                allocated += allocated_size(path)
            except PermissionError:
                # Windows can deny opening a NamedTemporaryFile for allocation
                # statistics while its creator holds it. Logical size is still
                # measurable; never present incomplete allocation as a total.
                allocation_unavailable = True
        except FileNotFoundError:
            pass  # A short-lived import staging file finished between samples.
    return logical, allocated, allocation_unavailable


def child(args):
    job = json.loads(Path(args.job_file).read_text(encoding='utf-8'))
    single_cpu = one_cpu()
    store = Store(job['store'])
    archive = Path(args.output_dir) / 'export.zip'
    started = time.perf_counter()
    cpu_started = time.process_time()
    result = {'phase': args.phase, 'single_cpu_affinity': single_cpu,
              'memory_before': memory_metrics()}
    if args.phase == 'export':
        result['archive_bytes'] = store.export(job['owner'], job['identifier'], archive)
    else:
        expected_manifest, expected_payload = store.read(job['owner'], job['identifier'])
        manifest, payload, added = store.import_zip(job['owner'], archive)
        if canonical(payload) != canonical(expected_payload) or manifest != expected_manifest:
            raise ValueError('Full archive differs from saved snapshot')
        result.update({'counts': manifest['counts'], 'files': len(manifest['release']['files']),
                       'unique_originals': len({v['sha256'] for v in manifest['release']['files'].values()}),
                       'largest_original_bytes': max(v['size'] for v in manifest['release']['files'].values()),
                       'new_original_bytes': added, 'data_sha256': manifest['data_sha256'],
                       'captured_at': manifest['captured_at'], 'all_archive_checks_passed': True})
    result.update({'elapsed_seconds': time.perf_counter() - started,
                   'cpu_seconds': time.process_time() - cpu_started,
                   'memory_after': memory_metrics()})
    print(json.dumps(result), flush=True)


def measure(args, phase):
    stage = Path(args.output_dir).resolve()
    job = json.loads(Path(args.job_file).read_text(encoding='utf-8'))
    store = Path(job['store']).resolve()
    existing = {p.name for p in store.iterdir() if p.is_file()}
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
        '--job-file', str(Path(args.job_file).resolve()), '--output-dir', str(stage),
        '--phase', phase], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8')
    logical_peak = allocated_peak = samples = 0
    allocation_unavailable = False
    try:
        while True:
            logical, allocated, unavailable = temporary_usage(stage, store, existing)
            allocation_unavailable |= unavailable
            logical_peak, allocated_peak = max(logical_peak, logical), max(allocated_peak, allocated)
            samples += 1
            if process.poll() is not None:
                break
            time.sleep(0.01)
        stdout, stderr = process.communicate()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
    if process.returncode:
        # Do not relay arbitrary exception payloads into logs/reports.
        raise RuntimeError('Benchmark phase failed: ' + phase + '; exit ' + str(process.returncode))
    result = json.loads(stdout)
    result.update({'sampled_peak_temporary_logical_bytes': logical_peak,
                   'sampled_peak_temporary_allocated_bytes': None if allocation_unavailable else allocated_peak,
                   'allocation_unavailable_for_some_open_files': allocation_unavailable,
                   'disk_sample_interval_seconds': 0.01, 'disk_samples': samples})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job-file', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--phase', choices=['export', 'verify'])
    args = parser.parse_args()
    if args.phase:
        child(args)
        return
    stage = Path(args.output_dir).resolve()
    stage.mkdir(parents=True, exist_ok=True)
    if any(stage.iterdir()):
        raise ValueError('Benchmark requires an empty output directory')
    report = {'measured_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
              'platform': platform.platform(), 'python': platform.python_version(),
              'production_database_written': False, 's3_tested': False,
              'limits': 'One CPU affinity; no 2 GiB VM or cgroup limit; OS/cache excluded',
              'phases': []}
    for phase in ('export', 'verify'):
        report['phases'].append(measure(args, phase))
        (stage / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    report['archive_sha256'] = file_hash(stage / 'export.zip')[0]
    (stage / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
