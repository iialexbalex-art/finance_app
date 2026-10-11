-- После 001–005, целиком как postgres. Подготовлено, агентом НЕ применено.
begin;
do $migration$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
end
$migration$;

alter table public.expenses add column revision uuid not null default gen_random_uuid();

-- Неизменяемые квитанции не доступны через Data API. Повтор проверяется
-- до версии: потерянный ответ остаётся успешным даже после следующих правок.
create table finance_private.expense_edit_requests (
  actor_id uuid not null references auth.users(id),
  request_id uuid not null,
  expense_id uuid not null references public.expenses(id),
  payload jsonb not null,
  before_row jsonb not null,
  after_row jsonb not null,
  created_at timestamptz not null default now(),
  primary key(actor_id, request_id)
);
revoke all on finance_private.expense_edit_requests from public, anon, authenticated;

-- Создание тоже должно оставаться идемпотентным после редактирования расхода.
create table finance_private.expense_creation_receipts (
  expense_id uuid primary key references public.expenses(id),
  author_id uuid not null,
  request_id uuid not null,
  original_row jsonb not null,
  unique(author_id, request_id)
);
revoke all on finance_private.expense_creation_receipts from public, anon, authenticated;
insert into finance_private.expense_creation_receipts
select id,author_id,request_id,to_jsonb(e) from public.expenses e;
create function finance_private.record_expense_creation()
returns trigger language plpgsql security definer set search_path=''
as $function$
begin
  insert into finance_private.expense_creation_receipts
  values(new.id,new.author_id,new.request_id,to_jsonb(new));
  return new;
end
$function$;
revoke all on function finance_private.record_expense_creation() from public,anon,authenticated;
create trigger expense_creation_receipt after insert on public.expenses
for each row execute function finance_private.record_expense_creation();

create function public.edit_expense(
  p_request_id uuid, p_space_id uuid, p_expense_id uuid, p_expected_revision uuid,
  p_wallet_id uuid, p_category_id uuid, p_amount_minor text,
  p_expense_date date, p_comment text, p_currency text, p_currency_scale integer
) returns uuid language plpgsql volatile security definer set search_path=''
as $function$
declare
  actor uuid := auth.uid();
  saved public.expenses%rowtype;
  changed public.expenses%rowtype;
  w public.wallets%rowtype;
  cat public.categories%rowtype;
  receipt finance_private.expense_edit_requests%rowtype;
  payload jsonb;
  amount bigint;
  next_id uuid;
  visited uuid[] := array[]::uuid[];
  names text[] := array[]::text[];
  category_snapshot text;
begin
  if actor is null then raise exception using errcode='42501',message='Authentication required'; end if;
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing guard'; end if;
  select * into saved from public.expenses where id=p_expense_id and space_id=p_space_id for update;
  if not found or not exists(select 1 from public.spaces where id=p_space_id and owner_user_id=actor) then
    raise exception using errcode='42501',message='Owner access required';
  end if;
  payload := jsonb_build_object('expense',p_expense_id,'space',p_space_id,
    'revision',p_expected_revision,'wallet',p_wallet_id,'category',p_category_id,
    'amount',p_amount_minor,'date',p_expense_date,'comment',p_comment,
    'currency',p_currency,'scale',p_currency_scale);
  select * into receipt from finance_private.expense_edit_requests
    where actor_id=actor and request_id=p_request_id;
  if found then
    if receipt.payload is distinct from payload then
      raise exception using errcode='P1002',message='Request id already used with different data';
    end if;
    return receipt.expense_id;
  end if;
  if p_request_id is null or p_expected_revision is null or p_wallet_id is null or p_category_id is null
    or p_amount_minor is null or p_amount_minor !~ '^[0-9]{1,19}$'
    or p_expense_date is null or p_expense_date not between date '0001-01-01' and date '9999-12-31'
    or p_comment is null or char_length(p_comment)>1000
    or p_currency is null or p_currency_scale is null then
    raise exception using errcode='22023',message='Invalid expense input';
  end if;
  if saved.revision<>p_expected_revision then
    raise exception using errcode='P1003',message='Expense revision conflict';
  end if;
  amount:=p_amount_minor::bigint;
  if amount<=0 then raise exception using errcode='22023',message='Amount must be positive'; end if;
  select * into w from public.wallets where id=p_wallet_id and space_id=saved.space_id;
  if not found then raise exception using errcode='42501',message='Wallet access denied'; end if;
  -- Валюта от клиента — только ожидаемое значение, не источник снимка.
  if w.currency<>p_currency or w.currency_scale<>p_currency_scale then
    raise exception using errcode='P1004',message='Wallet currency changed';
  end if;
  select * into cat from public.categories
    where id=p_category_id and space_id=saved.space_id and kind='expense';
  if not found then raise exception using errcode='P1001',message='Category unavailable'; end if;
  category_snapshot:=saved.category_path;
  if p_category_id<>saved.category_id then
    next_id:=p_category_id;
    while next_id is not null loop
      if next_id=any(visited) or cardinality(visited)>=3 then
        raise exception using errcode='P1001',message='Invalid category chain';
      end if;
      select * into cat from public.categories where id=next_id;
      if not found or cat.space_id<>saved.space_id or cat.kind<>'expense' or cat.is_archived then
        raise exception using errcode='P1001',message='Category or ancestor unavailable';
      end if;
      visited:=array_append(visited,next_id);
      names:=array_prepend(cat.name,names);
      next_id:=cat.parent_id;
    end loop;
    category_snapshot:=array_to_string(names,' → ');
  end if;
  -- Один UPDATE атомарно переносит вклад в агрегаты обоих кошельков.
  -- ID, автор, created_at, request_id и пространство не меняются.
  update public.expenses set wallet_id=p_wallet_id, category_id=p_category_id,
    amount_minor=amount, expense_date=p_expense_date, comment=p_comment,
    wallet_name=case when p_wallet_id<>saved.wallet_id then w.name else saved.wallet_name end,
    currency=case when p_wallet_id<>saved.wallet_id then w.currency else saved.currency end,
    currency_scale=case when p_wallet_id<>saved.wallet_id then w.currency_scale else saved.currency_scale end,
    category_path=category_snapshot, revision=gen_random_uuid()
  where id=saved.id returning * into changed;
  insert into finance_private.expense_edit_requests(actor_id,request_id,expense_id,payload,before_row,after_row)
    values(actor,p_request_id,saved.id,payload,to_jsonb(saved),to_jsonb(changed));
  return saved.id;
