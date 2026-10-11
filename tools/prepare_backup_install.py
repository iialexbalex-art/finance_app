"""Create complete SQL/TXT packages; no credentials and no production writes."""
import hashlib
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / 'backups-install'
CAPTURE = r"""
create temporary table finance_backup_checkpoint(snapshot jsonb) on commit drop;
create or replace function pg_temp.finance_data_before_backup() returns jsonb
language plpgsql set search_path='' as $$
declare t record; rows_data jsonb; result jsonb:='{}'; begin
 for t in select schemaname,tablename from pg_catalog.pg_tables where schemaname in ('public','finance_private')
  and not (schemaname='finance_private' and tablename='category_tree_guard') order by schemaname,tablename loop
  execute format('select coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text),''[]'') from %I.%I r',t.schemaname,t.tablename) into rows_data;
  result:=result||jsonb_build_object(t.schemaname||'.'||t.tablename,rows_data);
 end loop; return result;
end $$;
select singleton from finance_private.category_tree_guard for update;
lock table public.spaces,public.space_members,public.wallets,public.wallet_assignments,
 public.wallet_opening_balances,public.categories,public.expenses,public.incomes,public.transfers in share mode;
"""
PRE_BACKUP = """-- PRE_BACKUP_018: read-only administrative copy; download the backup_json result.
begin;
do $$ begin if current_user<>'postgres' then raise exception 'Run as postgres'; end if; end $$;
""" + CAPTURE + r"""
insert into finance_backup_checkpoint(snapshot)
select jsonb_build_object('kind','finance-admin-before-018','project_ref','bgyuxibywuxdultxsmiv',
 'captured_at',clock_timestamp(),'canonical_data',data::text,
 'data_sha256',encode(sha256(convert_to(data::text,'UTF8')),'hex'),
 'auth_user_ids',(select coalesce(jsonb_agg(id),'[]') from auth.users),
 'structure',jsonb_build_object(
 'extensions',(select jsonb_agg(jsonb_build_object('name',extname,'version',extversion)) from pg_extension),
 'columns',(select jsonb_agg(jsonb_build_object('schema',n.nspname,'table',c.relname,'column',a.attname,'type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'generated',a.attgenerated,'default',pg_get_expr(d.adbin,d.adrelid)) order by n.nspname,c.relname,a.attnum)
  from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace left join pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum
  where n.nspname in ('public','finance_private') and a.attnum>0 and not a.attisdropped and c.relkind in ('r','v')),
 'constraints',(select jsonb_agg(jsonb_build_object('relation',conrelid::regclass::text,'name',conname,'definition',pg_get_constraintdef(oid))) from pg_constraint where connamespace in(select oid from pg_namespace where nspname in ('public','finance_private'))),
 'indexes',(select jsonb_agg(to_jsonb(i)) from pg_indexes i where schemaname in ('public','finance_private')),
 'functions',(select jsonb_agg(pg_get_functiondef(p.oid) order by p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','finance_private') and p.prokind in ('f','p')),
 'triggers',(select jsonb_agg(pg_get_triggerdef(t.oid)) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname in ('public','finance_private')),
 'policies',(select jsonb_agg(to_jsonb(p)) from pg_policies p where schemaname in ('public','finance_private')),
 'rls',(select jsonb_agg(jsonb_build_object('schema',n.nspname,'table',c.relname,'enabled',c.relrowsecurity,'forced',c.relforcerowsecurity)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','finance_private') and c.relkind='r'),
 'table_grants',(select jsonb_agg(to_jsonb(g)) from information_schema.role_table_grants g where table_schema in ('public','finance_private')),
 'column_grants',(select jsonb_agg(to_jsonb(g)) from information_schema.role_column_grants g where table_schema in ('public','finance_private')),
 'function_grants',(select jsonb_agg(jsonb_build_object('function',p.oid::regprocedure::text,'acl',p.proacl::text,'owner',pg_get_userbyid(p.proowner))) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','finance_private')),
 'views',(select jsonb_agg(to_jsonb(v)) from pg_views v where schemaname in ('public','finance_private'))))
from (select pg_temp.finance_data_before_backup() data) captured;
select snapshot::text as backup_json from finance_backup_checkpoint;
commit;
"""

def main():
    FOLDER.mkdir(exist_ok=True)
    sql = (ROOT/'supabase/migrations/202610070018_backups.sql').read_bytes()
    for extension in ('sql','txt'):
        (FOLDER/('PRE_BACKUP_018.'+extension)).write_text(PRE_BACKUP,encoding='utf-8')
        (FOLDER/('018_BACKUPS_UNGUARDED_DO_NOT_RUN.'+extension)).write_bytes(sql)
    # This SQL is supplied for review/testing only. Production installation goes
    # through verify_admin_backup.py, which emits the guarded INSTALL SQL.
    sql_files=[FOLDER/'PRE_BACKUP_018.sql',FOLDER/'018_BACKUPS_UNGUARDED_DO_NOT_RUN.sql']
    metadata = '\n'.join(f'{p.name}: {len(p.read_text(encoding="utf-8").splitlines())} lines; SHA256 {hashlib.sha256(p.read_bytes()).hexdigest()}\nFirst: {p.read_text(encoding="utf-8").splitlines()[0]}\nLast: {p.read_text(encoding="utf-8").splitlines()[-1]}' for p in sql_files)
    (FOLDER/'FILES.txt').write_text(metadata+'\nProject: bgyuxibywuxdultxsmiv\nRole: postgres\nDo not execute UNGUARDED files in production. Read BACKUPS_SETUP.md.\n',encoding='utf-8')
    with zipfile.ZipFile(ROOT/'backups-install.zip','w',zipfile.ZIP_DEFLATED) as archive:
        for p in [FOLDER/'FILES.txt',*[FOLDER/(s.stem+'.'+ext) for s in sql_files for ext in ('sql','txt')]]:
            archive.write(p,p.name)
        for p in (ROOT/'server').glob('*'):
            if p.is_file(): archive.write(p,'server/'+p.name)
        for name in ('BACKUPS_SETUP.md','tools/verify_admin_backup.py','tools/prepare_backup_install.py','tools/apply_backup_migration.py','tools/project_checkpoint.py','supabase/migrations/202610070018_backups.sql'):
            p=ROOT/name
            if p.exists():archive.write(p,name)
    print(metadata)

if __name__=='__main__': main()
