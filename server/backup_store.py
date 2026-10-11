"""Streaming immutable object store and standalone ZIP format. Stdlib only."""
import contextlib
import datetime as dt
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import zipfile
from backup_runtime import TemporarySpace

MAX_ARCHIVE = 2 * 1024**3
MAX_DATA = 64 * 1024**2
MAX_FILE = 128 * 1024**2
MAX_ENTRIES = 10000
TABLES = {'spaces', 'wallets', 'categories', 'wallet_opening_balances',
          'transfers', 'expenses', 'incomes', 'finance_settings'}

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def file_hash(path):
    h = hashlib.sha256()
    size = 0
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size

def safe_path(name):
    p = PurePosixPath(name)
    if not name or '\\' in name or ':' in name or '\x00' in name or p.is_absolute() or '..' in p.parts or str(p) != name:
        raise ValueError('Unsafe archive path')
    return name

def validate_payload(payload, owner):
    if set(payload) != {'format','schema','app','owner_id','data','history','receipts'}:
        raise ValueError('Incomplete or unsupported payload')
    if payload.get('format') != 1 or payload.get('schema') != 18 or payload.get('app')!='1.0.0+1' or payload.get('owner_id') != owner:
        raise ValueError('Unsupported format/schema or foreign owner')
    data = payload.get('data', {})
    if set(data) != TABLES:
        raise ValueError('Unexpected/missing tables')
    spaces = {r['id'] for r in data['spaces'] if r.get('owner_user_id') == owner}
    if not spaces or len(spaces) != len(data['spaces']):
        raise ValueError('Foreign/empty spaces')
    wallets = {r['id']: r for r in data['wallets']}
    categories = {r['id']: r for r in data['categories']}
    transfers = {r['id']: r for r in data['transfers']}
    for table, rows in data.items():
        if not isinstance(rows, list):
            raise ValueError('Invalid row collection')
        key = 'wallet_id' if table == 'wallet_opening_balances' else 'owner_id' if table == 'finance_settings' else 'id'
        if len({r[key] for r in rows}) != len(rows):
            raise ValueError('Duplicate IDs')
        for r in rows:
            if 'space_id' in r and r['space_id'] not in spaces:
                raise ValueError('Foreign space')
            if table == 'finance_settings' and r[key] != owner:
                raise ValueError('Foreign settings')
            for field in ('amount_minor', 'source_minor', 'target_minor', 'fee_minor'):
                if field in r and (not isinstance(r[field], str) or not r[field].lstrip('-').isdigit() or not -(2**63) <= int(r[field]) < 2**63):
                    raise ValueError('Money must be exact int64 text')
            if table == 'wallet_opening_balances' and r['wallet_id'] not in wallets:
                raise ValueError('Missing wallet')
            if table in {'expenses', 'incomes'}:
                w, c = wallets.get(r['wallet_id']), categories.get(r['category_id'])
                if not w or not c or w['space_id'] != r['space_id'] or c['space_id'] != r['space_id'] or c['kind'] != ('expense' if table == 'expenses' else 'income'):
                    raise ValueError('Broken operation references')
                if r['currency'] != w['currency'] or r['currency_scale'] != w['currency_scale']:
                    raise ValueError('Operation currency mismatch')
                if r.get('transfer_id') and r['transfer_id'] not in transfers:
                    raise ValueError('Missing transfer')
            if table == 'transfers':
                for field in ('source_id', 'target_id'):
                    if r[field] not in wallets or wallets[r[field]]['space_id'] != r['space_id']:
                        raise ValueError('Broken transfer')
                if r.get('fee_category_id') and r['fee_category_id'] not in categories:
                    raise ValueError('Broken fee category')
    for c in categories.values():
        seen = {c['id']}
        parent = c.get('parent_id')
        while parent:
            if parent in seen or len(seen) >= 3 or parent not in categories:
                raise ValueError('Category cycle/depth/missing parent')
            p = categories[parent]
            if (p['space_id'], p['kind']) != (c['space_id'], c['kind']):
                raise ValueError('Foreign parent')
            seen.add(parent)
            parent = p.get('parent_id')
    # Untrusted history may never claim another owner. Actors are descriptive,
    # not permission grants. Auth/Vault/sessions are never part of this format.
    for action in payload.get('history', []):
        if action.get('owner_id') != owner or action.get('table_name') not in TABLES:
            raise ValueError('Foreign history')
    receipts = payload.get('receipts', {})
    allowed_receipts = {'expense_creation_receipts', 'expense_edit_requests', 'operation_receipts', 'bulk_action_receipts','backup_mutation_receipts'}
    if not isinstance(receipts, dict) or set(receipts) != allowed_receipts:
        raise ValueError('Unknown receipt tables')
    for table, rows in receipts.items():
        if not isinstance(rows, list):
            raise ValueError('Invalid receipts')
        for row in rows:
            if table == 'expense_creation_receipts':
                original = row['original_row']
                if original['space_id'] not in spaces or original['id'] != row['expense_id'] or original['author_id'] != row['author_id'] or original['request_id'] != row['request_id']:
                    raise ValueError('Foreign creation receipt')
            elif table == 'expense_edit_requests':
                if row['actor_id'] != owner or row['before_row']['space_id'] not in spaces or row['after_row']['space_id'] not in spaces:
                    raise ValueError('Foreign edit receipt')
            elif table=='backup_mutation_receipts':
                if row.get('owner_id')!=owner: raise ValueError('Foreign mutation receipt')
            elif row.get('actor_id') != owner or (table == 'bulk_action_receipts' and row['space_id'] not in spaces):
                raise ValueError('Foreign operation receipt')
    return {k: len(v) for k, v in data.items()}