end
$function$;
revoke all on function public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) from public,anon,authenticated;
grant execute on function public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer) to authenticated;
comment on table public.expenses is 'Расходы. Создание через create_expense, правка владельцем через edit_expense с проверкой revision и квитанциями повторов. Снимки обновляются только при смене соответствующего справочника.';
create or replace function public.create_expense(
  p_request_id uuid, p_space_id uuid, p_wallet_id uuid, p_category_id uuid,
  p_amount_minor text, p_expense_date date, p_comment text default ''
) returns uuid language plpgsql volatile security definer set search_path=''
as $function$
declare
  actor uuid := auth.uid();
  w public.wallets%rowtype;
  s public.spaces%rowtype;
  cat public.categories%rowtype;
  saved public.expenses%rowtype;
  amount bigint;
  next_id uuid;
  visited uuid[] := array[]::uuid[];
  names text[] := array[]::text[];
begin
  if actor is null then raise exception using errcode='42501',message='Authentication required'; end if;
  if p_request_id is null or p_category_id is null or p_amount_minor is null or p_amount_minor !~ '^[0-9]{1,19}$'
    or p_expense_date is null or p_expense_date not between date '0001-01-01' and date '9999-12-31'
    or p_comment is null or char_length(p_comment)>1000 then
    raise exception using errcode='22023',message='Invalid expense input';
  end if;
  amount := p_amount_minor::bigint;
  if amount<=0 then raise exception using errcode='22023',message='Amount must be positive'; end if;

  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing guard'; end if;
  select * into s from public.spaces where id=p_space_id;
  if not found then raise exception using errcode='42501',message='Expense access denied'; end if;
  select * into w from public.wallets where id=p_wallet_id and space_id=p_space_id;
  if not found then raise exception using errcode='42501',message='Expense access denied'; end if;
  if s.owner_user_id<>actor and not (
    s.kind='business' and exists(select 1 from public.space_members
      where space_id=p_space_id and user_id=actor and role='manager' and space_kind='business')
    and exists(select 1 from public.wallet_assignments
      where space_id=p_space_id and wallet_id=p_wallet_id and user_id=actor)
  ) then raise exception using errcode='42501',message='Expense access denied'; end if;

  -- Автор берётся только из auth.uid(). Повтор не раскрывает запись другого автора.
  -- Сначала текущий доступ, затем идемпотентный ответ; после отзыва даже повтор запрещён.
  select original.* into saved from finance_private.expense_creation_receipts r cross join lateral jsonb_populate_record(null::public.expenses,r.original_row) original where r.author_id=actor and r.request_id=p_request_id;
  if found then
    if saved.space_id<>p_space_id or saved.wallet_id<>p_wallet_id or saved.category_id<>p_category_id
      or saved.amount_minor<>amount or saved.expense_date<>p_expense_date or saved.comment<>p_comment then
      raise exception using errcode='P1002',message='Request id already used with different data';
    end if;
    return saved.id;
  end if;

  next_id:=p_category_id;
  if next_id is null then raise exception using errcode='P1001',message='Select expense category'; end if;
  while next_id is not null loop
    if next_id=any(visited) or cardinality(visited)>=3 then
      raise exception using errcode='P1001',message='Invalid category chain';
    end if;
    select * into cat from public.categories where id=next_id;
    if not found or cat.space_id<>p_space_id or cat.kind<>'expense' or cat.is_archived then
      raise exception using errcode='P1001',message='Category or ancestor unavailable';
    end if;
    visited:=array_append(visited,next_id);
    names:=array_prepend(cat.name,names);
    next_id:=cat.parent_id;
  end loop;
  insert into public.expenses(request_id,author_id,space_id,wallet_id,category_id,
    amount_minor,currency,currency_scale,expense_date,comment,wallet_name,category_path)
  values(p_request_id,actor,p_space_id,p_wallet_id,p_category_id,amount,w.currency,
    w.currency_scale,p_expense_date,p_comment,w.name,array_to_string(names,' → '))
  returning * into saved;
  return saved.id;
end
$function$;

notify pgrst,'reload schema';
commit;
