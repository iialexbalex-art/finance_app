-- Apply once after 015, as postgres. Does not seed/replace any categories.
begin;
do $$ begin if current_user<>'postgres' then raise exception 'Run as postgres'; end if; end $$;
alter table public.categories add column revision uuid not null default gen_random_uuid();
-- Assign only missing positions. Keep the installed business catalog positions.
with ranked as (
  select id,row_number() over(partition by space_id,kind,parent_id order by created_at,id) n,
    max(sort_order) over(partition by space_id,kind,parent_id) existing_max
  from public.categories
) update public.categories c set sort_order=(r.existing_max+r.n)::integer
  from ranked r where c.id=r.id and c.sort_order=0;
create function finance_private.category_revision() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op='UPDATE' then new.revision:=gen_random_uuid(); end if;
  if tg_op='INSERT' and new.sort_order=0 then
    select coalesce(max(sort_order),0)+1 into new.sort_order from public.categories
      where space_id=new.space_id and kind=new.kind and parent_id is not distinct from new.parent_id;
  end if;
  return new;
end $$;
revoke all on function finance_private.category_revision() from public,anon,authenticated;
create trigger category_revision before insert or update on public.categories
for each row execute function finance_private.category_revision();

-- Immutable receipts survive physical deletion and keep old creation requests spent.
-- Drop only the two existing receipt -> expense FKs, never category/wallet FKs.
do $$ declare c record; begin
  for c in select conrelid::regclass relation,conname from pg_catalog.pg_constraint
    where contype='f' and confrelid='public.expenses'::regclass
      and conrelid in ('finance_private.expense_creation_receipts'::regclass,
                      'finance_private.expense_edit_requests'::regclass)
  loop execute format('alter table %s drop constraint %I',c.relation,c.conname); end loop;
end $$;
create table finance_private.bulk_action_receipts (
  actor_id uuid not null references auth.users(id), request_id uuid not null,
  space_id uuid not null, action text not null, payload jsonb not null,
  before_rows jsonb not null, result jsonb not null, created_at timestamptz not null default now(),
  primary key(actor_id,request_id)
);
revoke all on finance_private.bulk_action_receipts from public,anon,authenticated;

create function finance_private.check_category_snapshot(p_space_id uuid,p_kind text,p_expected jsonb)
returns void language plpgsql set search_path='' as $$
declare actual jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id),'[]') into actual
    from public.categories where space_id=p_space_id and kind=p_kind;
  if actual is distinct from p_expected then
    raise exception using errcode='P1003',message='Category tree changed; refresh before retry';
  end if;
end $$;
revoke all on function finance_private.check_category_snapshot(uuid,text,jsonb) from public,anon,authenticated;

