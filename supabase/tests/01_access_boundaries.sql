-- ПОДГОТОВЛЕННЫЙ, НЕ ЗАПУЩЕННЫЙ ТЕСТ.
-- Для отдельного тестового Supabase проекта/ветки после миграции.
-- Выполнять целиком в SQL Editor как postgres. Реальные UUID не подставлять.
-- Фиктивные пользователи/данные живут только в этой транзакции. COMMIT нет.
begin;

do $test$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  manager_id constant uuid := '00000000-0000-4000-8000-000000000002';
  outsider_id constant uuid := '00000000-0000-4000-8000-000000000003';
  other_owner_id constant uuid := '00000000-0000-4000-8000-000000000004';
  personal_id constant uuid := '10000000-0000-4000-8000-000000000001';
  business_id constant uuid := '10000000-0000-4000-8000-000000000002';
  other_business_id constant uuid := '10000000-0000-4000-8000-000000000003';
  personal_wallet constant uuid := '20000000-0000-4000-8000-000000000001';
  assigned_wallet constant uuid := '20000000-0000-4000-8000-000000000002';
  hidden_wallet constant uuid := '20000000-0000-4000-8000-000000000003';
  other_wallet constant uuid := '20000000-0000-4000-8000-000000000004';
  new_space uuid;
  affected integer;
