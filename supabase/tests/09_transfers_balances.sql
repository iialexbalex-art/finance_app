-- После 001–009. Выполнить целиком как postgres в тестовом проекте. ROLLBACK в конце.
begin;
create function pg_temp.reject_test_fee() returns trigger language plpgsql as $$
begin
  if new.transfer_id is not null and current_setting('finance_test.reject_fee',true)='yes' then
    raise exception using errcode='P1999',message='Injected fee failure';
  end if;
  return new;
end $$;
create trigger test_reject_fee before insert or update on public.expenses for each row execute function pg_temp.reject_test_fee();
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000101';
  manager uuid:='00000000-0000-4000-8000-000000000102';
  outsider uuid:='00000000-0000-4000-8000-000000000103';
  scope uuid:='10000000-0000-4000-8000-000000000101';
  other_scope uuid:='10000000-0000-4000-8000-000000000103';
  w1 uuid:='20000000-0000-4000-8000-000000000101';
  w2 uuid:='20000000-0000-4000-8000-000000000102';
  usd uuid:='20000000-0000-4000-8000-000000000103';
  foreign_wallet uuid:='20000000-0000-4000-8000-000000000104';
  cat uuid; income_cat uuid; saved uuid; fee_id uuid; fee_revision uuid; manager_expense uuid;
  create_req uuid:=gen_random_uuid(); edit_req uuid:=gen_random_uuid(); retry_req uuid:=gen_random_uuid();
  payload jsonb; edited jsonb; original jsonb; result jsonb; page2 jsonb; revision1 uuid; revision2 uuid;
  actor uuid; before_balance jsonb; before_count integer;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if has_table_privilege('authenticated','public.transfers','INSERT') or has_any_column_privilege('authenticated','public.transfers','UPDATE')
    or has_table_privilege('authenticated','public.transfers','DELETE')
    or has_function_privilege('authenticated','finance_private.edit_expense(uuid,uuid,uuid,uuid,uuid,uuid,text,date,text,text,integer)','EXECUTE')
    or has_function_privilege('anon','public.save_transfer(uuid,jsonb)','EXECUTE') then raise exception 'FAIL: privileges'; end if;
  insert into auth.users(id) values(owner_id),(manager),(outsider);
  insert into public.spaces(id,owner_user_id,kind,name) values(scope,owner_id,'business','Transfers'),(other_scope,outsider,'personal','Other');
  insert into public.wallets(id,space_id,name,wallet_group,currency) values
    (w1,scope,'Source','cash','RUB'),(w2,scope,'Target','card','RUB'),(usd,scope,'USD','cash','USD'),(foreign_wallet,other_scope,'Other','cash','RUB');
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(w1,1000000),(w2,200000);
  insert into public.space_members(space_id,user_id) values(scope,manager);
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(scope,w1,manager);
  insert into public.categories(space_id,kind,name) values(scope,'expense','Fees') returning id into cat;
  insert into public.categories(space_id,kind,name) values(scope,'income','Income') returning id into income_cat;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  payload:=jsonb_build_object('space_id',scope,'id',null,'revision',null,'source_id',w1,'target_id',w2,
    'source_minor','100000','target_minor','100000','source_currency','RUB','target_currency','RUB','source_scale',2,'target_scale',2,
    'date','2150-10-01','comment','Перевод 100%','fee_minor','1000','fee_category_id',cat);
  saved:=public.save_transfer(create_req,payload);
  select revision,to_jsonb(t) into revision1,original from public.transfers t where id=saved;
  select id,revision into fee_id,fee_revision from public.expenses where transfer_id=saved;
  if public.wallet_expense_balance(w1)->>'current_minor'<>'899000' or public.wallet_expense_balance(w2)->>'current_minor'<>'300000'
    or public.wallet_expense_balance(w1)->>'expense_minor'<>'1000' then raise exception 'FAIL: transfer + fee balances'; end if;
  if public.query_expenses(scope,p_include_totals=>true)->'totals'->0->>'amount_minor'<>'1000'
    or public.query_incomes(scope,p_include_totals=>true)->'totals'<>'[]'::jsonb then raise exception 'FAIL: transfer entered cash flow totals'; end if;
  begin
    perform public.edit_expense(gen_random_uuid(),scope,fee_id,fee_revision,w1,cat,'2',current_date,'independent','RUB',2);
    raise exception 'FAIL: independent fee edit';
  exception when sqlstate 'P1005' then null; end;
  -- Move BOTH sides, switch currency, and edit commission atomically.
  edited:=payload||jsonb_build_object('id',saved,'revision',revision1,'source_id',w2,'target_id',usd,
    'source_minor','200000','target_minor','2000','target_currency','USD','fee_minor','2000');
  perform public.save_transfer(edit_req,edited);
  select revision into revision2 from public.transfers where id=saved;
  if public.wallet_expense_balance(w1)->>'current_minor'<>'1000000' or public.wallet_expense_balance(w2)->>'current_minor'<>'-2000'
    or public.wallet_expense_balance(usd)->>'current_minor'<>'2000'
    or (select wallet_id from public.expenses where id=fee_id)<>w2
    or (select author_id::text<>original->>'author_id' or created_at::text<>(original->>'created_at')::timestamptz::text from public.transfers where id=saved)
  then raise exception 'FAIL: moving transfer, fee or identity'; end if;
  if public.save_transfer(create_req,payload)<>saved or public.save_transfer(edit_req,edited)<>saved
    or (select revision from public.transfers where id=saved)<>revision2 then raise exception 'FAIL: replay after edit'; end if;
  begin
    perform public.save_transfer(create_req,payload||jsonb_build_object('comment','changed'));
    raise exception 'FAIL: request mismatch';
  exception when sqlstate 'P1002' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),edited);
    raise exception 'FAIL: revision conflict';
  exception when sqlstate 'P1003' then null; end;
  -- Remove fee, then restore it: one linked expense ID, never an extra debit.
  edited:=edited||jsonb_build_object('revision',revision2,'fee_minor','0','fee_category_id',null);
  perform public.save_transfer(gen_random_uuid(),edited);
  if exists(select 1 from public.expenses where transfer_id=saved) or public.wallet_expense_balance(w2)->>'current_minor'<>'0'
    then raise exception 'FAIL: removed fee still counted'; end if;
  edited:=edited||jsonb_build_object('revision',(select revision from public.transfers where id=saved),'fee_minor','500','fee_category_id',cat);
  perform public.save_transfer(gen_random_uuid(),edited);
  if (select id from public.expenses where transfer_id=saved)<>fee_id or public.wallet_expense_balance(w2)->>'current_minor'<>'-500'
    then raise exception 'FAIL: restoring fee duplicated'; end if;
  -- Deliberate failure AFTER transfer write, in the fee trigger. Everything must roll back.
  before_balance:=public.wallet_expense_balance(w1);select count(*) into before_count from public.transfers;
  perform set_config('finance_test.reject_fee','yes',true);
  begin
    perform public.save_transfer(retry_req,payload);
    raise exception 'FAIL: injected failure did not fire';
  exception when sqlstate 'P1999' then null; end;
  perform set_config('finance_test.reject_fee','no',true);
  if public.wallet_expense_balance(w1)<>before_balance or (select count(*) from public.transfers)<>before_count then raise exception 'FAIL: partial transaction'; end if;
  perform public.save_transfer(retry_req,payload);
  -- Failed edits must roll back transfer revision and fee as well.
  edited:=edited||jsonb_build_object('revision',(select revision from public.transfers where id=saved),'fee_minor','600');
  select revision into revision2 from public.transfers where id=saved;
  perform set_config('finance_test.reject_fee','yes',true);
  begin
    perform public.save_transfer(gen_random_uuid(),edited);
    raise exception 'FAIL: edit injection';
  exception when sqlstate 'P1999' then null; end;
  perform set_config('finance_test.reject_fee','no',true);
  if (select revision from public.transfers where id=saved)<>revision2 or (select amount_minor from public.expenses where id=fee_id)<>500 then raise exception 'FAIL: partial edit'; end if;
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('target_id',w1));
    raise exception 'FAIL: same wallet';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('target_minor','99999'));
    raise exception 'FAIL: unequal RUB';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('target_id',foreign_wallet));
    raise exception 'FAIL: cross-space';
  exception when insufficient_privilege then null; end;
  for i in 1..30 loop
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('date','2026-10-01','comment','page_100%','fee_minor','0','fee_category_id',null));
  end loop;
  result:=public.query_transfers(scope,array[w1,w2],date '2026-10-01',date '2026-10-01','100%');
  if jsonb_array_length(result)<>26 then raise exception 'FAIL: filter both sides duplicates or missing'; end if;
  page2:=public.query_transfers(scope,array[w1,w2],date '2026-10-01',date '2026-10-01','100%',(result->24->>'transfer_date')::date,(result->24->>'id')::uuid);
  if jsonb_array_length(page2)<>5 or exists(select 1 from jsonb_array_elements(page2) n join
    jsonb_array_elements(result) with ordinality p(item,pos) on n->>'id'=p.item->>'id' where pos<=25) then raise exception 'FAIL: transfer pagination'; end if;
  if public.query_transfers(scope,p_search=>'not present')<>'[]'::jsonb then raise exception 'FAIL: literal search'; end if;
  -- Owner's income and manager's ordinary expense contribute independently.
  perform public.save_income(gen_random_uuid(),scope,null,null,w1,income_cat,'1000',date '2026-10-01','income','RUB',2);
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',manager::text,true);execute 'set local role authenticated';
  manager_expense:=public.create_expense(gen_random_uuid(),scope,w1,cat,'100',date '2026-10-01','ordinary expense');
  result:=public.query_expenses(scope);
  if jsonb_array_length(result->'items')<>1 or result->'items'->0->>'id'<>manager_expense::text then raise exception 'FAIL: manager sees owner commission'; end if;
  execute 'reset role';
  foreach actor in array array[manager,outsider] loop
    perform set_config('request.jwt.claim.sub',actor::text,true);execute 'set local role authenticated';
    if exists(select 1 from public.transfers) then raise exception 'FAIL: transfer RLS'; end if;
    begin perform public.save_transfer(gen_random_uuid(),payload); raise exception 'FAIL: unauthorized save'; exception when insufficient_privilege then null; end;
    begin perform public.query_transfers(scope); raise exception 'FAIL: unauthorized history'; exception when insufficient_privilege then null; end;
    begin perform public.wallet_expense_balance(w1); raise exception 'FAIL: unauthorized balance'; exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
  -- 10,000 + 10 income - 1 ordinary expense - 10 fee - 1,000 transfer - 30*1,000 transfers.
  if public.wallet_expense_balance(w1)->>'current_minor'<>'-2100100'
    or public.wallet_expense_balance(w2)->>'current_minor'<>'3099500'
    or public.wallet_expense_balance(usd)->>'current_minor'<>'2000'
    or jsonb_array_length(public.space_balances(scope))<>3 then raise exception 'FAIL: final common balances'; end if;
  -- Extreme string amounts remain exact; this nested block rolls itself back.
  before_balance:=public.wallet_expense_balance(w1);
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object(
      'source_minor','9223372036854775807','target_minor','9223372036854775807','fee_minor','0','fee_category_id',null));
    if (public.wallet_expense_balance(w1)->>'current_minor')::numeric <>
      (before_balance->>'current_minor')::numeric-9223372036854775807::numeric
      then raise exception 'FAIL: transfer precision'; end if;
    raise exception using errcode='P1998',message='Rollback precision fixture';
  exception when sqlstate 'P1998' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('source_minor',100000));
    raise exception 'FAIL: numeric JSON money accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),payload||jsonb_build_object('fee_category_id',income_cat));
    raise exception 'FAIL: income category used for fee';
  exception when sqlstate 'P1001' then null; end;
  update public.categories set is_archived=true where id=cat;
  edited:=edited||jsonb_build_object('revision',(select revision from public.transfers where id=saved),'fee_minor','500');
  perform public.save_transfer(gen_random_uuid(),edited);
  begin
    perform public.save_transfer(gen_random_uuid(),payload);
    raise exception 'FAIL: new archived fee category';
  exception when sqlstate 'P1001' then null; end;
  if public.wallet_expense_balance(w1)<>before_balance then raise exception 'FAIL: fixture rollback or archived fee balance'; end if;
  execute 'reset role';
  raise notice 'PASS: transfers, FX, fees, atomic rollback, replay, conflicts, filters, balances, expense compatibility and RLS';
end $test$;
rollback;
