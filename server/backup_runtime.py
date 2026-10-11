"""Single-host, cross-process resource gate and owned temporary workspaces."""
import contextlib
import json
import os
from pathlib import Path
import shutil
import threading
import time
import uuid


class BusyError(RuntimeError):
    pass


class DiskSpaceError(RuntimeError):
    pass


class OperationGate:
    def __init__(self, root, timeout=30, operation_timeout=1500):
        self.path = Path(root) / '.operation.lock'
        self.timeout = timeout
        self.operation_timeout = operation_timeout
        self.mutex = threading.RLock()
        self.local = threading.local()

    def __enter__(self):
        until = time.monotonic() + self.timeout
        if not self.mutex.acquire(timeout=self.timeout):
            raise BusyError('Another backup operation is running; retry later')
        depth = getattr(self.local, 'depth', 0)
        if depth:
            self.local.depth = depth + 1
            return self
        stream = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            stream = self.path.open('a+b')
            if self.path.stat().st_size == 0:
                stream.write(b'0'); stream.flush()
            while True:
                try:
                    if os.name == 'nt':
                        import msvcrt
                        stream.seek(0)
                        msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except (BlockingIOError, OSError):
                    if time.monotonic() >= until:
                        raise BusyError('Another backup process is running; retry later') from None
                    time.sleep(0.05)
            self.local.stream = stream
            self.local.started = time.monotonic()
            self.local.depth = 1
            return self
        except BaseException:
            if stream is not None: stream.close()
            self.mutex.release()
            raise

    def check_deadline(self):
        if getattr(self.local, 'depth', 0) and time.monotonic() - self.local.started > self.operation_timeout:
            raise BusyError('Backup operation timed out; retry later')

    def __exit__(self, *args):
        try:
            self.local.depth -= 1
            if not self.local.depth:
                stream = self.local.stream
                try:
                    if os.name == 'nt':
                        import msvcrt
                        stream.seek(0); msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
                finally:
                    stream.close()
        finally:
            self.mutex.release()


class TemporarySpace:
    marker = {'format': 1, 'purpose': 'finance-backup-temporary'}

    def __init__(self, root, minimum_free_bytes=None):
        self.root = Path(root).resolve()
        self.minimum_free_bytes = int(os.environ.get('BACKUP_MIN_FREE_BYTES', 5 * 1024**3)) if minimum_free_bytes is None else minimum_free_bytes
        if self.minimum_free_bytes < 0: raise ValueError('Invalid free space limit')
        self.folder = self.root / '.tmp'
        if self.folder.is_symlink(): raise ValueError('Unsafe temporary directory')
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)

    def check(self, reserved=0):
        if reserved < 0 or shutil.disk_usage(self.root).free < self.minimum_free_bytes + reserved:
            raise DiskSpaceError('Insufficient free disk space for a protected backup operation')

    def remove(self, path):
        path = Path(path)
        if path.is_symlink() or path.resolve().parent != self.folder.resolve():
            raise ValueError('Unsafe temporary cleanup path')
        uuid.UUID(path.name.removeprefix('op-'))
        if not path.name.startswith('op-') or json.loads((path / '.owned.json').read_text()) != self.marker:
            raise ValueError('Not a managed temporary directory')
        shutil.rmtree(path)

    @contextlib.contextmanager
    def workspace(self, reserved=0):
        self.check(reserved)
        path = self.folder / ('op-' + str(uuid.uuid4()))
        path.mkdir(mode=0o700)
        (path / '.owned.json').write_text(json.dumps(self.marker), encoding='utf-8')
        try:
            yield path
        finally:
            self.remove(path)

    def cleanup(self):
        """Caller MUST hold the common OperationGate; no age-based deletion."""
        count = 0
        for path in self.folder.iterdir():
            if path.is_symlink() or not path.is_dir() or not path.name.startswith('op-'):
                continue
            try:
                uuid.UUID(path.name[3:])
                if json.loads((path / '.owned.json').read_text()) != self.marker: continue
            except (ValueError, OSError):
                continue
            self.remove(path); count += 1
        return count