create function public.category_delete_plan(p_space_id uuid,p_kind text,p_ids uuid[],p_expected jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  perform finance_private.check_category_snapshot(p_space_id,p_kind,p_expected);
  if p_ids is null or p_kind is null or p_kind not in ('expense','income') or cardinality(p_ids)=0 or (select count(*) from public.categories where space_id=p_space_id and kind=p_kind and id=any(p_ids))<>cardinality(p_ids) then
    raise exception using errcode='22023',message='Invalid category selection';
  end if;
  if exists(select 1 from public.categories where parent_id=any(p_ids) and not(id=any(p_ids))) then
    raise exception using errcode='P1011',message='Select the complete deleted branch';
  end if;
  return (select jsonb_agg(jsonb_build_object('id',c.id,'expenses',(select count(*) from public.expenses where category_id=c.id),
    'incomes',(select count(*) from public.incomes where category_id=c.id),
    'transfers',(select count(*) from public.transfers where fee_category_id=c.id)) order by c.id)
    from public.categories c where c.space_id=p_space_id and c.kind=p_kind and c.id=any(p_ids));
end $$;
revoke all on function public.category_delete_plan(uuid,text,uuid[],jsonb) from public,anon,authenticated;
grant execute on function public.category_delete_plan(uuid,text,uuid[],jsonb) to authenticated;

create function public.mutate_categories(p_request_id uuid,p_space_id uuid,p_kind text,
  p_action text,p_ids uuid[],p_expected jsonb,p_replacements jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare receipt finance_private.bulk_action_receipts%rowtype; payload jsonb; before_data jsonb; result jsonb;
  category public.categories%rowtype; replacement uuid; usage jsonb; row record;
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if auth.uid() is null or not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  if p_request_id is null or p_action is null or p_kind is null or p_action not in ('archive','restore','delete') or p_kind not in ('expense','income') then
    raise exception using errcode='22023',message='Invalid category action';
  end if;
  payload:=jsonb_build_object('kind',p_kind,'ids',p_ids,'expected',p_expected,'replacements',p_replacements);
  select * into receipt from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id;
  if found then
    if receipt.space_id<>p_space_id or receipt.action<>p_action or receipt.payload is distinct from payload then
      raise exception using errcode='P1002',message='Request id reused'; end if;
    return receipt.result;
  end if;
  perform finance_private.check_category_snapshot(p_space_id,p_kind,p_expected);
  if p_ids is null or cardinality(p_ids)=0 or
    (select count(*) from public.categories where space_id=p_space_id and kind=p_kind and id=any(p_ids))<>cardinality(p_ids) then
    raise exception using errcode='22023',message='Invalid category selection'; end if;
  select jsonb_agg(to_jsonb(c) order by id) into before_data from public.categories c where id=any(p_ids);
  if p_action='archive' then
    update public.categories set is_archived=true where id=any(p_ids) and space_id=p_space_id and kind=p_kind;
  elsif p_action='restore' then
    if exists(with recursive ancestors as (
      select parent_id id from public.categories where id=any(p_ids)
      union select c.parent_id from public.categories c join ancestors a on a.id=c.id
    ) select 1 from public.categories c join ancestors a on a.id=c.id where c.is_archived and not(c.id=any(p_ids))) then
      raise exception using errcode='P1011',message='Restore archived ancestors first'; end if;
    update public.categories set is_archived=false where id=any(p_ids) and space_id=p_space_id and kind=p_kind;
  else
    usage:=public.category_delete_plan(p_space_id,p_kind,p_ids,p_expected);
    for category in select * from public.categories where id=any(p_ids) loop
      if exists(select 1 from public.expenses where category_id=category.id) or
        exists(select 1 from public.incomes where category_id=category.id) or
        exists(select 1 from public.transfers where fee_category_id=category.id) then
        replacement:=(p_replacements->>category.id::text)::uuid;
        if replacement is null or replacement=any(p_ids) or not exists(select 1 from public.categories
          where id=replacement and space_id=p_space_id and kind=p_kind) then
          raise exception using errcode='P1012',message='Choose a same-scope replacement outside the deleted branch'; end if;
        -- Reject archived replacement chains, including inherited archive.
        perform finance_private.operation_category_path(p_space_id,replacement,p_kind,null,null);
        update public.expenses set category_id=replacement,revision=gen_random_uuid() where category_id=category.id;
        update public.incomes set category_id=replacement,revision=gen_random_uuid() where category_id=category.id;
        update public.transfers set fee_category_id=replacement,revision=gen_random_uuid() where fee_category_id=category.id;
      end if;
    end loop;
    for row in with recursive depth as (
      select id,parent_id,1 n from public.categories where space_id=p_space_id and kind=p_kind and parent_id is null
      union all select c.id,c.parent_id,d.n+1 from public.categories c join depth d on c.parent_id=d.id
    ) select id from depth where id=any(p_ids) order by n desc,id loop
      delete from public.categories where id=row.id and space_id=p_space_id and kind=p_kind;
    end loop;
  end if;
  result:=jsonb_build_object('affected',cardinality(p_ids));
  insert into finance_private.bulk_action_receipts(actor_id,request_id,space_id,action,payload,before_rows,result)
    values(auth.uid(),p_request_id,p_space_id,p_action,payload,before_data,result);
  return result;
end $$;
revoke all on function public.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.mutate_categories(uuid,uuid,text,text,uuid[],jsonb,jsonb) to authenticated;

create function public.reorder_categories(p_request_id uuid,p_space_id uuid,p_kind text,
  p_parent_id uuid,p_ids uuid[],p_expected jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare payload jsonb; receipt finance_private.bulk_action_receipts%rowtype; before_data jsonb; result jsonb;
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  if p_request_id is null or p_kind is null or p_kind not in ('income','expense') then raise exception using errcode='22023',message='Invalid reorder'; end if;
  payload:=jsonb_build_object('kind',p_kind,'parent',p_parent_id,'ids',p_ids,'expected',p_expected);
  select * into receipt from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id;
  if found then
    if receipt.space_id<>p_space_id or receipt.action<>'reorder' or receipt.payload is distinct from payload then
      raise exception using errcode='P1002',message='Request id reused'; end if; return receipt.result;
  end if;
  perform finance_private.check_category_snapshot(p_space_id,p_kind,p_expected);
  if p_ids is null or cardinality(p_ids)=0 or
    (select count(*) from public.categories where space_id=p_space_id and kind=p_kind and parent_id is not distinct from p_parent_id)<>cardinality(p_ids) or
    (select count(*) from public.categories where space_id=p_space_id and kind=p_kind and parent_id is not distinct from p_parent_id and id=any(p_ids))<>cardinality(p_ids) then
    raise exception using errcode='P1003',message='Sibling set changed'; end if;
  select jsonb_agg(to_jsonb(c) order by id) into before_data from public.categories c where id=any(p_ids);
  update public.categories c set sort_order=o.position::integer from unnest(p_ids) with ordinality o(id,position) where c.id=o.id;
  result:=jsonb_build_object('affected',cardinality(p_ids));
  insert into finance_private.bulk_action_receipts(actor_id,request_id,space_id,action,payload,before_rows,result)
    values(auth.uid(),p_request_id,p_space_id,'reorder',payload,before_data,result);
  return result;
end $$;
revoke all on function public.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb) from public,anon,authenticated;
grant execute on function public.reorder_categories(uuid,uuid,text,uuid,uuid[],jsonb) to authenticated;

create function public.delete_cashflow(p_request_id uuid,p_space_id uuid,p_kind text,p_rows jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare payload jsonb; receipt finance_private.bulk_action_receipts%rowtype; expected record;
  saved_expense public.expenses%rowtype; saved_income public.incomes%rowtype;
  before_data jsonb:='[]'; result jsonb;
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if auth.uid() is null or not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  if p_request_id is null or p_kind is null or p_kind not in ('expense','income') or jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)=0 then
    raise exception using errcode='22023',message='Invalid operation selection'; end if;
  payload:=jsonb_build_object('kind',p_kind,'rows',p_rows);
  select * into receipt from finance_private.bulk_action_receipts where actor_id=auth.uid() and request_id=p_request_id;
  if found then
    if receipt.space_id<>p_space_id or receipt.action<>'delete_cashflow' or receipt.payload is distinct from payload then
      raise exception using errcode='P1002',message='Request id reused'; end if; return receipt.result;
  end if;
  if (select count(distinct x.id) from jsonb_to_recordset(p_rows) x(id uuid,revision uuid))<>jsonb_array_length(p_rows) then
    raise exception using errcode='22023',message='Duplicate operation selection'; end if;
  -- Verify every record BEFORE deleting any. Guard serializes writers/revocations.
  for expected in select * from jsonb_to_recordset(p_rows) x(id uuid,revision uuid) loop
    if p_kind='expense' then
      select * into saved_expense from public.expenses where id=expected.id and space_id=p_space_id for update;
      if not found or saved_expense.revision is distinct from expected.revision then raise exception using errcode='P1003',message='Expense changed or unavailable'; end if;
      if saved_expense.transfer_id is not null then raise exception using errcode='P1005',message='Change commission through transfer'; end if;
      before_data:=before_data||jsonb_build_array(to_jsonb(saved_expense));
    else
      select * into saved_income from public.incomes where id=expected.id and space_id=p_space_id for update;
      if not found or saved_income.revision is distinct from expected.revision then raise exception using errcode='P1003',message='Income changed or unavailable'; end if;
      before_data:=before_data||jsonb_build_array(to_jsonb(saved_income));
    end if;
  end loop;
  if p_kind='expense' then
    delete from public.expenses where space_id=p_space_id and id in(select (value->>'id')::uuid from jsonb_array_elements(p_rows));
  else
    delete from public.incomes where space_id=p_space_id and id in(select (value->>'id')::uuid from jsonb_array_elements(p_rows));
  end if;
  result:=jsonb_build_object('affected',jsonb_array_length(p_rows));
  insert into finance_private.bulk_action_receipts(actor_id,request_id,space_id,action,payload,before_rows,result)
    values(auth.uid(),p_request_id,p_space_id,'delete_cashflow',payload,before_data,result);
  return result;
end $$;
revoke all on function public.delete_cashflow(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.delete_cashflow(uuid,uuid,text,jsonb) to authenticated;
-- No direct DELETE grants. Existing calculations use surviving rows, once only.
notify pgrst,'reload schema';
commit;
