-- 017: Personal expense reconciliation; run the complete prepared file as postgres.
begin;
do $admin$ begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
  if not exists(select 1 from pg_attribute where attrelid='public.categories'::regclass and attname='revision' and not attisdropped) then
    raise exception 'Migration 016 is required';
  end if;
end $admin$;

create table if not exists finance_private.personal_expense_catalog (
  category_key text primary key, name text not null, parent_key text,
  sort_order integer not null, icon_id text not null
);
insert into finance_private.personal_expense_catalog values
__CATALOG_VALUES__
on conflict(category_key) do nothing;

create table if not exists finance_private.personal_expense_installations (
  space_id uuid not null references public.spaces(id), package_key text not null,
  installed_at timestamptz not null default now(), result jsonb not null,
  categories_before jsonb not null, references_before jsonb not null,
  primary key(space_id,package_key)
);
-- No category FK: a later deliberate deletion must remain deleted on replay.
create table if not exists finance_private.personal_expense_mappings (
  space_id uuid not null, package_key text not null, category_key text not null,
  category_id uuid not null, resolution text not null check(resolution in ('created','reused')),
  primary key(space_id,package_key,category_key), unique(space_id,package_key,category_id)
);
revoke all on finance_private.personal_expense_catalog,finance_private.personal_expense_installations,
  finance_private.personal_expense_mappings from public,anon,authenticated;

create or replace function finance_private.personal_expense_references(p_space uuid)
returns jsonb language sql stable set search_path='' set timezone='UTC' as $fn$
select jsonb_build_object(
 'expenses',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('amount_minor',e.amount_minor::text) order by e.id) from public.expenses e where e.space_id=p_space and not e.is_void),'[]'::jsonb),
 'incomes',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('amount_minor',i.amount_minor::text) order by i.id) from public.incomes i where i.space_id=p_space),'[]'::jsonb),
 'transfers',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('source_minor',t.source_minor::text,'target_minor',t.target_minor::text,'fee_minor',t.fee_minor::text) order by t.id) from public.transfers t where t.space_id=p_space),'[]'::jsonb)
);
$fn$;
revoke all on function finance_private.personal_expense_references(uuid) from public,anon,authenticated;

create or replace function finance_private.install_personal_expenses_20261006(
  p_space uuid,p_owner uuid,p_plan jsonb,p_expected jsonb,p_references jsonb
) returns jsonb language plpgsql volatile security invoker set search_path='' as $fn$
declare
  package constant text := 'personal_expenses_20261006_v1';
  before_categories jsonb; before_refs jsonb; untouched jsonb; money jsonb;
  result jsonb; created integer; reused integer; moved integer;
