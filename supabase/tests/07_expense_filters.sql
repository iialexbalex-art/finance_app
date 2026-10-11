-- Выполнить целиком как postgres после 001–007 в тестовом проекте.
-- Агентом не запускался. Фиктивные данные полностью откатываются.
begin;
do $test$
declare
  owner_id uuid := '00000000-0000-4000-8000-000000000081';
  manager uuid := '00000000-0000-4000-8000-000000000082';
  outsider uuid := '00000000-0000-4000-8000-000000000083';
  space uuid := '10000000-0000-4000-8000-000000000081';
  other_space uuid := '10000000-0000-4000-8000-000000000083';
  rub uuid := '20000000-0000-4000-8000-000000000081';
  usd uuid := '20000000-0000-4000-8000-000000000082';
  usd_whole uuid := '20000000-0000-4000-8000-000000000084';
  root_id uuid; leaf_id uuid; foreign_cat uuid;
  result jsonb; next_page jsonb; cursor_row jsonb; own_expense uuid;
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
  if has_function_privilege('anon','public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean)','EXECUTE')
    or (select prosecdef from pg_proc where oid='public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean)'::regprocedure)
  then raise exception 'FAIL: query privileges'; end if;
  insert into auth.users(id) values(owner_id),(manager),(outsider);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (space,owner_id,'business','Filters'),(other_space,outsider,'personal','Other');
  insert into public.wallets(id,space_id,name,wallet_group,currency) values
    (rub,space,'Cash','cash','RUB'),(usd,space,'Card','card','USD');
  insert into public.wallets(id,space_id,name,wallet_group,currency,currency_scale)
    values(usd_whole,space,'Whole USD','cash','USD',0);
  insert into public.space_members(space_id,user_id) values(space,manager);
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(space,rub,manager);
  insert into public.categories(space_id,kind,name) values(space,'expense','Root') returning id into root_id;
  insert into public.categories(space_id,kind,name,parent_id) values(space,'expense','Leaf',root_id) returning id into leaf_id;
  insert into public.categories(space_id,kind,name) values(other_space,'expense','Other') returning id into foreign_cat;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  for i in 1..30 loop
    perform public.create_expense(gen_random_uuid(),space,rub,leaf_id,'9007199254740993',date '2026-09-30','row');
  end loop;
  perform public.create_expense(gen_random_uuid(),space,usd,root_id,'500',date '2026-10-01','USD');
  perform public.create_expense(gen_random_uuid(),space,usd_whole,root_id,'2',date '2026-10-01','USD whole');
  perform public.create_expense(gen_random_uuid(),space,rub,root_id,'100',date '2026-09-01','start');
  perform public.create_expense(gen_random_uuid(),space,rub,root_id,'200',date '2026-08-31','outside');
  update public.categories set is_archived=true where id=root_id;
  result := public.query_expenses(space,array[rub],array[root_id,leaf_id,root_id],date '2026-09-01',date '2026-09-30',null,null,true);
  if jsonb_array_length(result->'items')<>26
    or result->'totals'->0->>'amount_minor'<>'270215977642229890'
    or jsonb_array_length(result->'totals')<>1
  then raise exception 'FAIL: full-history total, precision, inclusive period or overlapping archived branches: %',result; end if;
  -- Client displays 25, the 26th row is only a hasMore sentinel.
  cursor_row := result->'items'->24;
  next_page := public.query_expenses(space,array[rub],array[root_id,leaf_id],date '2026-09-01',date '2026-09-30',
    (cursor_row->>'expense_date')::date,(cursor_row->>'id')::uuid,false);
  if jsonb_array_length(next_page->'items')<>6 or jsonb_array_length(next_page->'totals')<>0
    or exists(select 1 from jsonb_array_elements(next_page->'items') n
      join jsonb_array_elements(result->'items') with ordinality p(item,position)
      on n->>'id'=p.item->>'id' where p.position<=25)
  then raise exception 'FAIL: cursor pagination'; end if;
  result := public.query_expenses(space,p_include_totals=>true);
  if jsonb_array_length(result->'totals')<>2 then raise exception 'FAIL: currency totals'; end if;
  if result->'totals'->1->>'amount_minor'<>'700' or result->'totals'->1->>'currency'<>'USD'
    or result->'totals'->1->>'currency_scale'<>'2' then raise exception 'FAIL: mixed scales'; end if;
  result := public.query_expenses(space,p_wallet_ids=>array[usd,usd_whole],p_include_totals=>true);
  if jsonb_array_length(result->'items')<>2 or jsonb_array_length(result->'totals')<>1
    or result->'totals'->0->>'amount_minor'<>'700' then raise exception 'FAIL: multiple wallets'; end if;
  result := public.query_expenses(space,p_category_ids=>array[foreign_cat],p_include_totals=>true);
  if result->'items'<>'[]'::jsonb or result->'totals'<>'[]'::jsonb then raise exception 'FAIL: foreign category filter'; end if;
  result := public.query_expenses(space,p_from=>date '2027-01-01',p_include_totals=>true);
  if result->'items'<>'[]'::jsonb or result->'totals'<>'[]'::jsonb then raise exception 'FAIL: empty result'; end if;
  begin
    perform public.query_expenses(space,p_from=>date '2026-10-01',p_to=>date '2026-09-01');
    raise exception 'FAIL: reversed dates';
  exception when sqlstate '22023' then null; end;
  update public.categories set is_archived=false where id=root_id;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  own_expense := public.create_expense(gen_random_uuid(),space,rub,leaf_id,'50',date '2026-09-30','manager');
  result := public.query_expenses(space,p_category_ids=>array[root_id]);
  if jsonb_array_length(result->'items')<>1 or result->'items'->0->>'id'<>own_expense::text
    or result->'totals'<>'[]'::jsonb then raise exception 'FAIL: manager history boundary'; end if;
  result := public.query_expenses(space,p_wallet_ids=>array[usd]);
  if result->'items'<>'[]'::jsonb then raise exception 'FAIL: manager wallet boundary'; end if;
  begin
    perform public.query_expenses(space,p_include_totals=>true);
    raise exception 'FAIL: manager totals';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  delete from public.wallet_assignments where user_id=manager;
  execute 'set local role authenticated';
  result := public.query_expenses(space);
  if result->'items'<>'[]'::jsonb then raise exception 'FAIL: revoked assignment'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  execute 'set local role authenticated';
  result := public.query_expenses(space);
  if result->'items'<>'[]'::jsonb then raise exception 'FAIL: foreign history'; end if;
  begin
    perform public.query_expenses(space,p_include_totals=>true);
    raise exception 'FAIL: foreign totals';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'PASS: filters, archived descendants, pagination, exact totals, RLS';
end
$test$;
rollback;
