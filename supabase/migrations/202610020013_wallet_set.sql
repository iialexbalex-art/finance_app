-- После 001–012. Подготовлено агентом, в Supabase не выполнялось.
begin;

alter table public.wallets add column sort_order integer;
alter table public.wallets add column is_archived boolean not null default false;

with ranked as (
  select id,row_number() over(partition by space_id order by created_at,id)::integer position
  from public.wallets
)
update public.wallets w set sort_order=r.position from ranked r where r.id=w.id;

alter table public.wallets alter column sort_order set not null;
alter table public.wallets add constraint wallet_sort_order_positive check(sort_order>0);
alter table public.wallets add constraint wallets_space_sort_order_key
  unique(space_id,sort_order) deferrable initially immediate;

create function finance_private.default_wallet_sort_order() returns trigger
language plpgsql set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('wallet-order:'||new.space_id::text,0));
  if new.sort_order is null then
    select coalesce(max(sort_order),0)+1 into new.sort_order
    from public.wallets where space_id=new.space_id;
  end if;
  return new;
end $$;
revoke all on function finance_private.default_wallet_sort_order() from public,anon,authenticated;
create trigger wallet_default_sort_order before insert on public.wallets
for each row execute function finance_private.default_wallet_sort_order();

grant update(is_archived) on public.wallets to authenticated;

create function finance_private.reject_archived_cashflow_wallet() returns trigger
language plpgsql set search_path='' as $$
begin
  if (tg_op='INSERT' or new.wallet_id is distinct from old.wallet_id)
    and not exists(select 1 from public.wallets w where w.id=new.wallet_id and not w.is_archived) then
    raise exception using errcode='P1006',message='Archived wallet unavailable for new operation';
  end if;
  return new;
end $$;
revoke all on function finance_private.reject_archived_cashflow_wallet() from public,anon,authenticated;
create trigger expense_active_wallet before insert or update of wallet_id on public.expenses
for each row execute function finance_private.reject_archived_cashflow_wallet();
create trigger income_active_wallet before insert or update of wallet_id on public.incomes
for each row execute function finance_private.reject_archived_cashflow_wallet();

create function finance_private.reject_archived_transfer_wallets() returns trigger
language plpgsql set search_path='' as $$
begin
  if (tg_op='INSERT' or new.source_id is distinct from old.source_id)
    and not exists(select 1 from public.wallets w where w.id=new.source_id and not w.is_archived) then
    raise exception using errcode='P1006',message='Archived source wallet unavailable';
  end if;
  if (tg_op='INSERT' or new.target_id is distinct from old.target_id)
    and not exists(select 1 from public.wallets w where w.id=new.target_id and not w.is_archived) then
    raise exception using errcode='P1006',message='Archived target wallet unavailable';
  end if;
  return new;
end $$;
revoke all on function finance_private.reject_archived_transfer_wallets() from public,anon,authenticated;
create trigger transfer_active_wallets before insert or update of source_id,target_id on public.transfers
for each row execute function finance_private.reject_archived_transfer_wallets();

create function public.reorder_wallets(p_space_id uuid,p_wallet_ids uuid[])
returns void language plpgsql volatile security definer set search_path='' as $$
begin
  if not finance_private.owns_space(p_space_id) then
    raise exception using errcode='42501',message='Owner access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('wallet-order:'||p_space_id::text,0));
  if coalesce(cardinality(p_wallet_ids),0)<>(select count(*) from public.wallets where space_id=p_space_id)
    or coalesce(cardinality(p_wallet_ids),0)<>(select count(distinct u.id) from unnest(p_wallet_ids) as u(id))
    or exists(select 1 from unnest(p_wallet_ids) as u(id) where not exists(
      select 1 from public.wallets w where w.space_id=p_space_id and w.id=u.id)) then
    raise exception using errcode='22023',message='Wallet order must contain every wallet exactly once';
  end if;
  set constraints public.wallets_space_sort_order_key deferred;
  update public.wallets w set sort_order=u.position
  from unnest(p_wallet_ids) with ordinality u(id,position)
  where w.space_id=p_space_id and w.id=u.id;
