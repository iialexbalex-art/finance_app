-- После 001–007. Подготовлено; самостоятельно в Supabase не выполнять.
begin;

create function finance_private.positive_minor(value text) returns bigint
language plpgsql immutable set search_path='' as $$
declare result bigint;
begin
  if value is null or value !~ '^[0-9]{1,19}$' then
    raise exception using errcode='22023',message='Invalid money';
  end if;
  result:=value::bigint;
  if result<=0 then raise exception using errcode='22023',message='Positive money required'; end if;
  return result;
end $$;

-- Called only after acquiring category_tree_guard by the owning RPC.
create function finance_private.operation_category_path(
  scope uuid, category uuid, expected_kind text, previous_id uuid default null, previous_path text default null
) returns text language plpgsql stable set search_path='' as $$
declare c public.categories%rowtype; next_id uuid:=category; visited uuid[]:='{}'; names text[]:='{}';
begin
  select * into c from public.categories where id=category and space_id=scope and kind=expected_kind;
  if not found then raise exception using errcode='P1001',message='Category unavailable'; end if;
  if category=previous_id then return previous_path; end if;
  while next_id is not null loop
    if next_id=any(visited) or cardinality(visited)>=3 then
      raise exception using errcode='P1001',message='Invalid category chain';
    end if;
    select * into c from public.categories where id=next_id;
    if not found or c.space_id<>scope or c.kind<>expected_kind or c.is_archived then
      raise exception using errcode='P1001',message='Category or ancestor unavailable';
    end if;
    visited:=array_append(visited,next_id); names:=array_prepend(c.name,names); next_id:=c.parent_id;
  end loop;
  return array_to_string(names,' → ');
end $$;
revoke all on function finance_private.positive_minor(text),
  finance_private.operation_category_path(uuid,uuid,text,uuid,text) from public,anon,authenticated;

create table public.incomes (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete restrict,
  author_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  revision uuid not null default gen_random_uuid(),
  wallet_id uuid not null,
  category_id uuid not null,
  category_kind text not null default 'income' check(category_kind='income'),
  amount_minor bigint not null check(amount_minor>0),
  currency text not null,
  currency_scale smallint not null check(currency_scale between 0 and 4),
  income_date date not null check(income_date between date '0001-01-01' and date '9999-12-31'),
  comment text not null default '' check(char_length(comment)<=1000),
  wallet_name text not null,
  category_path text not null,
  foreign key(space_id,wallet_id) references public.wallets(space_id,id) on delete restrict,
  foreign key(space_id,category_kind,category_id) references public.categories(space_id,kind,id) on delete restrict
);
create index incomes_history_idx on public.incomes(space_id,income_date desc,id desc);
create index incomes_wallet_idx on public.incomes(wallet_id);
create index incomes_category_idx on public.incomes(category_id);
alter table public.incomes enable row level security;
revoke all on public.incomes from public,anon,authenticated;
grant select on public.incomes to authenticated;
create policy incomes_owner on public.incomes for select to authenticated
  using(finance_private.owns_space(space_id));

-- All original CREATE and EDIT payloads are immutable, even after later edits.
create table finance_private.operation_receipts (
  actor_id uuid not null references auth.users(id), request_id uuid not null,
  operation_kind text not null check(operation_kind in ('income','transfer')),
  operation_id uuid not null, payload jsonb not null,
  before_row jsonb, after_row jsonb not null,
  created_at timestamptz not null default now(), primary key(actor_id,request_id)
);
revoke all on finance_private.operation_receipts from public,anon,authenticated;

create function public.save_income(
  p_request_id uuid, p_space_id uuid, p_income_id uuid, p_expected_revision uuid,
  p_wallet_id uuid, p_category_id uuid, p_amount_minor text, p_income_date date,
  p_comment text, p_currency text, p_currency_scale integer
) returns uuid language plpgsql volatile security definer set search_path='' as $$
declare actor uuid:=auth.uid(); prior public.incomes%rowtype; saved public.incomes%rowtype;
  w public.wallets%rowtype; receipt finance_private.operation_receipts%rowtype;
  payload jsonb; amount bigint; v_path text;
