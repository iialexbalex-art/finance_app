-- ПОДГОТОВЛЕНО, НЕ ЗАПУЩЕНО. Изолированный проект после 001–005.
-- Целиком как postgres. Фиктивные UUID не менять, всё откатывается.
begin;
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000061';
  manager uuid:='00000000-0000-4000-8000-000000000062';
  other_manager uuid:='00000000-0000-4000-8000-000000000063';
  outsider uuid:='00000000-0000-4000-8000-000000000064';
  personal uuid:='10000000-0000-4000-8000-000000000061';
  business uuid:='10000000-0000-4000-8000-000000000062';
  foreign_space uuid:='10000000-0000-4000-8000-000000000064';
  personal_w uuid:='20000000-0000-4000-8000-000000000061';
  assigned_w uuid:='20000000-0000-4000-8000-000000000062';
  hidden_w uuid:='20000000-0000-4000-8000-000000000063';
  kzt_w uuid:='20000000-0000-4000-8000-000000000064';
  foreign_w uuid:='20000000-0000-4000-8000-000000000065';
  huge_w uuid:='20000000-0000-4000-8000-000000000066';
  root_id uuid; middle_id uuid; leaf_id uuid; income_id uuid; personal_cat uuid; foreign_cat uuid;
  req uuid:=gen_random_uuid(); manager_req uuid:=gen_random_uuid(); saved uuid; repeated uuid;
  balance jsonb; i integer;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres in test project'; end if;
  if not(select relrowsecurity from pg_class where oid='public.expenses'::regclass)
    or has_table_privilege('authenticated','public.expenses','INSERT')
    or has_table_privilege('authenticated','public.expenses','UPDATE')
    or has_table_privilege('authenticated','public.expenses','DELETE')
    or has_table_privilege('authenticated','public.expenses','TRUNCATE')
    or has_table_privilege('authenticated','public.expenses','TRIGGER')
    or has_table_privilege('authenticated','public.expenses','REFERENCES')
    or has_table_privilege('anon','public.expenses','SELECT')
    or has_function_privilege('anon','public.create_expense(uuid,uuid,uuid,uuid,text,date,text)','EXECUTE')
    or has_function_privilege('anon','public.wallet_expense_balance(uuid)','EXECUTE')
  then raise exception 'FAIL: grants/RLS'; end if;
  insert into auth.users(id) values(owner_id),(manager),(other_manager),(outsider);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (personal,owner_id,'personal','Personal'),(business,owner_id,'business','Business'),
    (foreign_space,outsider,'business','Foreign');
  insert into public.wallets(id,space_id,name,wallet_group,currency) values
    (personal_w,personal,'Personal RUB','cash','RUB'),(assigned_w,business,'Assigned RUB','cash','RUB'),
    (hidden_w,business,'Hidden RUB','card','RUB'),(kzt_w,business,'KZT','bank_account','KZT'),
    (foreign_w,foreign_space,'Foreign','cash','USD'),(huge_w,business,'Huge','cash','RUB');
  insert into public.space_members(space_id,user_id) values(business,manager),(business,other_manager);
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values
    (business,assigned_w,manager),(business,assigned_w,other_manager);
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(assigned_w,100000),(huge_w,-9223372036854775808);
  insert into public.categories(space_id,kind,name) values(business,'expense','Daily') returning id into root_id;
  insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Food',root_id) returning id into middle_id;
  insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Groceries',middle_id) returning id into leaf_id;
  insert into public.categories(space_id,kind,name) values(business,'income','Income') returning id into income_id;
  insert into public.categories(space_id,kind,name) values(personal,'expense','Personal') returning id into personal_cat;
  insert into public.categories(space_id,kind,name) values(foreign_space,'expense','Foreign') returning id into foreign_cat;

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',owner_id,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  saved:=public.create_expense(req,business,assigned_w,leaf_id,'25000',date '2026-09-30','Lunch');
  repeated:=public.create_expense(req,business,assigned_w,leaf_id,'25000',date '2026-09-30','Lunch');
  if saved<>repeated or (select count(*) from public.expenses)<>1 then raise exception 'FAIL: duplicate'; end if;
  if not exists(select 1 from public.expenses where id=saved and author_id=owner_id and category_path='Daily → Food → Groceries' and amount_minor=25000)
  then raise exception 'FAIL: author/snapshot'; end if;
  balance:=public.wallet_expense_balance(assigned_w);
  if balance->>'current_minor'<>'75000' or jsonb_typeof(balance->'current_minor')<>'string'
  then raise exception 'FAIL: exact owner balance'; end if;
  begin
    perform public.create_expense(req,business,assigned_w,leaf_id,'25001',date '2026-09-30','Lunch');
    raise exception 'FAIL: idempotency mismatch';
  exception when sqlstate 'P1002' then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,leaf_id,'0',current_date,'');
    raise exception 'FAIL: zero';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,leaf_id,'1.23',current_date,'');
    raise exception 'FAIL: fractional minor';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,leaf_id,'-1',current_date,'');
    raise exception 'FAIL: negative';
  exception when invalid_parameter_value then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,leaf_id,'9223372036854775808',current_date,'');
    raise exception 'FAIL: bigint overflow';
  exception when numeric_value_out_of_range then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,income_id,'1',current_date,'');
    raise exception 'FAIL: income category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,personal_cat,'1',current_date,'');
    raise exception 'FAIL: cross space category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,foreign_cat,'1',current_date,'');
    raise exception 'FAIL: foreign category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,personal_w,leaf_id,'1',current_date,'');
    raise exception 'FAIL: cross space wallet';
  exception when insufficient_privilege then null; end;
  update public.categories set is_archived=true where id=root_id;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,leaf_id,'1',current_date,'');
    raise exception 'FAIL: archived grandparent';
  exception when sqlstate 'P1001' then null; end;
  -- После потерянного ответа повтор уже сохранённой операции допустим, даже если категория архивирована.
  if public.create_expense(req,business,assigned_w,leaf_id,'25000',date '2026-09-30','Lunch')<>saved
  then raise exception 'FAIL: retry after archive'; end if;
  update public.categories set is_archived=false,name='Renamed' where id=root_id;
  if (select category_path from public.expenses where id=saved)<>'Daily → Food → Groceries'
  then raise exception 'FAIL: historical path mutated'; end if;
  perform public.create_expense(gen_random_uuid(),personal,personal_w,personal_cat,'123456',current_date,'');
  perform public.create_expense(gen_random_uuid(),business,kzt_w,root_id,'100',current_date,'');
  if public.wallet_expense_balance(kzt_w)->>'current_minor'<>'-100' or
    public.wallet_expense_balance(assigned_w)->>'current_minor'<>'75000'
  then raise exception 'FAIL: currencies/absent opening'; end if;
  for i in 1..30 loop
    perform public.create_expense(gen_random_uuid(),business,assigned_w,middle_id,'1',current_date,'pagination');
  end loop;
  if public.wallet_expense_balance(assigned_w)->>'current_minor'<>'74970'
  then raise exception 'FAIL: full aggregate beyond page'; end if;
  update public.wallet_opening_balances set amount_minor=200000 where wallet_id=assigned_w;
  if public.wallet_expense_balance(assigned_w)->>'current_minor'<>'174970'
    or (select count(*) from public.expenses where wallet_id=assigned_w)<>31
  then raise exception 'FAIL: initial balance edit removed expenses'; end if;
  perform public.create_expense(gen_random_uuid(),business,huge_w,root_id,'9223372036854775807',current_date,'');
  perform public.create_expense(gen_random_uuid(),business,huge_w,root_id,'9223372036854775807',current_date,'');
  if public.wallet_expense_balance(huge_w)->>'current_minor'<>'-27670116110564327422'
  then raise exception 'FAIL: numeric aggregate overflow/rounding'; end if;
  begin
    update public.expenses set amount_minor=1 where id=saved;
    raise exception 'FAIL: expense mutable';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.expenses where id=saved;
    raise exception 'FAIL: expense deletable';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',manager,'role','authenticated','user_metadata',json_build_object('role','owner'))::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.expenses) then raise exception 'FAIL: manager sees others'; end if;
  saved:=public.create_expense(manager_req,business,assigned_w,leaf_id,'9007199254740993',current_date,'Manager');
  if not exists(select 1 from public.expenses where id=saved and author_id=manager and amount_minor=9007199254740993)
  then raise exception 'FAIL: manager author/precision'; end if;
  if (select count(*) from public.expenses)<>1 then raise exception 'FAIL: manager history'; end if;
  begin
    perform public.wallet_expense_balance(assigned_w);
    raise exception 'FAIL: manager aggregate leak';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from public.wallet_opening_balances) then raise exception 'FAIL: opening leak'; end if;
  begin
    perform public.create_expense(gen_random_uuid(),personal,personal_w,personal_cat,'1',current_date,'');
    raise exception 'FAIL: manager personal';
  exception when insufficient_privilege then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),business,hidden_w,leaf_id,'1',current_date,'');
    raise exception 'FAIL: unassigned';
  exception when insufficient_privilege then null; end;
  begin
    perform public.create_expense(gen_random_uuid(),foreign_space,foreign_w,foreign_cat,'1',current_date,'');
    raise exception 'FAIL: foreign expense';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.expenses(request_id,author_id,space_id,wallet_id,category_id,amount_minor,currency,currency_scale,expense_date,wallet_name,category_path)
    values(gen_random_uuid(),owner_id,business,assigned_w,leaf_id,1,'RUB',2,current_date,'fake','fake');
    raise exception 'FAIL: spoof author direct insert';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',other_manager::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',other_manager,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.expenses) then raise exception 'FAIL: second manager sees first'; end if;
  perform public.create_expense(manager_req,business,assigned_w,root_id,'1',current_date,'Other manager same request id');

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',owner_id,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if (select count(*) from public.expenses where wallet_id=assigned_w)<>33
    or public.wallet_expense_balance(assigned_w)->>'current_minor'<>'-9007199254566024'
  then raise exception 'FAIL: owner must include both managers in history and balance'; end if;
  delete from public.wallet_assignments where wallet_id=assigned_w and user_id=manager;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',manager,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.expenses) then raise exception 'FAIL: revoked wallet history'; end if;
  begin
    perform public.create_expense(manager_req,business,assigned_w,leaf_id,'9007199254740993',current_date,'Manager');
    raise exception 'FAIL: revoked replay';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(business,assigned_w,manager);
  delete from public.space_members where space_id=business and user_id=manager;
  execute 'set local role authenticated';
  if exists(select 1 from public.expenses) then raise exception 'FAIL: revoked membership history'; end if;
  begin
    perform public.create_expense(gen_random_uuid(),business,assigned_w,root_id,'1',current_date,'');
    raise exception 'FAIL: revoked membership write';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',outsider,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.expenses) then raise exception 'FAIL: foreign owner history'; end if;
  begin
    perform public.wallet_expense_balance(assigned_w);
    raise exception 'FAIL: foreign owner balance';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role anon';
  begin
    perform 1 from public.expenses;
    raise exception 'FAIL: anon history';
  exception when insufficient_privilege then null; end;
  begin
    perform public.wallet_expense_balance(assigned_w);
    raise exception 'FAIL: anon balance';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'PASS: expense money, idempotency, RLS and revocation; rolling back';
end
$test$;
rollback;
