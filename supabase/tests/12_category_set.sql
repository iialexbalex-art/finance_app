-- После 001–012, целиком как postgres. Агентом не запускался. Данные откатываются.
begin;
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000131';
  manager_id uuid:='00000000-0000-4000-8000-000000000132';
  outsider_id uuid:='00000000-0000-4000-8000-000000000133';
  scope uuid:='10000000-0000-4000-8000-000000000131';
  archive_scope uuid:='10000000-0000-4000-8000-000000000132';
  other_scope uuid:='10000000-0000-4000-8000-000000000133';
  wallet_id uuid; food_id uuid; bonus_a uuid; bonus_b uuid; parking_id uuid; toll_id uuid;
  archived_parent uuid;
  expense_id uuid; response jsonb; before_expense jsonb; before_balance jsonb; affected integer;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if (select count(*) from finance_private.category_set_items where set_version='category_set_2026_10_01' and kind='expense')<>130
    or (select count(*) from finance_private.category_set_items where set_version='category_set_2026_10_01' and kind='income')<>16
    or (select count(distinct icon_id) from finance_private.category_set_items where set_version='category_set_2026_10_01')<>146
    or (select count(*) from finance_private.category_set_items where set_version='category_set_2026_10_01' and name='Наставничество')<>2
    then raise exception 'FAIL: registry counts, icon IDs or separate mentoring categories'; end if;
  if has_function_privilege('authenticated','finance_private.install_category_set_2026_10_01(uuid)','EXECUTE')
    or has_table_privilege('authenticated','finance_private.category_set_items','SELECT')
    then raise exception 'FAIL: importer exposed to application roles'; end if;

  insert into auth.users(id) values(owner_id),(manager_id),(outsider_id);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (scope,owner_id,'business','Target'),(archive_scope,owner_id,'personal','Archive conflicts'),(other_scope,outsider_id,'personal','Other');
  insert into public.space_members(space_id,user_id) values(scope,manager_id);
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Cash','cash','RUB') returning id into wallet_id;
  -- One exact match is reused; multiple normalized matches are reported and untouched.
  insert into public.categories(space_id,kind,name,icon_id) values(scope,'expense','  Еда  ','category') returning id into food_id;
  insert into public.categories(space_id,kind,name) values(scope,'income','Бонусы') returning id into bonus_a;
  insert into public.categories(space_id,kind,name) values(scope,'income',' бонусы ') returning id into bonus_b;
  insert into public.categories(space_id,kind,name) values(other_scope,'expense','Foreign sentinel');

  perform set_config('request.jwt.claim.sub',owner_id::text,true); execute 'set local role authenticated';
  expense_id:=public.create_expense(gen_random_uuid(),scope,wallet_id,food_id,'12345',date '2026-10-01','unchanged');
  before_balance:=public.space_balances(scope);
  execute 'reset role';
  select to_jsonb(e) into before_expense from public.expenses e where id=expense_id;

  response:=finance_private.install_category_set_2026_10_01(scope);
  if response->>'created'<>'144' or response->>'reused'<>'1' or response->>'ambiguous'<>'1' or response->>'skipped'<>'0'
    or response->>'archived_conflicts'<>'0' or jsonb_array_length(response->'ambiguities')<>1
    or jsonb_array_length(response->'conflicts')<>0 then raise exception 'FAIL: first import result %',response; end if;
  if (select count(*) from finance_private.category_set_imports where space_id=scope and set_version='category_set_2026_10_01')<>145
    or (select count(*) from public.categories where space_id=scope and kind='expense')<>130
    or (select count(*) from public.categories where space_id=scope and kind='income')<>17
    or (select icon_id from public.categories where id=food_id)<>'category'
    then raise exception 'FAIL: created/reused/ambiguous category state'; end if;
  if (select count(*) from public.categories where space_id=other_scope)<>1 then raise exception 'FAIL: foreign space changed'; end if;

  select category_id into parking_id from finance_private.category_set_imports where space_id=scope and set_key='exp_parking';
  select category_id into toll_id from finance_private.category_set_imports where space_id=scope and set_key='exp_toll_road';
  update public.categories set name='Моя парковка',icon_id='future_icon',parent_id=food_id where id=parking_id;
  delete from public.categories where id=toll_id;
  response:=finance_private.install_category_set_2026_10_01(scope);
  if response->>'created'<>'0' or response->>'reused'<>'0' or response->>'skipped'<>'145' or response->>'ambiguous'<>'1'
    or response->>'archived_conflicts'<>'0'
    or not exists(select 1 from public.categories where id=parking_id and name='Моя парковка' and icon_id='future_icon' and parent_id=food_id)
    or exists(select 1 from public.categories where id=toll_id)
    or exists(select 1 from public.categories where space_id=scope and kind='expense' and name='Платная дорога')
    then raise exception 'FAIL: idempotency restored deletion or reset edit: %',response; end if;

  -- An archived exact match and a match below an archived parent are explicit,
  -- unresolved conflicts. Neither is duplicated or written to the import ledger.
  insert into public.categories(space_id,kind,name,is_archived) values(archive_scope,'expense','Парковка',true) returning id into parking_id;
  insert into public.categories(space_id,kind,name,is_archived) values(archive_scope,'expense','Архивная ветвь',false) returning id into archived_parent;
  insert into public.categories(space_id,kind,name,parent_id) values(archive_scope,'expense','Платная дорога',archived_parent) returning id into toll_id;
  update public.categories set is_archived=true where id=archived_parent;
  response:=finance_private.install_category_set_2026_10_01(archive_scope);
  if response->>'created'<>'144' or response->>'reused'<>'0' or response->>'ambiguous'<>'0' or response->>'skipped'<>'0'
    or response->>'archived_conflicts'<>'2' or jsonb_array_length(response->'conflicts')<>2
    or not exists(select 1 from jsonb_array_elements(response->'conflicts') c
      where c->>'set_key'='exp_parking' and c->'matches'->0->>'reason'='category_archived')
    or not exists(select 1 from jsonb_array_elements(response->'conflicts') c
      where c->>'set_key'='exp_toll_road' and c->'matches'->0->>'reason'='archived_ancestor')
    or exists(select 1 from finance_private.category_set_imports where space_id=archive_scope and set_key in('exp_parking','exp_toll_road'))
    or (select count(*) from public.categories where space_id=archive_scope and name in('Парковка','Платная дорога'))<>2
    then raise exception 'FAIL: archived category/ancestor conflict: %',response; end if;
  update public.categories set is_archived=false where id in(parking_id,archived_parent);
  response:=finance_private.install_category_set_2026_10_01(archive_scope);
  if response->>'created'<>'0' or response->>'reused'<>'2' or response->>'skipped'<>'144' or response->>'ambiguous'<>'0'
    or response->>'archived_conflicts'<>'0'
    or (select category_id from finance_private.category_set_imports where space_id=archive_scope and set_key='exp_parking')<>parking_id
    or (select category_id from finance_private.category_set_imports where space_id=archive_scope and set_key='exp_toll_road')<>toll_id
    then raise exception 'FAIL: resolved archive conflicts not completed: %',response; end if;
  if (select to_jsonb(e) from public.expenses e where id=expense_id) is distinct from before_expense
    then raise exception 'FAIL: financial operation changed'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true); execute 'set local role authenticated';
  if public.space_balances(scope) is distinct from before_balance then raise exception 'FAIL: balance changed'; end if;
  execute 'reset role';

  foreach owner_id in array array[manager_id,outsider_id] loop
    perform set_config('request.jwt.claim.sub',owner_id::text,true); execute 'set local role authenticated';
    begin perform finance_private.install_category_set_2026_10_01(scope); raise exception 'FAIL: importer execution'; exception when insufficient_privilege then null; end;
    begin perform count(*) from finance_private.category_set_items; raise exception 'FAIL: registry read'; exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
  raise notice 'PASS: 130+16 exact registry, archive conflicts and resolution, scoped idempotency, ambiguity, deletion/edit preservation, finances and access';
end $test$;
rollback;
