"""Loopback-only S3 protocol fixture for SDK preflight, never a deployment API.

Test credentials are literals. This checks SigV4 header presence, not signature
cryptography. Production S3Store constructs HTTPS clients and cannot select it.
"""
import base64
import hashlib
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
from urllib.parse import urlsplit, unquote

from test_s3_runtime import DiskS3


class LocalS3Endpoint:
    def __init__(self, root):
        self.storage = DiskS3(root)
        storage = self.storage
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *args): pass
            def send(self, status, data=b'', headers=None):
                self.send_response(status)
                for key, value in (headers or {}).items(): self.send_header(key, value)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                if self.command != 'HEAD': self.wfile.write(data)
            def error(self, status, code):
                self.send(status, ('<Error><Code>' + code + '</Code></Error>').encode(), {'Content-Type': 'application/xml'})
            def target(self):
                if not self.headers.get('Authorization', '').startswith('AWS4-HMAC-SHA256 '):
                    self.error(403, 'SignatureDoesNotMatch'); return None
                if 'Credential=fixture/' not in self.headers.get('Authorization', ''):
                    self.error(403, 'InvalidAccessKeyId'); return None
                url = urlsplit(self.path)
                name = unquote(url.path).lstrip('/').split('/', 1)
                if name[0] != 'private-fixture': self.error(404, 'NoSuchBucket'); return None
                return (name[1] if len(name) > 1 else '', url.query)
            def do_HEAD(self):
                self.do_GET()
            def do_GET(self):
                target = self.target()
                if target is None: return
                key, query = target
                if not key and query == 'acl':
                    return self.send(200, b'<AccessControlPolicy xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Owner><ID>fixture</ID></Owner><AccessControlList><Grant><Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser"><ID>fixture</ID></Grantee><Permission>FULL_CONTROL</Permission></Grant></AccessControlList></AccessControlPolicy>')
                if not key and query == 'policy': return self.error(404, 'NoSuchBucketPolicy')
                if key not in storage.metadata: return self.error(404, 'NoSuchKey')
                self.send_response(200)
                self.send_header('Content-Length', str(storage.path(key).stat().st_size))
                for name, value in storage.metadata[key].items(): self.send_header('x-amz-meta-' + name, value)
                self.end_headers()
                if self.command == 'GET':
                    with storage.path(key).open('rb') as stream:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''): self.wfile.write(chunk)
            def do_PUT(self):
                target = self.target()
                if target is None: return
                key, _ = target
                size = int(self.headers.get('Content-Length', '-1'))
                if size < 0 or size > 128 * 1024**2:
                    self.close_connection = True; return self.error(400, 'InvalidLength')
                if key in storage.metadata and self.headers.get('If-None-Match') == '*':
                    # Drain tiny probes to keep the HTTP connection synchronized.
                    if size <= 65536: self.rfile.read(size)
                    else: self.close_connection = True
                    return self.error(412, 'PreconditionFailed')
                temporary = storage.root / ('upload-' + threading.current_thread().name)
                md5 = hashlib.md5(usedforsecurity=False)
                remaining = size
                try:
                    with temporary.open('wb') as out:
                        while remaining:
                            chunk = self.rfile.read(min(1024 * 1024, remaining))
                            if not chunk: return self.error(400, 'IncompleteBody')
                            out.write(chunk); md5.update(chunk); remaining -= len(chunk)
                    expected = self.headers.get('Content-MD5')
                    if expected and expected != base64.b64encode(md5.digest()).decode(): return self.error(400, 'BadDigest')
                    temporary.replace(storage.path(key))
                    storage.metadata[key] = {name[11:].lower(): value for name, value in self.headers.items() if name.lower().startswith('x-amz-meta-')}
                    storage.puts.append(key); storage.put_bytes += size
                    self.send(200)
                finally:
                    temporary.unlink(missing_ok=True)
            def do_DELETE(self):
                target = self.target()
                if target is None: return
                storage.delete_object(Key=target[0]); self.send(204)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
    def __enter__(self):
        self.thread.start(); return self
    def __exit__(self, *args):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
    def client(self, access_key='fixture'):
        import boto3
        from botocore.config import Config
        return boto3.client('s3', endpoint_url='http://127.0.0.1:' + str(self.server.server_port), region_name='ru-1',
            aws_access_key_id=access_key, aws_secret_access_key='fixture', config=Config(signature_version='s3v4',
                s3={'addressing_style': 'path'}, connect_timeout=5, read_timeout=10,
                request_checksum_calculation='when_required', response_checksum_validation='when_required',
                retries={'total_max_attempts': 1}, max_pool_connections=2))
