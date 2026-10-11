import copy
import datetime as dt
import io
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile

from backup_store import Store, canonical, sha, retention_keep, validate_payload

OWNER = '18000000-0000-0000-0000-000000000001'
SPACE = '18100000-0000-0000-0000-000000000001'
WALLET = '18200000-0000-0000-0000-000000000001'
OTHER = '18000000-0000-0000-0000-000000000002'

def payload():
    return {'format': 1, 'schema': 18, 'app':'1.0.0+1','owner_id': OWNER, 'history': [],
            'receipts':{t:[] for t in ['expense_creation_receipts','expense_edit_requests','operation_receipts','bulk_action_receipts','backup_mutation_receipts']}, 'data': {
        'spaces': [{'id': SPACE, 'owner_user_id': OWNER, 'kind': 'personal', 'name': 'Personal'}],
        'wallets': [{'id': WALLET, 'space_id': SPACE, 'currency': 'RUB', 'currency_scale': 2}],
        'wallet_opening_balances': [{'wallet_id': WALLET, 'amount_minor': '9007199254740993'}],
        'categories': [], 'expenses': [], 'incomes': [], 'transfers': [], 'finance_settings': []}}

class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root / 'source')
        self.image = self.root / 'original.png'
        project = Path(__file__).resolve().parents[1]
        original = project / 'assets' / 'personal_expenses' / 'pe_food.png'
        if not original.exists():
            original = next((project / 'assets').rglob('*.png'))
        self.image.write_bytes(original.read_bytes())
        self.digest, self.size, self.added = self.store.put_file(OWNER, self.image)
        self.job = {'id': str(uuid.uuid4()), 'captured_at': '2026-10-06T18:59:00+00:00',
                    'payload': payload(), 'release': {'version': 'test', 'files': {
                        'assets/test.png': {'sha256': self.digest, 'size': self.size}}}}
        self.store.save(OWNER, self.job)
        self.archive = self.root / 'full.zip'
        self.store.export(OWNER, self.job['id'], self.archive)

    def tearDown(self):
        self.temp.cleanup()

    def rewrite(self, mutate):
        with zipfile.ZipFile(self.archive) as z:
            entries = {n: z.read(n) for n in z.namelist()}
        mutate(entries)
        bad = self.root / 'bad.zip'
        with zipfile.ZipFile(bad, 'w') as z:
            for name, data in entries.items():
                z.writestr(name, data)
        return bad

    def test_standalone_clean_restore_exact_png_and_money(self):
        destination = Store(self.root / 'clean')
        manifest, restored, added = destination.import_zip(OWNER, self.archive)
        self.assertEqual(restored, self.job['payload'])
        self.assertEqual(restored['data']['wallet_opening_balances'][0]['amount_minor'], '9007199254740993')
        self.assertEqual(destination.object_path(OWNER, self.digest).read_bytes(), self.image.read_bytes())
        self.assertEqual(added, self.size)
        job = dict(self.job, id=str(uuid.uuid4()), payload=restored, release=manifest['release'])
        destination.save(OWNER, job)
        self.assertEqual(destination.read(OWNER, job['id'])[1], restored)

    def test_dedup_and_old_version_preserved(self):
        self.assertEqual(self.store.put_file(OWNER, self.image)[2], 0)
        self.image.write_bytes(b'different bytes')
        new_digest, _, _ = self.store.put_file(OWNER, self.image)
        self.assertNotEqual(self.digest, new_digest)
        self.store.read(OWNER, self.job['id'])
        self.assertTrue(self.store.object_path(OWNER, self.digest).exists())

    def test_corrupt_image_rejected_before_ingest(self):
        bad = self.rewrite(lambda entries: entries.update({'assets/test.png': b'bad'}))
        destination = Store(self.root / 'empty')
        with self.assertRaises(ValueError):
            destination.import_zip(OWNER, bad)
        self.assertFalse((destination.owner_dir(OWNER) / 'objects').exists())

    def test_corrupt_data_rejected(self):
        bad = self.rewrite(lambda entries: entries.update({'data.json': b'{}'}))
        with self.assertRaises(ValueError):
            self.store.import_zip(OWNER, bad)

    def test_missing_image_rejected(self):
        bad = self.rewrite(lambda entries: entries.pop('assets/test.png'))
        with self.assertRaises(ValueError):
            self.store.import_zip(OWNER, bad)

    def test_foreign_owner_and_incompatible_schema(self):
        with self.assertRaises(ValueError):
            self.store.import_zip(OTHER, self.archive)
        def change(entries):
            manifest = json.loads(entries['manifest.json'])
            manifest['schema'] = 19
            entries['manifest.json'] = canonical(manifest)
        with self.assertRaises(ValueError):
            self.store.import_zip(OWNER, self.rewrite(change))

    def test_path_traversal_extra_entry_rejected(self):
        bad = self.rewrite(lambda entries: entries.update({'../outside': b'bad'}))
        with self.assertRaises(ValueError):
            self.store.import_zip(OWNER, bad)

    def test_corrupt_saved_dependency_not_ready(self):
        self.store.object_path(OWNER, self.digest).write_bytes(b'bad')
        with self.assertRaises(ValueError):
            self.store.save(OWNER, dict(self.job, id=str(uuid.uuid4())))
        with self.assertRaises(ValueError):
            self.store.read(OWNER, self.job['id'])

    def test_owner_namespaced_objects(self):
        digest, _, added = self.store.put_file(OTHER, self.image)
        self.assertEqual(digest, self.digest)
        self.assertGreater(added, 0)
        self.assertNotEqual(self.store.object_path(OTHER, digest), self.store.object_path(OWNER, digest))

    def test_packaged_artwork_is_stored_once_without_per_owner_copies(self):
        store=Store(self.root/'packaged')
        package=store.root/'package-objects'/self.digest
        package.parent.mkdir()
        package.write_bytes(self.image.read_bytes())
        for owner in [OWNER,OTHER]:
            self.assertEqual(store.put_file(owner,self.image)[2],0)
            self.assertEqual(store.object_path(owner,self.digest),package)
            self.assertFalse((store.owner_dir(owner)/'objects'/self.digest).exists())

    def test_retention_protects_manual_monthly_last_and_running(self):
        now = dt.datetime(2026, 10, 7, tzinfo=dt.timezone.utc)
        jobs = [{'id': 'manual', 'kind': 'manual', 'state': 'ready', 'captured_at': '2020-01-01T00:00:00Z'},
                {'id': 'early', 'kind': 'daily', 'state': 'ready', 'captured_at': '2026-08-01T00:00:00Z'},
                {'id': 'monthly', 'kind': 'daily', 'state': 'ready', 'captured_at': '2026-08-31T00:00:00Z'},
                {'id': 'new', 'kind': 'before', 'state': 'ready', 'captured_at': '2026-10-06T00:00:00Z'},
                {'id': 'oldbefore', 'kind': 'before', 'state': 'ready', 'captured_at': '2026-01-01T00:00:00Z'},
                {'id': 'running', 'kind': 'before', 'state': 'running', 'captured_at': '2026-01-01T00:00:00Z'}]
        self.assertEqual(retention_keep(jobs, now), {'manual', 'monthly', 'new', 'running'})

    def test_bad_category_references_and_lossy_money(self):
        bad = payload()
        bad['data']['wallet_opening_balances'][0]['amount_minor'] = 9007199254740993
        with self.assertRaises(ValueError):
            validate_payload(bad, OWNER)
        bad = payload()
        bad['data']['categories'] = [{'id': 'a', 'space_id': SPACE, 'kind': 'expense', 'parent_id': 'b'}]
        with self.assertRaises(ValueError):
            validate_payload(bad, OWNER)

