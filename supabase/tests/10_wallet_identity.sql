-- После 001–010, целиком как postgres. Агентом не запускался. Данные откатываются.
begin;
do $test$
declare
  owner_id uuid:='00000000-0000-4000-8000-000000000111';
  manager_id uuid:='00000000-0000-4000-8000-000000000112';
  outsider_id uuid:='00000000-0000-4000-8000-000000000113';
  scope uuid:='10000000-0000-4000-8000-000000000111';
  other_scope uuid:='10000000-0000-4000-8000-000000000113';
  cash uuid; card uuid; bank uuid; e_root uuid; e_child uuid; e_leaf uuid;
  i_root uuid; i_child uuid; i_leaf uuid; other_cat uuid;
  expense_id uuid; income_id uuid; transfer_id uuid; manager_expense uuid;
  e_request uuid:=gen_random_uuid(); i_request uuid:=gen_random_uuid(); t_request uuid:=gen_random_uuid();
  p jsonb; before_expenses jsonb; before_incomes jsonb; before_transfers jsonb;
  before_receipts jsonb; before_create_receipts jsonb; before_balance jsonb;
  affected integer; actor uuid;
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if has_column_privilege('authenticated','public.categories','kind','UPDATE')
    or has_column_privilege('authenticated','public.wallets','currency','UPDATE')
    or has_column_privilege('authenticated','public.wallets','currency_scale','UPDATE')
    or has_table_privilege('anon','public.wallets','SELECT')
    then raise exception 'FAIL: immutable columns/access'; end if;
  insert into auth.users(id) values(owner_id),(manager_id),(outsider_id);
  insert into public.spaces(id,owner_user_id,kind,name) values(scope,owner_id,'business','Identity'),(other_scope,outsider_id,'personal','Other');
  insert into public.categories(space_id,kind,name) values(other_scope,'expense','Other') returning id into other_cat;
  insert into public.space_members(space_id,user_id) values(scope,manager_id);
  perform set_config('request.jwt.claim.sub',owner_id::text,true); execute 'set local role authenticated';
  -- Legacy INSERTs without icon_id remain valid and do not infer bank from names.
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Сбербанк','cash','RUB') returning id into cash;
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Card','card','RUB') returning id into card;
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Bank','bank_account','USD') returning id into bank;
  if (select icon_id from public.wallets where id=cash)<>'cash'
    or (select icon_id from public.wallets where id=card)<>'card'
    or (select icon_id from public.wallets where id=bank)<>'bank' then raise exception 'FAIL: defaults'; end if;
  insert into public.categories(space_id,kind,name) values(scope,'expense','Same') returning id into e_root;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'expense','Child',e_root) returning id into e_child;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'expense','Leaf',e_child) returning id into e_leaf;
  insert into public.categories(space_id,kind,name) values(scope,'income','Same') returning id into i_root;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'income','Child',i_root) returning id into i_child;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'income','Leaf',i_child) returning id into i_leaf;
  begin
    update public.categories set parent_id=i_root where id=e_child;
    raise exception 'FAIL: cross-kind parent';
  exception when check_violation or foreign_key_violation then null; end;
  begin
    update public.categories set parent_id=other_cat where id=e_child;
    raise exception 'FAIL: cross-space parent';
  exception when check_violation or foreign_key_violation then null; end;
  begin
    insert into public.categories(space_id,kind,name,parent_id) values(scope,'income','Fourth',i_leaf);
    raise exception 'FAIL: fourth level';
  exception when check_violation then null; end;
  expense_id:=public.create_expense(e_request,scope,cash,e_leaf,'100',date '2026-10-01','Expense');
  income_id:=public.save_income(i_request,scope,null,null,cash,i_leaf,'500',date '2026-10-01','Income','RUB',2);
  p:=jsonb_build_object('space_id',scope,'id',null,'revision',null,'source_id',cash,'target_id',card,
    'source_minor','200','target_minor','200','source_currency','RUB','target_currency','RUB','source_scale',2,'target_scale',2,
    'date','2026-10-01','comment','Transfer','fee_minor','10','fee_category_id',e_leaf);
  transfer_id:=public.save_transfer(t_request,p);
  begin
    perform public.create_expense(gen_random_uuid(),scope,cash,i_leaf,'100',current_date,'wrong');
    raise exception 'FAIL: expense with income category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.save_income(gen_random_uuid(),scope,null,null,cash,e_leaf,'100',current_date,'wrong','RUB',2);
    raise exception 'FAIL: income with expense category';
  exception when sqlstate 'P1001' then null; end;
  begin
    perform public.save_transfer(gen_random_uuid(),p||jsonb_build_object('fee_category_id',i_leaf));
    raise exception 'FAIL: fee with income category';
  exception when sqlstate 'P1001' then null; end;
  begin
    update public.categories set kind='income' where id=e_leaf;
    raise exception 'FAIL: changing linked category kind';
  exception when insufficient_privilege then null; end;
  update public.categories set parent_id=null where id=e_leaf;
  update public.categories set parent_id=e_child where id=e_leaf;
  update public.categories set is_archived=true where id=e_root;
  if public.query_expenses(scope,p_category_ids=>array[e_root,e_leaf],p_include_totals=>true)->'totals'->0->>'amount_minor'<>'110'
    or public.query_incomes(scope,p_category_ids=>array[e_root],p_include_totals=>true)->'items'<>'[]'::jsonb
    or public.query_expenses(scope,p_category_ids=>array[i_root])->'items'<>'[]'::jsonb
    or public.query_incomes(scope,p_category_ids=>array[i_root,i_leaf],p_include_totals=>true)->'totals'->0->>'amount_minor'<>'500'
    then raise exception 'FAIL: independent filters and preserved links'; end if;
  update public.categories set is_archived=false where id=e_root;
  before_balance:=public.space_balances(scope);
  execute 'reset role';
  select jsonb_agg(to_jsonb(e) order by id) into before_expenses from public.expenses e where space_id=scope;
  select jsonb_agg(to_jsonb(i) order by id) into before_incomes from public.incomes i where space_id=scope;
  select jsonb_agg(to_jsonb(t) order by id) into before_transfers from public.transfers t where space_id=scope;
  select jsonb_agg(to_jsonb(r) order by request_id) into before_receipts from finance_private.operation_receipts r where actor_id=owner_id;
  select jsonb_agg(to_jsonb(r) order by request_id) into before_create_receipts from finance_private.expense_creation_receipts r where author_id=owner_id;
  execute 'set local role authenticated';
  update public.wallets set name='New source',icon_id='bank_kaspi' where id=cash;
  update public.wallets set name='New target',icon_id='piggy' where id=card;
  -- Only current wallet metadata changes. Old APIs and replay keep audit snapshots.
  if public.create_expense(e_request,scope,cash,e_leaf,'100',date '2026-10-01','Expense')<>expense_id
    or public.save_income(i_request,scope,null,null,cash,i_leaf,'500',date '2026-10-01','Income','RUB',2)<>income_id
    or public.save_transfer(t_request,p)<>transfer_id then raise exception 'FAIL: replay after rename'; end if;
  if exists(select 1 from jsonb_array_elements(before_balance) old
    join jsonb_array_elements(public.space_balances(scope)) now on old->>'id'=now->>'id'
    where old->'balance'<>now->'balance') then raise exception 'FAIL: balance changed'; end if;
  if not exists(select 1 from jsonb_array_elements(public.space_balances(scope)) w
    where w->>'id'=cash::text and w->>'name'='New source' and w->>'icon_id'='bank_kaspi') then raise exception 'FAIL: overview metadata'; end if;
  -- Future catalog IDs accepted, paths/URLs rejected. A new icon does not change group.
  update public.wallets set icon_id='future_icon' where id=bank;
  begin
    update public.wallets set icon_id='https://external/image.png' where id=bank;
    raise exception 'FAIL: invalid icon ID';
  exception when check_violation then null; end;
  execute 'reset role';
  if (select jsonb_agg(to_jsonb(e) order by id) from public.expenses e where space_id=scope) is distinct from before_expenses
    or (select jsonb_agg(to_jsonb(i) order by id) from public.incomes i where space_id=scope) is distinct from before_incomes
    or (select jsonb_agg(to_jsonb(t) order by id) from public.transfers t where space_id=scope) is distinct from before_transfers
    or (select jsonb_agg(to_jsonb(r) order by request_id) from finance_private.operation_receipts r where actor_id=owner_id) is distinct from before_receipts
    or (select jsonb_agg(to_jsonb(r) order by request_id) from finance_private.expense_creation_receipts r where author_id=owner_id) is distinct from before_create_receipts
    then raise exception 'FAIL: transaction, revision or receipt mutated'; end if;
  insert into public.wallet_assignments(space_id,wallet_id,user_id) values(scope,cash,manager_id);
  perform set_config('request.jwt.claim.sub',manager_id::text,true); execute 'set local role authenticated';
  manager_expense:=public.create_expense(gen_random_uuid(),scope,cash,e_leaf,'1',current_date,'Manager');
  if (select count(*) from public.wallets where space_id=scope)<>1
    or not exists(select 1 from public.wallets where id=cash and name='New source' and icon_id='bank_kaspi')
    or exists(select 1 from public.categories where space_id=scope and kind='income')
    or jsonb_array_length(public.query_expenses(scope)->'items')<>1 then raise exception 'FAIL: manager visibility'; end if;
  execute 'reset role';
  foreach actor in array array[manager_id,outsider_id] loop
    perform set_config('request.jwt.claim.sub',actor::text,true); execute 'set local role authenticated';
    update public.wallets set name='Intrusion',icon_id='safe' where id=cash;
    get diagnostics affected=row_count;
    if affected<>0 then raise exception 'FAIL: unauthorized metadata write'; end if;
    begin perform public.space_balances(scope); raise exception 'FAIL: balances access'; exception when insufficient_privilege then null; end;
    begin perform public.query_incomes(scope); raise exception 'FAIL: incomes access'; exception when insufficient_privilege then null; end;
    begin perform public.query_transfers(scope); raise exception 'FAIL: transfers access'; exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
  raise notice 'PASS: category kinds, identity, wallet metadata, replay, balances and RLS';
end $test$;
rollback;
