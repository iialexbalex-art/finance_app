-- Migration 016 required. All fixtures are rolled back. Run as postgres.
begin;
do $test$
declare
  actor uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); scope uuid;
  scope_kind text; flow_kind text; cat uuid; child uuid; replacement uuid;
  w uuid; target uuid; op uuid; second_op uuid; fee uuid; transfer uuid; fee_replacement uuid;
  create_req uuid; delete_req uuid; snapshot jsonb; rows jsonb; economic jsonb;
  payload jsonb; before_balance jsonb; result jsonb;
begin
  insert into auth.users(id) values(actor),(outsider);
  if has_table_privilege('authenticated','public.expenses','DELETE') or
    has_table_privilege('authenticated','public.incomes','DELETE') or
    has_table_privilege('authenticated','finance_private.bulk_action_receipts','SELECT') or
    has_function_privilege('anon','public.delete_cashflow(uuid,uuid,text,jsonb)','EXECUTE') then
    raise exception 'FAIL: rights'; end if;
  foreach scope_kind in array array['personal','business'] loop
    insert into public.spaces(owner_user_id,kind,name) values(actor,scope_kind,'Bulk QA') returning id into scope;
    insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Source','cash','RUB') returning id into w;
    insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Target','card','RUB') returning id into target;
    insert into public.wallet_opening_balances(wallet_id,amount_minor) values(w,100000);
    foreach flow_kind in array array['expense','income'] loop
      insert into public.categories(space_id,kind,name) values(scope,flow_kind,'Parent') returning id into cat;
      insert into public.categories(space_id,kind,name,parent_id) values(scope,flow_kind,'Child',cat) returning id into child;
      insert into public.categories(space_id,kind,name) values(scope,flow_kind,'Replacement') returning id into replacement;
      perform set_config('request.jwt.claim.sub',actor::text,true);
      execute 'set local role authenticated';
      create_req:=gen_random_uuid();
      if flow_kind='expense' then
        op:=public.create_expense(create_req,scope,w,child,'20000',current_date,'Keep economics');
        second_op:=public.create_expense(gen_random_uuid(),scope,w,replacement,'1000',current_date,'Second');
        select to_jsonb(e)-'category_id'-'revision' into economic from public.expenses e where id=op;
      else
        op:=public.save_income(create_req,scope,null,null,w,child,'50000',current_date,'Keep economics','RUB',2);
        second_op:=public.save_income(gen_random_uuid(),scope,null,null,w,replacement,'1000',current_date,'Second','RUB',2);
        select to_jsonb(e)-'category_id'-'revision' into economic from public.incomes e where id=op;
      end if;
      select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into snapshot from public.categories where space_id=scope and kind=flow_kind;
      perform public.reorder_categories(gen_random_uuid(),scope,flow_kind,null,array[replacement,cat],snapshot);
      if (select sort_order from public.categories where id=replacement)<>1 then raise exception 'FAIL: sibling order'; end if;
      begin
        perform public.mutate_categories(gen_random_uuid(),scope,flow_kind,'archive',array[cat,child],snapshot);
        raise exception 'FAIL: stale tree';
      exception when sqlstate 'P1003' then null; end;
      select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into snapshot from public.categories where space_id=scope and kind=flow_kind;
      begin
        perform public.reorder_categories(gen_random_uuid(),scope,flow_kind,null,array[replacement,child],snapshot);
        raise exception 'FAIL: cross-parent reorder';
      exception when sqlstate 'P1003' then null; end;
      perform public.mutate_categories(gen_random_uuid(),scope,flow_kind,'archive',array[cat,child],snapshot);
      select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into snapshot from public.categories where space_id=scope and kind=flow_kind;
      begin
        perform public.mutate_categories(gen_random_uuid(),scope,flow_kind,'restore',array[child],snapshot);
        raise exception 'FAIL: archived ancestor';
      exception when sqlstate 'P1011' then null; end;
      perform public.mutate_categories(gen_random_uuid(),scope,flow_kind,'restore',array[cat,child],snapshot);
      select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into snapshot from public.categories where space_id=scope and kind=flow_kind;
      before_balance:=public.wallet_expense_balance(w);
      begin
        perform public.mutate_categories(gen_random_uuid(),scope,flow_kind,'delete',array[cat,child],snapshot);
        raise exception 'FAIL: used category without replacement';
      exception when sqlstate 'P1012' then null; end;
      delete_req:=gen_random_uuid();
      result:=public.mutate_categories(delete_req,scope,flow_kind,'delete',array[cat,child],snapshot,jsonb_build_object(child,replacement));
      if public.mutate_categories(delete_req,scope,flow_kind,'delete',array[cat,child],snapshot,jsonb_build_object(child,replacement))<>result then raise exception 'FAIL: category retry'; end if;
      if exists(select 1 from public.categories where id in(cat,child)) or public.wallet_expense_balance(w)<>before_balance then raise exception 'FAIL: deletion/remap balance'; end if;
      if flow_kind='expense' then
        if (select to_jsonb(e)-'category_id'-'revision' from public.expenses e where id=op)<>economic then raise exception 'FAIL: expense economics'; end if;
        select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into rows from public.expenses where id in(op,second_op);
      else
        if (select to_jsonb(e)-'category_id'-'revision' from public.incomes e where id=op)<>economic then raise exception 'FAIL: income economics'; end if;
        select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into rows from public.incomes where id in(op,second_op);
      end if;
      begin
        perform public.delete_cashflow(gen_random_uuid(),scope,flow_kind,jsonb_set(rows,'{1,revision}',to_jsonb(gen_random_uuid())));
        raise exception 'FAIL: stale operation';
      exception when sqlstate 'P1003' then null; end;
      if public.wallet_expense_balance(w)<>before_balance then raise exception 'FAIL: partial deletion'; end if;
      delete_req:=gen_random_uuid();
      result:=public.delete_cashflow(delete_req,scope,flow_kind,rows);
      if result->>'affected'<>'2' or public.delete_cashflow(delete_req,scope,flow_kind,rows)<>result then raise exception 'FAIL: delete receipt'; end if;
      if flow_kind='expense' then
        if public.create_expense(create_req,scope,w,child,'20000',current_date,'Keep economics')<>op then raise exception 'FAIL: creation receipt'; end if;
        if exists(select 1 from public.expenses where id=op) then raise exception 'FAIL: resurrected expense'; end if;
      else
        if public.save_income(create_req,scope,null,null,w,child,'50000',current_date,'Keep economics','RUB',2)<>op then raise exception 'FAIL: income receipt'; end if;
        if exists(select 1 from public.incomes where id=op) then raise exception 'FAIL: resurrected income'; end if;
      end if;
      if public.wallet_expense_balance(w)->>'current_minor'<>'100000' then raise exception 'FAIL: balance applied twice'; end if;
      execute 'reset role';
    end loop;
    select id into replacement from public.categories where space_id=scope and kind='expense';
    perform set_config('request.jwt.claim.sub',actor::text,true); execute 'set local role authenticated';
    payload:=jsonb_build_object('space_id',scope,'id',null,'revision',null,'source_id',w,'target_id',target,
      'source_minor','10000','target_minor','10000','source_currency','RUB','target_currency','RUB','source_scale',2,'target_scale',2,
      'date','2026-10-06','comment','Fee protection','fee_minor','100','fee_category_id',replacement);
    transfer:=public.save_transfer(gen_random_uuid(),payload);
    select id,jsonb_build_array(jsonb_build_object('id',id,'revision',revision)) into fee,rows from public.expenses where transfer_id=transfer;
    begin
      perform public.delete_cashflow(gen_random_uuid(),scope,'expense',rows);
      raise exception 'FAIL: fee deleted independently';
    exception when sqlstate 'P1005' then null; end;
    before_balance:=public.wallet_expense_balance(w);
    execute 'reset role';
    insert into public.categories(space_id,kind,name) values(scope,'expense','Fee replacement') returning id into fee_replacement;
    execute 'set local role authenticated';
    select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into snapshot from public.categories where space_id=scope and kind='expense';
    perform public.mutate_categories(gen_random_uuid(),scope,'expense','delete',array[replacement],snapshot,jsonb_build_object(replacement,fee_replacement));
    if public.wallet_expense_balance(w)<>before_balance or (select fee_category_id from public.transfers where id=transfer)<>fee_replacement
      or (select category_id from public.expenses where id=fee)<>fee_replacement then raise exception 'FAIL: fee remap'; end if;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub',outsider::text,true); execute 'set local role authenticated';
    begin
      perform public.delete_cashflow(gen_random_uuid(),scope,'expense',rows);
      raise exception 'FAIL: outsider';
    exception when insufficient_privilege then null; end;
    execute 'reset role';
  end loop;
