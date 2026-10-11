"""Validate the existing dart-define JSON without printing configuration values."""
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit


def validate(data):
    if len(data) > 16384:
        raise ValueError('Client config is too large')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate client config key')
            result[key] = value
        return result
    config = json.loads(data, object_pairs_hook=unique)
    allowed = {'SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'BACKUP_API_URL'}
    if not isinstance(config, dict) or set(config) - allowed:
        raise ValueError('Only public client config keys are allowed')
    if not all(isinstance(value, str) for value in config.values()):
        raise ValueError('Client config values must be strings')
    key = config.get('SUPABASE_PUBLISHABLE_KEY', '')
    if not re.fullmatch(r'sb_publishable_[A-Za-z0-9_-]{16,}', key):
        raise ValueError('A Supabase sb_publishable_ key is required; admin keys are forbidden')
    for name in ('SUPABASE_URL', 'BACKUP_API_URL'):
        value = config.get(name, '')
        if name == 'BACKUP_API_URL' and not value:
            continue
        uri = urlsplit(value)
        if (uri.scheme != 'https' or not uri.hostname or uri.username or uri.password
                or uri.query or uri.fragment):
            raise ValueError(name + ' must be an HTTPS URL without credentials, query or fragment')
        if name == 'SUPABASE_URL' and uri.path not in ('', '/'):
            raise ValueError('SUPABASE_URL must be an origin URL')
    return config


if __name__ == '__main__':
    try:
        data = Path(sys.argv[1]).read_bytes()
        expected = sys.argv[2]
        if not re.fullmatch(r'[a-fA-F0-9]{64}', expected):
            raise ValueError('Pass CLIENT_CONFIG_SHA256 to invalidate the build cache')
        if hashlib.sha256(data).hexdigest() != expected.lower():
            raise ValueError('Client config hash mismatch')
        validate(data)
    except (ValueError, OSError, IndexError):
        sys.exit('Invalid public client config or hash; values have not been logged')
    print('Public client config validated')
