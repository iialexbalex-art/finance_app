"""Private S3 authority with a verified disk cache; no original object deletion.

All objects fit single PUT (original <=128 MiB, data <=64 MiB). ZIPs are built
locally on request. No multipart uploads or unfinished multipart parts exist.
Never use ETag as SHA-256 or trust HEAD alone before sealing a snapshot.
"""
import contextlib
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import uuid
from urllib.parse import urlsplit

from backup_store import Store, MAX_DATA, MAX_FILE, MAX_ENTRIES, canonical, file_hash, safe_path, sha


class StorageError(RuntimeError):
    """Messages are fixed strings. Never include a provider exception/credential."""


def error_code(error):
    return getattr(error, 'response', {}).get('Error', {}).get('Code', '')


class S3Store(Store):
    def __init__(self, root, bucket, endpoint='https://s3.twcstorage.ru', region='ru-1',
                 prefix='finance-backups', client=None, minimum_free_bytes=None):
        super().__init__(root, minimum_free_bytes)
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', bucket):
            raise ValueError('Invalid S3 bucket name')
        safe_path(prefix)
        if not prefix or prefix.startswith('.'):
            raise ValueError('Invalid S3 key prefix')
        self.bucket, self.prefix = bucket, prefix
        self.deadline_check = lambda: None
        if client is None:
            url = urlsplit(endpoint)
            if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
                raise ValueError('S3 requires a clean HTTPS endpoint')
            import boto3
            from botocore.config import Config
            # SDK debug logs can contain signed headers; prohibit them here.
            for name in ('boto3', 'botocore', 's3transfer', 'urllib3'):
                logging.getLogger(name).setLevel(logging.CRITICAL)
            if not os.environ.get('AWS_ACCESS_KEY_ID') or not os.environ.get('AWS_SECRET_ACCESS_KEY'):
                raise StorageError('S3 credentials are missing in protected settings')
            self.client = boto3.client('s3', endpoint_url=endpoint, region_name=region,
                aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'], aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
                config=Config(signature_version='s3v4', s3={'addressing_style': 'path'},
                    connect_timeout=10, read_timeout=30, max_pool_connections=2,
                    retries={'mode': 'standard', 'total_max_attempts': 3},
                    request_checksum_calculation='when_required', response_checksum_validation='when_required'))
        else:
            self.client = client  # Isolated tests inject a client; env cannot disable TLS.

    @classmethod
    def from_environment(cls, root):
        return cls(root, os.environ['BACKUP_S3_BUCKET'], os.environ.get('BACKUP_S3_ENDPOINT', 'https://s3.twcstorage.ru'),
                   os.environ.get('BACKUP_S3_REGION', 'ru-1'), os.environ.get('BACKUP_S3_PREFIX', 'finance-backups'))

    def _request(self, method, **args):
        self.deadline_check()
        try:
            return getattr(self.client, method)(Bucket=self.bucket, **args)
        except Exception as error:
            code = error_code(error)
            if code in {'NoSuchKey', 'NotFound', '404', 'NoSuchBucketPolicy'}:
                raise FileNotFoundError('S3 object not found') from None
            if code in {'PreconditionFailed', 'ConditionalRequestConflict', '412', '409'}:
                raise FileExistsError('Immutable S3 object already exists') from None
            if code in {'AccessDenied', 'InvalidAccessKeyId', 'SignatureDoesNotMatch', 'ExpiredToken', 'InvalidToken', '403'}:
                raise StorageError('S3 authentication failed; check protected settings') from None
            raise StorageError('S3 request failed; no backup was confirmed') from None

    def validate_access(self):
        acl = self._request('get_bucket_acl')
        for grant in acl.get('Grants', []):
            if grant.get('Grantee', {}).get('Type') == 'Group':
                raise StorageError('Backup S3 bucket must be private')
        try:
            policy = json.loads(self._request('get_bucket_policy')['Policy'])
        except FileNotFoundError:
            return
        statements = policy.get('Statement', [])
        if isinstance(statements, dict): statements = [statements]
        for item in statements:
            principal = item.get('Principal')
            values = list(principal.values()) if isinstance(principal, dict) else [principal]
            if item.get('Effect') == 'Allow' and any(v == '*' or isinstance(v, list) and '*' in v for v in values):
                raise StorageError('Backup S3 policy allows public access')

    def check_storage(self):
        """Probe only a new disposable key; no DB or saved backup changes."""
        self.validate_access()
        key = self._key('checks/' + str(uuid.uuid4()))
        with self.workspace(65536) as folder:
            path = folder / 'probe'
            path.write_bytes(b'finance-backup-storage-probe-v1\n')
            try:
                self._put(key, path)
                import io
                try:
                    self._request('put_object', Key=key, Body=io.BytesIO(b'overwrite-probe'),
                                  ContentLength=15, IfNoneMatch='*')
                except FileExistsError:
                    pass
                else:
                    raise StorageError('S3 conditional writes are unsupported; deployment refused')
                self._fetch(key, *file_hash(path))
            finally:
                self._request('delete_object', Key=key)

    def _key(self, relative):
        return self.prefix + '/' + safe_path(relative)

    def _head(self, key):
        try: return self._request('head_object', Key=key)
        except FileNotFoundError: return None

    def _fetch(self, key, digest, size, destination=None):
        if not re.fullmatch(r'[0-9a-f]{64}', digest) or not isinstance(size, int) or size < 0:
            raise StorageError('Invalid remote object checksum metadata')
        # A cache hit never skips verification of stored S3 contents.
        target = Path(destination) if destination is not None else None
        if target is not None and target.exists():
            if file_hash(target) != (digest, size): raise StorageError('Local backup cache checksum mismatch')
            target = None
        with self.workspace(size if target is not None else 0) as folder:
            response = self._request('get_object', Key=key)
            body = response.get('Body')
            try:
                if response.get('ContentLength') != size:
                    raise StorageError('S3 object size mismatch')
                h, count = hashlib.sha256(), 0
                temporary = folder / 'download'
                with temporary.open('wb') if target is not None else contextlib.nullcontext() as output:
                    while True:
                        self.deadline_check()
                        try: chunk = body.read(1024 * 1024)
                        except Exception: raise StorageError('S3 download interrupted') from None
                        if not chunk: break
                        count += len(chunk)
                        if count > size: raise StorageError('S3 object exceeds expected size')
                        h.update(chunk)
                        if output is not None: output.write(chunk)
                    if count != size or h.hexdigest() != digest:
                        raise StorageError('S3 object checksum mismatch')
                    if output is not None: output.flush(); os.fsync(output.fileno())
                if target is not None:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    os.replace(temporary, target)
            finally:
                if body is not None:
                    try: body.close()
                    except Exception: raise StorageError('S3 stream cleanup failed') from None

    def _put(self, key, source):
        digest, size = file_hash(source)
        existing = self._head(key)
        added = 0
        if existing is None:
            md5 = hashlib.md5(usedforsecurity=False)
            with Path(source).open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): md5.update(chunk)
            import base64
            with Path(source).open('rb') as stream:
                try:
                    self._request('put_object', Key=key, Body=stream, ContentLength=size,
                                  ContentMD5=base64.b64encode(md5.digest()).decode('ascii'),
                                  Metadata={'sha256': digest}, IfNoneMatch='*')
                    added = size
                except FileExistsError:
                    pass  # A repeated request/race may only accept identical bytes.
        self._fetch(key, digest, size)
        return added

    def register_package_file(self, path):
        digest, size = file_hash(path)
        if size > MAX_FILE: raise ValueError('Original exceeds supported size')
        target = self.root / 'package-objects' / digest
        key = self._key('package-objects/' + digest)
        if self._head(key) is not None:
            self._fetch(key, digest, size, target)
            return digest, size, 0
        super().register_package_file(path)
        return digest, size, self._put(key, target)

    def _original(self, owner, digest, size, source=None):
        owner = str(uuid.UUID(owner))
        if not re.fullmatch(r'[0-9a-f]{64}', digest) or not isinstance(size, int) or not 0 <= size <= MAX_FILE:
            raise StorageError('Invalid original manifest')
        for relative, target in [
            ('package-objects/' + digest, self.root / 'package-objects' / digest),
            ('owners/' + owner + '/objects/' + digest, self.owner_dir(owner) / 'objects' / digest)]:
            key = self._key(relative)
            if self._head(key) is not None:
                self._fetch(key, digest, size, target)
                return 0
        local = Path(source) if source is not None else self.object_path(owner, digest)
        if not local.exists() or file_hash(local) != (digest, size):
            raise StorageError('Required original is missing or corrupt')
        if local.parent == self.root / 'package-objects':
            key = self._key('package-objects/' + digest)
        else:
            key = self._key('owners/' + owner + '/objects/' + digest)
        return self._put(key, local)

    def put_file(self, owner, path):
        digest, size = file_hash(path)
        added = self._original(owner, digest, size, source=path)
        # Ensure a verified cache copy for the existing ZIP/export implementation.
        self._original(owner, digest, size)
        return digest, size, added

    def save_release(self, release):
        super().save_release(release)
        raw = canonical(release)
        return self._put(self._key('releases/' + sha(raw) + '.json'), self.root / 'release.json')

    def save(self, owner, job):
        self.validate_access()
        added = 0
        unique = {}
        for info in job['release']['files'].values():
            digest, size = info['sha256'], info['size']
            if digest in unique and unique[digest] != size: raise StorageError('Inconsistent original sizes')
            unique[digest] = size
        for digest, size in unique.items(): added += self._original(owner, digest, size)
        manifest, _ = super().save(owner, job)
        folder = self.owner_dir(owner) / 'snapshots' / str(uuid.UUID(job['id']))
        relative = 'owners/' + str(uuid.UUID(owner)) + '/snapshots/' + str(uuid.UUID(job['id']))
        # Data first, manifest last; SQL may seal only after both full readbacks.
        for name in ('data.json.gz', 'manifest.json'):
            added += self._put(self._key(relative + '/' + name), folder / name)
        verified, payload = self.read(owner, job['id'])
        if canonical(verified) != canonical(manifest) or canonical(payload) != canonical(job['payload']):
            raise StorageError('Stored S3 snapshot differs from captured data')
        return manifest, added

    def _hydrate_file(self, key, target, limit):
        head = self._head(key)
        if head is None: raise StorageError('Saved S3 snapshot is missing')
        size = head.get('ContentLength')
        digest = head.get('Metadata', {}).get('sha256', '')
        if not isinstance(size, int) or not 0 <= size <= limit:
            raise StorageError('Saved S3 snapshot exceeds its limit')
        self._fetch(key, digest, size, target)

    def read(self, owner, identifier):
        owner, identifier = str(uuid.UUID(owner)), str(uuid.UUID(identifier))
        folder = self.owner_dir(owner) / 'snapshots' / identifier
        relative = 'owners/' + owner + '/snapshots/' + identifier
        self._hydrate_file(self._key(relative + '/manifest.json'), folder / 'manifest.json', MAX_DATA)
        manifest = json.loads((folder / 'manifest.json').read_bytes())
        if manifest.get('owner_id') != owner or manifest.get('format') != 1 or manifest.get('schema') != 18:
            raise StorageError('Foreign or unsupported S3 manifest')
        files = manifest.get('release', {}).get('files', {})
        if not isinstance(files, dict) or not 0 < len(files) <= MAX_ENTRIES - 3:
            raise StorageError('Invalid S3 original manifest')
        unique = {}
        for name, info in files.items():
            if not safe_path(name).startswith('assets/'): raise StorageError('Unsupported attachment path')
            digest, size = info['sha256'], info['size']
            if digest in unique and unique[digest] != size: raise StorageError('Inconsistent original sizes')
            unique[digest] = size
        for digest, size in unique.items(): self._original(owner, digest, size)
        self._hydrate_file(self._key(relative + '/data.json.gz'), folder / 'data.json.gz', MAX_DATA + 1024**2)
        result, payload = super().read(owner, identifier)
        if result.get('counts') != {k: len(v) for k, v in payload['data'].items()}:
            raise StorageError('S3 snapshot counts mismatch')
        return result, payload

    def remove_snapshots(self, owner, deleted_ids):
        # Only IDs already pruned/deleted by SQL with pin/last/manual protection.
        # Originals, releases and other snapshot IDs are never deleted here.
        owner = str(uuid.UUID(owner))
        for identifier in deleted_ids:
            identifier = str(uuid.UUID(identifier))
            relative = 'owners/' + owner + '/snapshots/' + identifier
            for name in ('manifest.json', 'data.json.gz'):
                self._request('delete_object', Key=self._key(relative + '/' + name))
        super().remove_snapshots(owner, deleted_ids)
