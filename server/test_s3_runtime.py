"""Isolated S3 fault injection; no external account/DB/credentials required."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from botocore.exceptions import ClientError
from backup_store import Store, canonical, file_hash
from backup_runtime import OperationGate, TemporarySpace, BusyError, DiskSpaceError
from backup_s3 import S3Store, StorageError
from backup_worker import Worker, run_once, PrivateHTTPServer, handler, main
from test_backups import OWNER, OTHER, payload


class DiskS3:
    """Disk-backed SDK-shaped fixture, including atomic conditional PUT."""
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.metadata = {}
        self.puts = []
        self.put_bytes = 0
        self.fault = None
        self.corrupt_put = False
        self.interrupt_put = False
        self.interrupt_get = False
        self.public = False
        self.policy = None

    def error(self, code):
        raise ClientError({'Error': {'Code': code, 'Message': 'SECRET-DO-NOT-LOG'}}, 'Fixture')

    def check(self):
        if self.fault == 'offline': raise OSError('SECRET-DO-NOT-LOG')
        if self.fault: self.error(self.fault)

    def path(self, key):
        # Never interpret remote keys as OS paths supplied by an archive.
        from backup_store import sha
        return self.root / sha(key.encode())

    def get_bucket_acl(self, **kw):
        self.check()
        return {'Grants': [{'Grantee': {'Type': 'Group'}, 'Permission': 'READ'}] if self.public else []}

    def get_bucket_policy(self, **kw):
        self.check()
        if self.policy is None: self.error('NoSuchBucketPolicy')
        return {'Policy': json.dumps(self.policy)}

    def head_object(self, Key, **kw):
        self.check()
        if Key not in self.metadata: self.error('NoSuchKey')
        return {'ContentLength': self.path(Key).stat().st_size, 'Metadata': self.metadata[Key]}

    def put_object(self, Key, Body, ContentLength, IfNoneMatch, Metadata=None, **kw):
        self.check()
        if Key in self.metadata and IfNoneMatch == '*': self.error('PreconditionFailed')
        if self.interrupt_put: raise OSError('SECRET-DO-NOT-LOG interrupted PUT')
        self.puts.append(Key)
        count = 0
        with self.path(Key).open('wb') as out:
            for chunk in iter(lambda: Body.read(1024 * 1024), b''):
                out.write(chunk); count += len(chunk)
        if count != ContentLength: raise AssertionError('Invalid length')
        self.put_bytes += count
        self.metadata[Key] = Metadata or {}
        if self.corrupt_put:
            with self.path(Key).open('r+b') as out: out.write(b'X')
        return {}

    def get_object(self, Key, **kw):
        info = self.head_object(Key=Key)
        body = self.path(Key).open('rb')
        if self.interrupt_get:
            original_body = body
            class Interrupted:
                def read(self, size): raise OSError('SECRET-DO-NOT-LOG broken stream')
                def close(self): original_body.close()
            body = Interrupted()
        return dict(info, Body=body)

    def delete_object(self, Key, **kw):
        self.check()
        self.metadata.pop(Key, None)
        self.path(Key).unlink(missing_ok=True)
        return {}


class FixtureWorker(Worker):
    def __init__(self, store, job):
        self.store = store
        self.lock = OperationGate(store.root, timeout=.5)
        self.store.deadline_check = self.lock.check_deadline
        self.jobs = {job['id']: dict(copy.deepcopy(job), state='queued', owner_id=OWNER)}
        self.storage_label = 'isolated fixture'
        self.scheduler_error = None
        self.scheduler_summary = None
        self.sealed = 0
        self.owner_list = [OWNER]
        self.scheduler_thread = None
        self.scheduler_heartbeat = None
        self.scheduler_started = None
        self.origin = 'https://fixture.invalid'
        self.independent = False

    def identify(self, token):
        if token != 'fixture-token': raise PermissionError('Authorization required')
        return OWNER

    def call(self, name, *args):
        if name == 'owners': return self.owner_list
        if name == 'get': return self.jobs.get(args[1])
        if name == 'capture': return next(iter(self.jobs))
        if name == 'claim': self.jobs[args[1]]['state'] = 'running'; return True
        if name == 'storage_count': return 0
        if name == 'fail': self.jobs[args[1]]['state'] = 'failed'; return
        if name == 'seal':
            self.sealed += 1
            self.jobs[args[1]].update(state='ready', data_sha256=args[2])
            return
        if name == 'pending': return [j for j in self.jobs.values() if j['state'] != 'ready']
        if name in {'prune', 'release', 'pin', 'unpin'}: return None
        if name == 'list': return list(self.jobs.values())
        raise AssertionError(name)


class S3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.client = DiskS3(self.root / 'remote')
        self.store = S3Store(self.root / 'cache', 'private-fixture', client=self.client, minimum_free_bytes=0)
        self.image = self.root / 'image.png'
        self.image.write_bytes(b'original image bytes unchanged')
        digest, size, _ = self.store.register_package_file(self.image)
        self.digest = digest
        self.job = {'id': str(uuid.uuid4()), 'captured_at': '2026-10-07T09:42:58Z', 'payload': payload(),
                    'release': {'version': 'fixture', 'files': {'assets/test.png': {'sha256': digest, 'size': size}}}}
        self.worker = FixtureWorker(self.store, self.job)

    def tearDown(self): self.temp.cleanup()

    def test_save_readback_then_seal_repeat_no_original_put(self):
        self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 1)
        original_puts = [k for k in self.client.puts if '/package-objects/' in k]
        second = dict(self.job, id=str(uuid.uuid4()))
        self.store.save(OWNER, second)
        before = len(self.client.puts)
        self.store.save(OWNER, second)
        self.assertEqual(len(self.client.puts), before)
        self.assertEqual(original_puts, [k for k in self.client.puts if '/package-objects/' in k])

    def test_offline_wrong_key_interrupted_put_cannot_seal_or_leak(self):
        for fault in ['offline', 'InvalidAccessKeyId', 'SignatureDoesNotMatch', 'AccessDenied']:
            with self.subTest(fault=fault):
                self.client.fault = fault
                with self.assertRaises(StorageError) as caught: self.worker.process(OWNER, self.job['id'])
                self.assertNotIn('SECRET', str(caught.exception))
                self.assertEqual(self.worker.sealed, 0)
                self.assertEqual(self.worker.jobs[self.job['id']]['state'], 'failed')
                code, result = run_once(self.worker)
                self.assertEqual(code, 1)
                self.assertEqual(result['status'], 'failed')
        self.client.fault = None
        self.client.interrupt_put = True
        with self.assertRaises(StorageError): self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 0)
        self.client.interrupt_put = False
        self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 1)
        self.assertEqual(list(self.store.temporary.folder.iterdir()), [])

    def test_corrupt_original_even_with_good_head_and_cache_rejected(self):
        key = self.store._key('package-objects/' + self.digest)
        self.client.path(key).write_bytes(b'X' * self.image.stat().st_size)
        with self.assertRaisesRegex(StorageError, 'checksum'): self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 0)

    def test_corrupt_saved_snapshot_before_seal(self):
        self.client.corrupt_put = True
        with self.assertRaises(StorageError): self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 0)
        self.assertEqual(self.worker.jobs[self.job['id']]['state'], 'failed')

    def test_interrupted_download_cleanup(self):
        self.client.interrupt_get = True
        with self.assertRaises(StorageError): self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 0)
        self.assertEqual(list(self.store.temporary.folder.iterdir()), [])

    def test_snapshot_half_uploaded_retry_reuses_completed_data(self):
        original = self.client.put_object
        def fail_manifest(**args):
            if args['Key'].endswith('/manifest.json'): raise OSError('SECRET-DO-NOT-LOG')
            return original(**args)
        with patch.object(self.client, 'put_object', fail_manifest):
            with self.assertRaises(StorageError): self.worker.process(OWNER, self.job['id'])
        self.assertEqual(self.worker.sealed, 0)
        data_puts = [k for k in self.client.puts if k.endswith('/data.json.gz')]
        self.worker.process(OWNER, self.job['id'])
        self.assertEqual(data_puts, [k for k in self.client.puts if k.endswith('/data.json.gz')])
        self.assertEqual(self.worker.sealed, 1)

    def test_clean_cache_standalone_zip_restore_without_source_assets(self):
        self.worker.process(OWNER, self.job['id'])
        clean = S3Store(self.root / 'new-cache', 'private-fixture', client=self.client, minimum_free_bytes=0)
        archive = self.root / 'standalone.zip'
        clean.export(OWNER, self.job['id'], archive)
        restored = Store(self.root / 'restored', minimum_free_bytes=0)
        manifest, data, added = restored.import_zip(OWNER, archive)
        self.assertEqual(data, self.job['payload'])
        self.assertEqual(added, self.image.stat().st_size)
        self.assertEqual(restored.object_path(OWNER, self.digest).read_bytes(), self.image.read_bytes())
        restored.save(OWNER, dict(self.job, id=str(uuid.uuid4()), payload=data, release=manifest['release']))

    def test_private_owner_uploads_not_shared_with_other_owner(self):
        self.store.put_file(OWNER, self.image)
        private = self.root / 'private.png'; private.write_bytes(b'private attachment')
        digest, size, _ = self.store.put_file(OWNER, private)
        with self.assertRaises(StorageError): self.store._original(OTHER, digest, size)

    def test_public_acl_policy_or_unreadable_policy_fail_closed(self):
        self.client.public = True
        with self.assertRaises(StorageError): self.store.validate_access()
        self.client.public = False
        self.client.policy = {'Statement': {'Effect': 'Allow', 'Principal': {'AWS': ['*']}}}
        with self.assertRaises(StorageError): self.store.validate_access()
        self.client.policy = None; self.client.fault = 'AccessDenied'
        with self.assertRaises(StorageError): self.store.validate_access()

    def test_probe_conditional_write_and_cleanup(self):
        self.store.check_storage()
        self.assertFalse(any('/checks/' in k for k in self.client.metadata))
        original = self.client.put_object
        def ignore_condition(**args):
            self.client.metadata.pop(args['Key'], None)
            return original(**args)
        with patch.object(self.client, 'put_object', ignore_condition):
            with self.assertRaisesRegex(StorageError, 'conditional'): self.store.check_storage()
        self.assertFalse(any('/checks/' in k for k in self.client.metadata))

    def test_pruning_retains_originals_and_other_snapshot(self):
        self.store.save(OWNER, self.job)
        second = dict(self.job, id=str(uuid.uuid4()))
        self.store.save(OWNER, second)
        self.store.remove_snapshots(OWNER, {self.job['id']})
        self.store.read(OWNER, second['id'])
        self.assertIn(self.store._key('package-objects/' + self.digest), self.client.metadata)

    def test_disk_guard_precedes_capture(self):
        calls = []
        original = self.worker.call
        self.worker.call = lambda *args: (calls.append(args[0]), original(*args))[1]
        with patch('backup_runtime.shutil.disk_usage', return_value=type('Usage', (), {'free': -1})()):
            with self.assertRaises(DiskSpaceError): self.worker.capture(OWNER, str(uuid.uuid4()))
        self.assertEqual(calls, [])

    def test_once_created_verified_error_and_no_jobs(self):
        code, result = run_once(self.worker)
        self.assertEqual((code, result['created_count']), (0, 1))
        code, result = run_once(self.worker)
        self.assertEqual((code, result['created_count'], result['verified_count']), (0, 0, 1))
        self.worker.owner_list = []; self.worker.jobs = {}
        code, result = run_once(self.worker)
        self.assertEqual((code, result['status']), (2, 'no_jobs'))

    def test_scheduler_health_is_real_and_stale_is_not_active(self):
        self.assertFalse(self.worker.scheduler_healthy())
        stop = threading.Event()
        thread = threading.Thread(target=stop.wait); thread.start()
        try:
            self.worker.scheduler_thread = thread
            self.worker.scheduler_heartbeat = time.monotonic()
            self.assertTrue(self.worker.scheduler_healthy())
            self.worker.scheduler_heartbeat -= 121
            self.assertFalse(self.worker.scheduler_healthy())
            self.worker.scheduler_started = time.monotonic()
            self.assertTrue(self.worker.scheduler_healthy())
            self.worker.scheduler_started -= 2000
            self.assertFalse(self.worker.scheduler_healthy())
        finally: stop.set(); thread.join()
        self.assertFalse(self.worker.scheduler_healthy())

    def test_manual_capture_and_scheduler_serialized(self):
        active, peak = 0, 0
        mutex = threading.Lock()
        original = self.worker.process
        def process(*args):
            nonlocal active, peak
            with self.worker.lock:
                with mutex: active += 1; peak = max(peak, active)
                time.sleep(.05)
                try: return original(*args)
                finally:
                    with mutex: active -= 1
        self.worker.process = process
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.worker.capture(OWNER, str(uuid.uuid4())))),
                   threading.Thread(target=lambda: results.append(self.worker.tick()))]
        for t in threads: t.start()
        for t in threads: t.join()
        self.assertEqual(len(results), 2)
        self.assertEqual(peak, 1)

    def test_http_auth_scheduler_status_and_aborted_upload_cleanup(self):
        server = PrivateHTTPServer(('127.0.0.1', 0), handler(self.worker))
        thread = threading.Thread(target=server.serve_forever); thread.start()
        import http.client
        try:
            client = http.client.HTTPConnection('127.0.0.1', server.server_port)
            client.request('GET', '/status')
            response = client.getresponse(); self.assertEqual(response.status, 403); response.read()
            client.request('GET', '/status', headers={'Authorization': 'Bearer fixture-token'})
            response = client.getresponse(); result = json.loads(response.read())
            self.assertFalse(result['scheduler_active']); self.assertIsNone(result['next_run'])
            client.close()
            sock = socket.create_connection(('127.0.0.1', server.server_port))
            sock.sendall(b'POST /import HTTP/1.0\r\nAuthorization: Bearer fixture-token\r\nContent-Length: 100000\r\n\r\npartial')
            sock.shutdown(socket.SHUT_WR)
            while sock.recv(4096): pass
            sock.close()
            self.assertEqual(list(self.store.temporary.folder.iterdir()), [])
            self.assertEqual(self.worker.sealed, 0)
        finally: server.shutdown(); server.server_close(); thread.join()


class RuntimeTests(unittest.TestCase):
    def test_interprocess_gate_reentrant_and_released_after_process_death(self):
        with tempfile.TemporaryDirectory() as root:
            code = "from backup_runtime import OperationGate; import time; g=OperationGate(r'%s'); g.__enter__(); print('locked',flush=True); time.sleep(20)" % root
            child = subprocess.Popen([sys.executable, '-c', code], cwd=Path(__file__).parent,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), 'locked')
                with self.assertRaises(BusyError):
                    with OperationGate(root, timeout=.1): pass
            finally:
                child.terminate(); child.communicate(timeout=5)
            gate = OperationGate(root, timeout=.1)
            with gate:
                with gate: gate.check_deadline()

    def test_safe_cleanup_only_owned_temp_and_keep_originals(self):
        with tempfile.TemporaryDirectory() as root:
            space = TemporarySpace(root, 0)
            owned = space.folder / ('op-' + str(uuid.uuid4())); owned.mkdir()
            (owned / '.owned.json').write_text(json.dumps(space.marker))
            (owned / 'partial.zip').write_bytes(b'partial')
            foreign = space.folder / ('op-' + str(uuid.uuid4())); foreign.mkdir()
            (foreign / 'unmarked').write_bytes(b'keep')
            original = Path(root) / 'package-objects' / ('a' * 64)
            original.parent.mkdir(); original.write_bytes(b'keep')
            with OperationGate(root): self.assertEqual(space.cleanup(), 1)
            self.assertFalse(owned.exists()); self.assertTrue(foreign.exists()); self.assertTrue(original.exists())
            with self.assertRaises(ValueError): space.remove(Path(root))

    def test_timeout_and_disk_reservation_fail_closed(self):
        with tempfile.TemporaryDirectory() as root:
            gate = OperationGate(root, operation_timeout=.001)
            with gate:
                gate.local.started -= 1
                with self.assertRaises(BusyError): gate.check_deadline()
            space = TemporarySpace(root, 10)
            with patch('backup_runtime.shutil.disk_usage', return_value=type('Usage', (), {'free': 19})()):
                with self.assertRaises(DiskSpaceError):
                    with space.workspace(10): pass
            self.assertEqual(list(space.folder.iterdir()), [])

    def test_cli_process_failure_exit_and_no_secret_traceback(self):
        env = dict(os.environ)
        env.pop('BACKUP_DATABASE_URL', None)
        result = subprocess.run([sys.executable, str(Path(__file__).parent / 'backup_worker.py'), '--once'],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['status'], 'failed')
        self.assertEqual(result.stderr, '')

    def test_sdk_network_failure_and_access_denied_messages_are_safe(self):
        from s3_test_endpoint import LocalS3Endpoint
        with tempfile.TemporaryDirectory() as root:
            with LocalS3Endpoint(Path(root) / 'remote') as endpoint:
                client = endpoint.client()
                store = S3Store(Path(root) / 'cache', 'private-fixture', client=client, minimum_free_bytes=0)
                store.check_storage()
                wrong = S3Store(Path(root) / 'wrong', 'private-fixture',
                                client=endpoint.client('wrong-fixture-key'), minimum_free_bytes=0)
                with self.assertRaises(StorageError) as error: wrong.validate_access()
                self.assertNotIn('wrong-fixture-key', str(error.exception))
                wrong.client.close()
                client.close()
            with self.assertRaises(StorageError) as error: store.validate_access()
            self.assertIn('S3 request failed', str(error.exception))

    def test_cli_configuration_failure_is_nonzero_without_secret(self):
        with patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()) as stream:
            self.assertEqual(main(['--once']), 1)
        self.assertEqual(json.loads(stream.getvalue())['status'], 'failed')

    def test_real_sdk_configured_for_sigv4_and_streamed_readback(self):
        import boto3
        from botocore.stub import Stubber
        from botocore.config import Config
        from botocore.response import StreamingBody
        client = boto3.client('s3', endpoint_url='https://s3.twcstorage.ru', region_name='ru-1',
            aws_access_key_id='fixture', aws_secret_access_key='fixture', config=Config(signature_version='s3v4'))
        with tempfile.TemporaryDirectory() as root:
            store = S3Store(root, 'private-fixture', client=client, minimum_free_bytes=0)
            path = Path(root) / 'original'; path.write_bytes(b'hello')
            key = store._key('package-objects/' + file_hash(path)[0])
            with Stubber(client) as stub:
                stub.add_client_error('head_object', service_error_code='404', http_status_code=404)
                stub.add_response('put_object', {})
                stub.add_response('get_object', {'Body': StreamingBody(io.BytesIO(b'hello'), 5), 'ContentLength': 5})
                self.assertEqual(store._put(key, path), 5)
                stub.assert_no_pending_responses()
        self.assertEqual(client.meta.config.signature_version, 's3v4')


if __name__ == '__main__': unittest.main()