begin
  if current_user <> 'postgres' then raise exception using errcode='42501',message='Run as postgres'; end if;
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing category tree guard'; end if;
  if not exists(select 1 from public.spaces where id=p_space and kind='personal' and owner_user_id=p_owner) then
    raise exception 'Wrong personal space or owner';
  end if;
  select i.result into result from finance_private.personal_expense_installations i where i.space_id=p_space and i.package_key=package;
  if found then return result||jsonb_build_object('replay',true); end if;
  perform finance_private.check_category_snapshot(p_space,'expense',p_expected);
  before_refs := finance_private.personal_expense_references(p_space);
  if before_refs <> p_references then raise exception 'References changed since backup; prepare a fresh package'; end if;
  if jsonb_typeof(p_plan)<>'array' or jsonb_array_length(p_plan)<>143 then raise exception 'Expected all 143 catalog mappings'; end if;
  if exists(select 1 from pg_constraint k where k.contype='f' and k.confrelid='public.categories'::regclass
    and k.conrelid in (select oid from pg_class where relnamespace='public'::regnamespace)
    and k.conrelid not in ('public.categories'::regclass,'public.expenses'::regclass,'public.incomes'::regclass,'public.transfers'::regclass)) then
    raise exception 'Unexpected public category references; review before import';
  end if;
  create temporary table personal_plan on commit drop as
    select x.key category_key,x.id,x.reuse,x.icon_id,c.name,c.parent_key,c.sort_order
    from jsonb_to_recordset(p_plan) as x(key text,id uuid,reuse boolean,icon_id text)
    join finance_private.personal_expense_catalog c on c.category_key=x.key;
  if (select count(*) from personal_plan)<>143 or (select count(distinct id) from personal_plan)<>143
    or (select count(distinct category_key) from personal_plan)<>143
    or exists(select 1 from personal_plan where id is null or reuse is null or icon_id is null or icon_id!~'^[a-z][a-z0-9_-]{0,95}$') then
    raise exception 'Incomplete or duplicate plan';
  end if;
  if exists(select 1 from personal_plan p left join public.categories c on c.id=p.id
      where (p.reuse and (c.id is null or c.space_id<>p_space or c.kind<>'expense')) or (not p.reuse and c.id is not null)) then
    raise exception 'Invalid reused category or colliding new UUID';
  end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) into before_categories from public.categories c where c.space_id=p_space and c.kind='expense';
  select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) into untouched from public.categories c where c.space_id<>p_space or c.kind<>'expense';
  money := jsonb_build_object(
    'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]'::jsonb) from public.expenses e),
    'incomes',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]'::jsonb) from public.incomes i),
    'transfers',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb) from public.transfers t),
    'wallets',(select coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb) from public.wallets w),
    'opening',(select coalesce(jsonb_agg(to_jsonb(o) order by wallet_id),'[]'::jsonb) from public.wallet_opening_balances o));
  select count(*) filter(where not reuse),count(*) filter(where reuse) into created,reused from personal_plan;
  select count(*) into moved from personal_plan p join public.categories c on c.id=p.id
    left join personal_plan parent on parent.category_key=p.parent_key where p.reuse and c.parent_id is distinct from parent.id;
  -- Insert/activate roots before children. Detaching roots cannot increase depth.
  insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order)
    select id,p_space,'expense',name,null,icon_id,sort_order from personal_plan where not reuse and parent_key is null;
  update public.categories c set name=p.name,parent_id=null,icon_id=p.icon_id,sort_order=p.sort_order,is_archived=false
    from personal_plan p where p.reuse and p.parent_key is null and c.id=p.id;
  insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order)
    select p.id,p_space,'expense',p.name,parent.id,p.icon_id,p.sort_order from personal_plan p
    join personal_plan parent on parent.category_key=p.parent_key where not p.reuse;
  -- One statement validates the final state for every retained subtree.
  update public.categories c set name=p.name,parent_id=parent.id,icon_id=p.icon_id,sort_order=p.sort_order,is_archived=false
    from personal_plan p join personal_plan parent on parent.category_key=p.parent_key
    where p.reuse and c.id=p.id;
  -- Retained siblings follow the catalog without changing relative order/links.
  with extras as (
    select c.id,c.parent_id,row_number() over(partition by c.parent_id order by nullif(c.sort_order,0) nulls last,c.created_at,c.id) ordinal
    from public.categories c where c.space_id=p_space and c.kind='expense'
      and not exists(select 1 from personal_plan p where p.id=c.id)
      and (c.parent_id is null or exists(select 1 from personal_plan p where p.id=c.parent_id))
  ), ranked as (
    select e.id,e.ordinal+coalesce((select max(p.sort_order) from personal_plan p
      left join personal_plan parent on parent.category_key=p.parent_key where parent.id is not distinct from e.parent_id),0) position from extras e
  ) update public.categories c set sort_order=r.position::integer from ranked r where c.id=r.id;
  if finance_private.personal_expense_references(p_space)<>before_refs then raise exception 'Financial references changed'; end if;
  if untouched is distinct from (select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) from public.categories c where c.space_id<>p_space or c.kind<>'expense') then
    raise exception 'Unrelated scope changed';
  end if;
  if money <> jsonb_build_object(
    'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]'::jsonb) from public.expenses e),
    'incomes',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]'::jsonb) from public.incomes i),
    'transfers',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb) from public.transfers t),
    'wallets',(select coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb) from public.wallets w),
    'opening',(select coalesce(jsonb_agg(to_jsonb(o) order by wallet_id),'[]'::jsonb) from public.wallet_opening_balances o)) then raise exception 'Financial data changed'; end if;
  if (select count(*) from personal_plan p join public.categories c on c.id=p.id and c.space_id=p_space and c.kind='expense'
    left join personal_plan parent on parent.category_key=p.parent_key
    where c.name=p.name and c.parent_id is not distinct from parent.id and c.sort_order=p.sort_order and c.icon_id=p.icon_id and not c.is_archived)<>143 then
    raise exception 'Final catalog validation failed';
  end if;
  insert into finance_private.personal_expense_mappings(space_id,package_key,category_key,category_id,resolution)
    select p_space,package,category_key,id,case when reuse then 'reused' else 'created' end from personal_plan;
  result := jsonb_build_object('installed',143,'roots',16,'children',127,'reused',reused,'moved',moved,'created',created,'merged',0,'replay',false);
  insert into finance_private.personal_expense_installations(space_id,package_key,result,categories_before,references_before)
    values(p_space,package,result,before_categories,before_refs);
  return result;
end $fn$;
revoke all on function finance_private.install_personal_expenses_20261006(uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
