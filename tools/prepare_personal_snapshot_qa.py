"""Generate isolated QA from the protected live backup; never sends it to production."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
backup = json.loads((ROOT / '.local-backups/personal-expenses/before.json').read_text(encoding='utf-8-sig'))
install = (ROOT / 'personal-expenses-install/INSTALL_PERSONAL_EXPENSES.sql').read_text(encoding='utf-8-sig')
script = r"""(async()=>{
 window.personalSnapshotQA={state:'starting'};
 const db=window.businessSqlQADB;
 try {
  await db.exec('rollback; begin;');
  const snapshot=SNAPSHOT;
  const users=new Set(snapshot.spaces.map(x=>x.owner_user_id));
  for(const table of ['expenses','incomes','transfers']) for(const x of snapshot[table]) users.add(x.author_id);
  for(const id of users) await db.query('insert into auth.users(id) values($1) on conflict do nothing',[id]);
  async function insert(table,rows) {
    if(!rows.length)return;
    const cols=(await db.query("select attname from pg_attribute where attrelid=$1::regclass and attnum>0 and not attisdropped and attgenerated='' order by attnum",['public.'+table])).rows.map(x=>x.attname);
    await db.query('insert into public.'+table+'('+cols.join(',')+') select '+cols.join(',')+' from jsonb_populate_recordset(null::public.'+table+',$1::jsonb)',[JSON.stringify(rows)]);
  }
  await insert('spaces',snapshot.spaces); await insert('wallets',snapshot.wallets);
  let remaining=[...snapshot.categories], inserted=new Set();
  while(remaining.length) {
    const ready=remaining.filter(x=>!x.parent_id||inserted.has(x.parent_id));
    if(!ready.length)throw Error('Fixture cycle');
    await insert('categories',ready); ready.forEach(x=>inserted.add(x.id)); remaining=remaining.filter(x=>!inserted.has(x.id));
  }
  // Rehydrate historical operations whose wallets were archived afterwards.
  // Only this in-memory fixture load bypasses INSERT-time availability checks.
  for(const table of ['transfers','expenses','incomes']) await db.exec('alter table public.'+table+' disable trigger user');
  await insert('transfers',snapshot.transfers); await insert('expenses',snapshot.expenses);
  await insert('incomes',snapshot.incomes); await insert('wallet_opening_balances',snapshot.opening_balances);
  for(const table of ['transfers','expenses','incomes']) await db.exec('alter table public.'+table+' enable trigger user');
  // A nested BEGIN does not commit the fixture. Replace only final COMMIT with rollback.
  const scope=snapshot.spaces.find(x=>x.kind==='personal').id;
  const actual=(await db.query('select finance_private.personal_expense_references($1) refs',[scope])).rows[0].refs;
  const expected=Object.fromEntries(['expenses','incomes','transfers'].map(t=>[t,snapshot[t].filter(x=>x.space_id===scope)]));
  window.personalSnapshotReferenceDiff=[];
  function diff(a,b,path='') {
    if(JSON.stringify(a)===JSON.stringify(b))return;
    if(a&&b&&typeof a==='object'&&typeof b==='object') for(const k of new Set([...Object.keys(a),...Object.keys(b)]))diff(a[k],b[k],path+'.'+k);
    else window.personalSnapshotReferenceDiff.push({path,actual:a,expected:b});
  }diff(actual,expected);
  const sql=INSTALL.replace(/commit;\s*$/,'');
  const result=await db.exec(sql);
  window.personalSnapshotQA={state:'passed',result:result.filter(x=>x.rows?.length).map(x=>x.rows)};
  await db.exec('rollback');
 }catch(e){window.personalSnapshotQA={state:'failed',message:e.message,detail:e.detail,where:e.where};await db.exec('rollback');}
})(); 'Isolated backup reconciliation started';
""".replace('SNAPSHOT',json.dumps(backup)).replace('INSTALL',json.dumps(install))
(ROOT / '.dart_tool/business-qa/personal-snapshot-qa.js').write_text(script,encoding='utf-8')