begin
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing guard'; end if;
  if actor is null or not finance_private.owns_space(p_space_id) then
    raise exception using errcode='42501',message='Owner access required';
  end if;
  payload:=jsonb_build_object('space',p_space_id,'id',p_income_id,'revision',p_expected_revision,
    'wallet',p_wallet_id,'category',p_category_id,'amount',p_amount_minor,'date',p_income_date,
    'comment',p_comment,'currency',p_currency,'scale',p_currency_scale);
  select * into receipt from finance_private.operation_receipts where actor_id=actor and request_id=p_request_id;
  if found then
    if receipt.operation_kind<>'income' or receipt.payload is distinct from payload then
      raise exception using errcode='P1002',message='Request id reused';
    end if;
    return receipt.operation_id;
  end if;
  if p_request_id is null or p_income_date is null or p_income_date not between date '0001-01-01' and date '9999-12-31'
    or p_comment is null or char_length(p_comment)>1000 or (p_income_id is null)<>(p_expected_revision is null) then
    raise exception using errcode='22023',message='Invalid income';
  end if;
  if p_income_id is not null then
    select * into prior from public.incomes where id=p_income_id and space_id=p_space_id for update;
    if not found then raise exception using errcode='42501',message='Income unavailable'; end if;
    if prior.revision<>p_expected_revision then raise exception using errcode='P1003',message='Revision conflict'; end if;
  end if;
  select * into w from public.wallets where id=p_wallet_id and space_id=p_space_id;
  if not found then raise exception using errcode='42501',message='Wallet unavailable'; end if;
  if w.currency is distinct from p_currency or w.currency_scale is distinct from p_currency_scale then
    raise exception using errcode='P1004',message='Currency changed';
  end if;
  amount:=finance_private.positive_minor(p_amount_minor);
  v_path:=finance_private.operation_category_path(p_space_id,p_category_id,'income',prior.category_id,prior.category_path);
  if p_income_id is null then
    insert into public.incomes(space_id,author_id,wallet_id,category_id,amount_minor,currency,currency_scale,income_date,comment,wallet_name,category_path)
    values(p_space_id,actor,w.id,p_category_id,amount,w.currency,w.currency_scale,p_income_date,p_comment,w.name,v_path)
    returning * into saved;
  else
    update public.incomes set wallet_id=w.id, category_id=p_category_id,amount_minor=amount,
      currency=w.currency,currency_scale=w.currency_scale,income_date=p_income_date,comment=p_comment,
      wallet_name=case when prior.wallet_id=w.id then prior.wallet_name else w.name end,
      category_path=v_path,revision=gen_random_uuid()
    where id=prior.id returning * into saved;
  end if;
  insert into finance_private.operation_receipts(actor_id,request_id,operation_kind,operation_id,payload,before_row,after_row)
  values(actor,p_request_id,'income',saved.id,payload,case when prior.id is not null then to_jsonb(prior) end,to_jsonb(saved));
  return saved.id;
end $$;
revoke all on function public.save_income(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) from public,anon,authenticated;
grant execute on function public.save_income(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) to authenticated;

create function public.query_incomes(
  p_space_id uuid, p_wallet_ids uuid[] default '{}', p_category_ids uuid[] default '{}',
  p_from date default null, p_to date default null,
  p_before_date date default null, p_before_id uuid default null,
  p_include_totals boolean default false
) returns jsonb language plpgsql stable security invoker set search_path = ''
as $function$
declare result jsonb;
begin
  if not finance_private.owns_space(p_space_id) then
    raise exception using errcode='42501', message='Income access denied';
  end if;
  if p_from > p_to or ((p_before_date is null) <> (p_before_id is null)) then
    raise exception using errcode='22023', message='Invalid period or cursor';
  end if;
  -- RLS remains active for BOTH incomes and categories. UNION removes overlapping
  -- branches and repeated IDs; EXISTS never multiplies an income row.
  with recursive branches(id) as (
    select c.id from public.categories c
    where c.space_id=p_space_id and c.kind='income' and c.id=any(p_category_ids)
    union
    select c.id from public.categories c join branches b on c.parent_id=b.id
    where c.space_id=p_space_id and c.kind='income'
  ), matched as materialized (
    select e.* from public.incomes e where e.space_id=p_space_id
      and (coalesce(cardinality(p_wallet_ids),0)=0 or e.wallet_id=any(p_wallet_ids))
      and (coalesce(cardinality(p_category_ids),0)=0 or exists(select 1 from branches b where b.id=e.category_id))
      and (p_from is null or e.income_date>=p_from)
      and (p_to is null or e.income_date<=p_to)
  ), page as (
    select * from matched e where p_before_date is null
      or (e.income_date,e.id)<(p_before_date,p_before_id)
    order by e.income_date desc,e.id desc limit 26
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
        'revision',revision,'expense_date',income_date,'amount_minor',amount_minor::text,
        'currency',currency,'currency_scale',currency_scale,'wallet_name',wallet_name,
        'category_path',category_path,'comment',comment)
      order by income_date desc,id desc) from page),'[]'::jsonb),
    'totals',coalesce((select jsonb_agg(to_jsonb(t) order by currency,currency_scale) from totals t),'[]'::jsonb)
  ) into result;
  return result;
end
$function$;
revoke all on function public.query_incomes(uuid,uuid[],uuid[],date,date,date,uuid,boolean) from public,anon,authenticated;
grant execute on function public.query_incomes(uuid,uuid[],uuid[],date,date,date,uuid,boolean) to authenticated;

notify pgrst,'reload schema';
commit;
