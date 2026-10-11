"""Checkpoint + coherent private pg_dump before applying the single new migration.

Configure ADMIN_DATABASE_URL in protected environment. Requires pg_dump and
pg_restore of a compatible PostgreSQL major version. No credentials in argv/logs.
Default: prepare only. --apply explicitly executes the verified migration.
Never seeds, restores production data, or rolls the schema backward.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from project_checkpoint import create as checkpoint

ROOT = Path(__file__).resolve().parents[1]

def run(args, env, **kwargs):
    result = subprocess.run(args, env=env, stderr=subprocess.PIPE, **kwargs)
    if result.returncode:
        # pg_dump errors can contain hostname/user/details. Keep these private;
        # don't expose connection strings or financial records in console logs.
        raise RuntimeError('PostgreSQL command failed; check connection, grants and tool version')
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pg-bin', default='')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    import psycopg
    from psycopg.conninfo import conninfo_to_dict
    dsn = os.environ['ADMIN_DATABASE_URL']
    env = dict(os.environ)
    params = conninfo_to_dict(dsn)
    for key, target in {'host':'PGHOST','port':'PGPORT','user':'PGUSER','password':'PGPASSWORD',
                        'dbname':'PGDATABASE','sslmode':'PGSSLMODE'}.items():
        if key in params:
            env[target] = params[key]
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    destination = ROOT / '.local-backups' / 'database-before-018' / stamp
    destination.mkdir(parents=True)
    pg_dump = str(Path(args.pg_bin) / ('pg_dump.exe' if os.name=='nt' else 'pg_dump')) if args.pg_bin else 'pg_dump'
    pg_restore = str(Path(args.pg_bin) / ('pg_restore.exe' if os.name=='nt' else 'pg_restore')) if args.pg_bin else 'pg_restore'
    source_checkpoint = checkpoint('Before migration 018')
    sql_path = ROOT / 'supabase/migrations/202610070018_backups.sql'
    sql_bytes = sql_path.read_bytes()
    sql_hash = hashlib.sha256(sql_bytes).hexdigest()
    # Keep the existing application guard locked throughout export and migration.
    # External DB tools use an exported REPEATABLE READ snapshot. This is a short
    # administrative maintenance window; no image/network upload while locked.
    with psycopg.connect(dsn) as conn:
        conn.execute('set transaction isolation level repeatable read')
        if conn.execute('select current_user').fetchone()[0] != 'postgres':
            raise RuntimeError('Use the administrator postgres connection')
        conn.execute('select singleton from finance_private.category_tree_guard for update')
        conn.execute('lock table public.spaces,public.space_members,public.wallets,public.wallet_assignments,public.wallet_opening_balances,public.categories,public.expenses,public.incomes,public.transfers in share mode')
        snapshot = conn.execute('select pg_export_snapshot()').fetchone()[0]
        dump = destination / 'database.dump'
        with dump.open('wb') as out:
            run([pg_dump, '--no-password', '--format=custom', '--schema=public', '--schema=finance_private', '--snapshot='+snapshot], env, stdout=out)
            out.flush()
            os.fsync(out.fileno())
        listing = run([pg_restore, '--list', str(dump)], env, stdout=subprocess.PIPE).stdout
        if not dump.stat().st_size or b'TABLE DATA' not in listing or b'FUNCTION' not in listing:
            raise RuntimeError('Incomplete database dump; migration was not applied')
        # No auth secrets exported. IDs are needed for a later admin-directed
        # identity mapping in a new Supabase project.
        ids = [str(row[0]) for row in conn.execute('select id from auth.users').fetchall()]
        (destination/'auth-user-ids.json').write_text(json.dumps(ids), encoding='utf-8')
        manifest = {'created_at': dt.datetime.now(dt.timezone.utc).isoformat(),
            'dump_sha256': '', 'dump_bytes': dump.stat().st_size,
            'schema_sql_sha256': sql_hash, 'checkpoint': str(source_checkpoint),
            'scope': ['public','finance_private'], 'auth_secrets_excluded': True,
            'schema_only_roles': 'Create roles/enable required extensions in the clean target; do not import access grants from a user ZIP'}
        with dump.open('rb') as stream: manifest['dump_sha256']=hashlib.file_digest(stream,'sha256').hexdigest()
        (destination/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
        if args.apply:
            if sql_path.read_bytes() != sql_bytes:
                raise RuntimeError('Migration changed after checkpoint')
            # Existing BEGIN/COMMIT would release the guard too early; execute
            # the same body inside this connection's locked transaction.
            sql = sql_bytes.decode('utf-8-sig')
            sql = sql.replace('begin;','',1)
            sql = sql.rsplit('commit;',1)[0]
            conn.execute("select set_config('finance.backup_install_verified',%s,true)", (manifest['dump_sha256'],))
            conn.execute(sql)
    print(json.dumps({'verified_database_backup': str(destination), 'migration_applied': args.apply}))

if __name__ == '__main__':
    main()