class Store:
    def __init__(self, root, minimum_free_bytes=None):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.temporary = TemporarySpace(self.root, minimum_free_bytes)
        self.deadline_check = lambda: None

    def workspace(self, reserved=0):
        return self.temporary.workspace(reserved)

    def cleanup_temporary(self):
        return self.temporary.cleanup()

    def atomic_write(self, destination, data):
        with self.workspace(len(data)) as folder:
            path = folder / 'write.bin'
            with path.open('wb') as stream:
                stream.write(data); stream.flush(); os.fsync(stream.fileno())
            Path(destination).parent.mkdir(parents=True, exist_ok=True)
            os.replace(path, destination)

    def register_package_file(self, path):
        digest, size = file_hash(path)
        target = self.root / 'package-objects' / digest
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if file_hash(target) != (digest, size): raise ValueError('Corrupt release original')
            return digest, size, 0
        with self.workspace(size) as folder:
            import shutil
            temporary = folder / 'original'
            shutil.copyfile(path, temporary)
            if file_hash(temporary) != (digest, size): raise ValueError('Original changed during registration')
            os.replace(temporary, target)
        return digest, size, size

    def save_release(self, release):
        self.atomic_write(self.root / 'release.json', canonical(release))
        return 0

    def owner_dir(self, owner):
        import uuid
        owner = str(uuid.UUID(owner))
        path = self.root / 'owners' / owner
        path.mkdir(parents=True, exist_ok=True)
        return path

    def object_path(self, owner, digest):
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('Invalid digest')
        private = self.owner_dir(owner) / 'objects' / digest
        # Embedded application artwork is public, identical package content.
        # Keep it once globally. Owner uploads remain strictly namespaced.
        package = self.root / 'package-objects' / digest
        return package if not private.exists() and package.exists() else private

    def put_file(self, owner, path):
        digest, size = file_hash(path)
        target = self.object_path(owner, digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if file_hash(target) != (digest, size):
                raise ValueError('Corrupt stored original')
            return digest, size, 0
        with self.workspace(size) as folder:
            temporary = folder / 'original'
            with temporary.open('wb') as out, Path(path).open('rb') as src:
                import shutil
                shutil.copyfileobj(src, out, 1024 * 1024)
                out.flush(); os.fsync(out.fileno())
            if file_hash(temporary) != (digest, size): raise ValueError('File changed during capture')
            os.replace(temporary, target)
        return digest, size, size

    def save(self, owner, job):
        import uuid
        identifier = str(uuid.UUID(job['id']))
        payload = job['payload']
        validate_payload(payload, owner)
        release = job['release']
        for name, info in release['files'].items():
            self.deadline_check()
            safe_path(name)
            if not name.startswith('assets/'):
                raise ValueError('Unknown attachment path; configure storage adapter')
            path = self.object_path(owner, info['sha256'])
            if file_hash(path) != (info['sha256'], info['size']):
                raise ValueError('Missing/corrupt original: ' + name)
        raw = canonical(payload)
        if len(raw) > MAX_DATA:
            raise ValueError('Data exceeds backup limit')
        manifest = {'format': 1, 'schema': 18, 'owner_id': owner,
                    'captured_at': job['captured_at'], 'timezone': 'Asia/Qyzylorda',
                    'data_sha256': sha(raw), 'data_size': len(raw), 'release': release,
                    'counts': validate_payload(payload, owner)}
        folder = self.owner_dir(owner) / 'snapshots' / identifier
        folder.mkdir(parents=True, exist_ok=True)
        with self.workspace(len(raw) + 65536) as work:
            temporary = work / 'data.json.gz'
            with temporary.open('wb') as stream:
                with gzip.GzipFile(fileobj=stream, mode='wb', mtime=0) as compressed:
                    compressed.write(raw)
                stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, folder / 'data.json.gz')
        self.atomic_write(folder / 'manifest.json', canonical(manifest))
        # Validate local bytes here; remote subclasses verify after uploading.
        Store.read(self, owner, job['id'])
        # Actual compressed data + manifest; unique asset additions are reported
        # by the worker on its first ingest, not counted repeatedly.
        return manifest, (folder / 'data.json.gz').stat().st_size + (folder / 'manifest.json').stat().st_size

    def read(self, owner, identifier):
        import uuid
        identifier = str(uuid.UUID(identifier))
        folder = self.owner_dir(owner) / 'snapshots' / identifier
        manifest = json.loads((folder / 'manifest.json').read_bytes())
        with gzip.open(folder / 'data.json.gz', 'rb') as stream:
            raw = stream.read(MAX_DATA + 1)
        if len(raw) > MAX_DATA or sha(raw) != manifest['data_sha256'] or len(raw) != manifest['data_size']:
            raise ValueError('Corrupt backup data')
        payload = json.loads(raw)
        validate_payload(payload, owner)
        if manifest['owner_id'] != owner:
            raise ValueError('Foreign manifest')
        for info in manifest['release']['files'].values():
            if file_hash(self.object_path(owner, info['sha256'])) != (info['sha256'], info['size']):
                raise ValueError('Original is unavailable')
        return manifest, payload

    def export(self, owner, identifier, destination):
        manifest, payload = self.read(owner, identifier)
        self.temporary.check(manifest['data_size'] + sum(i['size'] for i in manifest['release']['files'].values()) + 1024**2)
        with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            archive.writestr('manifest.json', canonical(manifest))
            archive.writestr('data.json', canonical(payload))
            archive.writestr('RESTORE.txt', 'Finance backup format 1 / schema 18. Settings > Backups > Restore from file.\nThis archive contains data and original files; it is not a code installer.\nAuth, roles and access grants are deliberately excluded.\n')
            for name, info in manifest['release']['files'].items():
                self.deadline_check()
                # PNG already compressed; STORE keeps export CPU/memory bounded.
                archive.write(self.object_path(owner, info['sha256']), name, compress_type=zipfile.ZIP_STORED)
        return Path(destination).stat().st_size

    def import_zip(self, owner, archive_path):
        if Path(archive_path).stat().st_size > MAX_ARCHIVE:
            raise ValueError('Archive too large')
        with zipfile.ZipFile(archive_path) as archive:
            entries = archive.infolist()
            names = [safe_path(e.filename) for e in entries]
            if len(entries) > MAX_ENTRIES or len(set(names)) != len(names) or sum(e.file_size for e in entries) > MAX_ARCHIVE:
                raise ValueError('Archive duplicates/decompression limit')
            if any(e.file_size > MAX_FILE or e.flag_bits & 1 or ((e.external_attr >> 16) & 0o170000) == 0o120000 for e in entries):
                raise ValueError('Unsupported entry')
            for key in ('manifest.json', 'data.json'):
                if archive.getinfo(key).file_size > MAX_DATA:
                    raise ValueError('Manifest/data too large')
            manifest = json.loads(archive.read('manifest.json'))
            raw = archive.read('data.json')
            if manifest.get('format') != 1 or manifest.get('schema') != 18 or manifest.get('owner_id') != owner or manifest.get('data_sha256') != sha(raw) or manifest.get('data_size') != len(raw):
                raise ValueError('Manifest/checksum mismatch')
            payload = json.loads(raw)
            counts = validate_payload(payload, owner)
            if counts != manifest['counts']:
                raise ValueError('Wrong counts')
            files = manifest['release']['files']
            if set(names) != {'manifest.json', 'data.json', 'RESTORE.txt'} | set(files):
                raise ValueError('Unexpected/missing files')
            # Verify ALL files before storing anything or changing the database.
            for name, info in files.items():
                if not safe_path(name).startswith('assets/'):
                    raise ValueError('Unknown asset path')
                h = hashlib.sha256()
                size = 0
                with archive.open(name) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        self.deadline_check()
                        size += len(chunk)
                        h.update(chunk)
                if size != info['size'] or h.hexdigest() != info['sha256']:
                    raise ValueError('Corrupt original: ' + name)
            added = 0
            for name, info in files.items():
                self.deadline_check()
                with self.workspace(info['size']) as work:
                    temporary = work / 'original'
                    with temporary.open('wb') as out, archive.open(name) as stream:
                        import shutil
                        shutil.copyfileobj(stream, out, 1024 * 1024)
                    _, _, new_bytes = self.put_file(owner, temporary)
                    added += new_bytes
            return manifest, payload, added

    def remove_snapshots(self, owner, deleted_ids):
        """Delete only unreferenced snapshot metadata, never shared originals.
        Caller holds the worker lock and DB pin protection. Paths are verified
        within the configured owner's snapshot directory before recursive delete.
        """
        import shutil
        import uuid
        folder = self.owner_dir(owner) / 'snapshots'
        if not folder.exists(): return
        for target in folder.iterdir():
            try: identifier = str(uuid.UUID(target.name))
            except ValueError: continue
            resolved = target.resolve()
            if identifier not in deleted_ids or target.is_symlink() or resolved.parent != folder.resolve():
                continue
            if target.is_dir(): shutil.rmtree(resolved)

def retention_keep(jobs, now):
    """Reference-aware policy; caller only removes metadata, never shared objects.
    Conservative: running/failed jobs are retained, objects are never GC'd.
    """
    ready = [j for j in jobs if j['state'] == 'ready']
    keep = {j['id'] for j in jobs if j['state'] != 'ready' or j['kind'] == 'manual'}
    if ready:
        keep.add(max(ready, key=lambda j: j['captured_at'])['id'])
    monthly = {}
    for j in ready:
        stamp = dt.datetime.fromisoformat(j['captured_at'].replace('Z', '+00:00'))
        local = stamp + dt.timedelta(hours=5)
        month = (local.year, local.month)
        if stamp >= now - dt.timedelta(days=30):
            keep.add(j['id'])
        if j['kind'] == 'daily' and month < ((now + dt.timedelta(hours=5)).year, (now + dt.timedelta(hours=5)).month):
            if month not in monthly or j['captured_at'] > monthly[month]['captured_at']:
                monthly[month] = j
    for month in sorted(monthly, reverse=True)[:12]:
        keep.add(monthly[month]['id'])
    return keep