class SchedulerTests(unittest.TestCase):
    def test_2359_qyzylorda_is_1859_utc_and_catchup_is_real_date(self):
        from backup_worker import due_date, next_run
        before = dt.datetime(2026,10,7,18,58,59,tzinfo=dt.timezone.utc)
        due = dt.datetime(2026,10,7,18,59,tzinfo=dt.timezone.utc)
        self.assertEqual(next_run(before), due)
        self.assertEqual(due_date(before), dt.date(2026,10,6))
        self.assertEqual(due_date(due), dt.date(2026,10,7))
        self.assertEqual(next_run(due), dt.datetime(2026,10,8,18,59,tzinfo=dt.timezone.utc))
        self.assertEqual(due_date(dt.datetime(2026,10,8,1,tzinfo=dt.timezone.utc)),dt.date(2026,10,7))

    def test_same_worker_handler_retries_and_is_idempotent(self):
        from backup_worker import Worker
        class FakeWorker(Worker):
            def __init__(self):
                import threading
                self.lock=threading.RLock()
                self.jobs={}
                self.processed=0
                self.scheduler_error=None
                self.fail_once=True
            def call(self,name,*args):
                if name=='owners': return [OWNER]
                if name=='capture':
                    self.jobs.setdefault(args[1],{'id':args[1],'owner_id':args[0],'state':'queued'})
                    return args[1]
                if name=='get': return self.jobs[args[1]]
                if name=='prune': return None
                if name=='pending':return [j for j in self.jobs.values() if j['state']!='ready']
                raise AssertionError(name)
            def process(self,owner,identifier):
                self.processed+=1
                if self.fail_once:
                    self.fail_once=False
                    raise OSError('Storage offline')
                self.jobs[identifier]['state']='ready'
        worker=FakeWorker()
        instant=dt.datetime(2026,10,7,19,tzinfo=dt.timezone.utc)
        worker.tick(instant)
        worker.tick(instant)
        worker.tick(instant)
        self.assertEqual(len(worker.jobs),1)
        self.assertEqual(worker.processed,2)
        self.assertIsNone(worker.scheduler_error)

if __name__ == '__main__':
    unittest.main()
