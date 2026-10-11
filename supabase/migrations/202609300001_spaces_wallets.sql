-- Этап 1. Выполнить целиком в Supabase SQL Editor, роль postgres.
-- Не назначает владельцев и не создаёт пользователей/операции.
-- Не применять повторно: при совпадении имён объектов транзакция остановится.
begin;

do $migration$
begin
  if current_user <> 'postgres' then
    raise exception 'Run this migration as postgres in Supabase SQL Editor';
  end if;
end
$migration$;

create schema finance_private authorization postgres;
revoke all on schema finance_private from public, anon, authenticated;
grant usage on schema finance_private to authenticated;

create table public.spaces (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  kind text not null check (kind in ('personal', 'business')),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  created_at timestamptz not null default now(),
  unique (id, kind)
);
create index spaces_owner_idx on public.spaces(owner_user_id);

-- Владелец определяется ТОЛЬКО spaces.owner_user_id, не этой таблицей.
-- Участники здесь -- назначенные финансовые менеджеры бизнес-пространств.
create table public.space_members (
  space_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  space_kind text not null default 'business' check (space_kind = 'business'),
  role text not null default 'manager' check (role = 'manager'),
  created_at timestamptz not null default now(),
  primary key (space_id, user_id),
  foreign key (space_id, space_kind)
    references public.spaces(id, kind) on delete cascade
);
create index space_members_user_idx on public.space_members(user_id, space_id);

-- Только реквизиты: никаких остатков или начальных балансов здесь нет.
create table public.wallets (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 100),
  wallet_group text not null check (wallet_group in ('cash', 'bank_account', 'card')),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  currency_scale smallint not null default 2 check (currency_scale between 0 and 4),
  created_at timestamptz not null default now(),
  unique (space_id, id)
);

-- Назначение разрешает видеть кошелёк; право записи расходов появится
-- только вместе с будущей таблицей операций и её отдельными RLS-политиками.
create table public.wallet_assignments (
  space_id uuid not null,
  wallet_id uuid not null,
  user_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (wallet_id, user_id),
  foreign key (space_id, wallet_id)
    references public.wallets(space_id, id) on delete cascade,
  foreign key (space_id, user_id)
    references public.space_members(space_id, user_id) on delete cascade
);
create index wallet_assignments_member_idx
  on public.wallet_assignments(user_id, space_id, wallet_id);
create index wallet_assignments_space_idx
  on public.wallet_assignments(space_id, user_id);

-- Отдельная защищённая строка начального баланса: bigint, минимальные единицы.
-- Например, 12345 при currency_scale=2 означает 123.45 единицы валюты.
-- Текущих остатков/агрегатов операций на этом этапе нет.
create table public.wallet_opening_balances (
  wallet_id uuid primary key references public.wallets(id) on delete cascade,
  amount_minor bigint not null default 0
);

alter table public.spaces enable row level security;
alter table public.space_members enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_assignments enable row level security;
alter table public.wallet_opening_balances enable row level security;

-- Сбрасываем возможные Supabase default grants, включая TRUNCATE/REFERENCES/TRIGGER.
revoke all on table public.spaces, public.space_members, public.wallets,
  public.wallet_assignments, public.wallet_opening_balances
  from public, anon, authenticated;

-- Никаких прав UPDATE на owner_user_id, kind, id, space_id, currency/scale.
grant select, delete on public.spaces to authenticated;
grant insert (owner_user_id, kind, name) on public.spaces to authenticated;
grant update (name) on public.spaces to authenticated;
grant select, delete on public.space_members to authenticated;
grant insert (space_id, user_id) on public.space_members to authenticated;
grant select, delete on public.wallets to authenticated;
grant insert (space_id, name, wallet_group, currency, currency_scale)
  on public.wallets to authenticated;
grant update (name, wallet_group) on public.wallets to authenticated;
grant select, delete on public.wallet_assignments to authenticated;
grant insert (space_id, wallet_id, user_id) on public.wallet_assignments to authenticated;
grant select, delete on public.wallet_opening_balances to authenticated;
grant insert (wallet_id, amount_minor) on public.wallet_opening_balances to authenticated;
grant update (amount_minor) on public.wallet_opening_balances to authenticated;

