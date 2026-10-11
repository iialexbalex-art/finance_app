-- После 008. Подготовлено; самостоятельно в Supabase не выполнять.
begin;
create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete restrict,
  author_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  revision uuid not null default gen_random_uuid(),
  source_id uuid not null, target_id uuid not null,
  source_minor bigint not null check(source_minor>0), target_minor bigint not null check(target_minor>0),
  source_currency text not null, target_currency text not null,
  source_scale smallint not null check(source_scale between 0 and 4),
  target_scale smallint not null check(target_scale between 0 and 4),
  source_name text not null, target_name text not null,
  transfer_date date not null check(transfer_date between date '0001-01-01' and date '9999-12-31'),
  comment text not null default '' check(char_length(comment)<=1000),
  fee_minor bigint not null default 0 check(fee_minor>=0),
  fee_category_id uuid, fee_category_path text,
  fee_kind text not null default 'expense' check(fee_kind='expense'),
  unique(space_id,id), check(source_id<>target_id),
  check((fee_minor=0 and fee_category_id is null and fee_category_path is null)
    or (fee_minor>0 and fee_category_id is not null and fee_category_path is not null)),
  check(source_currency<>target_currency or
    source_minor::numeric * power(10::numeric,target_scale)=target_minor::numeric * power(10::numeric,source_scale)),
  foreign key(space_id,source_id) references public.wallets(space_id,id) on delete restrict,
  foreign key(space_id,target_id) references public.wallets(space_id,id) on delete restrict,
  foreign key(space_id,fee_kind,fee_category_id) references public.categories(space_id,kind,id) on delete restrict
);
create index transfers_history_idx on public.transfers(space_id,transfer_date desc,id desc);
create index transfers_source_idx on public.transfers(source_id);
create index transfers_target_idx on public.transfers(target_id);
alter table public.transfers enable row level security;
revoke all on public.transfers from public,anon,authenticated;
grant select on public.transfers to authenticated;
create policy transfers_owner on public.transfers for select to authenticated using(finance_private.owns_space(space_id));

alter table public.expenses add column transfer_id uuid unique;
alter table public.expenses add column is_void boolean not null default false;
alter table public.expenses add constraint expense_transfer_scope foreign key(space_id,transfer_id)
  references public.transfers(space_id,id) on delete restrict;
alter table public.expenses add constraint void_only_transfer check(not is_void or transfer_id is not null);
drop policy expenses_read on public.expenses;
create policy expenses_read on public.expenses for select to authenticated using (
  not is_void and (finance_private.owns_space(space_id) or (transfer_id is null and
    author_id=(select auth.uid()) and exists (
      select 1 from public.space_members m join public.wallet_assignments a
        on a.space_id=m.space_id and a.user_id=m.user_id
      where m.space_id=expenses.space_id and m.user_id=(select auth.uid())
        and m.space_kind='business' and m.role='manager' and a.wallet_id=expenses.wallet_id
    )))
);

-- Preserve the existing public signature, but close the independent commission edit path.
alter function public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) set schema finance_private;
revoke all on function finance_private.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) from public,anon,authenticated;
create function public.edit_expense(
  p_request_id uuid,p_space_id uuid,p_expense_id uuid,p_expected_revision uuid,
  p_wallet_id uuid,p_category_id uuid,p_amount_minor text,p_expense_date date,p_comment text,p_currency text,p_currency_scale integer
) returns uuid language plpgsql volatile security definer set search_path='' as $$
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing guard'; end if;
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  if exists(select 1 from public.expenses where id=p_expense_id and space_id=p_space_id and transfer_id is not null) then
    raise exception using errcode='P1005',message='Edit commission through transfer';
  end if;
  return finance_private.edit_expense(p_request_id,p_space_id,p_expense_id,p_expected_revision,
    p_wallet_id,p_category_id,p_amount_minor,p_expense_date,p_comment,p_currency,p_currency_scale);
end $$;
revoke all on function public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) from public,anon,authenticated;
grant execute on function public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) to authenticated;

