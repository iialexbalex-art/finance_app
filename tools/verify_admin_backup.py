"""Verify SQL Editor JSON/CSV export and emit a guarded installation package.
python tools/verify_admin_backup.py PATH_TO_EXPORT
Never prints financial data or Auth secrets. This is an admin backup, not a
user import archive. Its checksum must still match the current DB before DDL.
"""
import csv
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import sys
import zipfile

from prepare_backup_install import ROOT, CAPTURE
from project_checkpoint import create as checkpoint

def parse(path):
    raw=Path(path).read_text(encoding='utf-8-sig')
    try:
        value=json.loads(raw)
    except json.JSONDecodeError:
        rows=list(csv.DictReader(io.StringIO(raw)))
        if len(rows)!=1 or 'backup_json' not in rows[0]: raise ValueError('Expected one backup_json result')
        value=json.loads(rows[0]['backup_json'])
    if isinstance(value,list):
        if len(value)!=1: raise ValueError('Expected one backup row')
        value=value[0]
    if isinstance(value,dict) and 'backup_json' in value: value=json.loads(value['backup_json'])
    if isinstance(value,str): value=json.loads(value)
    return value

def main(path):
    backup=parse(path)
    if backup['kind']!='finance-admin-before-018' or backup['project_ref']!='bgyuxibywuxdultxsmiv': raise ValueError('Wrong administrative project backup')
    text=backup['canonical_data']
    digest=hashlib.sha256(text.encode()).hexdigest()
    if digest!=backup['data_sha256']: raise ValueError('Corrupt or truncated database copy')
    data=json.loads(text)
    expected={'public.'+t for t in ['spaces','wallets','categories','wallet_opening_balances','expenses','incomes','transfers','space_members','wallet_assignments']}
    if not expected.issubset(data) or not backup['structure']['functions'] or not backup['structure']['policies']: raise ValueError('Incomplete data/structure')
    captured=dt.datetime.fromisoformat(backup['captured_at'].replace('Z','+00:00'))
    age=dt.datetime.now(dt.timezone.utc)-captured
    if age>dt.timedelta(hours=1) or age<dt.timedelta(minutes=-5): raise ValueError('Create a fresh database copy (less than one hour old)')
    point=checkpoint('Before SQL Editor migration 018')
    folder=ROOT/'.local-backups'/'database-before-018'/captured.strftime('%Y%m%dT%H%M%SZ')
    folder.mkdir(parents=True,exist_ok=True)
    (folder/'verified-admin.json').write_text(json.dumps(backup,ensure_ascii=False),encoding='utf-8')
    install_folder=ROOT/'backups-install'
    install_folder.mkdir(exist_ok=True)
    migration=(ROOT/'supabase/migrations/202610070018_backups.sql').read_text(encoding='utf-8')
    body=migration.replace('begin;','',1).rsplit('commit;',1)[0]
    # Checks the same complete data under application/table locks. Even a backup
    # one minute old is rejected if the owner changes data in the meantime.
    install="-- INSTALL_BACKUPS_018: guarded by a verified saved administrative copy.\nbegin;\n"+CAPTURE+f"\ndo $$ begin if current_user<>'postgres' then raise exception 'Run as postgres'; end if; if encode(sha256(convert_to(pg_temp.finance_data_before_backup()::text,'UTF8')),'hex')<>'{digest}' then raise exception 'Database changed after backup; create a fresh copy'; end if; perform set_config('finance.backup_install_verified','{digest}',true); end $$;\n"+body+'\ncommit;\n'
    for extension in ('sql','txt'): (install_folder/('INSTALL_BACKUPS_018.'+extension)).write_text(install,encoding='utf-8')
    with zipfile.ZipFile(ROOT/'backups-install-verified.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for extension in ('sql','txt'): archive.write(install_folder/('INSTALL_BACKUPS_018.'+extension),'INSTALL_BACKUPS_018.'+extension)
    print(json.dumps({'verified_backup':str(folder),'checkpoint':str(point),'install_sql':str(install_folder/'INSTALL_BACKUPS_018.sql'),'lines':len(install.splitlines()),'first_line':install.splitlines()[0],'last_line':install.splitlines()[-1]}))

if __name__=='__main__':
    main(sys.argv[1])
