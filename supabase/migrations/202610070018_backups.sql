-- Finance backups 018. Apply via tools/apply_backup_migration.py as postgres.
begin;
do $$ begin
 if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
 if coalesce(current_setting('finance.backup_install_verified',true),'') !~ '^[a-f0-9]{64}$' then
  raise exception 'Verified fresh administrative backup required; use apply_backup_migration.py or verify_admin_backup.py'; end if;
 if to_regclass('finance_private.personal_expense_installations') is null then
  raise exception 'Migration 017 required'; end if;
end $$;
alter table public.wallets add column if not exists revision uuid not null default gen_random_uuid();
alter table public.wallet_opening_balances add column if not exists revision uuid not null default gen_random_uuid();
create table if not exists public.finance_settings (
 owner_id uuid primary key references auth.users(id),
 report_templates jsonb not null default '[]', revision uuid not null default gen_random_uuid(),
 asset_manifest jsonb not null default '{}'
);
alter table public.finance_settings enable row level security;
revoke all on public.finance_settings from public,anon,authenticated;
grant select,insert,update on public.finance_settings to authenticated;
drop policy if exists finance_settings_owner on public.finance_settings;
create policy finance_settings_owner on public.finance_settings to authenticated
 using(owner_id=auth.uid() and finance_private.is_established_owner())
 with check(owner_id=auth.uid() and finance_private.is_established_owner());
create or replace function finance_private.backup_revision() returns trigger
language plpgsql set search_path='' as $$ begin
 if tg_op='UPDATE' then new.revision:=gen_random_uuid(); end if; return new; end $$;
revoke all on function finance_private.backup_revision() from public,anon,authenticated;
do $$ declare t text; begin
 foreach t in array array['wallets','wallet_opening_balances','finance_settings'] loop
  execute format('drop trigger if exists backup_revision on public.%I',t);
  execute format('create trigger backup_revision before update on public.%I for each row execute function finance_private.backup_revision()',t);
 end loop;
end $$;
create table if not exists finance_private.backup_release (
 singleton boolean primary key default true check(singleton), version text not null,
 manifest jsonb not null, registered_at timestamptz not null default now()
);
create table if not exists finance_private.backup_actions (
 id bigint generated always as identity primary key, operation_id uuid not null,
 transaction_id bigint not null, owner_id uuid not null, space_id uuid,
 actor_id uuid, occurred_at timestamptz not null default clock_timestamp(),
 format integer not null default 1, table_name text not null,
 object_id uuid not null, action text not null, before_row jsonb, after_row jsonb
);
create index if not exists backup_actions_owner on finance_private.backup_actions(owner_id,occurred_at desc);
create index if not exists backup_actions_operation on finance_private.backup_actions(operation_id);
create table if not exists finance_private.backup_jobs (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null,
 request_id uuid not null, kind text not null check(kind in ('manual','daily','before','restore')),
 comment text not null default '' check(length(comment)<=1000),
 state text not null default 'queued' check(state in ('queued','running','ready','failed')),
 captured_at timestamptz not null default clock_timestamp(), timezone text not null default 'Asia/Qyzylorda',
 fingerprint text not null, payload jsonb not null, release jsonb not null,
 data_sha256 text, new_bytes bigint, export_bytes bigint, storage text, error text,
 attempts integer not null default 0, lease_until timestamptz,
 unique(owner_id,request_id)
);
create table if not exists finance_private.backup_restore_audit (
 owner_id uuid not null, request_id uuid not null, source_id uuid not null,
 kind text not null, occurred_at timestamptz not null default clock_timestamp(),
 primary key(owner_id,request_id)
);
create table if not exists finance_private.backup_history_sources (
 owner_id uuid not null, digest text not null, primary key(owner_id,digest)
);
create table if not exists finance_private.backup_pins (
 pin_id uuid primary key, owner_id uuid not null,
 snapshot_id uuid not null references finance_private.backup_jobs(id) on delete cascade,
 expires_at timestamptz not null default now()+interval '30 minutes'
);
create table if not exists finance_private.backup_io_guard(owner_id uuid primary key,flip boolean not null default false);
create table if not exists finance_private.backup_mutation_receipts(
 owner_id uuid not null,request_id uuid not null,payload jsonb not null,result jsonb not null,
 primary key(owner_id,request_id)
);
revoke all on finance_private.backup_release,finance_private.backup_actions,
 finance_private.backup_jobs,finance_private.backup_restore_audit,finance_private.backup_history_sources,finance_private.backup_pins,finance_private.backup_io_guard,finance_private.backup_mutation_receipts from public,anon,authenticated;

-- Money is text in snapshots/history; no JavaScript integer roundtrip.
create or replace function finance_private.backup_json(p_row jsonb) returns jsonb
language plpgsql immutable set search_path='' as $$
declare k text; v jsonb; result jsonb;
begin
 if p_row is null then return null; end if;
 if jsonb_typeof(p_row)='array' then
  select coalesce(jsonb_agg(finance_private.backup_json(value)),'[]') into result from jsonb_array_elements(p_row);
 elsif jsonb_typeof(p_row)='object' then
  result:='{}';
  for k,v in select * from jsonb_each(p_row) loop
   if k in ('amount_minor','source_minor','target_minor','fee_minor') and v<>'null' then
    result:=result||jsonb_build_object(k,v#>>'{}');
   else result:=result||jsonb_build_object(k,finance_private.backup_json(v)); end if;
  end loop;
 else result:=p_row;
 end if;
 return result;
end $$;

create or replace function finance_private.backup_receipts(p_owner uuid) returns jsonb
language sql security definer set search_path='' as $$ select jsonb_build_object(
 'expense_creation_receipts',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(r)) order by expense_id) from finance_private.expense_creation_receipts r join public.spaces s on s.id=(r.original_row->>'space_id')::uuid where s.owner_user_id=p_owner),'[]'),
 'expense_edit_requests',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(r)) order by request_id) from finance_private.expense_edit_requests r join public.spaces s on s.id=(r.before_row->>'space_id')::uuid where s.owner_user_id=p_owner),'[]'),
 'operation_receipts',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(r)) order by request_id) from finance_private.operation_receipts r where r.actor_id=p_owner),'[]'),
 'bulk_action_receipts',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(r)) order by request_id) from finance_private.bulk_action_receipts r join public.spaces s on s.id=r.space_id where s.owner_user_id=p_owner),'[]'),
 'backup_mutation_receipts',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(r)) order by request_id) from finance_private.backup_mutation_receipts r where r.owner_id=p_owner),'[]')) $$;

