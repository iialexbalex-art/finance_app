"""Read-only smoke checks for Caddy serving a Flutter Web release (stdlib only)."""
import gzip
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def fetch(base, path, headers=None):
    request = Request(base.rstrip('/') + path, headers=headers or {})
    try:
        response = urlopen(request, timeout=30)
    except HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def check(base):
    status, headers, index = fetch(base, '/')
    assert status == 200 and b'flutter_bootstrap.js' in index, 'Home page failed'
    assert 'no-cache' in headers.get('Cache-Control', ''), 'HTML can become stale'
    for path in ('/reports', '/wallets/details', '/auth/callback?code=example'):
        code, route_headers, body = fetch(base, path)
        assert code == 200 and body == index, 'SPA shell failed: ' + path
        assert 'no-cache' in route_headers.get('Cache-Control', ''), 'SPA caching failed'
    for path in ('/favicon.png', '/manifest.json', '/main.dart.js', '/flutter_bootstrap.js'):
        code, asset_headers, body = fetch(base, path)
        assert code == 200 and body, 'Resource failed: ' + path
        assert 'no-cache' in asset_headers.get('Cache-Control', ''), 'Resource caching failed'
        if path == '/flutter_bootstrap.js':
            assert b'{{flutter_' not in body and b'_flutter.loader.load()' in body
    for path in ('/missing.js', '/missing.wasm', '/assets/missing.png', '/assets/missing',
                 '/canvaskit/missing.wasm', '/icons/missing.png', '/api/missing'):
        code, _, body = fetch(base, path)
        assert code == 404 and body != index, 'Missing resource is not 404: ' + path
    code, _, worker = fetch(base, '/flutter_service_worker.js')
    assert code == 200 and b'self.registration.unregister()' in worker, 'Worker retirement missing'
    code, compressed_headers, data = fetch(base, '/main.dart.js', {'Accept-Encoding': 'gzip'})
    assert code == 200 and compressed_headers.get('Content-Encoding') == 'gzip', 'Compression failed'
    assert gzip.decompress(data), 'Compressed response is corrupt'
    print('PASS: home, SPA shell, resources, missing-resource 404, cache headers, retirement worker, gzip')


if __name__ == '__main__':
    check(sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:18080')
