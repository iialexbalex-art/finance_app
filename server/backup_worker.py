"""Private backup HTTP API + durable daily scheduler on a long-lived server.

The worker is NOT an Edge Function and must run outside the user's computer.
It validates Supabase access tokens for every request. No token is logged/stored.
Bind loopback behind an HTTPS reverse proxy; expose only configured APP_ORIGIN.
"""
import argparse
import functools
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from zoneinfo import ZoneInfo

from backup_store import Store, MAX_ARCHIVE, MAX_FILE, MAX_ENTRIES, canonical, sha, file_hash
from backup_runtime import OperationGate, BusyError, DiskSpaceError
from backup_s3 import S3Store, StorageError

UTC = dt.timezone.utc
TZ = ZoneInfo('Asia/Qyzylorda')
NAMESPACE = uuid.UUID('d5caf4aa-a0e9-47c2-91e2-c2d80c7c0a98')
SCHEDULER_ERROR = 'Резервирование не выполнено. Проверьте подключение и хранилище.'

def serialized(method):
    @functools.wraps(method)
    def wrapped(self, *args, **kwargs):
        with self.lock:
            self.store.temporary.check()
            return method(self, *args, **kwargs)
    return wrapped

def configured_store():
    root = os.environ['BACKUP_STORAGE_ROOT']
    backend = os.environ.get('BACKUP_STORAGE_BACKEND', 'local')
    if backend not in {'local', 's3'}: raise ValueError('Unknown storage backend')
    return S3Store.from_environment(root) if backend == 's3' else Store(root)

def due_date(now):
    local = now.astimezone(TZ)
    if (local.hour, local.minute) < (23, 59):
        local -= dt.timedelta(days=1)
    return local.date()

def next_run(now):
    local = now.astimezone(TZ)
    due = local.replace(hour=23, minute=59, second=0, microsecond=0)
    if local >= due:
        due += dt.timedelta(days=1)
    return due.astimezone(UTC)