create or replace function finance_private.backup_data(p_owner uuid) returns jsonb
language sql volatile security definer set search_path='' as $$
 select jsonb_build_object(
 'spaces',coalesce((select jsonb_agg(to_jsonb(s) order by id) from public.spaces s where owner_user_id=p_owner),'[]'),
 'wallets',coalesce((select jsonb_agg(to_jsonb(w) order by w.id) from public.wallets w join public.spaces s on s.id=w.space_id where s.owner_user_id=p_owner),'[]'),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.categories c join public.spaces s on s.id=c.space_id where s.owner_user_id=p_owner),'[]'),
 'wallet_opening_balances',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(b)) order by wallet_id) from public.wallet_opening_balances b join public.wallets w on w.id=b.wallet_id join public.spaces s on s.id=w.space_id where s.owner_user_id=p_owner),'[]'),
 'transfers',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(t)) order by t.id) from public.transfers t join public.spaces s on s.id=t.space_id where s.owner_user_id=p_owner),'[]'),
 'expenses',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(e)) order by e.id) from public.expenses e join public.spaces s on s.id=e.space_id where s.owner_user_id=p_owner),'[]'),
 'incomes',coalesce((select jsonb_agg(finance_private.backup_json(to_jsonb(i)) order by i.id) from public.incomes i join public.spaces s on s.id=i.space_id where s.owner_user_id=p_owner),'[]'),
 'finance_settings',coalesce((select jsonb_agg(to_jsonb(f)) from public.finance_settings f where owner_id=p_owner),'[]'));
$$;

-- One common guard already used by cashflow/tree RPCs. New statement triggers
-- also cover direct PATCH/INSERT and opening balances. No network under lock.
create or replace function finance_private.backup_lock() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not found then raise exception 'Missing data guard'; end if;
 return null;
end $$;

-- Ordinary owner writes use request receipts and expected revisions. Old
-- clients cannot PATCH restored wallets/opening balances without a revision.
create or replace function public.backup_write(p_request uuid,p_table text,p_action text,p_id uuid,p_expected uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare scope uuid; saved jsonb; prior jsonb; owner uuid; body jsonb; receipt finance_private.backup_mutation_receipts%rowtype;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 owner:=auth.uid();
 if owner is null or not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 if p_request is null or p_table not in ('wallets','categories','wallet_opening_balances') or p_action not in ('create','update','delete') or jsonb_typeof(p_data) is distinct from 'object' then raise exception 'Unsupported mutation'; end if;
 if p_action='delete' and p_table<>'wallets' then raise exception 'Unsupported deletion'; end if;
 body:=jsonb_build_object('table',p_table,'action',p_action,'id',p_id,'expected',p_expected,'data',p_data);
 select * into receipt from finance_private.backup_mutation_receipts where owner_id=owner and request_id=p_request;
 if found then if receipt.payload<>body then raise exception 'Request id reused'; end if; return receipt.result; end if;
 if p_action='create' then
  if p_table='wallet_opening_balances' then select space_id into scope from public.wallets where id=p_id;
  else scope:=(p_data->>'space_id')::uuid; end if;
 else
  if p_id is null or p_expected is null then raise exception using errcode='P1003',message='Revision required; refresh'; end if;
  if p_table='wallet_opening_balances' then
   select finance_private.backup_json(to_jsonb(b)),w.space_id into prior,scope from public.wallet_opening_balances b join public.wallets w on w.id=b.wallet_id where b.wallet_id=p_id;
  else execute format('select finance_private.backup_json(to_jsonb(r)),r.space_id from public.%I r where id=$1',p_table) into prior,scope using p_id; end if;
  if prior is null or prior->>'revision'<>p_expected::text then raise exception using errcode='P1003',message='Revision conflict'; end if;
 end if;
 if not finance_private.owns_space(scope) then raise exception using errcode='42501',message='Owner access required'; end if;
 if p_action='delete' then delete from public.wallets where id=p_id; saved:=prior;
 elsif p_table='wallets' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('space_id','name','wallet_group','currency','currency_scale','icon_id','is_archived')) then raise exception 'Unsupported wallet fields'; end if;
  if p_action='create' then
   insert into public.wallets(space_id,name,wallet_group,currency,currency_scale,icon_id)
   values(scope,p_data->>'name',p_data->>'wallet_group',p_data->>'currency',coalesce((p_data->>'currency_scale')::smallint,2),p_data->>'icon_id') returning to_jsonb(wallets) into saved;
  else
   if p_data ?| array['space_id','currency','currency_scale'] then raise exception 'Immutable wallet scope/currency'; end if;
   update public.wallets set name=case when p_data?'name' then p_data->>'name' else name end,
    wallet_group=case when p_data?'wallet_group' then p_data->>'wallet_group' else wallet_group end,
    icon_id=case when p_data?'icon_id' then p_data->>'icon_id' else icon_id end,
    is_archived=case when p_data?'is_archived' then (p_data->>'is_archived')::boolean else is_archived end
    where id=p_id returning to_jsonb(wallets) into saved;
  end if;
 elsif p_table='categories' then
  if exists(select 1 from jsonb_object_keys(p_data) k where k not in ('space_id','kind','name','parent_id','icon_id','is_archived')) then raise exception 'Unsupported category fields'; end if;
  if p_action='create' then
   insert into public.categories(space_id,kind,name,parent_id,icon_id) values(scope,p_data->>'kind',p_data->>'name',(p_data->>'parent_id')::uuid,coalesce(p_data->>'icon_id','category')) returning to_jsonb(categories) into saved;
  else
   if p_data ?| array['space_id','kind'] then raise exception 'Immutable category scope'; end if;
   update public.categories set name=case when p_data?'name' then p_data->>'name' else name end,
    parent_id=case when p_data?'parent_id' then (p_data->>'parent_id')::uuid else parent_id end,
    icon_id=case when p_data?'icon_id' then p_data->>'icon_id' else icon_id end,
    is_archived=case when p_data?'is_archived' then (p_data->>'is_archived')::boolean else is_archived end
    where id=p_id returning to_jsonb(categories) into saved;
  end if;
 else
  if (select count(*) from jsonb_object_keys(p_data))<>1 or not p_data?'amount_minor' or jsonb_typeof(p_data->'amount_minor')<>'string' or p_data->>'amount_minor' !~ '^-?[0-9]{1,19}$' then raise exception 'Exact money required'; end if;
  if p_action='create' then
   insert into public.wallet_opening_balances(wallet_id,amount_minor) values(p_id,(p_data->>'amount_minor')::bigint) returning finance_private.backup_json(to_jsonb(wallet_opening_balances)) into saved;
  else update public.wallet_opening_balances set amount_minor=(p_data->>'amount_minor')::bigint where wallet_id=p_id returning finance_private.backup_json(to_jsonb(wallet_opening_balances)) into saved; end if;
 end if;
 insert into finance_private.backup_mutation_receipts(owner_id,request_id,payload,result) values(owner,p_request,body,saved);
 return saved;
