-- После 001–004, целиком как postgres. Агентом НЕ применено.
begin;
do $migration$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
end
$migration$;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  author_id uuid not null references auth.users(id) on delete restrict,
  space_id uuid not null references public.spaces(id) on delete restrict,
  wallet_id uuid not null,
  category_id uuid not null,
  category_kind text not null default 'expense' check(category_kind='expense'),
  amount_minor bigint not null check(amount_minor > 0),
  currency text not null,
  currency_scale smallint not null check(currency_scale between 0 and 4),
  expense_date date not null check(expense_date between date '0001-01-01' and date '9999-12-31'),
  comment text not null default '' check(char_length(comment)<=1000),
  wallet_name text not null,
  category_path text not null,
  created_at timestamptz not null default now(),
  unique(author_id,request_id),
  foreign key(space_id,wallet_id) references public.wallets(space_id,id) on delete restrict,
  foreign key(space_id,category_kind,category_id) references public.categories(space_id,kind,id) on delete restrict
);
create index expenses_history_idx on public.expenses(space_id,expense_date desc,id desc);
create index expenses_wallet_idx on public.expenses(wallet_id);
create index expenses_category_idx on public.expenses(category_id);
alter table public.expenses enable row level security;
revoke all on public.expenses from public,anon,authenticated;
grant select on public.expenses to authenticated;
-- INSERT/UPDATE/DELETE клиенту не выдаются. Создание только через узкую RPC.
create policy expenses_read on public.expenses for select to authenticated using (
  finance_private.owns_space(space_id) or (
    author_id=(select auth.uid()) and exists (
      select 1 from public.space_members m join public.wallet_assignments a
        on a.space_id=m.space_id and a.user_id=m.user_id
      where m.space_id=expenses.space_id and m.user_id=(select auth.uid())
        and m.space_kind='business' and m.role='manager' and a.wallet_id=expenses.wallet_id
    )
  )
);

-- Та же guard-строка, что у категорий. Отзыв участия/назначения, удаление
-- пространства/кошелька не может вклиниться между проверкой и записью расхода.
create trigger members_serialize_expenses before insert or update or delete on public.space_members
for each statement execute function finance_private.lock_category_tree();
create trigger assignments_serialize_expenses before insert or update or delete on public.wallet_assignments
for each statement execute function finance_private.lock_category_tree();
create trigger wallets_serialize_expenses before insert or update or delete on public.wallets
for each statement execute function finance_private.lock_category_tree();
create trigger spaces_serialize_expenses before insert or update or delete on public.spaces
for each statement execute function finance_private.lock_category_tree();

create function public.create_expense(
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
  select * into saved from public.expenses where author_id=actor and request_id=p_request_id;
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
revoke all on function public.create_expense(uuid,uuid,uuid,uuid,text,date,text) from public,anon,authenticated;
grant execute on function public.create_expense(uuid,uuid,uuid,uuid,text,date,text) to authenticated;

-- INVOKER + явная проверка владельца: менеджер не может получить даже свою сумму
-- расходов через агрегат, число чужих операций или отсутствие начального остатка.
create function public.wallet_expense_balance(p_wallet_id uuid)
returns jsonb language plpgsql stable security invoker set search_path=''
as $function$
declare result jsonb;
begin
  if not exists(select 1 from public.wallets w where w.id=p_wallet_id
    and finance_private.owns_space(w.space_id)) then
    raise exception using errcode='42501',message='Balance access denied';
  end if;
  select jsonb_build_object(
    'opening_minor', b.amount_minor::text,
    'expense_minor', coalesce(e.total,0)::text,
    'current_minor',(coalesce(b.amount_minor::numeric,0)-coalesce(e.total,0))::text
  ) into result from public.wallets w
  left join public.wallet_opening_balances b on b.wallet_id=w.id
  left join lateral(select sum(amount_minor) as total from public.expenses where wallet_id=w.id) e on true
  where w.id=p_wallet_id;
  return result;
end
$function$;
revoke all on function public.wallet_expense_balance(uuid) from public,anon,authenticated;
grant execute on function public.wallet_expense_balance(uuid) to authenticated;
comment on table public.expenses is 'Неизменяемые расходы. Автор из auth.uid(), уникальный request_id на автора. Название кошелька, путь категории и валюта — снимки на момент создания.';
notify pgrst,'reload schema';
commit;
