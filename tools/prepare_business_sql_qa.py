"""Create a browser-side in-memory PostgreSQL QA script, with no production data."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
bootstrap = """
create role anon; create role authenticated;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
grant usage on schema auth to anon,authenticated;
grant execute on function auth.uid() to anon,authenticated;
"""
migrations = [{'name': p.name, 'sql': p.read_text(encoding='utf-8-sig')}
              for p in sorted((ROOT / 'supabase/migrations').glob('*.sql'))]
tests = '\n'.join((ROOT / f'supabase/tests/{name}').read_text(encoding='utf-8') for name in ['15_business_expenses.sql','16_bulk_actions.sql','17_personal_expenses.sql'])
script = """(async()=>{
  window.businessSqlQA={state:'starting',passed:[]};
  try {
    const {PGlite} = await import('https://cdn.jsdelivr.net/npm/@electric-sql/pglite/dist/index.js');
    const db = new PGlite();
    window.businessSqlQADB=db;
    await db.exec(BOOTSTRAP);
    for(const migration of MIGRATIONS) {
      window.businessSqlQA.state=migration.name;
      await db.exec(migration.sql);
      window.businessSqlQA.passed.push(migration.name);
    }
    window.businessSqlQA.state='migration tests';
    await db.exec(TESTS);
    window.businessSqlQA.state='passed';
  } catch(e) { window.businessSqlQA.state='failed'; window.businessSqlQA.error={message:e.message,detail:e.detail,where:e.where}; }
})(); 'SQL QA started in memory; production is untouched';
""".replace('BOOTSTRAP', json.dumps(bootstrap)).replace('MIGRATIONS', json.dumps(migrations)).replace('TESTS', json.dumps(tests))
folder = ROOT / '.dart_tool/business-qa'
folder.mkdir(exist_ok=True)
(folder / 'sql-qa.js').write_text(script, encoding='utf-8')
print('Created isolated SQL QA script')