end $$;
revoke all on function public.backup_write(uuid,text,text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.backup_write(uuid,text,text,uuid,uuid,jsonb) to authenticated;
create or replace function public.backup_save_templates(p_request uuid,p_expected uuid,p_templates jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare owner uuid:=auth.uid(); prior public.finance_settings%rowtype; saved jsonb; body jsonb; receipt finance_private.backup_mutation_receipts%rowtype;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if owner is null or not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 if p_request is null or jsonb_typeof(p_templates) is distinct from 'array' then raise exception 'Invalid templates'; end if;
 body:=jsonb_build_object('table','finance_settings','expected',p_expected,'templates',p_templates);
 select * into receipt from finance_private.backup_mutation_receipts where owner_id=owner and request_id=p_request;
 if found then if receipt.payload<>body then raise exception 'Request id reused'; end if; return receipt.result; end if;
 select * into prior from public.finance_settings where owner_id=owner;
 if prior.revision is distinct from p_expected then raise exception using errcode='P1003',message='Templates changed; refresh'; end if;
 insert into public.finance_settings(owner_id,report_templates) values(owner,p_templates)
 on conflict(owner_id) do update set report_templates=excluded.report_templates
 returning to_jsonb(finance_settings) into saved;
 insert into finance_private.backup_mutation_receipts(owner_id,request_id,payload,result) values(owner,p_request,body,saved);
 return saved;
end $$;
revoke all on function public.backup_save_templates(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.backup_save_templates(uuid,uuid,jsonb) to authenticated;
revoke insert,update,delete on public.finance_settings from authenticated;
-- Remove both table and previously granted column write privileges.
revoke insert,update,delete on public.wallets,public.categories,public.wallet_opening_balances from authenticated;
do $$ declare t text; cols text; begin
 foreach t in array array['wallets','categories','wallet_opening_balances'] loop
  select string_agg(quote_ident(attname),',') into cols from pg_attribute where attrelid=('public.'||t)::regclass and attnum>0 and not attisdropped;
  execute format('revoke insert(%s),update(%s) on public.%I from authenticated',cols,cols,t);
 end loop;
end $$;
create or replace function finance_private.backup_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare prior jsonb; later jsonb; row_data jsonb; scope uuid; owner uuid; object uuid; op uuid;
begin
 if tg_op<>'INSERT' then prior:=finance_private.backup_json(to_jsonb(old)); end if;
 if tg_op<>'DELETE' then later:=finance_private.backup_json(to_jsonb(new)); end if;
 if prior is not distinct from later then return null; end if;
 row_data:=coalesce(later,prior);
 if tg_table_name='spaces' then scope:=(row_data->>'id')::uuid; owner:=(row_data->>'owner_user_id')::uuid;
 elsif tg_table_name='finance_settings' then owner:=(row_data->>'owner_id')::uuid;
 elsif tg_table_name='wallet_opening_balances' then
  select w.space_id,s.owner_user_id into scope,owner from public.wallets w join public.spaces s on s.id=w.space_id where w.id=(row_data->>'wallet_id')::uuid;
 else scope:=(row_data->>'space_id')::uuid;
 end if;
 if owner is null then select owner_user_id into owner from public.spaces where id=scope; end if;
 if owner is null then
  select a.owner_id,coalesce(scope,a.space_id,(a.before_row->>'space_id')::uuid)
   into owner,scope from finance_private.backup_actions a where a.transaction_id=txid_current()
   and ((a.table_name='spaces' and a.object_id=scope) or
    (a.table_name='wallets' and a.object_id=(row_data->>'wallet_id')::uuid)) order by a.id desc limit 1;
 end if;
 if owner is null then raise exception 'History owner unavailable'; end if;
 object:=coalesce(row_data->>'id',row_data->>'wallet_id',row_data->>'owner_id')::uuid;
 select operation_id into op from finance_private.backup_actions where transaction_id=txid_current() limit 1;
 op:=coalesce(op,gen_random_uuid());
 insert into finance_private.backup_actions(operation_id,transaction_id,owner_id,space_id,actor_id,table_name,object_id,action,before_row,after_row)
 values(op,txid_current(),owner,scope,auth.uid(),tg_table_name,object,tg_op,prior,later);
 if tg_op='DELETE' then return old; end if;
 return null;
end $$;
do $$ declare t text; begin
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  execute format('drop trigger if exists aaa_backup_lock on public.%I',t);
  execute format('create trigger aaa_backup_lock before insert or update or delete on public.%I for each statement execute function finance_private.backup_lock()',t);
  execute format('drop trigger if exists zzz_backup_history on public.%I',t);
  -- BEFORE DELETE retains owner info even when a parent cascades deletion.
  execute format('create trigger zzz_backup_history after insert or update on public.%I for each row execute function finance_private.backup_history()',t);
  execute format('drop trigger if exists aaa_backup_delete_history on public.%I',t);
  execute format('create trigger aaa_backup_delete_history before delete on public.%I for each row execute function finance_private.backup_history()',t);
 end loop;
end $$;

create or replace function public.backup_capture(p_request_id uuid,p_kind text default 'manual',p_comment text default '')
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare owner uuid:=auth.uid(); data jsonb; release jsonb; saved finance_private.backup_jobs%rowtype; identifier uuid;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if owner is null or not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 select * into saved from finance_private.backup_jobs where owner_id=owner and request_id=p_request_id;
 if found then
  if saved.kind<>p_kind or saved.comment<>p_comment then raise exception 'Request id reused'; end if;
  return saved.id;
 end if;
 select jsonb_build_object('version',version,'files',manifest||coalesce((select asset_manifest from public.finance_settings where owner_id=owner),'{}')) into release from finance_private.backup_release where singleton;
 if release is null then raise exception 'Original images have not been registered in backup storage'; end if;
 data:=finance_private.backup_data(owner);
 insert into finance_private.backup_jobs(owner_id,request_id,kind,comment,fingerprint,payload,release)
 values(owner,p_request_id,p_kind,p_comment,encode(sha256(convert_to(data::text,'UTF8')),'hex'),jsonb_build_object(
  'format',1,'schema',18,'app','1.0.0+1','owner_id',owner,'data',data,
  'receipts',finance_private.backup_receipts(owner),
  'history',coalesce((select jsonb_agg(to_jsonb(a) order by id) from finance_private.backup_actions a
   where owner_id=owner and occurred_at>=now()-interval '30 days'),'[]')),release) returning id into identifier;
 return identifier;
end $$;
create or replace function public.backup_list() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'kind',kind,'comment',comment,
  'state',state,'captured_at',captured_at,'timezone',timezone,'new_bytes',new_bytes,
  'export_bytes',export_bytes,'storage',storage,'error',error) order by captured_at desc)
  from finance_private.backup_jobs where owner_id=auth.uid()),'[]');
