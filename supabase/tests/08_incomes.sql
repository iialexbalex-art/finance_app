-- После 001–009, целиком как postgres в тестовом проекте. Все данные откатываются.
begin;
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000091';
  manager uuid:='00000000-0000-4000-8000-000000000092';
  outsider uuid:='00000000-0000-4000-8000-000000000093';
  scope uuid:='10000000-0000-4000-8000-000000000091';
  other_scope uuid:='10000000-0000-4000-8000-000000000093';
  w1 uuid:='20000000-0000-4000-8000-000000000091';
  w2 uuid:='20000000-0000-4000-8000-000000000092';
  usd uuid:='20000000-0000-4000-8000-000000000093';
  usd_whole uuid:='20000000-0000-4000-8000-000000000095';
  foreign_wallet uuid:='20000000-0000-4000-8000-000000000094';
  root_id uuid; leaf_id uuid; expense_cat uuid; saved uuid; revision1 uuid; revision2 uuid;
  create_req uuid:=gen_random_uuid(); edit_req uuid:=gen_random_uuid();
  result jsonb; next_page jsonb; original public.incomes%rowtype;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if has_any_column_privilege('authenticated','public.incomes','UPDATE')
    or has_table_privilege('authenticated','public.incomes','INSERT')
    or has_table_privilege('authenticated','public.incomes','DELETE')
    or has_table_privilege('authenticated','finance_private.operation_receipts','SELECT')
    or has_function_privilege('anon','public.save_income(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer)','EXECUTE')
  then raise exception 'FAIL: grants'; end if;
  insert into auth.users(id) values(owner_id),(manager),(outsider);
  insert into public.spaces(id,owner_user_id,kind,name) values(scope,owner_id,'business','Income test'),(other_scope,outsider,'personal','Other');
  insert into public.wallets(id,space_id,name,wallet_group,currency) values
    (w1,scope,'First','cash','RUB'),(w2,scope,'Second','card','RUB'),(usd,scope,'USD','cash','USD'),(foreign_wallet,other_scope,'Foreign','cash','RUB');
  insert into public.space_members(space_id,user_id) values(scope,manager);
  insert into public.wallets(id,space_id,name,wallet_group,currency,currency_scale) values(usd_whole,scope,'Whole USD','cash','USD',0);
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(scope,w1,manager);
  insert into public.categories(space_id,kind,name) values(scope,'income','Root') returning id into root_id;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'income','Leaf',root_id) returning id into leaf_id;
  insert into public.categories(space_id,kind,name) values(scope,'expense','Expense') returning id into expense_cat;
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(w1,10000),(w2,20000);
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  saved:=public.save_income(create_req,scope,null,null,w1,leaf_id,'9007199254740993',date '2150-12-31','future','RUB',2);
  select * into original from public.incomes where id=saved;
  revision1:=original.revision;
  if public.wallet_expense_balance(w1)->>'current_minor'<>'9007199254750993' then raise exception 'FAIL: future income exact balance'; end if;
  perform public.save_income(edit_req,scope,saved,revision1,w2,leaf_id,'30000',date '1900-01-01','moved','RUB',2);
  select revision into revision2 from public.incomes where id=saved;
  if public.wallet_expense_balance(w1)->>'current_minor'<>'10000' or public.wallet_expense_balance(w2)->>'current_minor'<>'50000'
    or (select author_id<>original.author_id or created_at<>original.created_at from public.incomes where id=saved)
  then raise exception 'FAIL: moved income or immutable fields'; end if;
  if public.save_income(create_req,scope,null,null,w1,leaf_id,'9007199254740993',date '2150-12-31','future','RUB',2)<>saved
    or public.save_income(edit_req,scope,saved,revision1,w2,leaf_id,'30000',date '1900-01-01','moved','RUB',2)<>saved
    or (select revision from public.incomes where id=saved)<>revision2
  then raise exception 'FAIL: replay after edit'; end if;
  begin
    perform public.save_income(create_req,scope,null,null,w1,leaf_id,'1',date '2150-12-31','future','RUB',2);
    raise exception 'FAIL: changed replay';
  exception when sqlstate 'P1002' then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,saved,revision1,w1,leaf_id,'1',current_date,'stale','RUB',2);
    raise exception 'FAIL: stale revision';
  exception when sqlstate 'P1003' then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,saved,revision2,foreign_wallet,leaf_id,'1',current_date,'foreign','RUB',2);
    raise exception 'FAIL: foreign wallet';
  exception when insufficient_privilege then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,null,null,w1,expense_cat,'1',current_date,'wrong kind','RUB',2);
    raise exception 'FAIL: expense category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,null,null,w1,leaf_id,'0',current_date,'zero','RUB',2);
    raise exception 'FAIL: zero';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,null,null,w1,leaf_id,'9223372036854775808',current_date,'overflow','RUB',2);
    raise exception 'FAIL: overflow';
  exception when numeric_value_out_of_range then null; end;
  for i in 1..30 loop
    perform public.save_income(gen_random_uuid(),scope,null,null,w1,leaf_id,'9007199254740993',date '2026-10-01','history','RUB',2);
  end loop;
  perform public.save_income(gen_random_uuid(),scope,null,null,usd,root_id,'200',date '2026-10-01','USD','USD',2);
  perform public.save_income(gen_random_uuid(),scope,null,null,usd_whole,root_id,'2',date '2026-10-01','whole USD','USD',0);
  update public.categories set is_archived=true where id=root_id;
  result:=public.query_incomes(scope,array[w1],array[root_id,leaf_id],date '2026-10-01',date '2026-10-01',null,null,true);
  if jsonb_array_length(result->'items')<>26 or result->'totals'->0->>'amount_minor'<>'270215977642229790' then raise exception 'FAIL: filters and full exact total'; end if;
  next_page:=public.query_incomes(scope,array[w1],array[root_id,leaf_id],date '2026-10-01',date '2026-10-01',
    (result->'items'->24->>'expense_date')::date,(result->'items'->24->>'id')::uuid,false);
  if jsonb_array_length(next_page->'items')<>5 or next_page->'totals'<>'[]'::jsonb then raise exception 'FAIL: pagination'; end if;
  result:=public.query_incomes(scope,p_include_totals=>true);
  if jsonb_array_length(result->'totals')<>2 then raise exception 'FAIL: currencies'; end if;
  if result->'totals'->1->>'currency'<>'USD' or result->'totals'->1->>'amount_minor'<>'400'
    or result->'totals'->1->>'currency_scale'<>'2' then raise exception 'FAIL: mixed income scales'; end if;
  if public.query_incomes(scope,p_from=>date '2200-01-01',p_include_totals=>true)<>jsonb_build_object('items','[]'::jsonb,'totals','[]'::jsonb)
    then raise exception 'FAIL: empty income filters'; end if;
  -- Existing archived category may be retained; assigning it to a new income is forbidden.
  perform public.save_income(gen_random_uuid(),scope,saved,revision2,w2,leaf_id,'30000',date '1900-01-01','retained','RUB',2);
  begin
    perform public.save_income(gen_random_uuid(),scope,null,null,w1,leaf_id,'1',current_date,'archived','RUB',2);
    raise exception 'FAIL: archived assignment';
  exception when sqlstate 'P1001' then null; end;
  execute 'reset role';
  foreach owner_id in array array[manager,outsider] loop
    perform set_config('request.jwt.claim.sub',owner_id::text,true);
    execute 'set local role authenticated';
    if exists(select 1 from public.incomes where space_id=scope) then raise exception 'FAIL: income RLS'; end if;
    begin
      perform public.query_incomes(scope);
      raise exception 'FAIL: query access';
    exception when insufficient_privilege then null; end;
    begin
      perform public.save_income(gen_random_uuid(),scope,null,null,w1,leaf_id,'1',current_date,'denied','RUB',2);
      raise exception 'FAIL: save access';
    exception when insufficient_privilege then null; end;
    begin
      perform public.space_balances(scope);
      raise exception 'FAIL: balances access';
    exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
  raise notice 'PASS: incomes, replay, conflicts, dates, exact totals, filters, pagination and access';
end $test$;
rollback;