end $test$;
do $control$
declare actor uuid:=gen_random_uuid(); scope uuid; w uuid; usd_wallet uuid; usd_expense uuid; ec uuid; ic uuid; e uuid; i uuid;
  rows jsonb; edit_req uuid:=gen_random_uuid(); revision uuid;
begin
  insert into auth.users(id) values(actor);
  insert into public.spaces(owner_user_id,kind,name) values(actor,'personal','1000 + 500 - 200') returning id into scope;
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Control','cash','RUB') returning id into w;
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'USD','cash','USD') returning id into usd_wallet;
  insert into public.wallet_opening_balances(wallet_id,amount_minor) values(w,100000);
  insert into public.categories(space_id,kind,name) values(scope,'expense','Expense') returning id into ec;
  insert into public.categories(space_id,kind,name) values(scope,'income','Income') returning id into ic;
  perform set_config('request.jwt.claim.sub',actor::text,true);execute 'set local role authenticated';
  i:=public.save_income(gen_random_uuid(),scope,null,null,w,ic,'50000',current_date,'Control','RUB',2);
  e:=public.create_expense(gen_random_uuid(),scope,w,ec,'20000',current_date,'Control');
  usd_expense:=public.create_expense(gen_random_uuid(),scope,usd_wallet,ec,'123',current_date,'USD separate');
  select x.revision into revision from public.expenses x where id=e;
  perform public.edit_expense(edit_req,scope,e,revision,w,ec,'20000',current_date,'Edited control','RUB',2);
  if public.wallet_expense_balance(w)->>'current_minor'<>'130000' then raise exception 'FAIL: control 1300'; end if;
  select jsonb_agg(jsonb_build_object('id',id,'revision',x.revision) order by id) into rows from public.expenses x where id in(e,usd_expense);
  perform public.delete_cashflow(gen_random_uuid(),scope,'expense',rows);
  if public.wallet_expense_balance(w)->>'current_minor'<>'150000' or public.query_expenses(scope,p_include_totals=>true)->'totals'<>'[]'::jsonb then raise exception 'FAIL: control 1500/totals'; end if;
  if public.wallet_expense_balance(usd_wallet)->>'current_minor'<>'0' then raise exception 'FAIL: currency mixing'; end if;
  begin
    perform public.edit_expense(edit_req,scope,e,revision,w,ec,'20000',current_date,'Edited control','RUB',2);
    raise exception 'FAIL: edit accepted for deleted expense';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from public.expenses where id=e) then raise exception 'FAIL: edit receipt resurrected'; end if;
  select jsonb_build_array(jsonb_build_object('id',id,'revision',x.revision)) into rows from public.incomes x where id=i;
  perform public.delete_cashflow(gen_random_uuid(),scope,'income',rows);
  if public.wallet_expense_balance(w)->>'current_minor'<>'100000' or public.query_incomes(scope,p_include_totals=>true)->'totals'<>'[]'::jsonb then raise exception 'FAIL: control 1000/totals'; end if;
  execute 'reset role';
end $control$;
rollback;