end $$;
create or replace function public.backup_history_list() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 return coalesce((select jsonb_agg(row_data order by occurred_at desc) from (
  select operation_id,max(occurred_at) occurred_at,jsonb_build_object('operation_id',operation_id,
  'occurred_at',max(occurred_at),'actor_id',max(actor_id::text),'changes',jsonb_agg(jsonb_build_object(
   'table',table_name,'action',action,'object_id',object_id,'before',before_row,'after',after_row) order by id)) row_data
  from finance_private.backup_actions where owner_id=auth.uid() and occurred_at>=now()-interval '30 days'
  group by operation_id order by max(occurred_at) desc limit 100) a),'[]');
end $$;

create or replace function finance_private.backup_require(p_request uuid) returns void
language plpgsql set search_path='' as $$
declare saved finance_private.backup_jobs%rowtype;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 select * into saved from finance_private.backup_jobs where request_id=p_request and owner_id=auth.uid() and kind in ('before','restore') and state='ready';
 if not found then raise exception using errcode='P1018',message='A verified backup is required before this action'; end if;
 if saved.fingerprint<>encode(sha256(convert_to(finance_private.backup_data(auth.uid())::text,'UTF8')),'hex') then
  raise exception using errcode='P1018',message='Data changed after backup; refresh and create a new backup'; end if;
end $$;
-- Wrap the actual existing server RPCs, preserving signatures/retry receipts.
-- DDL is idempotent: the private delegate is renamed only once.
do $$ begin
 if to_regprocedure('finance_private.backup_mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb)') is null then
  alter function public.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb) set schema finance_private;
  alter function finance_private.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb) rename to backup_mutate_categories;
 end if;
 if to_regprocedure('finance_private.backup_reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb)') is null then
  alter function public.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb) set schema finance_private;
  alter function finance_private.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb) rename to backup_reorder_categories;
 end if;
 if to_regprocedure('finance_private.backup_delete_cashflow(uuid,uuid,text,jsonb)') is null then
  alter function public.delete_cashflow(uuid,uuid,text,jsonb) set schema finance_private;
  alter function finance_private.delete_cashflow(uuid,uuid,text,jsonb) rename to backup_delete_cashflow;
 end if;
 if to_regprocedure('finance_private.backup_reorder_wallets(uuid,uuid[])') is null then
  alter function public.reorder_wallets(uuid,uuid[]) set schema finance_private;
  alter function finance_private.reorder_wallets(uuid,uuid[]) rename to backup_reorder_wallets;
 end if;
end $$;
create or replace function public.reorder_wallets(p_space_id uuid,p_wallet_ids uuid[],p_request_id uuid default null)
returns void language plpgsql volatile security definer set search_path='' as $$
declare payload jsonb:=jsonb_build_object('wallets',p_wallet_ids); receipt finance_private.bulk_action_receipts%rowtype;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
 select * into receipt from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id;
 if found then
  if receipt.action<>'reorder_wallets' or receipt.space_id<>p_space_id or receipt.payload<>payload then raise exception 'Request id reused'; end if;
  return;
 end if;
 perform finance_private.backup_require(p_request_id);
 perform finance_private.backup_reorder_wallets(p_space_id,p_wallet_ids);
 insert into finance_private.bulk_action_receipts(actor_id,request_id,space_id,action,payload,before_rows,result)
 values(auth.uid(),p_request_id,p_space_id,'reorder_wallets',payload,'[]','{}');
end $$;
revoke all on function public.reorder_wallets(uuid,uuid[],uuid) from public,anon,authenticated;
grant execute on function public.reorder_wallets(uuid,uuid[],uuid) to authenticated;
create or replace function public.mutate_categories(p_request_id uuid,p_space_id uuid,p_kind text,p_action text,p_ids uuid[],p_expected jsonb,p_replacements jsonb default '{}')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
 if not exists(select 1 from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id) then perform finance_private.backup_require(p_request_id); end if;
 return finance_private.backup_mutate_categories(p_request_id,p_space_id,p_kind,p_action,p_ids,p_expected,p_replacements);