begin
  if current_user <> 'postgres' then
    raise exception 'Run the test as postgres in an isolated test project';
  end if;

  if (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname in
        ('spaces', 'space_members', 'wallets', 'wallet_assignments', 'wallet_opening_balances')
        and c.relrowsecurity) <> 5 then
    raise exception 'FAIL: RLS must be enabled on all five tables';
  end if;
  if has_table_privilege('authenticated', 'public.wallets', 'TRUNCATE')
     or has_table_privilege('authenticated', 'public.wallets', 'TRIGGER')
     or has_table_privilege('authenticated', 'public.wallets', 'REFERENCES')
     or has_table_privilege('anon', 'public.wallets', 'SELECT')
     or has_column_privilege('authenticated', 'public.spaces', 'owner_user_id', 'UPDATE')
     or has_column_privilege('authenticated', 'public.space_members', 'role', 'INSERT')
     or has_column_privilege('authenticated', 'public.wallets', 'space_id', 'UPDATE')
     or has_function_privilege('anon', 'finance_private.owns_space(uuid)', 'EXECUTE') then
    raise exception 'FAIL: excessive grants';
  end if;

  -- Не использовать ON CONFLICT: совпадение фиктивного UUID должно остановить тест.
  insert into auth.users(id) values (owner_id), (manager_id), (outsider_id), (other_owner_id);
  insert into public.spaces(id, owner_user_id, kind, name) values
    (personal_id, owner_id, 'personal', 'Test personal'),
    (business_id, owner_id, 'business', 'Test business'),
    (other_business_id, other_owner_id, 'business', 'Other business');
  insert into public.wallets(id, space_id, name, wallet_group, currency) values
    (personal_wallet, personal_id, 'Personal', 'cash', 'RUB'),
    (assigned_wallet, business_id, 'Assigned', 'bank_account', 'KZT'),
    (hidden_wallet, business_id, 'Hidden', 'card', 'RUB'),
    (other_wallet, other_business_id, 'Other', 'cash', 'RUB');
  insert into public.wallet_opening_balances(wallet_id, amount_minor) values
    (personal_wallet, 10000), (assigned_wallet, 20000),
    (hidden_wallet, 30000), (other_wallet, 40000);

  -- Реальные операции владельца через authenticated, не через обход RLS postgres.
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (select count(*) from public.spaces) <> 2
     or (select count(*) from public.wallets) <> 3
     or (select count(*) from public.wallet_opening_balances) <> 3 then
    raise exception 'FAIL: owner scope isolation';
  end if;
  insert into public.spaces(owner_user_id, kind, name)
    values (owner_id, 'business', 'Another owned space') returning id into new_space;
  update public.spaces set name = 'Renamed' where id = new_space;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'FAIL: owner cannot rename own space'; end if;
  delete from public.spaces where id = new_space;

  insert into public.space_members(space_id, user_id) values (business_id, manager_id);
  insert into public.wallet_assignments(space_id, wallet_id, user_id)
    values (business_id, assigned_wallet, manager_id);
  update public.wallet_opening_balances set amount_minor = 9007199254740993
    where wallet_id = assigned_wallet;
  if (select amount_minor from public.wallet_opening_balances where wallet_id = assigned_wallet)
       is distinct from 9007199254740993::bigint then
    raise exception 'FAIL: integer precision';
  end if;
  begin
    insert into public.spaces(owner_user_id, kind, name) values (manager_id, 'business', 'Escalation');
    raise exception 'FAIL: owner gave another user ownership';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.spaces set owner_user_id = manager_id where id = business_id;
    raise exception 'FAIL: ownership reassignment allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.space_members(space_id, user_id) values (personal_id, manager_id);
    raise exception 'FAIL: manager admitted to personal space';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.wallet_assignments(space_id, wallet_id, user_id)
      values (business_id, other_wallet, manager_id);
    raise exception 'FAIL: cross-space assignment allowed';
  exception when foreign_key_violation then null;
  end;
  begin
    update public.wallets set currency = 'USD' where id = assigned_wallet;
    raise exception 'FAIL: money reinterpreted by currency change';
  exception when insufficient_privilege then null;
  end;

  -- Менеджер: поддельная роль в metadata не расширяет права.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', manager_id::text, true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', manager_id, 'role', 'authenticated', 'user_metadata', json_build_object('role', 'owner'))::text, true);
  execute 'set local role authenticated';
  if (select count(*) from public.spaces) <> 1
     or (select count(*) from public.wallets) <> 1
     or not exists (select 1 from public.wallets where id = assigned_wallet)
     or (select count(*) from public.space_members) <> 1
     or (select count(*) from public.wallet_assignments) <> 1 then
    raise exception 'FAIL: manager metadata visibility';
  end if;
  if exists (select 1 from public.wallet_opening_balances)
     or exists (select 1 from public.wallets w join public.wallet_opening_balances b on b.wallet_id = w.id)
     or exists (select 1 from public.wallets where id in (personal_wallet, hidden_wallet, other_wallet)) then
    raise exception 'FAIL: manager sees balance/personal/unassigned/foreign data';
  end if;
  begin
    insert into public.spaces(owner_user_id, kind, name) values (manager_id, 'business', 'Self owner');
    raise exception 'FAIL: manager self-bootstrap';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.space_members(space_id, user_id) values (business_id, outsider_id);
    raise exception 'FAIL: manager invited another user';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.space_members set role = 'owner' where user_id = manager_id;
    raise exception 'FAIL: manager promoted self';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.wallet_assignments(space_id, wallet_id, user_id)
      values (business_id, hidden_wallet, manager_id);
    raise exception 'FAIL: manager assigned self another wallet';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.wallets(space_id, name, wallet_group, currency)
      values (business_id, 'Forbidden', 'cash', 'RUB');
    raise exception 'FAIL: manager created wallet';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.wallet_opening_balances(wallet_id, amount_minor)
      values (assigned_wallet, 1);
    raise exception 'FAIL: manager inserted initial balance';
  exception when insufficient_privilege then null;
  end;
  update public.wallets set name = 'Forbidden' where id = assigned_wallet;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: manager changed wallet'; end if;
  update public.wallet_opening_balances set amount_minor = 0 where wallet_id = assigned_wallet;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: manager changed balance'; end if;
  delete from public.wallets where id = assigned_wallet;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: manager deleted wallet'; end if;
  delete from public.wallet_assignments where wallet_id = assigned_wallet;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: manager changed access'; end if;

  -- Другой владелец не имеет глобального доступа.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', other_owner_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', other_owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (select count(*) from public.wallets) <> 1
     or not exists (select 1 from public.wallets where id = other_wallet)
     or (select count(*) from public.wallet_opening_balances) <> 1 then
    raise exception 'FAIL: other owner isolation';
  end if;
  begin
    insert into public.space_members(space_id, user_id) values (business_id, outsider_id);
    raise exception 'FAIL: other owner granted access in foreign space';
  exception when insufficient_privilege then null;
  end;

  -- Посторонний вошедший пользователь не может bootstrap-нуть владение.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', outsider_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', outsider_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if exists (select 1 from public.spaces) or exists (select 1 from public.wallets)
     or exists (select 1 from public.space_members) or exists (select 1 from public.wallet_assignments)
     or exists (select 1 from public.wallet_opening_balances) then
    raise exception 'FAIL: outsider data leak';
  end if;
  begin
    insert into public.spaces(owner_user_id, kind, name) values (outsider_id, 'personal', 'Self owner');
    raise exception 'FAIL: new user self-bootstrap';
  exception when insufficient_privilege then null;
  end;

  -- Отзыв участия владельцем немедленно убирает назначения.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  delete from public.space_members where space_id = business_id and user_id = manager_id;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'FAIL: owner cannot revoke membership'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', manager_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', manager_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if exists (select 1 from public.wallets) or exists (select 1 from public.wallet_assignments)
     or exists (select 1 from public.spaces) then
    raise exception 'FAIL: revoked manager still has access';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  execute 'set local role anon';
  begin
    perform 1 from public.wallets;
    raise exception 'FAIL: anon can query wallets';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.wallet_opening_balances;
    raise exception 'FAIL: anon can query balances';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  raise notice 'PASS: access boundary scenarios completed; rolling back all fixtures';
end
$test$;

rollback;
