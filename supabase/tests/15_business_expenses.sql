-- Run after migration 015 as postgres. All fixtures are rolled back.
begin;
do $test$
declare
  actor uuid := '00000000-0000-4000-8000-000000000151';
  scope uuid := '10000000-0000-4000-8000-000000000151';
  personal uuid := '10000000-0000-4000-8000-000000000152';
  ambiguous_scope uuid := '10000000-0000-4000-8000-000000000153';
  advertising uuid; olx uuid; archived uuid; ambiguous uuid; income uuid; sentinel uuid;
  wallet uuid; expense uuid; unused uuid; result jsonb; economics jsonb; old_ids uuid[];
begin
  if current_user<>'postgres' then raise exception 'Run as postgres'; end if;
  if has_function_privilege('authenticated','finance_private.install_business_expenses_20261006(uuid,uuid,uuid[],jsonb,uuid[])','EXECUTE')
    or has_table_privilege('authenticated','finance_private.business_expense_installations','SELECT') then
    raise exception 'FAIL: privileged importer/backup exposed';
  end if;
  insert into auth.users(id) values(actor);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (scope,actor,'business','Replacement test'),(personal,actor,'personal','Personal sentinel'),
    (ambiguous_scope,actor,'business','Ambiguity test');
  insert into public.categories(space_id,kind,name) values(personal,'expense','Personal sentinel') returning id into sentinel;
  insert into public.categories(space_id,kind,name) values(scope,'income','Income sentinel') returning id into income;
  insert into public.categories(space_id,kind,name) values(scope,'expense','Реклама') returning id into advertising;
  insert into public.categories(space_id,kind,name,parent_id) values(scope,'expense','OLX',advertising) returning id into olx;
  insert into public.categories(space_id,kind,name,is_archived) values(scope,'expense','Archived sentinel',true) returning id into archived;
  insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Cash','cash','RUB') returning id into wallet;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  execute 'set local role authenticated';
  expense := public.create_expense(gen_random_uuid(),scope,wallet,olx,'12345',date '2026-10-06','Keep exactly');
  execute 'reset role';
  select to_jsonb(e)-'category_id' into economics from public.expenses e where id=expense;
  old_ids := array[advertising,olx,archived];
  begin
    perform finance_private.install_business_expenses_20261006(scope,actor,old_ids,p_expected_reference_ids => '{}'::uuid[]);
    raise exception 'FAIL: stale backup was accepted';
  exception when others then
    if sqlerrm<>'References changed since local backup; capture a fresh backup' then raise; end if;
  end;
  result := finance_private.install_business_expenses_20261006(scope,actor,old_ids,p_expected_reference_ids => array[expense]);
  if result->>'installed'<>'62' or result->>'deleted'<>'3' or result->>'remapped_expenses'<>'1' then
    raise exception 'FAIL: replacement result %',result;
  end if;
  if (select to_jsonb(e)-'category_id' from public.expenses e where id=expense) is distinct from economics then
    raise exception 'FAIL: economics/snapshot altered';
  end if;
  if not exists(select 1 from public.expenses e join finance_private.business_expense_keys k on e.category_id=k.category_id
    where e.id=expense and k.space_id=scope and k.key='advertising-olx') then
    raise exception 'FAIL: alias reference not moved';
  end if;
  if exists(select 1 from public.categories where id=any(old_ids)) or
    not exists(select 1 from public.categories where id=sentinel and name='Personal sentinel') or
    not exists(select 1 from public.categories where id=income and name='Income sentinel') then
    raise exception 'FAIL: scope/deletion';
  end if;
  if exists(select 1 from finance_private.business_expense_keys k
    join finance_private.business_expense_items i on i.key=k.key
    join public.categories c on c.id=k.category_id
    left join finance_private.business_expense_keys p on p.space_id=k.space_id and p.key=i.parent_key
    where k.space_id=scope and (c.name<>i.name or c.icon_id<>i.icon_id or c.is_archived
      or c.sort_order<>i.sort_order or c.parent_id is distinct from p.category_id)) then
    raise exception 'FAIL: exact catalog fields';
  end if;
  select category_id into unused from finance_private.business_expense_keys where space_id=scope and key='advertising-seo';
  delete from public.categories where id=unused;
  update public.categories set name='User renamed',icon_id='category' where id=(
    select category_id from finance_private.business_expense_keys where space_id=scope and key='advertising-olx');
  result := finance_private.install_business_expenses_20261006(scope,actor,old_ids);
  if result->>'already_installed'<>'true' or exists(select 1 from public.categories where id=unused) then
    raise exception 'FAIL: duplicate/recreated deletion';
  end if;
  perform finance_private.install_category_set_2026_10_01(scope);
  if (select count(*) from public.categories where space_id=scope and kind='expense')<>61 or
    not exists(select 1 from public.categories where space_id=scope and name='User renamed' and icon_id='category') then
    raise exception 'FAIL: legacy seed restored old set or reset edits';
  end if;

  -- A root Internet is not equivalent to Internet under Office maintenance.
  insert into public.categories(space_id,kind,name) values(ambiguous_scope,'expense','Интернет') returning id into ambiguous;
  insert into public.wallets(space_id,name,wallet_group,currency) values(ambiguous_scope,'Cash','cash','RUB') returning id into wallet;
  perform set_config('request.jwt.claim.sub',actor::text,true); execute 'set local role authenticated';
  perform public.create_expense(gen_random_uuid(),ambiguous_scope,wallet,ambiguous,'456',date '2026-10-06','Ambiguous root');
  execute 'reset role';
  begin
    perform finance_private.install_business_expenses_20261006(ambiguous_scope,actor,array[ambiguous]);
    raise exception 'FAIL: ambiguous root silently reclassified';
  exception when others then
    if sqlerrm<>'Unresolved used business categories' then raise; end if;
  end;
  if (select count(*) from public.categories where space_id=ambiguous_scope)<>1 or
    exists(select 1 from finance_private.business_expense_installations where space_id=ambiguous_scope) or
    exists(select 1 from finance_private.business_expense_mapping where space_id=ambiguous_scope) then
    raise exception 'FAIL: unresolved replacement did not roll back';
  end if;
  begin
    perform finance_private.install_business_expenses_20261006(personal,actor,array[sentinel]);
    raise exception 'FAIL: personal target accepted';
  exception when others then
    if sqlerrm<>'Expected owner/business space not found' then raise; end if;
  end;
  raise notice 'PASS: catalog, aliases, preservation, archive deletion, scope, rollback, repeat and legacy seed';
end $test$;
rollback;