-- Узкие read-only helpers разрывают рекурсию RLS. Создатель postgres;
-- нет динамического SQL, аргумента user_id, доверия к user_metadata или JWT role.
-- search_path пустой; имена объектов квалифицированы.
create function finance_private.owns_space(target_space uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.spaces s
    where s.id = target_space and s.owner_user_id = (select auth.uid())
  );
$function$;

-- Новое пространство может создать только уже назначенный администратором
-- владелец. Первый вошедший/обычный пользователь/менеджер владельцем не станет.
create function finance_private.is_established_owner()
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.spaces s
    where s.owner_user_id = (select auth.uid())
  );
$function$;

revoke all on function finance_private.owns_space(uuid),
  finance_private.is_established_owner() from public, anon, authenticated;
grant execute on function finance_private.owns_space(uuid),
  finance_private.is_established_owner() to authenticated;

create policy spaces_read on public.spaces for select to authenticated
using (
  owner_user_id = (select auth.uid())
  or (kind = 'business' and exists (
    select 1 from public.space_members m
    where m.space_id = spaces.id and m.user_id = (select auth.uid())
  ))
);
create policy spaces_create on public.spaces for insert to authenticated
with check (
  owner_user_id = (select auth.uid())
  and (select finance_private.is_established_owner())
);
create policy spaces_rename on public.spaces for update to authenticated
using (owner_user_id = (select auth.uid()))
with check (owner_user_id = (select auth.uid()));
create policy spaces_delete on public.spaces for delete to authenticated
using (owner_user_id = (select auth.uid()));

create policy members_read on public.space_members for select to authenticated
using (user_id = (select auth.uid()) or finance_private.owns_space(space_id));
create policy members_assign on public.space_members for insert to authenticated
with check (
  finance_private.owns_space(space_id)
  and role = 'manager' and space_kind = 'business'
  and user_id <> (select auth.uid())
);
create policy members_revoke on public.space_members for delete to authenticated
using (finance_private.owns_space(space_id));
-- UPDATE намеренно отсутствует: изменение назначения через revoke + assign.

create policy wallets_read on public.wallets for select to authenticated
using (
  finance_private.owns_space(space_id)
  or exists (
    select 1 from public.wallet_assignments a
    where a.space_id = wallets.space_id and a.wallet_id = wallets.id
      and a.user_id = (select auth.uid())
  )
);
create policy wallets_create on public.wallets for insert to authenticated
with check (finance_private.owns_space(space_id));
create policy wallets_edit on public.wallets for update to authenticated
using (finance_private.owns_space(space_id))
with check (finance_private.owns_space(space_id));
create policy wallets_delete on public.wallets for delete to authenticated
using (finance_private.owns_space(space_id));

create policy assignments_read on public.wallet_assignments for select to authenticated
using (user_id = (select auth.uid()) or finance_private.owns_space(space_id));
create policy assignments_grant on public.wallet_assignments for insert to authenticated
with check (finance_private.owns_space(space_id));
create policy assignments_revoke on public.wallet_assignments for delete to authenticated
using (finance_private.owns_space(space_id));

create policy opening_balances_owner_only on public.wallet_opening_balances
for all to authenticated
using (exists (
  select 1 from public.wallets w
  where w.id = wallet_opening_balances.wallet_id
    and finance_private.owns_space(w.space_id)
))
with check (exists (
  select 1 from public.wallets w
  where w.id = wallet_opening_balances.wallet_id
    and finance_private.owns_space(w.space_id)
));

comment on table public.spaces is 'Владелец определяется только owner_user_id; первичное назначение через административный bootstrap SQL.';
comment on table public.space_members is 'Только менеджеры бизнес-пространств. Участие само по себе не даёт чтения всех кошельков.';
comment on table public.wallets is 'Реквизиты без денежных остатков; менеджеру видны только назначенные кошельки.';
comment on table public.wallet_opening_balances is 'Начальные балансы в минимальных единицах валюты; доступ только владельцу.';

commit;