class Worker:
    def __init__(self):
        self.dsn = os.environ['BACKUP_DATABASE_URL']
        self.store = configured_store()
        self.supabase_url = os.environ['SUPABASE_URL'].rstrip('/')
        self.publishable_key = os.environ['SUPABASE_PUBLISHABLE_KEY']
        self.origin = os.environ['APP_ORIGIN'].rstrip('/')
        self.storage_label = os.environ.get('BACKUP_STORAGE_LABEL', 'Private server storage')
        self.independent = os.environ.get('BACKUP_INDEPENDENT', '') == 'true'
        self.release_path = self.store.root / 'release.json'
        self.scheduler_error = None
        self.lock = OperationGate(self.store.root)
        self.store.deadline_check = self.lock.check_deadline
        self.scheduler_thread = None
        self.scheduler_heartbeat = None
        self.scheduler_started = None
        self.scheduler_summary = None
        with self.lock:
            self.store.cleanup_temporary()
            if isinstance(self.store, S3Store): self.store.validate_access()

    def call(self, name, *args):
        import psycopg
        # Call names are internal constants only; no SQL/table names from HTTP.
        allowed = {'owners', 'capture', 'get', 'list', 'release', 'claim', 'seal',
                   'fail', 'import', 'pending', 'delete', 'history', 'undo', 'prune',
                   'storage_count', 'asset_manifest', 'pin', 'unpin'}
        if name not in allowed:
            raise ValueError('Unsupported function')
        with psycopg.connect(self.dsn, connect_timeout=10) as conn:
            conn.execute("set statement_timeout = '60s'")
            params = [psycopg.types.json.Jsonb(a) if isinstance(a, (dict, list)) else a for a in args]
            result = conn.execute('select finance_private.backup_worker_' + name + '(' + ','.join(['%s'] * len(args)) + ')', params).fetchall()
            if name == 'owners':
                return [str(r[0]) for r in result]
            value = result[0][0] if result else None
            return str(value) if isinstance(value, uuid.UUID) else value

    @serialized
    def restore(self, owner, source, request):
        import psycopg
        # Revalidate the immutable archive and files before DB changes.
        job = self.call('get', owner, source)
        if not job or job['state'] != 'ready':
            raise ValueError('Ready backup required')
        pin=str(uuid.uuid4())
        self.call('pin',owner,source,pin)
        try:
            self.verified_read(owner, job)
            self.capture(owner, request, 'restore', 'Перед полным восстановлением')
            with psycopg.connect(self.dsn, connect_timeout=10) as conn:
                conn.execute("set statement_timeout = '60s'")
                conn.execute('select finance_private.backup_restore(%s,%s,%s)', (owner, source, request))
        finally:
            self.call('unpin',owner,pin)

    def verified_read(self,owner,job):
        manifest,payload=self.store.read(owner,job['id'])
        if manifest['data_sha256']!=job['data_sha256'] or manifest['release']!=job['release'] or canonical(payload)!=canonical(job['payload']):
            raise ValueError('Independent storage does not match the sealed database snapshot')
        return manifest,payload

    def identify(self, token):
        if not token or len(token) > 16384:
            raise PermissionError('Sign in required')
        request = urllib.request.Request(self.supabase_url + '/auth/v1/user', headers={
            'Authorization': 'Bearer ' + token, 'apikey': self.publishable_key})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                user = json.load(response)
        except urllib.error.HTTPError:
            raise PermissionError('Session expired') from None
        owner = str(uuid.UUID(user['id']))
        # Do not expose any job metadata or originals to a manager/non-owner.
        if owner not in self.call('owners'):
            raise PermissionError('Owner access required')
        return owner

    @serialized
    def register_assets(self, project):
        """Deployment command. Originals uploaded once, no browser access needed."""
        project = Path(project).resolve()
        manifest = {}
        added=0
        for p in sorted((project / 'assets').rglob('*')):
            self.lock.check_deadline()
            if p.is_file():
                name = p.relative_to(project).as_posix()
                if p.is_symlink() or p.stat().st_size > MAX_FILE or len(manifest) >= MAX_ENTRIES - 3:
                    raise ValueError('Unsupported release original')
                digest, size, count = self.store.register_package_file(p)
                added += count
                manifest[name] = {'sha256': digest, 'size': size}
        if not manifest:
            raise ValueError('No assets found')
        version = sha(canonical(manifest))
        added += self.store.save_release({'version': version, 'files': manifest})
        self.call('release', version, manifest)
        return {'files': len(manifest), 'original_bytes': sum(x['size'] for x in manifest.values()), 'new_bytes':added, 'version': version}

    def process(self, owner, identifier):
        with self.lock:
            self.store.temporary.check()
            job = self.call('get', owner, identifier)
            if not job:
                raise PermissionError('Backup unavailable')
            if job['state'] == 'ready':
                self.verified_read(owner, job)
                return job
            if not self.call('claim', owner, identifier):
                raise ValueError('Backup is running or exhausted retries')
            try:
                added = 0
                # Storage adapter is intentionally fail-closed. Current app uses
                # embedded assets only; unseen remote attachments must not be
                # silently omitted from a snapshot advertised as complete.
                if self.call('storage_count', owner):
                    raise ValueError('Remote Storage attachments need an owner-scoped adapter')
                for info in ([] if isinstance(self.store, S3Store) else job['release']['files'].values()):
                    target = self.store.object_path(owner, info['sha256'])
                    if not target.exists():
                        source = self.store.root / 'package-objects' / info['sha256']
                        _, _, count = self.store.put_file(owner, source)
                        added += count
                manifest, size = self.store.save(owner, job)
                if isinstance(self.lock, OperationGate): self.lock.check_deadline()
                export_size = manifest['data_size'] + sum(i['size'] for i in manifest['release']['files'].values())
                self.call('seal', owner, identifier, manifest['data_sha256'], size + added, export_size, self.storage_label)
                return self.call('get', owner, identifier)
            except Exception:
                try: self.call('fail', owner, identifier)
                except Exception: pass  # Lease/pending retry survives a DB outage.
                raise

    @serialized
    def capture(self, owner, request, kind='manual', comment=''):
        identifier = self.call('capture', owner, str(uuid.UUID(request)), kind, comment)
        return self.process(owner, identifier)

    @serialized
    def preview(self, owner, identifier):
        job = self.call('get', owner, identifier)
        if not job or job['state'] != 'ready':
            raise PermissionError('Backup unavailable')
        manifest, payload = self.verified_read(owner, job)
        return {'id': identifier, 'captured_at': manifest['captured_at'], 'counts': manifest['counts'],
                'schema': manifest['schema'], 'files': len(manifest['release']['files']),
                'scope': [s['name'] for s in payload['data']['spaces']],
                'warning': 'Все личные и бизнес-данные владельца будут заменены. Более поздние записи будут удалены. Права доступа не импортируются.'}

    @serialized
    def import_archive(self, owner, path):
        with self.lock:
            manifest, payload, added = self.store.import_zip(owner, path)
            identifier = str(uuid.uuid4())
            self.call('import', owner, identifier, payload, manifest['release'], manifest['data_sha256'], manifest['captured_at'])
            job = self.call('get', owner, identifier)
            try:
                if not self.call('claim', owner, identifier): raise ValueError('Imported backup could not be claimed')
                stored, size = self.store.save(owner, job)
                self.call('seal', owner, identifier, stored['data_sha256'], size + added,
                          stored['data_size'] + sum(i['size'] for i in stored['release']['files'].values()), self.storage_label)
                return self.preview(owner, identifier)
            except Exception:
                try: self.call('fail', owner, identifier)
                except Exception: pass
                raise

    def tick(self, now=None, verify_existing=False):
        now = now or dt.datetime.now(UTC)
        created, verified, existing, failures, seen = set(), set(), set(), set(), set()
        with self.lock:
            if hasattr(self, 'store'):
                self.store.cleanup_temporary()
                self.store.temporary.check()
            for owner in self.call('owners'):
                identifier = None
                try:
                    request = str(uuid.uuid5(NAMESPACE, owner + ':daily:' + due_date(now).isoformat()))
                    # Catchup captures NOW; the date is an idempotency key only.
                    identifier = self.call('capture', owner, request, 'daily', '23:59 Asia/Qyzylorda; actual capture time in snapshot')
                    seen.add((owner, identifier))
                    job = self.call('get', owner, identifier)
                    if job['state'] != 'ready':
                        self.process(owner, identifier)
                        if self.call('get', owner, identifier)['state'] != 'ready':
                            raise ValueError('Backup was not sealed')
                        created.add((owner, identifier))
                    elif verify_existing:
                        self.verified_read(owner, job)
                        verified.add((owner, identifier))
                    else:
                        existing.add((owner, identifier))
                    deleted = self.call('prune', owner)
                    if deleted: self.store.remove_snapshots(owner, set(deleted))
                except Exception:
                    failures.add((owner, identifier))
            for job in self.call('pending') or []:
                key = (job['owner_id'], job['id'])
                seen.add(key)
                try:
                    self.process(*key)
                    if self.call('get', *key)['state'] != 'ready': raise ValueError('Backup was not sealed')
                    created.add(key)
                    failures.discard(key)
                except Exception:
                    failures.add(key)
        self.scheduler_error = SCHEDULER_ERROR if failures else None
        result = {'status': 'failed' if failures else 'completed' if created or verified else 'idle' if seen else 'no_jobs',
                  'created_count': len(created), 'verified_count': len(verified),
                  'existing_count': len(existing), 'failed_count': len(failures)}
        self.scheduler_summary = result
        return result

    def scheduler_healthy(self):
        if not self.scheduler_thread or not self.scheduler_thread.is_alive(): return False
        now = time.monotonic()
        if self.scheduler_started is not None:
            return now - self.scheduler_started < self.lock.operation_timeout + self.lock.timeout + 60
        return self.scheduler_heartbeat is not None and now - self.scheduler_heartbeat < 120

    def schedule(self):
        while True:
            self.scheduler_heartbeat = time.monotonic()
            self.scheduler_started = self.scheduler_heartbeat
            try:
                self.tick()
            except Exception:
                self.scheduler_error = SCHEDULER_ERROR
                self.scheduler_summary = {'status': 'failed', 'error': SCHEDULER_ERROR}
            finally:
                self.scheduler_started = None
                self.scheduler_heartbeat = time.monotonic()
            time.sleep(30)


class PrivateHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # The default implementation prints exception tracebacks with request data.
        print('HTTP request ended without completion', file=sys.stderr)


def handler(worker):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(30)
            self.transfer_started = time.monotonic()

        def log_message(self, *args): pass

        def transfer_check(self):
            worker.lock.check_deadline()
            if time.monotonic() - self.transfer_started > 900:
                raise TimeoutError('HTTP transfer timed out')

        def stream_file(self, path):
            with Path(path).open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    self.transfer_check()
                    self.wfile.write(chunk)

        def upload_chunks(self, size):
            remaining = size
            while remaining:
                self.transfer_check()
                # read1 returns after one underlying read, so trickling clients
                # cannot evade the overall deadline inside a large buffered read.
                chunk = self.rfile.read1(min(1024 * 1024, remaining))
                if not chunk: raise ValueError('Truncated upload')
                remaining -= len(chunk)
                yield chunk

        def cors(self):
            self.send_header('Access-Control-Allow-Origin', worker.origin)
            self.send_header('Vary', 'Origin')
            self.send_header('Cache-Control', 'no-store')

        def do_OPTIONS(self):
            if self.headers.get('Origin') != worker.origin:
                self.send_error(403); return
            self.send_response(204)
            self.cors()
            self.send_header('Access-Control-Allow-Headers', 'Authorization,Content-Type')
            self.send_header('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS')
            self.end_headers()

        def json_reply(self, value, status=200):
            data = canonical(value)
            self.send_response(status); self.cors()
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)

        def dispatch(self):
            if self.headers.get('Origin') not in {None, worker.origin}:
                raise PermissionError('Origin not allowed')
            auth = self.headers.get('Authorization', '')
            owner = worker.identify(auth[7:] if auth.startswith('Bearer ') else '')
            path = self.path.split('?', 1)[0]
            parts = path.strip('/').split('/')
            if self.command == 'GET' and path == '/status':
                jobs = worker.call('list', owner)
                successful = [j for j in jobs if j['state'] == 'ready']
                last = max(successful, key=lambda j: j['captured_at']) if successful else None
                stale = not last or dt.datetime.now(UTC) - dt.datetime.fromisoformat(last['captured_at'].replace('Z', '+00:00')) > dt.timedelta(hours=25)
                healthy = worker.scheduler_healthy()
                return self.json_reply({'independent': worker.independent, 'storage': worker.storage_label,
                    'scheduler_active': healthy, 'next_run': next_run(dt.datetime.now(UTC)).isoformat() if healthy else None,
                    'stale': stale, 'error': worker.scheduler_error or (None if healthy else 'Планировщик резервных копий не работает.'),
                    'last_ready': last, 'jobs': jobs, 'last_run': worker.scheduler_summary})
            if self.command == 'GET' and path == '/history':
                return self.json_reply(worker.call('history', owner))
            # Common OS file gate covers the whole HTTP transfer and all nested
            # worker operations, including automatic/CLI execution in another process.
            with worker.lock:
                worker.store.temporary.check()
                return self.heavy_dispatch(owner, path, parts)

        def heavy_dispatch(self, owner, path, parts):
            if len(parts) == 3 and parts[0] == 'backups' and self.command == 'GET':
                identifier = str(uuid.UUID(parts[1]))
                if parts[2] == 'preview': return self.json_reply(worker.preview(owner, identifier))
                if parts[2] == 'download':
                    pin = str(uuid.uuid4())
                    worker.call('pin', owner, identifier, pin)
                    try:
                        worker.preview(owner, identifier)
                        with worker.store.workspace() as directory:
                            output = directory / 'export.zip'
                            size = worker.store.export(owner, identifier, output)
                            manifest, _ = worker.store.read(owner, identifier)
                            stamp = dt.datetime.fromisoformat(manifest['captured_at'].replace('Z', '+00:00')).astimezone(TZ).strftime('%Y-%m-%d_%H-%M-%S')
                            self.send_response(200); self.cors()
                            self.send_header('Content-Type', 'application/zip')
                            self.send_header('Content-Length', str(size))
                            self.send_header('Content-Disposition', 'attachment; filename="finance_' + stamp + '_UTC+05.zip"')
                            self.end_headers(); self.stream_file(output)
                    finally:
                        worker.call('unpin', owner, pin)
                    return
            if self.command == 'GET' and len(parts) == 2 and parts[0] == 'assets':
                digest = parts[1]
                allowed = worker.call('asset_manifest', owner)
                info = next((i for i in allowed.values() if i['sha256'] == digest), None)
                if not info: raise PermissionError('Asset unavailable')
                if isinstance(worker.store, S3Store): worker.store._original(owner, digest, info['size'])
                image = worker.store.object_path(owner, digest)
                if file_hash(image) != (digest, info['size']): raise ValueError('Original checksum mismatch')
                self.send_response(200); self.cors()
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(info['size']))
                self.end_headers(); self.stream_file(image); return
            if self.command == 'DELETE' and len(parts) == 2 and parts[0] == 'backups':
                identifier = str(uuid.UUID(parts[1]))
                worker.call('delete', owner, identifier)
                worker.store.remove_snapshots(owner, {identifier})
                return self.json_reply({'deleted': True})
            size = int(self.headers.get('Content-Length', '0'))
            if self.command == 'POST' and path == '/import':
                if size <= 0 or size > MAX_ARCHIVE: raise ValueError('Invalid archive length')
                # Finally cleanup includes the upload itself, even a disconnect.
                with worker.store.workspace(size + MAX_FILE) as directory:
                    temporary = directory / 'upload.zip'
                    with temporary.open('wb') as out:
                        for chunk in self.upload_chunks(size): out.write(chunk)
                    return self.json_reply(worker.import_archive(owner, temporary))
            if size <= 0 or size > 65536: raise ValueError('Invalid request length')
            body = json.loads(b''.join(self.upload_chunks(size)))
            if not isinstance(body, dict): raise ValueError('Invalid request body')
            if self.command == 'POST' and path == '/capture':
                if body.get('kind', 'manual') not in {'manual', 'before'}: raise ValueError('Unsupported capture kind')
                job = worker.capture(owner, body['request_id'], body.get('kind', 'manual'), body.get('comment', ''))
                return self.json_reply({'id': job['id'], 'state': job['state']})
            if self.command == 'POST' and path == '/restore':
                worker.restore(owner, str(uuid.UUID(body['source_id'])), str(uuid.UUID(body['request_id'])))
                return self.json_reply({'restored': True})
            if self.command == 'POST' and path == '/undo':
                worker.capture(owner, str(uuid.UUID(body['request_id'])), 'before', 'Before undo')
                worker.call('undo', owner, str(uuid.UUID(body['operation_id'])), str(uuid.UUID(body['request_id'])))
                return self.json_reply({'undone': True})
            raise ValueError('Unsupported endpoint')

        def safe_dispatch(self):
            try:
                self.dispatch()
            except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout):
                self.close_connection = True
            except Exception as error:
                # Never echo arbitrary exception messages or provider responses.
                status, message = 409, 'Сервер не подтвердил действие. Проверьте хранилище и обновите экран.'
                if isinstance(error, PermissionError): status, message = 403, 'Требуется авторизация владельца.'
                elif isinstance(error, (ValueError, KeyError)): status, message = 400, 'Запрос или копия не прошли проверку.'
                elif isinstance(error, DiskSpaceError): status, message = 507, 'Недостаточно свободного места для защищённой операции.'
                elif isinstance(error, BusyError): status, message = 503, 'Операция резервирования занята или превысила время. Повторите позже.'
                elif isinstance(error, StorageError): status, message = 503, 'S3 не подтвердило сохранённое содержимое. Проверьте защищённые настройки хранилища.'
                if getattr(error, 'sqlstate', '') in {'P1003', 'P1018', '23503', '23514'}:
                    message = 'Данные или зависимости изменились. Восстановление/отмена не выполнены.'
                try: self.json_reply({'error': message}, status)
                except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout): self.close_connection = True
        do_GET = safe_dispatch
        do_POST = safe_dispatch
        do_DELETE = safe_dispatch
    return Handler