create function public.save_transfer(p_request_id uuid,p_data jsonb)
returns uuid language plpgsql volatile security definer set search_path='' as $$
declare
  actor uuid:=auth.uid(); scope uuid:=(p_data->>'space_id')::uuid;
  operation_id uuid:=(p_data->>'id')::uuid; expected uuid:=(p_data->>'revision')::uuid;
  source_wallet public.wallets%rowtype; target_wallet public.wallets%rowtype;
  prior public.transfers%rowtype; saved public.transfers%rowtype;
  receipt finance_private.operation_receipts%rowtype;
  debit bigint; credit bigint; fee bigint; fee_category uuid:=(p_data->>'fee_category_id')::uuid;
  v_path text; v_date date:=(p_data->>'date')::date; v_comment text:=p_data->>'comment';
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing guard'; end if;
  if actor is null or not finance_private.owns_space(scope) then
    raise exception using errcode='42501',message='Owner access required';
  end if;
  select * into receipt from finance_private.operation_receipts where actor_id=actor and request_id=p_request_id;
  if found then
    if receipt.operation_kind<>'transfer' or receipt.payload is distinct from p_data then
      raise exception using errcode='P1002',message='Request id reused';
    end if;
    return receipt.operation_id;
  end if;
  if p_request_id is null or v_date is null or v_date not between date '0001-01-01' and date '9999-12-31'
    or v_comment is null or char_length(v_comment)>1000 or (operation_id is null)<>(expected is null)
    or jsonb_typeof(p_data->'source_minor') is distinct from 'string'
    or jsonb_typeof(p_data->'target_minor') is distinct from 'string'
    or jsonb_typeof(p_data->'fee_minor') is distinct from 'string' then
    raise exception using errcode='22023',message='Invalid transfer';
  end if;
  if operation_id is not null then
    select * into prior from public.transfers where id=operation_id and space_id=scope for update;
    if not found then raise exception using errcode='42501',message='Transfer unavailable'; end if;
    if prior.revision<>expected then raise exception using errcode='P1003',message='Revision conflict'; end if;
  end if;
  select * into source_wallet from public.wallets where id=(p_data->>'source_id')::uuid and space_id=scope;
  if not found then raise exception using errcode='42501',message='Source unavailable'; end if;
  select * into target_wallet from public.wallets where id=(p_data->>'target_id')::uuid and space_id=scope;
  if not found then raise exception using errcode='42501',message='Target unavailable'; end if;
  if source_wallet.id=target_wallet.id then raise exception using errcode='22023',message='Same wallet'; end if;
  if source_wallet.currency is distinct from p_data->>'source_currency'
    or target_wallet.currency is distinct from p_data->>'target_currency'
    or source_wallet.currency_scale is distinct from (p_data->>'source_scale')::integer
    or target_wallet.currency_scale is distinct from (p_data->>'target_scale')::integer then
    raise exception using errcode='P1004',message='Currency changed';
  end if;
  debit:=finance_private.positive_minor(p_data->>'source_minor');
  credit:=finance_private.positive_minor(p_data->>'target_minor');
  fee:=case when p_data->>'fee_minor'='0' then 0 else finance_private.positive_minor(p_data->>'fee_minor') end;
  if source_wallet.currency=target_wallet.currency and
    debit::numeric*power(10::numeric,target_wallet.currency_scale)<>credit::numeric*power(10::numeric,source_wallet.currency_scale) then
    raise exception using errcode='22023',message='Equal currency requires equal amounts';
  end if;
  if fee=0 and fee_category is not null then raise exception using errcode='22023',message='Unexpected fee category'; end if;
  if fee>0 then
    v_path:=finance_private.operation_category_path(scope,fee_category,'expense',prior.fee_category_id,prior.fee_category_path);
  end if;
  if operation_id is null then
    insert into public.transfers(space_id,author_id,source_id,target_id,source_minor,target_minor,
      source_currency,target_currency,source_scale,target_scale,source_name,target_name,transfer_date,comment,fee_minor,fee_category_id,fee_category_path)
    values(scope,actor,source_wallet.id,target_wallet.id,debit,credit,source_wallet.currency,target_wallet.currency,
      source_wallet.currency_scale,target_wallet.currency_scale,source_wallet.name,target_wallet.name,v_date,v_comment,fee,fee_category,v_path)
    returning * into saved;
  else
    update public.transfers set source_id=source_wallet.id,target_id=target_wallet.id,source_minor=debit,target_minor=credit,
      source_currency=source_wallet.currency,target_currency=target_wallet.currency,
      source_scale=source_wallet.currency_scale,target_scale=target_wallet.currency_scale,
      source_name=case when prior.source_id=source_wallet.id then prior.source_name else source_wallet.name end,
      target_name=case when prior.target_id=target_wallet.id then prior.target_name else target_wallet.name end,
      transfer_date=v_date,comment=v_comment,fee_minor=fee,fee_category_id=fee_category,fee_category_path=v_path,revision=gen_random_uuid()
    where id=prior.id returning * into saved;
  end if;
  if fee=0 then
    update public.expenses set is_void=true,revision=gen_random_uuid() where transfer_id=saved.id and not is_void;
  else
    -- One expense per transfer for its lifetime, reactivated when a removed fee is restored.
    update public.expenses set wallet_id=saved.source_id,category_id=fee_category,amount_minor=fee,
      currency=saved.source_currency,currency_scale=saved.source_scale,expense_date=v_date,
      comment='Комиссия перевода',
      wallet_name=saved.source_name,category_path=v_path,is_void=false,revision=gen_random_uuid()
    where transfer_id=saved.id;
    if not found then
      insert into public.expenses(request_id,author_id,space_id,wallet_id,category_id,amount_minor,currency,currency_scale,
        expense_date,comment,wallet_name,category_path,transfer_id)
      values(gen_random_uuid(),actor,scope,saved.source_id,fee_category,fee,saved.source_currency,saved.source_scale,v_date,
        'Комиссия перевода',saved.source_name,v_path,saved.id);
    end if;
  end if;
  insert into finance_private.operation_receipts(actor_id,request_id,operation_kind,operation_id,payload,before_row,after_row)
  values(actor,p_request_id,'transfer',saved.id,p_data,case when prior.id is not null then to_jsonb(prior) end,to_jsonb(saved));
  return saved.id;
