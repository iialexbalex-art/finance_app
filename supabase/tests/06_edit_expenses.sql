-- ПОДГОТОВЛЕНО, НЕ ЗАПУЩЕНО. Изолированный проект после 001–006.
-- Выполнить целиком как postgres. Все фиктивные данные откатываются.
begin;
do $test$
declare
  owner_id uuid := '00000000-0000-4000-8000-000000000071';
  manager uuid := '00000000-0000-4000-8000-000000000072';
  outsider uuid := '00000000-0000-4000-8000-000000000073';
  space uuid := '10000000-0000-4000-8000-000000000071';
  foreign_space uuid := '10000000-0000-4000-8000-000000000073';
  w1 uuid := '20000000-0000-4000-8000-000000000071';
  w2 uuid := '20000000-0000-4000-8000-000000000072';
  w3 uuid := '20000000-0000-4000-8000-000000000073';
  foreign_w uuid := '20000000-0000-4000-8000-000000000074';
  root_id uuid; leaf_id uuid; active_id uuid; foreign_cat uuid; income_id uuid;
  saved uuid; revision1 uuid; revision2 uuid; revision3 uuid;
  create_req uuid := gen_random_uuid();
  req1 uuid := gen_random_uuid(); req2 uuid := gen_random_uuid();
  before_row public.expenses%rowtype; after_row public.expenses%rowtype;
  invalid_amount text;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if has_table_privilege('authenticated','public.expenses','UPDATE')
    or has_any_column_privilege('authenticated','public.expenses','UPDATE')
    or has_table_privilege('authenticated','finance_private.expense_edit_requests','SELECT')
    or has_table_privilege('authenticated','finance_private.expense_creation_receipts','SELECT')
    or has_function_privilege('anon','public.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer)','EXECUTE')
  then raise exception 'FAIL: privileges'; end if;
  insert into auth.users(id) values(owner_id),(manager),(outsider);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (space,owner_id,'business','Edit test'),(foreign_space,outsider,'business','Foreign');
  insert into public.wallets(id,space_id,name,wallet_group,currency) values
    (w1,space,'First','cash','RUB'),(w2,space,'Second','card','RUB'),
    (w3,space,'USD','cash','USD'),(foreign_w,foreign_space,'Foreign','cash','RUB');
  insert into public.space_members(space_id,user_id) values(space,manager);
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(space,w1,manager);
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(w1,100000),(w2,200000);
  insert into public.categories(space_id,kind,name) values(space,'expense','Root') returning id into root_id;
  insert into public.categories(space_id,kind,name,parent_id) values(space,'expense','Leaf',root_id) returning id into leaf_id;
  insert into public.categories(space_id,kind,name) values(space,'expense','Active') returning id into active_id;
  insert into public.categories(space_id,kind,name) values(foreign_space,'expense','Foreign') returning id into foreign_cat;
  insert into public.categories(space_id,kind,name) values(space,'income','Income') returning id into income_id;

  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  saved:=public.create_expense(create_req,space,w1,leaf_id,'25000',date '2026-09-30','Original');
  select * into before_row from public.expenses where id=saved;
  revision1:=before_row.revision;
  begin
    perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: manager edited own expense';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  execute 'set local role authenticated';
  begin
    perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: foreign owner edited expense';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';

  update public.categories set name='Renamed',is_archived=true where id=root_id;
  update public.wallets set name='Renamed wallet' where id=w1;
  -- Старую архивную цепочку разрешено оставить; дата/сумма/комментарий не обновляют снимки.
  perform set_config('TimeZone','Pacific/Kiritimati',true);
  if public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'30000',date '0001-01-01','Past','RUB',2)<>saved
  then raise exception 'FAIL: changed id'; end if;
  select * into after_row from public.expenses where id=saved;
  revision2:=after_row.revision;
  if after_row.author_id<>manager or after_row.created_at<>before_row.created_at
    or after_row.request_id<>create_req or after_row.space_id<>space
    or after_row.wallet_name<>'First' or after_row.category_path<>'Root → Leaf'
    or after_row.expense_date<>date '0001-01-01' or revision2=revision1
    or public.wallet_expense_balance(w1)->>'current_minor'<>'70000'
  then raise exception 'FAIL: immutable identity/snapshots/date/balance'; end if;
  -- Повтор того же запроса не увеличивает версию.
  perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'30000',date '0001-01-01','Past','RUB',2);
  if (select revision from public.expenses where id=saved)<>revision2 then raise exception 'FAIL: retry wrote twice'; end if;
  begin
    perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'30001',date '0001-01-01','Past','RUB',2);
    raise exception 'FAIL: changed replay accepted';
  exception when sqlstate 'P1002' then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision1,w1,leaf_id,'1',current_date,'Stale','RUB',2);
    raise exception 'FAIL: stale tab overwrote';
  exception when sqlstate 'P1003' then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,foreign_w,leaf_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: foreign wallet';
  exception when insufficient_privilege then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),foreign_space,saved,revision2,foreign_w,foreign_cat,'1',current_date,'','RUB',2);
    raise exception 'FAIL: moved space';
  exception when insufficient_privilege then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,foreign_cat,'1',current_date,'','RUB',2);
    raise exception 'FAIL: foreign category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,income_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: income category';
  exception when sqlstate 'P1001' then null; end;
  foreach invalid_amount in array array['0','-1','1.1','1e3','NaN',''] loop
    begin
      perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,leaf_id,invalid_amount,current_date,'','RUB',2);
      raise exception 'FAIL: invalid amount %',invalid_amount;
    exception when invalid_parameter_value then null; end;
  end loop;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,leaf_id,'9223372036854775808',current_date,'','RUB',2);
    raise exception 'FAIL: amount overflow';
  exception when numeric_value_out_of_range then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,leaf_id,'1',date '10000-01-01','','RUB',2);
    raise exception 'FAIL: unsupported date';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision2,w1,leaf_id,'1',date 'infinity','','RUB',2);
    raise exception 'FAIL: infinite date';
  exception when invalid_parameter_value then null; end;
  begin
    update public.expenses set amount_minor=1 where id=saved;
    raise exception 'FAIL: direct update';
  exception when insufficient_privilege then null; end;

  perform set_config('TimeZone','America/Adak',true);
  perform public.edit_expense(req2,space,saved,revision2,w2,active_id,'9007199254740993',date '9999-12-31','Future','RUB',2);
  select * into after_row from public.expenses where id=saved;
  revision3:=after_row.revision;
  if after_row.expense_date<>date '9999-12-31' or after_row.wallet_name<>'Second'
    or after_row.category_path<>'Active' or after_row.author_id<>manager
    or public.wallet_expense_balance(w1)->>'current_minor'<>'100000'
    or public.wallet_expense_balance(w2)->>'current_minor'<>'-9007199254540993'
  then raise exception 'FAIL: move both balances/date/snapshots/precision'; end if;
  -- Старый успешный запрос после следующей правки не откатывает её.
  perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'30000',date '0001-01-01','Past','RUB',2);
  if (select revision from public.expenses where id=saved)<>revision3 then raise exception 'FAIL: old retry rolled back edit'; end if;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision3,w2,leaf_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: new archived ancestor accepted';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.edit_expense(gen_random_uuid(),space,saved,revision3,w3,active_id,'1',current_date,'','RUB',2);
    raise exception 'FAIL: hidden currency conversion';
  exception when sqlstate 'P1004' then null; end;
  perform public.edit_expense(gen_random_uuid(),space,saved,revision3,w3,active_id,'12345',date '2024-02-29','USD','USD',2);
  if public.wallet_expense_balance(w2)->>'current_minor'<>'200000'
    or public.wallet_expense_balance(w3)->>'current_minor'<>'-12345'
    or not exists(select 1 from public.expenses where id=saved and currency='USD' and currency_scale=2 and wallet_name='USD')
  then raise exception 'FAIL: currency move'; end if;

  execute 'reset role';
  if (select count(*) from finance_private.expense_edit_requests where expense_id=saved)<>3
    or (select count(*) from public.expenses where space_id=space)<>1
  then raise exception 'FAIL: receipts/identity'; end if;
  -- Повтор CREATE после редактирования сравнивается с оригиналом, а не текущей строкой.
  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  if public.create_expense(create_req,space,w1,leaf_id,'25000',date '2026-09-30','Original')<>saved
  then raise exception 'FAIL: creation retry after edit'; end if;
  begin
    perform public.edit_expense(req1,space,saved,revision1,w1,leaf_id,'30000',date '0001-01-01','Past','RUB',2);
    raise exception 'FAIL: manager replay';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'PASS: owner edits, both balances, snapshots, dates, replay and conflicts; rolling back';
end
$test$;
rollback;