def run_once(worker):
    try:
        result = worker.tick(verify_existing=True)
        if result['failed_count']: return 1, result
        if result['status'] == 'no_jobs': return 2, result
        if not result['created_count'] and not result['verified_count']:
            return 2, dict(result, status='no_verified_backup')
        return 0, result
    except Exception:
        return 1, {'status': 'failed', 'error': SCHEDULER_ERROR}


def main(argv=None):
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--register-assets')
    group.add_argument('--once', action='store_true')
    group.add_argument('--check-storage', action='store_true')
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args(argv)
    try:
        if args.check_storage:
            store = configured_store()
            if not isinstance(store, S3Store): raise ValueError('S3 backend required')
            gate = OperationGate(store.root)
            store.deadline_check = gate.check_deadline
            with gate:
                store.cleanup_temporary()
                store.check_storage()
            print(json.dumps({'status': 'storage_verified', 'private': True, 'conditional_put': True}))
            return 0
        worker = Worker()
        if args.register_assets:
            print(json.dumps(dict(worker.register_assets(args.register_assets), status='release_verified')))
            return 0
        if args.once:
            code, result = run_once(worker)
            print(json.dumps(result)); return code
        worker.scheduler_thread = threading.Thread(target=worker.schedule, daemon=True)
        worker.scheduler_thread.start()
        PrivateHTTPServer(('127.0.0.1', args.port), handler(worker)).serve_forever()
    except Exception:
        print(json.dumps({'status': 'failed', 'error': 'Worker failed; check protected configuration, permissions and storage'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
