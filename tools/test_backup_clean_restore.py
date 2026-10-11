"""Full archive/clean-storage/clean-PostgreSQL QA, with SYNTHETIC data only.
Stage storage consumes the protected synthetic browser SQL fixture exported as
.local-backups/backups-task/test-job.json, never a Supabase access token.
It generates two browser scripts for isolated PGlite, with an actual disk seal
between the stages. No source bucket or assets folder is used during import.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import sys
import uuid

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'server'))
sys.path.insert(0,str(ROOT/'tools'))
from backup_store import Store,canonical,file_hash
from backup_worker import Worker
from backup_runtime import OperationGate
from prepare_backup_qa import BOOTSTRAP

FOLDER=ROOT/'.local-backups/backups-task'

def generate_first(metadata):
    migrations=[p.read_text(encoding='utf-8-sig') for p in sorted((ROOT/'supabase/migrations').glob('*.sql'))]
    script=r"""(async()=>{
 window.backupCleanQA={state:'starting'};
 try{
  const {PGlite}=await import('https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.3.14/dist/index.js');
  const db=new PGlite();window.backupCleanDB=db;
  await db.exec(BOOTSTRAP);
  for(const migration of MIGRATIONS)await db.exec(migration);
  const m=METADATA,owner=m.job.owner_id;
  const users=new Set([owner,...['expenses','incomes','transfers'].flatMap(t=>m.job.payload.data[t].map(r=>r.author_id))]);
  for(const id of users)await db.query('insert into auth.users(id) values($1)',[id]);
  await db.query("insert into public.spaces(id,owner_user_id,kind,name) values('18900000-0000-0000-0000-000000000001',$1,'personal','Empty target')",[owner]);
  await db.query('select finance_private.backup_worker_release($1,$2::jsonb)',[m.job.release.version,JSON.stringify(m.job.release.files)]);
  await db.query('select finance_private.backup_worker_import($1,$2,$3::jsonb,$4::jsonb,$5,$6::timestamptz)',[owner,m.job.id,JSON.stringify(m.job.payload),JSON.stringify(m.job.release),m.manifest.data_sha256,m.job.captured_at]);
  await db.query('select finance_private.backup_worker_claim($1,$2)',[owner,m.job.id]);
  await db.query('select finance_private.backup_worker_seal($1,$2,$3,$4,$5,$6)',[owner,m.job.id,m.manifest.data_sha256,m.imported_new_bytes,m.archive_bytes,'Isolated clean disk']);
  const before=(await db.query('select finance_private.backup_worker_capture($1,$2,$3,$4) id',[owner,m.restore_request,'restore','Before clean restore'])).rows[0].id;
  window.backupCleanQA={state:'needs_disk_seal',owner,source:m.job.id,request:m.restore_request,before_id:before};
 }catch(e){window.backupCleanQA={state:'failed',error:{message:e.message,detail:e.detail,where:e.where}};}
})(); 'Clean target PostgreSQL started; production is untouched';
""".replace('BOOTSTRAP',json.dumps(BOOTSTRAP)).replace('MIGRATIONS',json.dumps(migrations)).replace('METADATA',json.dumps(metadata))
    (FOLDER/'clean-first.js').write_text(script,encoding='utf-8')

def storage():
    job=json.loads((FOLDER/'test-job.json').read_text(encoding='utf-8-sig'))
    if job['owner_id']!='18000000-0000-0000-0000-000000000001':raise ValueError('Synthetic fixture required')
    stamp=dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    source=Store(FOLDER/('full-source-'+stamp))
    worker=Worker.__new__(Worker)
    worker.store=source
    worker.lock=OperationGate(source.root)
    worker.release_path=source.root/'release.json'
    worker.call=lambda *args:None
    release_report=worker.register_assets(ROOT)
    job['release']=json.loads(worker.release_path.read_bytes())
    manifest,added=source.save(job['owner_id'],job)
    first_bytes=added
    # A repeated snapshot reuses all 703 original hashes, not 704 file copies.
    second=dict(job,id=str(uuid.uuid4()))
    source.save(job['owner_id'],second)
    if len(list((source.root/'package-objects').iterdir()))!=len({i['sha256'] for i in job['release']['files'].values()}):raise ValueError('Originals duplicated')
    archive=FOLDER/('finance-synthetic-'+stamp+'.zip')
    archive_bytes=source.export(job['owner_id'],job['id'],archive)
    clean=Store(FOLDER/('clean-target-'+stamp))
    # The import's only input is the self-contained ZIP. No old source storage,
    # browser, live bucket, project assets or prior archive is consulted here.
    restored_manifest,restored,imported=clean.import_zip(job['owner_id'],archive)
    if restored!=job['payload']:raise ValueError('Data changed during archive roundtrip')
    clean_job=dict(job,payload=restored,release=restored_manifest['release'])
    clean_manifest,_=clean.save(job['owner_id'],clean_job)
    verified,_=clean.read(job['owner_id'],job['id'])
    metadata={'job':clean_job,'manifest':clean_manifest,'clean_root':str(clean.root),
        'archive_path':str(archive),'archive_bytes':archive_bytes,'imported_new_bytes':imported,
        'original_release':release_report,'first_snapshot_new_bytes':first_bytes,
        'restore_request':str(uuid.uuid4()),'all_originals_verified':len(job['release']['files'])}
    (FOLDER/'clean-metadata.json').write_bytes(canonical(metadata))
    generate_first(metadata)
    print(json.dumps({k:v for k,v in metadata.items() if k not in {'job','manifest'}}))

def seal():
    metadata=json.loads((FOLDER/'clean-metadata.json').read_bytes())
    before=json.loads((FOLDER/'clean-before-job.json').read_text(encoding='utf-8-sig'))
    store=Store(metadata['clean_root'])
    manifest,new_bytes=store.save(before['owner_id'],before)
    script=r"""(async()=>{
 try{
  const db=window.backupCleanDB,m=METADATA,b=BEFORE;
  const prior=(await db.query('select finance_private.backup_worker_get($1,$2) job',[b.owner_id,b.id])).rows[0].job;
  if(prior.state!=='ready'){
   await db.query('select finance_private.backup_worker_claim($1,$2)',[b.owner_id,b.id]);
   await db.query('select finance_private.backup_worker_seal($1,$2,$3,$4,$5,$6)',[b.owner_id,b.id,SEALED_SHA,NEW_BYTES,NEW_BYTES,'Isolated clean disk']);
  }
  await db.query('select finance_private.backup_restore($1,$2,$3)',[b.owner_id,m.job.id,m.restore_request]);
  const actual=(await db.query('select finance_private.backup_data($1) data',[b.owner_id])).rows[0].data;
  const stable=v=>Array.isArray(v)?v.map(stable):(v&&typeof v==='object')?Object.fromEntries(Object.keys(v).sort().map(k=>[k,stable(v[k])])):v;
  const encode=v=>JSON.stringify(stable(v));
  const normalize=rows=>rows.map(({revision,...r})=>r).sort((a,b)=>String(a.id??a.wallet_id??a.owner_id).localeCompare(String(b.id??b.wallet_id??b.owner_id)));
  for(const t of ['spaces','wallets','categories','wallet_opening_balances','expenses','incomes','transfers']){
   if(encode(normalize(actual[t]))!==encode(normalize(m.job.payload.data[t])))throw Error('Clean restored fields differ: '+t);
  }
  const files=(await db.query('select finance_private.backup_worker_asset_manifest($1) files',[b.owner_id])).rows[0].files;
  if(encode(files)!==encode(m.job.release.files))throw Error('Restored image versions differ');
  const e=m.job.payload.data.expenses.find(x=>!x.transfer_id);
  const count=(await db.query('select count(*)::int n from public.expenses')).rows[0].n;
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[b.owner_id]);
  await db.query('select public.create_expense($1,$2,$3,$4,$5,$6,$7)',[e.request_id,e.space_id,e.wallet_id,e.category_id,e.amount_minor,e.expense_date,e.comment]);
  if((await db.query('select count(*)::int n from public.expenses')).rows[0].n!==count)throw Error('Restored creation receipt allowed duplicate');
  window.backupCleanQA={state:'passed',tables:7,counts:Object.fromEntries(Object.entries(actual).map(([t,r])=>[t,r.length])),originals:Object.keys(files).length,archive_bytes:m.archive_bytes,clean_disk:m.clean_root,request_replay:'no duplicate'};
 }catch(e){window.backupCleanQA={state:'failed',error:{message:e.message,detail:e.detail,where:e.where}};}
})(); 'Archive restored into isolated clean PostgreSQL';
""".replace('METADATA',json.dumps(metadata)).replace('BEFORE',json.dumps(before)).replace('SEALED_SHA',json.dumps(manifest['data_sha256'])).replace('NEW_BYTES',str(new_bytes))
    (FOLDER/'clean-final.js').write_text(script,encoding='utf-8')
    print(json.dumps({'verified_before_restore_data_sha256':manifest['data_sha256'],'new_bytes':new_bytes}))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=['storage','seal']);args=parser.parse_args()
    storage() if args.stage=='storage' else seal()