end $$;
create or replace function public.reorder_categories(p_request_id uuid,p_space_id uuid,p_kind text,p_parent_id uuid,p_ids uuid[],p_expected jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
 if not exists(select 1 from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id) then perform finance_private.backup_require(p_request_id); end if;
 return finance_private.backup_reorder_categories(p_request_id,p_space_id,p_kind,p_parent_id,p_ids,p_expected);
end $$;
create or replace function public.delete_cashflow(p_request_id uuid,p_space_id uuid,p_kind text,p_rows jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
 if not exists(select 1 from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id) then perform finance_private.backup_require(p_request_id); end if;
 return finance_private.backup_delete_cashflow(p_request_id,p_space_id,p_kind,p_rows);
end $$;

-- All imported rows are data, never SQL. Fixed allowlist, collision/scope checks.
create or replace function finance_private.backup_validate(p_owner uuid,p_data jsonb) returns void
language plpgsql set search_path='' as $$
declare t text; k text; row_data jsonb; spaces uuid[]; existing_owner uuid; identifier uuid;
begin
 if jsonb_typeof(p_data) is distinct from 'object' or (select count(*) from jsonb_object_keys(p_data))<>8 then raise exception 'Invalid data tables'; end if;
 select array_agg((value->>'id')::uuid) into spaces from jsonb_array_elements(p_data->'spaces');
 if coalesce(cardinality(spaces),0)=0 then raise exception 'Snapshot needs spaces'; end if;
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  if jsonb_typeof(p_data->t) is distinct from 'array' then raise exception 'Missing table %',t; end if;
  k:=case t when 'wallet_opening_balances' then 'wallet_id' when 'finance_settings' then 'owner_id' else 'id' end;
  if (select count(distinct value->>k) from jsonb_array_elements(p_data->t))<>jsonb_array_length(p_data->t) then raise exception 'Duplicate/null IDs'; end if;
  for row_data in select value from jsonb_array_elements(p_data->t) loop
   identifier:=(row_data->>k)::uuid;
   if t='spaces' then
    if (row_data->>'owner_user_id')::uuid is distinct from p_owner then raise exception 'Wrong owner'; end if;
    select owner_user_id into existing_owner from public.spaces where id=identifier;
   elsif t='finance_settings' then
    if identifier<>p_owner then raise exception 'Wrong settings owner'; end if;
    existing_owner:=p_owner;
   elsif t='wallet_opening_balances' then
    if not exists(select 1 from jsonb_array_elements(p_data->'wallets') w where w->>'id'=row_data->>'wallet_id') then raise exception 'Missing balance wallet'; end if;
    select s.owner_user_id into existing_owner from public.wallets w join public.spaces s on s.id=w.space_id where w.id=identifier;
   else
    if ((row_data->>'space_id')::uuid=any(spaces)) is distinct from true then raise exception 'Wrong space'; end if;
    execute format('select s.owner_user_id from public.%I r join public.spaces s on s.id=r.space_id where r.id=$1',t) into existing_owner using identifier;
   end if;
   if existing_owner is not null and existing_owner<>p_owner then raise exception 'ID belongs to another owner'; end if;
  end loop;
 end loop;
end $$;

create or replace function finance_private.backup_apply(p_owner uuid,p_data jsonb,p_refresh_all boolean) returns void
language plpgsql set search_path='' as $$
declare t text; cols text; assignments text; k text; rows_data jsonb; scope_sql text;
 prior jsonb; later jsonb; r jsonb; before_row jsonb; after_row jsonb; op uuid:=gen_random_uuid();
begin
 perform finance_private.backup_validate(p_owner,p_data);
 -- Guard is acquired before any table locks. Exclusive locks make temporary
 -- trigger suspension invisible to every other client, including other owners.
 lock table public.spaces,public.wallets,public.categories,public.wallet_opening_balances,
 public.transfers,public.expenses,public.incomes,public.finance_settings in access exclusive mode;
 prior:=finance_private.backup_data(p_owner);
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  execute format('alter table public.%I disable trigger user',t);
 end loop;
 set constraints public.wallets_space_sort_order_key deferred;
 update public.categories set parent_id=null where space_id in(select id from public.spaces where owner_user_id=p_owner);
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  k:=case t when 'wallet_opening_balances' then 'wallet_id' when 'finance_settings' then 'owner_id' else 'id' end;
  rows_data:=p_data->t;
  if t='categories' then
   select coalesce(jsonb_agg(jsonb_set(value,'{parent_id}','null')),'[]') into rows_data from jsonb_array_elements(rows_data);
  end if;
  select string_agg(quote_ident(attname),',' order by attnum),
   string_agg(format('%I=excluded.%I',attname,attname),',' order by attnum) filter(where attname<>k)
   into cols,assignments from pg_catalog.pg_attribute where attrelid=('public.'||t)::regclass
    and attnum>0 and not attisdropped and attgenerated='';
  if t='wallets' then
   -- ON CONFLICT cannot use deferrable unique constraints, so UPDATE existing
   -- IDs and INSERT absent IDs separately for every table.
   null;
  end if;
  execute format('update public.%I existing set (%s)=(select %s from jsonb_populate_record(null::public.%I,item.value)) from jsonb_array_elements($1) item where existing.%I=(item.value->>%L)::uuid',t,cols,cols,t,k,k) using rows_data;
  execute format('insert into public.%I(%s) select %s from jsonb_populate_recordset(null::public.%I,$1) incoming where not exists(select 1 from public.%I existing where existing.%I=incoming.%I)',t,cols,cols,t,t,k,k) using rows_data;
 end loop;
 update public.categories c set parent_id=(r.value->>'parent_id')::uuid
  from jsonb_array_elements(p_data->'categories') r where c.id=(r.value->>'id')::uuid;
 foreach t in array array['expenses','incomes','wallet_opening_balances','transfers','categories','wallets','spaces','finance_settings'] loop
  k:=case t when 'wallet_opening_balances' then 'wallet_id' when 'finance_settings' then 'owner_id' else 'id' end;
  scope_sql:=case t when 'spaces' then 'owner_user_id=$2' when 'finance_settings' then 'owner_id=$2'
   when 'wallet_opening_balances' then 'wallet_id in(select w.id from public.wallets w join public.spaces s on s.id=w.space_id where s.owner_user_id=$2)'
   else 'space_id in(select id from public.spaces where owner_user_id=$2)' end;
  if t='categories' then
   update public.categories set parent_id=null where space_id in(select id from public.spaces where owner_user_id=p_owner)
    and id not in(select (value->>'id')::uuid from jsonb_array_elements(p_data->t));
  end if;
  execute format('delete from public.%I where %s and %I not in(select (value->>%L)::uuid from jsonb_array_elements($1))',t,scope_sql,k,k) using p_data->t,p_owner;
 end loop;
 -- Renew revisions. Undo renews only the changed records; full restore renews all.
 foreach t in array array['wallets','wallet_opening_balances','categories','expenses','incomes','transfers','finance_settings'] loop
  k:=case t when 'finance_settings' then 'owner_id' when 'wallet_opening_balances' then 'wallet_id' else 'id' end;
  scope_sql:=case t when 'finance_settings' then 'owner_id=$2' when 'wallet_opening_balances' then 'wallet_id in(select w.id from public.wallets w join public.spaces s on s.id=w.space_id where s.owner_user_id=$2)' else 'space_id in(select id from public.spaces where owner_user_id=$2)' end;
  execute format('update public.%I target set revision=gen_random_uuid() where %s and ($3 or not exists(select 1 from jsonb_array_elements($1) r where (r.value->>%L)::uuid=target.%I and r.value=finance_private.backup_json(to_jsonb(target))))',t,scope_sql,k,k) using prior->t,p_owner,p_refresh_all;
 end loop;
 -- Original request receipts stay spent even across restores/deletions. They
 -- are imported from their original immutable state by backup_restore, never
 -- reconstructed from a subsequently edited expense row.
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  execute format('alter table public.%I enable trigger user',t);
 end loop;
 -- FK/check constraints always stayed enabled. Explicit global tree validation.
 update public.categories set name=name where false;
 later:=finance_private.backup_data(p_owner);
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings'] loop
  k:=case t when 'wallet_opening_balances' then 'wallet_id' when 'finance_settings' then 'owner_id' else 'id' end;
  for r in select jsonb_build_object('id',coalesce(b.value->>k,a.value->>k),'before',b.value,'after',a.value) from jsonb_array_elements(prior->t) b full join jsonb_array_elements(later->t) a on b.value->>k=a.value->>k where b.value is distinct from a.value loop
   before_row:=nullif(r->'before','null'); after_row:=nullif(r->'after','null');
   insert into finance_private.backup_actions(operation_id,transaction_id,owner_id,space_id,actor_id,table_name,object_id,action,before_row,after_row)
   values(op,txid_current(),p_owner,coalesce(after_row->>'space_id',before_row->>'space_id')::uuid,auth.uid(),t,(r->>'id')::uuid,'RESTORE',before_row,after_row);
  end loop;
 end loop;
end $$;

create or replace function finance_private.backup_restore(p_owner uuid,p_source uuid,p_request uuid) returns void
language plpgsql security definer set search_path='' as $$
declare source finance_private.backup_jobs%rowtype; t text; cols text; h jsonb; digest text; imported_op uuid; operation_map jsonb:='{}';
begin
 perform set_config('request.jwt.claim.sub',p_owner::text,true);
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if exists(select 1 from finance_private.backup_restore_audit where owner_id=p_owner and request_id=p_request and source_id=p_source and kind='restore') then return; end if;
 if exists(select 1 from finance_private.backup_restore_audit where owner_id=p_owner and request_id=p_request) then raise exception 'Request id reused'; end if;
 perform finance_private.backup_require(p_request);
 select * into source from finance_private.backup_jobs where id=p_source and owner_id=p_owner and state='ready';
 if not found or source.payload->>'owner_id'<>p_owner::text or source.payload->>'schema'<>'18' then raise exception 'Snapshot unavailable/incompatible'; end if;
 perform finance_private.backup_apply(p_owner,source.payload->'data',true);
 -- Idempotency receipts are append-only and never rolled back/deleted. Restored
 -- requests remain spent in a clean database too. Only fixed tables are used.
 foreach t in array array['expense_creation_receipts','expense_edit_requests','operation_receipts','bulk_action_receipts','backup_mutation_receipts'] loop
  select string_agg(quote_ident(attname),',' order by attnum) into cols from pg_catalog.pg_attribute
   where attrelid=('finance_private.'||t)::regclass and attnum>0 and not attisdropped and attgenerated='';
  execute format('insert into finance_private.%I(%s) select %s from jsonb_populate_recordset(null::finance_private.%I,$1) on conflict do nothing',t,cols,cols,t) using coalesce(source.payload->'receipts'->t,'[]');
 end loop;
 insert into public.finance_settings(owner_id,asset_manifest) values(p_owner,source.release->'files')
 on conflict(owner_id) do update set asset_manifest=excluded.asset_manifest,revision=gen_random_uuid();
 -- Original history remains available in a clean target. IDs and actor grants
 -- are not trusted. Imported entries are labelled and may conflict on undo
 -- because full restoration intentionally renews every data revision.
 for h in select value from jsonb_array_elements(coalesce(source.payload->'history','[]')) loop
  if h->>'owner_id'<>p_owner::text or h->>'table_name' not in ('spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes','finance_settings') then raise exception 'Foreign history'; end if;
  if exists(select 1 from finance_private.backup_actions a where owner_id=p_owner and id=(h->>'id')::bigint and before_row is not distinct from nullif(h->'before_row','null') and after_row is not distinct from nullif(h->'after_row','null')) then continue; end if;
  if (h->>'occurred_at')::timestamptz<now()-interval '30 days' then continue; end if;
  digest:=encode(sha256(convert_to(h::text,'UTF8')),'hex');
  insert into finance_private.backup_history_sources(owner_id,digest) values(p_owner,digest) on conflict do nothing;
  if not found then continue; end if;
  imported_op:=(operation_map->>(h->>'operation_id'))::uuid;
  if imported_op is null then imported_op:=gen_random_uuid(); operation_map:=operation_map||jsonb_build_object(h->>'operation_id',imported_op); end if;
  insert into finance_private.backup_actions(operation_id,transaction_id,owner_id,space_id,actor_id,occurred_at,table_name,object_id,action,before_row,after_row)
  values(imported_op,0,p_owner,(h->>'space_id')::uuid,null,(h->>'occurred_at')::timestamptz,h->>'table_name',(h->>'object_id')::uuid,'IMPORTED_'||(h->>'action'),nullif(h->'before_row','null'),nullif(h->'after_row','null'));
 end loop;
 insert into finance_private.backup_restore_audit(owner_id,request_id,source_id,kind) values(p_owner,p_request,p_source,'restore');
end $$;
create or replace function public.backup_undo(p_operation uuid,p_request uuid) returns void
language plpgsql security definer set search_path='' as $$
declare owner uuid:=auth.uid(); target jsonb; entry record; k text; rows_data jsonb; current_row jsonb;
begin
 update finance_private.category_tree_guard set flip=not flip where singleton;
 if not finance_private.is_established_owner() then raise exception using errcode='42501',message='Owner access required'; end if;
 if exists(select 1 from finance_private.backup_restore_audit where owner_id=owner and request_id=p_request and source_id=p_operation and kind='undo') then return; end if;
 if exists(select 1 from finance_private.backup_restore_audit where owner_id=owner and request_id=p_request) then raise exception 'Request id reused'; end if;
 if not exists(select 1 from finance_private.backup_actions where owner_id=owner and operation_id=p_operation and occurred_at>=now()-interval '30 days') then raise exception 'Action unavailable'; end if;
 if (select count(*) from finance_private.backup_actions where owner_id=owner and operation_id=p_operation)>1 then perform finance_private.backup_require(p_request); end if;
 target:=finance_private.backup_data(owner);
 -- Reverse in event order: repeated writes to a row in one RPC are one action.
 for entry in select * from finance_private.backup_actions where owner_id=owner and operation_id=p_operation order by id desc loop
  k:=case entry.table_name when 'wallet_opening_balances' then 'wallet_id' when 'finance_settings' then 'owner_id' else 'id' end;
  select value into current_row from jsonb_array_elements(target->entry.table_name) where value->>k=entry.object_id::text;
  if current_row is distinct from entry.after_row then raise exception using errcode='P1003',message='Action has subsequent changes; undo cancelled'; end if;
  select coalesce(jsonb_agg(value order by value->>k),'[]') into rows_data from jsonb_array_elements(target->entry.table_name) where value->>k<>entry.object_id::text;
  if entry.before_row is not null then rows_data:=rows_data||jsonb_build_array(entry.before_row); end if;
  target:=jsonb_set(target,array[entry.table_name],rows_data);
 end loop;
 perform finance_private.backup_apply(owner,target,false);
 insert into finance_private.backup_restore_audit(owner_id,request_id,source_id,kind) values(owner,p_request,p_operation,'undo');
end $$;

-- Restricted server role. An administrator grants this NOLOGIN role to a
-- dedicated LOGIN role with a password entered through protected settings.
do $$ begin if not exists(select 1 from pg_roles where rolname='finance_backup_worker') then create role finance_backup_worker nologin; end if; end $$;
grant usage on schema public,finance_private,auth to finance_backup_worker;
create or replace function finance_private.backup_worker_owners() returns setof uuid
language sql security definer set search_path='' as $$ select distinct owner_user_id from public.spaces $$;
create or replace function finance_private.backup_worker_capture(p_owner uuid,p_request uuid,p_kind text,p_comment text) returns uuid
language plpgsql security definer set search_path='' as $$ begin
 perform set_config('request.jwt.claim.sub',p_owner::text,true);
 return public.backup_capture(p_request,p_kind,p_comment);
end $$;
create or replace function finance_private.backup_worker_get(p_owner uuid,p_id uuid) returns jsonb
language sql security definer set search_path='' as $$
 select to_jsonb(j) from finance_private.backup_jobs j where owner_id=p_owner and id=p_id
$$;
create or replace function finance_private.backup_worker_list(p_owner uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ begin
 perform set_config('request.jwt.claim.sub',p_owner::text,true); return public.backup_list(); end $$;
create or replace function finance_private.backup_worker_release(p_version text,p_manifest jsonb) returns void
language sql security definer set search_path='' as $$
 insert into finance_private.backup_release(singleton,version,manifest) values(true,p_version,p_manifest)
 on conflict(singleton) do update set version=excluded.version,manifest=excluded.manifest,registered_at=now()
$$;
create or replace function finance_private.backup_worker_claim(p_owner uuid,p_id uuid) returns boolean
language plpgsql security definer set search_path='' as $$ begin
 update finance_private.backup_jobs set state='running',attempts=attempts+1,lease_until=now()+interval '15 minutes',error=null
 where owner_id=p_owner and id=p_id and attempts<4 and (state in ('queued','failed') or (state='running' and lease_until<now()));
 return found;
end $$;
create or replace function finance_private.backup_worker_seal(p_owner uuid,p_id uuid,p_sha text,p_new bigint,p_export bigint,p_storage text) returns void
language plpgsql security definer set search_path='' as $$ begin
 if p_sha !~ '^[a-f0-9]{64}$' or p_new<0 or p_export<0 then raise exception 'Invalid sealed snapshot'; end if;
 update finance_private.backup_jobs set state='ready',data_sha256=p_sha,new_bytes=p_new,export_bytes=p_export,storage=p_storage,lease_until=null,error=null where owner_id=p_owner and id=p_id and state='running';
 if not found then raise exception 'Snapshot was not claimed'; end if;
end $$;
create or replace function finance_private.backup_worker_fail(p_owner uuid,p_id uuid) returns void
language sql security definer set search_path='' as $$ update finance_private.backup_jobs set state='failed',error='Backup storage failed; retry required',lease_until=null where owner_id=p_owner and id=p_id and state<>'ready' $$;
create or replace function finance_private.backup_worker_import(p_owner uuid,p_id uuid,p_payload jsonb,p_release jsonb,p_sha text,p_captured timestamptz) returns uuid
language plpgsql security definer set search_path='' as $$ begin
 if p_payload->>'format'<>'1' or p_payload->>'schema'<>'18' or p_payload->>'owner_id'<>p_owner::text then raise exception 'Incompatible or foreign archive'; end if;
 if not exists(select 1 from public.spaces where owner_user_id=p_owner) then raise exception using errcode='42501',message='Owner access required'; end if;
 perform finance_private.backup_validate(p_owner,p_payload->'data');
 insert into finance_private.backup_jobs(id,owner_id,request_id,kind,comment,fingerprint,payload,release,captured_at)
 values(p_id,p_owner,p_id,'manual','Imported archive',encode(sha256(convert_to((p_payload->'data')::text,'UTF8')),'hex'),p_payload,p_release,p_captured);
 return p_id;
end $$;

create or replace function finance_private.backup_worker_history(p_owner uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ begin
 perform set_config('request.jwt.claim.sub',p_owner::text,true); return public.backup_history_list(); end $$;
create or replace function finance_private.backup_worker_undo(p_owner uuid,p_operation uuid,p_request uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform set_config('request.jwt.claim.sub',p_owner::text,true); perform public.backup_undo(p_operation,p_request); end $$;
create or replace function finance_private.backup_worker_asset_manifest(p_owner uuid) returns jsonb
language sql security definer set search_path='' as $$ select coalesce((select asset_manifest from public.finance_settings where owner_id=p_owner),'{}') $$;
create or replace function finance_private.backup_worker_storage_count(p_owner uuid) returns bigint
language plpgsql security definer set search_path='' as $$ declare total bigint:=0; begin
 if to_regclass('storage.objects') is not null then
  -- Supabase Storage has no usage in the current Flutter code. Never silently
  -- skip uploaded files if a later version introduces them.
  execute 'select count(*) from storage.objects where owner_id=$1 or owner::text=$1' into total using p_owner::text;
 end if;
 return total;
end $$;
create or replace function finance_private.backup_worker_storage_lock(p_owner uuid) returns void
language sql security definer set search_path='' as $$
 insert into finance_private.backup_io_guard(owner_id) values(p_owner)
 on conflict(owner_id) do update set flip=not finance_private.backup_io_guard.flip $$;
create or replace function finance_private.backup_worker_prune(p_owner uuid) returns jsonb
language plpgsql security definer set search_path='' as $$ declare removed jsonb; begin
 perform finance_private.backup_worker_storage_lock(p_owner);
 delete from finance_private.backup_pins where owner_id=p_owner and expires_at<now();
 -- Keep last ready, manual, active jobs and last ready daily of each of the
 -- preceding 12 calendar months. Objects have conservative permanent retention.
 with deleted as (delete from finance_private.backup_jobs j where j.owner_id=p_owner and j.state='ready'
  and j.kind<>'manual' and j.captured_at<now()-interval '30 days'
  and not exists(select 1 from finance_private.backup_pins p where p.snapshot_id=j.id and p.expires_at>now())
  and j.id is distinct from (select id from finance_private.backup_jobs where owner_id=p_owner and state='ready' order by captured_at desc limit 1)
  and j.id not in (select distinct on(date_trunc('month',captured_at at time zone 'Asia/Qyzylorda')) id
   from finance_private.backup_jobs where owner_id=p_owner and state='ready' and kind='daily'
   and captured_at at time zone 'Asia/Qyzylorda'<date_trunc('month',now() at time zone 'Asia/Qyzylorda')
   and captured_at at time zone 'Asia/Qyzylorda'>=date_trunc('month',now() at time zone 'Asia/Qyzylorda')-interval '12 months'
   order by date_trunc('month',captured_at at time zone 'Asia/Qyzylorda'),captured_at desc) returning j.id)
 select coalesce(jsonb_agg(id),'[]') into removed from deleted;
 delete from finance_private.backup_actions where owner_id=p_owner and occurred_at<now()-interval '30 days';
 return removed;
end $$;
create or replace function finance_private.backup_worker_pending() returns jsonb
language sql security definer set search_path='' as $$ select coalesce(jsonb_agg(jsonb_build_object('id',id,'owner_id',owner_id)),'[]') from finance_private.backup_jobs where attempts<4 and (state in ('queued','failed') or (state='running' and lease_until<now())) $$;
create or replace function finance_private.backup_worker_delete(p_owner uuid,p_id uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform finance_private.backup_worker_storage_lock(p_owner);
 if exists(select 1 from finance_private.backup_pins where snapshot_id=p_id and owner_id=p_owner and expires_at>now()) then raise exception 'Export or restore is using this backup'; end if;
 if not exists(select 1 from finance_private.backup_jobs where owner_id=p_owner and state='ready' and id<>p_id) then raise exception 'Keep the last successful backup'; end if;
 delete from finance_private.backup_jobs where owner_id=p_owner and id=p_id and kind='manual' and state<>'running';
 if not found then raise exception 'Only manual backups can be deleted here'; end if;
end $$;
create or replace function finance_private.backup_worker_pin(p_owner uuid,p_id uuid,p_pin uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform finance_private.backup_worker_storage_lock(p_owner);
 perform 1 from finance_private.backup_jobs where id=p_id and owner_id=p_owner and state='ready' for update;
 if not found then raise exception 'Snapshot unavailable'; end if;
 insert into finance_private.backup_pins(pin_id,owner_id,snapshot_id) values(p_pin,p_owner,p_id);
end $$;
create or replace function finance_private.backup_worker_unpin(p_owner uuid,p_pin uuid) returns void
language plpgsql security definer set search_path='' as $$ begin
 perform finance_private.backup_worker_storage_lock(p_owner);
 delete from finance_private.backup_pins where owner_id=p_owner and pin_id=p_pin;
end $$;

-- Keep unrelated existing private grants intact.
do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='finance_private' and p.proname like 'backup_%' loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.signature::text like '%backup_worker_%' or f.signature::text like '%backup_restore(%' then execute format('grant execute on function %s to finance_backup_worker',f.signature); end if;
 end loop;
end $$;
revoke all on function public.backup_undo(uuid,uuid) from public,anon,authenticated;
grant execute on function public.backup_undo(uuid,uuid) to authenticated;
revoke all on function public.backup_capture(uuid,text,text),public.backup_list(),public.backup_history_list(),
 public.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb),public.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb),public.delete_cashflow(uuid,uuid,text,jsonb)
 from public,anon,authenticated;
grant execute on function public.backup_capture(uuid,text,text),public.backup_list(),public.backup_history_list(),
 public.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb),public.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb),public.delete_cashflow(uuid,uuid,text,jsonb)
 to authenticated;
notify pgrst,'reload schema';
commit;