end $$;
revoke all on function public.reorder_wallets(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.reorder_wallets(uuid,uuid[]) to authenticated;

create table finance_private.wallet_set_items(
  set_version text not null,
  set_key text not null,
  space_kind text not null check(space_kind in('personal','business')),
  display_order integer not null check(display_order>0),
  name text not null,
  wallet_group text not null check(wallet_group in('cash','bank_account','card')),
  currency text not null check(currency ~ '^[A-Z]{3}$'),
  icon_id text not null check(icon_id ~ '^[a-z][a-z0-9_]{0,47}$'),
  primary key(set_version,set_key),
  unique(set_version,space_kind,display_order)
);

create table finance_private.wallet_set_imports(
  space_id uuid not null references public.spaces(id) on delete cascade,
  set_version text not null,
  set_key text not null,
  wallet_id uuid references public.wallets(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(space_id,set_version,set_key),
  foreign key(set_version,set_key)
    references finance_private.wallet_set_items(set_version,set_key) on delete restrict
);

revoke all on table finance_private.wallet_set_items,
  finance_private.wallet_set_imports from public,anon,authenticated;

insert into finance_private.wallet_set_items
  (set_version,set_key,space_kind,display_order,name,wallet_group,currency,icon_id)
values
  ('wallet_set_2026_10_02','personal_cash_kzt','personal',1,'Наличные тенге','cash','KZT','cash_kzt_photo'),
  ('wallet_set_2026_10_02','personal_cash_usd','personal',2,'Наличные доллары','cash','USD','cash_usd_photo'),
  ('wallet_set_2026_10_02','personal_safe','personal',3,'Сейф','cash','RUB','safe_steel_photo'),
  ('wallet_set_2026_10_02','personal_kaspi_card','personal',4,'Карта Kaspi','card','KZT','card_kaspi_green'),
  ('wallet_set_2026_10_02','personal_kaspi_deposit','personal',5,'Депозит Kaspi','bank_account','KZT','account_kaspi_deposit'),
  ('wallet_set_2026_10_02','personal_sber_primary','personal',6,'Основная Сбер первый','card','RUB','card_sber_green'),
  ('wallet_set_2026_10_02','personal_sber_natasha','personal',7,'Карта Сбер Наташа','card','RUB','card_sber_silver'),
  ('wallet_set_2026_10_02','personal_sber_5581','personal',8,'Карта Сбер 55 81','card','RUB','card_sber_graphite'),
  ('wallet_set_2026_10_02','personal_sber_5255','personal',9,'Карта Сбер 52 55','card','RUB','card_sber_gold'),
  ('wallet_set_2026_10_02','personal_sber_savings','personal',10,'Копилка Сбер','bank_account','RUB','account_sber_savings'),
  ('wallet_set_2026_10_02','personal_t_card','personal',11,'Карта Тиньков','card','RUB','card_t_green'),
  ('wallet_set_2026_10_02','personal_t_savings','personal',12,'Копилка Тиньков','bank_account','RUB','account_t_savings'),
  ('wallet_set_2026_10_02','personal_alfa_card','personal',13,'Карта Альфа банка','card','RUB','card_alfa_green'),
  ('wallet_set_2026_10_02','personal_bakai_card','personal',14,'Киргизская карта','card','USD','card_bakai_green'),
  ('wallet_set_2026_10_02','personal_sber_rewards','personal',15,'Сбер Спасибо','bank_account','RUB','reward_sber_spasibo'),
  ('wallet_set_2026_10_02','personal_cash_thb','personal',16,'Наличка Таиландский бат','cash','THB','cash_thb_photo'),
  ('wallet_set_2026_10_02','personal_cash_egp','personal',17,'Наличка египетский фунт','cash','EGP','cash_egp_photo'),
  ('wallet_set_2026_10_02','personal_cash_try','personal',18,'наличка турецкая лира','cash','TRY','cash_try_photo'),
  ('wallet_set_2026_10_02','business_office_cash','business',1,'Касса офис','cash','RUB','cashbox_office_photo'),
  ('wallet_set_2026_10_02','business_sber_card','business',2,'Карта Сбер 6886 (ИП)','card','RUB','card_sber_business'),
  ('wallet_set_2026_10_02','business_sber_checking','business',3,'Расчётный счёт ИП','bank_account','RUB','account_sber_checking'),
  ('wallet_set_2026_10_02','business_bcc_checking','business',4,'Расчётный счёт ТОО','bank_account','KZT','account_bcc_checking');

create function finance_private.install_wallet_set_2026_10_02(
  p_personal_space uuid,p_business_space uuid
) returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  personal_owner uuid; business_owner uuid; item record; matched uuid[]; wallet uuid;
  next_order integer;
  created_count integer:=0; reused_count integer:=0; skipped_count integer:=0;
  conflicts jsonb:='[]'::jsonb; scope uuid;
begin
  if current_user<>'postgres' then
    raise exception using errcode='42501',message='Run installer as postgres';
  end if;
  if p_personal_space is null or p_business_space is null
    or p_personal_space=p_business_space then
    raise exception using errcode='22023',message='Expected two different spaces';
  end if;
  -- The same per-space locks are used by ordinary INSERTs and reorder_wallets.
  -- Always acquire two locks in UUID-text order to avoid a cross-space deadlock.
  perform pg_advisory_xact_lock(hashtextextended(
    'wallet-order:'||least(p_personal_space::text,p_business_space::text),0));
  perform pg_advisory_xact_lock(hashtextextended(
    'wallet-order:'||greatest(p_personal_space::text,p_business_space::text),0));
  select owner_user_id into personal_owner from public.spaces
    where id=p_personal_space and kind='personal' for update;
  select owner_user_id into business_owner from public.spaces
    where id=p_business_space and kind='business' for update;
  if personal_owner is null or business_owner is null or personal_owner<>business_owner
    then
    raise exception using errcode='22023',message='Expected personal and business spaces of one owner';
  end if;
  for item in select * from finance_private.wallet_set_items
    where set_version='wallet_set_2026_10_02'
    order by space_kind,display_order
  loop
    scope:=case item.space_kind when 'personal' then p_personal_space else p_business_space end;
    if exists(select 1 from finance_private.wallet_set_imports
      where space_id=scope and set_version=item.set_version and set_key=item.set_key) then
      skipped_count:=skipped_count+1;
      continue;
    end if;
    select coalesce(array_agg(id order by id),'{}'::uuid[]) into matched
    from public.wallets where space_id=scope and lower(btrim(name))=lower(btrim(item.name));
    if cardinality(matched)=0 then
      -- Keep every existing/user position untouched. In an empty space max=0,
      -- therefore the initial set is still created exactly as 1..18 / 1..4.
      select coalesce(max(sort_order),0)+1 into next_order
      from public.wallets where space_id=scope;
      insert into public.wallets(space_id,name,wallet_group,currency,currency_scale,icon_id,sort_order)
      values(scope,item.name,item.wallet_group,item.currency,2,item.icon_id,next_order)
      returning id into wallet;
      insert into public.wallet_opening_balances(wallet_id,amount_minor) values(wallet,0);
      created_count:=created_count+1;
    elsif cardinality(matched)=1 and exists(select 1 from public.wallets
      where id=matched[1] and wallet_group=item.wallet_group and currency=item.currency) then
      wallet:=matched[1];
      reused_count:=reused_count+1;
    else
      conflicts:=conflicts||jsonb_build_array(jsonb_build_object(
        'set_key',item.set_key,'space_id',scope,'name',item.name,
        'reason',case when cardinality(matched)>1 then 'ambiguous_name' else 'incompatible_wallet' end,
        'wallet_ids',to_jsonb(matched)));
      continue;
    end if;
    insert into finance_private.wallet_set_imports(space_id,set_version,set_key,wallet_id)
    values(scope,item.set_version,item.set_key,wallet);
  end loop;
  return jsonb_build_object('set_version','wallet_set_2026_10_02',
    'owner_user_id',personal_owner,'created',created_count,'reused',reused_count,
    'skipped',skipped_count,'conflicts',conflicts);
end $$;
revoke all on function finance_private.install_wallet_set_2026_10_02(uuid,uuid)
  from public,anon,authenticated;

create or replace function public.space_balances(p_space_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare result jsonb;
begin
  if not finance_private.owns_space(p_space_id) then raise exception using errcode='42501',message='Owner access required'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'space_id',w.space_id,'name',w.name,
    'wallet_group',w.wallet_group,'currency',w.currency,'currency_scale',w.currency_scale,'icon_id',w.icon_id,
    'sort_order',w.sort_order,'is_archived',w.is_archived,
    'balance',public.wallet_expense_balance(w.id)) order by w.sort_order,w.created_at,w.id),'[]'::jsonb)
  into result from public.wallets w where w.space_id=p_space_id;
  return result;
end $$;
revoke all on function public.space_balances(uuid) from public,anon,authenticated;
grant execute on function public.space_balances(uuid) to authenticated;

comment on column public.wallets.sort_order is 'Owner-controlled display order within one space.';
comment on column public.wallets.is_archived is 'Hidden from new-operation pickers; retained for history and balances.';
notify pgrst,'reload schema';
commit;
