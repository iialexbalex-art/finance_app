-- После 001–013, целиком как postgres. Агентом не запускался. Данные откатываются.
begin;
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000141';
  manager_id uuid:='00000000-0000-4000-8000-000000000142';
  outsider_id uuid:='00000000-0000-4000-8000-000000000143';
  personal uuid:='10000000-0000-4000-8000-000000000141';
  business uuid:='10000000-0000-4000-8000-000000000142';
  other uuid:='10000000-0000-4000-8000-000000000143';
  partial_personal uuid:='10000000-0000-4000-8000-000000000144';
  partial_business uuid:='10000000-0000-4000-8000-000000000145';
  edited uuid; deleted uuid; category_id uuid; foreign_wallet uuid; reused_wallet uuid; partial_wallet uuid;
  response jsonb; before_balances jsonb; desired_order uuid[]; actor uuid;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if (select count(*) from finance_private.wallet_set_items
      where set_version='wallet_set_2026_10_02' and space_kind='personal')<>18
    or (select count(*) from finance_private.wallet_set_items
      where set_version='wallet_set_2026_10_02' and space_kind='business')<>4
    or (select count(distinct set_key) from finance_private.wallet_set_items
      where set_version='wallet_set_2026_10_02')<>22
    or has_function_privilege('authenticated',
      'finance_private.install_wallet_set_2026_10_02(uuid,uuid)','EXECUTE')
    or has_table_privilege('authenticated','finance_private.wallet_set_items','SELECT')
    or has_column_privilege('authenticated','public.wallets','sort_order','UPDATE')
    or not has_column_privilege('authenticated','public.wallets','is_archived','UPDATE')
    then raise exception 'FAIL: registry or private access'; end if;

  insert into auth.users(id) values(owner_id),(manager_id),(outsider_id);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (personal,owner_id,'personal','Personal'),
    (business,owner_id,'business','Business'),
    (other,outsider_id,'personal','Other');
  insert into public.space_members(space_id,user_id) values(business,manager_id);
  insert into public.categories(space_id,kind,name) values(personal,'expense','Test') returning id into category_id;

  response:=finance_private.install_wallet_set_2026_10_02(personal,business);
  if response->>'created'<>'22' or response->>'reused'<>'0'
    or response->>'skipped'<>'0' or response->'conflicts'<>'[]'::jsonb
    then raise exception 'FAIL: first install %',response; end if;
  if (select count(*) from public.wallets where space_id=personal)<>18
    or (select count(*) from public.wallets where space_id=business)<>4
    or (select count(*) from finance_private.wallet_set_imports
      where set_version='wallet_set_2026_10_02' and space_id in(personal,business))<>22
    or exists(select 1 from finance_private.wallet_set_imports i
      left join public.wallet_opening_balances b on b.wallet_id=i.wallet_id
      where i.set_version='wallet_set_2026_10_02' and i.space_id in(personal,business)
        and (b.wallet_id is null or b.amount_minor<>0))
    then raise exception 'FAIL: counts or zero opening balances'; end if;
  if not exists(select 1 from public.wallets where space_id=personal and sort_order=1
      and name='Наличные тенге' and currency='KZT' and icon_id='cash_kzt_photo')
    or not exists(select 1 from public.wallets where space_id=personal and sort_order=18
      and name='наличка турецкая лира' and currency='TRY' and icon_id='cash_try_photo')
    or not exists(select 1 from public.wallets where space_id=business and sort_order=2
      and name='Карта Сбер 6886 (ИП)' and currency='RUB' and icon_id='card_sber_business')
    or not exists(select 1 from public.wallets where space_id=business and sort_order=4
      and name='Расчётный счёт ТОО' and currency='KZT' and icon_id='account_bcc_checking')
    then raise exception 'FAIL: exact wallet mapping or order'; end if;

  response:=finance_private.install_wallet_set_2026_10_02(personal,business);
  if response->>'created'<>'0' or response->>'reused'<>'0'
    or response->>'skipped'<>'22' or response->'conflicts'<>'[]'::jsonb
    then raise exception 'FAIL: idempotent replay %',response; end if;

  select wallet_id into edited from finance_private.wallet_set_imports
    where space_id=personal and set_key='personal_sber_primary';
  select wallet_id into deleted from finance_private.wallet_set_imports
    where space_id=business and set_key='business_office_cash';
  update public.wallets set name='Моя основная карта',icon_id='card_sber_gold'
    where id=edited;
  delete from public.wallets where id=deleted;
  response:=finance_private.install_wallet_set_2026_10_02(personal,business);
  if response->>'skipped'<>'22'
    or not exists(select 1 from public.wallets where id=edited
      and name='Моя основная карта' and icon_id='card_sber_gold')
    or exists(select 1 from public.wallets where id=deleted)
    or (select wallet_id from finance_private.wallet_set_imports
      where space_id=business and set_key='business_office_cash') is not null
    then raise exception 'FAIL: user edit/delete restored %',response; end if;

  perform set_config('request.jwt.claim.sub',owner_id::text,true); execute 'set local role authenticated';
  before_balances:=public.space_balances(personal);
  desired_order:=array(select id from public.wallets where space_id=personal order by sort_order desc,id);
  perform public.reorder_wallets(personal,desired_order);
  if (select array_agg(sort_order order by sort_order) from public.wallets where space_id=personal)
      <>array(select generate_series(1,18))
    or (select array_agg(id order by sort_order) from public.wallets where space_id=personal)
      is distinct from desired_order
    or exists(select 1 from public.wallets where space_id=personal and is_archived)
    then raise exception 'FAIL: owner reorder'; end if;
  update public.wallets set is_archived=true where id=edited;
  if not (select is_archived from public.wallets where id=edited)
    or exists(select 1 from jsonb_array_elements(before_balances) b
      join jsonb_array_elements(public.space_balances(personal)) a on a->>'id'=b->>'id'
      where a->'balance' is distinct from b->'balance')
    then raise exception 'FAIL: archive changed balances'; end if;
  begin
    perform public.create_expense(gen_random_uuid(),personal,edited,category_id,'1',current_date,'archived');
    raise exception 'FAIL: archived wallet accepted';
  exception when sqlstate 'P1006' then null; end;
  execute 'reset role';

  -- Existing position 1, one compatible wallet without a ledger row, and one
  -- already journalled item simulate a safe resume after a partial attempt.
  insert into public.spaces(id,owner_user_id,kind,name) values
    (partial_personal,owner_id,'personal','Partial personal'),
    (partial_business,owner_id,'business','Partial business');
  insert into public.wallets(space_id,name,wallet_group,currency,icon_id,sort_order)
    values(partial_personal,'Посторонний кошелёк','cash','RUB','wallet',1)
    returning id into foreign_wallet;
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(foreign_wallet,900);
  insert into public.wallets(space_id,name,wallet_group,currency,icon_id,sort_order)
    values(partial_personal,'Наличные тенге','cash','KZT','future_icon',2)
    returning id into reused_wallet;
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(reused_wallet,777);
  insert into public.wallets(space_id,name,wallet_group,currency,icon_id,sort_order)
    values(partial_business,'Касса офис','cash','RUB','cashbox_office_photo',1)
    returning id into partial_wallet;
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(partial_wallet,0);
  insert into finance_private.wallet_set_imports(space_id,set_version,set_key,wallet_id)
    values(partial_business,'wallet_set_2026_10_02','business_office_cash',partial_wallet);

  response:=finance_private.install_wallet_set_2026_10_02(partial_personal,partial_business);
  if response->>'created'<>'20' or response->>'reused'<>'1' or response->>'skipped'<>'1'
    or response->'conflicts'<>'[]'::jsonb
    or (select count(*) from public.wallets where space_id=partial_personal)<>19
    or (select count(*) from public.wallets where space_id=partial_business)<>4
    or (select count(distinct sort_order) from public.wallets where space_id=partial_personal)<>19
    or (select array_agg(sort_order order by sort_order) from public.wallets where space_id=partial_personal)
      <>array(select generate_series(1,19))
    or (select array_agg(sort_order order by sort_order) from public.wallets where space_id=partial_business)
      <>array(select generate_series(1,4))
    or not exists(select 1 from public.wallets where id=foreign_wallet
      and name='Посторонний кошелёк' and sort_order=1 and icon_id='wallet')
    or not exists(select 1 from public.wallets where id=reused_wallet
      and sort_order=2 and icon_id='future_icon')
    or (select amount_minor from public.wallet_opening_balances where wallet_id=foreign_wallet)<>900
    or (select amount_minor from public.wallet_opening_balances where wallet_id=reused_wallet)<>777
    then raise exception 'FAIL: occupied order or partial resume %',response; end if;

  update public.wallets set name='Мои наличные тенге',icon_id='cash_kzt_photo',is_archived=true
    where id=reused_wallet;
  response:=finance_private.install_wallet_set_2026_10_02(partial_personal,partial_business);
  if response->>'created'<>'0' or response->>'reused'<>'0' or response->>'skipped'<>'22'
    or response->'conflicts'<>'[]'::jsonb
    or (select count(*) from public.wallets where space_id=partial_personal)<>19
    or (select count(*) from public.wallets where space_id=partial_business)<>4
    or not exists(select 1 from public.wallets where id=reused_wallet
      and name='Мои наличные тенге' and icon_id='cash_kzt_photo' and is_archived and sort_order=2)
    or (select amount_minor from public.wallet_opening_balances where wallet_id=reused_wallet)<>777
    then raise exception 'FAIL: resumed set replay or user edit preservation %',response; end if;

  foreach actor in array array[manager_id,outsider_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true); execute 'set local role authenticated';
    begin
      perform finance_private.install_wallet_set_2026_10_02(personal,business);
      raise exception 'FAIL: installer execution';
    exception when insufficient_privilege then null; end;
    begin
      perform public.reorder_wallets(personal,array[]::uuid[]);
      raise exception 'FAIL: reorder access';
    exception when insufficient_privilege then null; end;
    update public.wallets set is_archived=false where id=edited;
    if found then raise exception 'FAIL: archive access'; end if;
    execute 'reset role';
  end loop;

  begin
    perform finance_private.install_wallet_set_2026_10_02(personal,other);
    raise exception 'FAIL: different owners accepted';
  exception when sqlstate '22023' then null; end;
  raise notice 'PASS: exact 18+4 wallets, zero balances, exact reorder, occupied positions, partial resume, idempotency, edit/delete preservation, archive and access';
end $test$;
rollback;
