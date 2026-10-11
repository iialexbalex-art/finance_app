-- Read-only administrator audit of migration 018; no data changes.
-- Supabase project bgyuxibywuxdultxsmiv; run as postgres.
begin transaction read only;
select jsonb_build_object(
 'settings_exists',to_regclass('public.finance_settings') is not null,
 'wallet_revision_exists',exists(select 1 from information_schema.columns where table_schema='public' and table_name='wallets' and column_name='revision' and udt_name='uuid'),
 'opening_revision_exists',exists(select 1 from information_schema.columns where table_schema='public' and table_name='wallet_opening_balances' and column_name='revision' and udt_name='uuid'),
 'lock_triggers',(select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and t.tgname='aaa_backup_lock' and not t.tgisinternal),
 'history_triggers',(select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and t.tgname='zzz_backup_history' and not t.tgisinternal),
 'delete_history_triggers',(select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and t.tgname='aaa_backup_delete_history' and not t.tgisinternal),
 'worker_role',(select jsonb_build_object('present',true,'can_login',rolcanlogin,'superuser',rolsuper,'bypass_rls',rolbypassrls) from pg_roles where rolname='finance_backup_worker'),
 'public_rpcs',(select jsonb_object_agg(name,to_regprocedure(signature) is not null) from (values
  ('capture','public.backup_capture(uuid,text,text)'),
  ('list','public.backup_list()'),
  ('history','public.backup_history_list()'),
  ('undo','public.backup_undo(uuid,uuid)'),
  ('write','public.backup_write(uuid,text,text,uuid,uuid,jsonb)'),
  ('templates','public.backup_save_templates(uuid,uuid,jsonb)')
 ) f(name,signature)),
 'settings_rls',(select relrowsecurity from pg_class where oid=to_regclass('public.finance_settings')),
 'worker_functions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='finance_private' and p.proname like 'backup_worker_%')
) as migration_018_audit;
commit;
