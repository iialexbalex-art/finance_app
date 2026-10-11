-- Local visual identities only. Financial operations and request receipts are untouched.
begin;
alter table public.categories
  add column icon_id text not null default 'category'
  constraint categories_icon_id_format check (icon_id ~ '^[a-z][a-z0-9_]{0,47}$');
-- Existing INSERT/UPDATE RLS remains authoritative; managers gain no write policy.
grant insert (icon_id), update (icon_id) on public.categories to authenticated;
comment on column public.categories.icon_id is
  'Stable local asset identifier; unknown IDs use neutral UI fallback. Not a URL.';
notify pgrst, 'reload schema';
commit;
