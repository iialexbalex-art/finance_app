-- После 202609300001_spaces_wallets.sql. Выполнить целиком как postgres.
-- Подготовлено, НЕ выполнено агентом. Не применять повторно.
begin;
do $migration$
begin
  if current_user <> 'postgres' then
    raise exception 'Run migration as postgres';
  end if;
end
$migration$;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete restrict,
  kind text not null check (kind in ('income', 'expense')),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  parent_id uuid,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  is_root boolean generated always as (parent_id is null) stored,
  parent_must_be_root boolean generated always as (true) stored,
  unique (space_id, kind, id, is_root),
  check (parent_id is null or parent_id <> id),
  -- MATCH SIMPLE: у корня parent_id NULL, ссылка не проверяется.
  -- У потомка ссылка всегда требует is_root=true у родителя.
  -- Поэтому третий уровень и циклы невозможны, включая конкурентные записи.
  foreign key (space_id, kind, parent_id, parent_must_be_root)
    references public.categories(space_id, kind, id, is_root)
    on delete restrict on update restrict
);
create index categories_parent_idx on public.categories(parent_id);
alter table public.categories enable row level security;
revoke all on public.categories from public, anon, authenticated;
grant select on public.categories to authenticated;
grant insert (space_id, kind, name, parent_id) on public.categories to authenticated;
grant update (name, is_archived) on public.categories to authenticated;
-- Нет DELETE/TRUNCATE, изменения пространства/типа/родителя/id и роли.

create policy categories_read on public.categories for select to authenticated
using (
  finance_private.owns_space(space_id)
  or (kind = 'expense' and exists (
    select 1 from public.space_members m
    where m.space_id = categories.space_id
      and m.user_id = (select auth.uid())
      and m.space_kind = 'business' and m.role = 'manager'
  ))
);
create policy categories_create on public.categories for insert to authenticated
with check (finance_private.owns_space(space_id));
create policy categories_edit on public.categories for update to authenticated
using (finance_private.owns_space(space_id))
with check (finance_private.owns_space(space_id));

comment on table public.categories is
  'Два уровня; неизменяемые пространство, тип и родитель. Архив сохраняется для истории. Потомок архивного родителя также считается архивным при выборе в будущих операциях.';
-- Новых SECURITY DEFINER функций, RPC или расширения старых прав нет.
notify pgrst, 'reload schema';
commit;
