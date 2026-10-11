"""Synthetic in-memory PostgreSQL checks; never runs on a production connection."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = """
create role anon; create role authenticated;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.uid() to anon,authenticated;
select set_config('finance.backup_install_verified',repeat('a',64),false);
"""
migrations = [{'name': p.name, 'sql': p.read_text(encoding='utf-8-sig')}
              for p in sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
test = (ROOT / 'supabase/tests/18_backups.sql').read_text(encoding='utf-8')
script = r"""(async()=>{
 window.backupQA={state:'starting',passed:[]};
 try {
  const {PGlite}=await import('https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.3.14/dist/index.js');
  const db=new PGlite(); window.backupQADB=db;
  await db.exec(BOOTSTRAP);
  for(const migration of MIGRATIONS) {
   window.backupQA.state=migration.name;
   await db.exec(migration.sql); window.backupQA.passed.push(migration.name);
  }
  window.backupQA.state='restore tests';
  await db.exec(TEST);
  const last=MIGRATIONS.at(-1); await db.exec(last.sql);
  const triggers=(await db.query("select count(*)::int n from pg_trigger where tgname='aaa_backup_lock' and not tgisinternal")).rows[0].n;
  if(triggers!==8)throw Error('Duplicate/missing backup triggers');
  window.backupQA.state='passed'; window.backupQA.triggers=triggers;
 }catch(e){window.backupQA.state='failed';window.backupQA.error={message:e.message,detail:e.detail,where:e.where};}
})(); 'Isolated PostgreSQL backup tests started';
""".replace('BOOTSTRAP', json.dumps(BOOTSTRAP)).replace('MIGRATIONS', json.dumps(migrations)).replace('TEST', json.dumps(test))
folder = ROOT / '.dart_tool' / 'backup-qa'
folder.mkdir(parents=True, exist_ok=True)
(folder / 'sql-qa.js').write_text(script, encoding='utf-8')
print('Created isolated QA script')
