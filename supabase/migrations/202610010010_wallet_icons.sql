-- После 001–009. Только подготовлено: агентом в Supabase не выполнялось.
begin;
alter table public.wallets add column icon_id text;
-- Только метаданные кошельков. Категории, операции и квитанции не изменяются.
update public.wallets set icon_id=case wallet_group
  when 'cash' then 'cash' when 'bank_account' then 'bank' else 'card' end;
alter table public.wallets alter column icon_id set not null;
alter table public.wallets add constraint wallet_icon_identifier
  check(icon_id ~ '^[a-z][a-z0-9_]{0,47}$');

-- Старые клиенты могут создавать кошельки без нового поля.
create function finance_private.default_wallet_icon() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.icon_id is null then
    new.icon_id:=case new.wallet_group when 'cash' then 'cash' when 'bank_account' then 'bank' else 'card' end;
  end if;
  return new;
end $$;
revoke all on function finance_private.default_wallet_icon() from public,anon,authenticated;
create trigger wallet_default_icon before insert on public.wallets
for each row execute function finance_private.default_wallet_icon();
grant insert(icon_id),update(icon_id) on public.wallets to authenticated;
-- RLS owners-only запись / назначенные кошельки менеджера остаётся прежним.
-- Неизвестный корректный ID разрешён для совместимости будущих каталогов;
-- клиент показывает для него стандартный кошелёк.

create or replace function public.space_balances(p_space_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'space_id',w.space_id,'name',w.name,
    'wallet_group',w.wallet_group,'currency',w.currency,'currency_scale',w.currency_scale,'icon_id',w.icon_id,
    'balance',public.wallet_expense_balance(w.id)) order by w.created_at,w.id),'[]'::jsonb)
  into result from public.wallets w where w.space_id=p_space_id;
  return result;
end $$;
revoke all on function public.space_balances(uuid) from public,anon,authenticated;
grant execute on function public.space_balances(uuid) to authenticated;
comment on column public.wallets.icon_id is 'Stable local icon catalog ID; presentation only, no currency, bank inference or access semantics.';
notify pgrst,'reload schema';
commit;