end $$;
revoke all on function public.save_transfer(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.save_transfer(uuid,jsonb) to authenticated;

-- Existing name and JSON keys preserved. Current balance now includes ALL posted operations,
-- including future calendar dates. Commission is counted only in expenses.
create or replace function public.wallet_expense_balance(p_wallet_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if not exists(select 1 from public.wallets where id=p_wallet_id and finance_private.owns_space(space_id)) then
    raise exception using errcode='42501',message='Balance access denied';
  end if;
  select jsonb_build_object('opening_minor',b.amount_minor::text,
    'expense_minor',e.total::text,'income_minor',i.total::text,'incoming_minor',ti.total::text,'outgoing_minor',tout.total::text,
    'current_minor',(coalesce(b.amount_minor::numeric,0)+i.total-e.total+ti.total-tout.total)::text)
  into result from public.wallets w
  left join public.wallet_opening_balances b on b.wallet_id=w.id
  cross join lateral(select coalesce(sum(amount_minor),0) total from public.expenses where wallet_id=w.id and not is_void) e
  cross join lateral(select coalesce(sum(amount_minor),0) total from public.incomes where wallet_id=w.id) i
  cross join lateral(select coalesce(sum(target_minor),0) total from public.transfers where target_id=w.id) ti
  cross join lateral(select coalesce(sum(source_minor),0) total from public.transfers where source_id=w.id) tout
  where w.id=p_wallet_id;
  return result;
end $$;

create function public.query_transfers(p_space_id uuid,p_wallet_ids uuid[] default '{}',p_from date default null,
  p_to date default null,p_search text default '',p_before_date date default null,p_before_id uuid default null,p_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  if p_from>p_to or (p_before_date is null)<>(p_before_id is null) then
    raise exception using errcode='22023',message='Invalid period or cursor';
  end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by transfer_date desc,id desc),'[]'::jsonb) into result from (
    select id,space_id,revision,source_id,target_id,source_minor::text,target_minor::text,
      source_currency,target_currency,source_scale,target_scale,source_name,target_name,
      transfer_date,comment,fee_minor::text,fee_category_id,fee_category_path
    from public.transfers where space_id=p_space_id and (p_id is null or id=p_id)
      and (coalesce(cardinality(p_wallet_ids),0)=0 or source_id=any(p_wallet_ids) or target_id=any(p_wallet_ids))
      and (p_from is null or transfer_date>=p_from) and (p_to is null or transfer_date<=p_to)
      and (coalesce(p_search,'')='' or position(lower(p_search) in lower(comment))>0)
      and (p_before_date is null or (transfer_date,id)<(p_before_date,p_before_id))
    order by transfer_date desc,id desc limit 26
  ) t;
  return result;
end $$;
revoke all on function public.query_transfers(uuid,uuid[],date,date,text,date,uuid,uuid) from public,anon,authenticated;
grant execute on function public.query_transfers(uuid,uuid[],date,date,text,date,uuid,uuid) to authenticated;

create or replace function public.query_expenses(
  p_space_id uuid, p_wallet_ids uuid[] default '{}', p_category_ids uuid[] default '{}',
  p_from date default null, p_to date default null,
  p_before_date date default null, p_before_id uuid default null,
  p_include_totals boolean default false
) returns jsonb language plpgsql stable security invoker set search_path = ''
as $function$
declare result jsonb;
begin
  if p_include_totals and not finance_private.owns_space(p_space_id) then
    raise exception using errcode='42501', message='Expense totals access denied';
  end if;
  if p_from > p_to or ((p_before_date is null) <> (p_before_id is null)) then
    raise exception using errcode='22023', message='Invalid period or cursor';
  end if;
  -- RLS remains active for BOTH expenses and categories. UNION removes overlapping
  -- branches and repeated IDs; EXISTS never multiplies an expense row.
  with recursive branches(id) as (
    select c.id from public.categories c
    where c.space_id=p_space_id and c.kind='expense' and c.id=any(p_category_ids)
    union
    select c.id from public.categories c join branches b on c.parent_id=b.id
    where c.space_id=p_space_id and c.kind='expense'
  ), matched as materialized (
    select e.* from public.expenses e where e.space_id=p_space_id
      and (coalesce(cardinality(p_wallet_ids),0)=0 or e.wallet_id=any(p_wallet_ids))
      and (coalesce(cardinality(p_category_ids),0)=0 or exists(select 1 from branches b where b.id=e.category_id))
      and (p_from is null or e.expense_date>=p_from)
      and (p_to is null or e.expense_date<=p_to)
  ), page as (
    select * from matched e where p_before_date is null
      or (e.expense_date,e.id)<(p_before_date,p_before_id)
    order by e.expense_date desc,e.id desc limit 26
  ), scales as (
    select currency,max(currency_scale) as currency_scale from matched
    where p_include_totals group by currency
  ), totals as (
    select e.currency,s.currency_scale,
      trunc(sum(e.amount_minor * power(10::numeric,s.currency_scale-e.currency_scale)))::text as amount_minor
    from matched e join scales s on s.currency=e.currency
    group by e.currency,s.currency_scale
  )
  select jsonb_build_object(
    'items',coalesce((select jsonb_agg(
      jsonb_build_object('id',id,'wallet_id',wallet_id,'category_id',category_id,
        'revision',revision,'expense_date',expense_date,'amount_minor',amount_minor::text,
        'currency',currency,'currency_scale',currency_scale,'wallet_name',wallet_name,
        'category_path',category_path,'comment',comment,'transfer_id',transfer_id)
      order by expense_date desc,id desc) from page),'[]'::jsonb),
    'totals',coalesce((select jsonb_agg(to_jsonb(t) order by currency,currency_scale) from totals t),'[]'::jsonb)
  ) into result;
  return result;
end
$function$;
revoke all on function public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean) from public,anon,authenticated;
grant execute on function public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean) to authenticated;

create function public.space_balances(p_space_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'space_id',w.space_id,'name',w.name,
    'wallet_group',w.wallet_group,'currency',w.currency,'currency_scale',w.currency_scale,
    'balance',public.wallet_expense_balance(w.id)) order by w.created_at,w.id),'[]'::jsonb)
  into result from public.wallets w where w.space_id=p_space_id;
  return result;
end $$;
revoke all on function public.space_balances(uuid) from public,anon,authenticated;
grant execute on function public.space_balances(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
