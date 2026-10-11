-- ПОДГОТОВЛЕННЫЙ, НЕ ЗАПУЩЕННЫЙ ТЕСТ.
-- Только отдельный тестовый Supabase проект/ветка после обеих миграций.
-- Выполнять ЦЕЛИКОМ как postgres. UUID не заменять. Данные откатываются.
begin;
do $test$
declare
  owner_id uuid := '00000000-0000-4000-8000-000000000011';
  manager_id uuid := '00000000-0000-4000-8000-000000000012';
  stranger_id uuid := '00000000-0000-4000-8000-000000000013';
  other_owner uuid := '00000000-0000-4000-8000-000000000014';
  personal uuid := '10000000-0000-4000-8000-000000000011';
  business uuid := '10000000-0000-4000-8000-000000000012';
  foreign_space uuid := '10000000-0000-4000-8000-000000000013';
  root_id uuid;
  child_id uuid;
  income_id uuid;
  personal_id uuid;
  foreign_id uuid;
  affected integer;
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres in isolated project'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.categories'::regclass)
    or has_table_privilege('anon', 'public.categories', 'SELECT')
    or has_table_privilege('authenticated', 'public.categories', 'DELETE')
    or has_table_privilege('authenticated', 'public.categories', 'TRUNCATE')
    or has_table_privilege('authenticated', 'public.categories', 'TRIGGER')
    or has_table_privilege('authenticated', 'public.categories', 'REFERENCES')
    or has_column_privilege('authenticated', 'public.categories', 'space_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.categories', 'kind', 'UPDATE')
    or has_column_privilege('authenticated', 'public.categories', 'parent_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.categories', 'id', 'INSERT')
    or has_column_privilege('authenticated', 'public.categories', 'is_root', 'INSERT')
    or has_column_privilege('authenticated', 'public.categories', 'parent_must_be_root', 'UPDATE')
  then raise exception 'FAIL: excessive grants or disabled RLS'; end if;

  insert into auth.users(id) values (owner_id), (manager_id), (stranger_id), (other_owner);
  insert into public.spaces(id, owner_user_id, kind, name) values
    (personal, owner_id, 'personal', 'Test personal'),
    (business, owner_id, 'business', 'Test business'),
    (foreign_space, other_owner, 'business', 'Test foreign');
  insert into public.space_members(space_id, user_id) values (business, manager_id);
  insert into public.categories(space_id, kind, name) values
    (foreign_space, 'expense', 'Foreign') returning id into foreign_id;

  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into public.categories(space_id, kind, name) values
    (personal, 'expense', 'Personal') returning id into personal_id;
  insert into public.categories(space_id, kind, name) values
    (business, 'expense', 'Business expense') returning id into root_id;
  insert into public.categories(space_id, kind, name, parent_id) values
    (business, 'expense', 'Child', root_id) returning id into child_id;
  insert into public.categories(space_id, kind, name) values
    (business, 'income', 'Income') returning id into income_id;
  if (select count(*) from public.categories) <> 4 then raise exception 'FAIL: owner isolation'; end if;
  update public.categories set name = 'Renamed' where id = root_id;
  get diagnostics affected = row_count;
  if affected <> 1 then raise exception 'FAIL: rename'; end if;
  update public.categories set is_archived = true where id = root_id;
  if not exists (select 1 from public.categories where id = root_id and is_archived)
    or not exists (select 1 from public.categories where id = child_id and parent_id = root_id)
  then raise exception 'FAIL: archive destroyed history'; end if;

  begin
    insert into public.categories(space_id, kind, name, parent_id) values (business, 'expense', 'Third level', child_id);
    raise exception 'FAIL: third level';
  exception when foreign_key_violation then null; end;
  begin
    insert into public.categories(space_id, kind, name, parent_id) values (business, 'income', 'Wrong type', root_id);
    raise exception 'FAIL: cross type';
  exception when foreign_key_violation then null; end;
  begin
    insert into public.categories(space_id, kind, name, parent_id) values (business, 'expense', 'Wrong space', personal_id);
    raise exception 'FAIL: cross personal/business';
  exception when foreign_key_violation then null; end;
  begin
    insert into public.categories(space_id, kind, name, parent_id) values (business, 'expense', 'Foreign parent', foreign_id);
    raise exception 'FAIL: foreign parent';
  exception when foreign_key_violation then null; end;
  begin
    insert into public.categories(space_id, kind, name) values (foreign_space, 'expense', 'Foreign write');
    raise exception 'FAIL: owner foreign insert';
  exception when insufficient_privilege then null; end;
  update public.categories set name = 'Forbidden' where id = foreign_id;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: foreign update'; end if;
  begin
    update public.categories set parent_id = child_id where id = root_id;
    raise exception 'FAIL: reparent privilege';
  exception when insufficient_privilege then null; end;
  begin
    update public.categories set space_id = foreign_space where id = root_id;
    raise exception 'FAIL: space mutation';
  exception when insufficient_privilege then null; end;
  begin
    update public.categories set kind = 'income' where id = root_id;
    raise exception 'FAIL: type mutation';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.categories where id = child_id;
    raise exception 'FAIL: deletion allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.categories(space_id, kind, name) values (business, 'expense', '   ');
    raise exception 'FAIL: blank name';
  exception when check_violation then null; end;

  -- Проверяем ограничения дерева даже при обходе RLS администратором.
  execute 'reset role';
  begin
    update public.categories set parent_id = id where id = root_id;
    raise exception 'FAIL: self cycle';
  exception when check_violation then null; end;
  begin
    update public.categories set parent_id = child_id where id = root_id;
    raise exception 'FAIL: two node cycle';
  exception when foreign_key_violation then null; end;
  begin
    update public.categories set parent_id = personal_id, space_id = personal where id = root_id;
    raise exception 'FAIL: move parent with children to third level';
  exception when foreign_key_violation then null; end;
  begin
    delete from public.spaces where id = business;
    raise exception 'FAIL: space deletion destroys category history';
  exception when foreign_key_violation then null; end;

  -- Metadata не назначает владельца. Менеджеру видны только расходы бизнеса.
  perform set_config('request.jwt.claim.sub', manager_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', manager_id, 'role', 'authenticated',
    'user_metadata', json_build_object('role', 'owner'))::text, true);
  execute 'set local role authenticated';
  if (select count(*) from public.categories) <> 2
    or exists (select 1 from public.categories where space_id <> business or kind <> 'expense')
  then raise exception 'FAIL: manager visibility'; end if;
  begin
    insert into public.categories(space_id, kind, name) values (business, 'expense', 'Escalation');
    raise exception 'FAIL: manager insert';
  exception when insufficient_privilege then null; end;
  update public.categories set name = 'Forbidden', is_archived = false where id = root_id;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: manager edit/archive'; end if;
  begin
    delete from public.categories where id = child_id;
    raise exception 'FAIL: manager delete';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', other_owner::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', other_owner, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if (select count(*) from public.categories) <> 1
    or not exists (select 1 from public.categories where id = foreign_id)
  then raise exception 'FAIL: other owner isolation'; end if;
  update public.categories set is_archived = true where id = personal_id;
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'FAIL: other owner foreign archive'; end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', stranger_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', stranger_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if exists (select 1 from public.categories) then raise exception 'FAIL: outsider read'; end if;
  begin
    insert into public.categories(space_id, kind, name) values (business, 'expense', 'Escalation');
    raise exception 'FAIL: outsider insert';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', owner_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  delete from public.space_members where space_id = business and user_id = manager_id;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', manager_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', manager_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  if exists (select 1 from public.categories) then raise exception 'FAIL: revoked manager read'; end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{}', true);
  execute 'set local role anon';
  begin
    perform 1 from public.categories;
    raise exception 'FAIL: anonymous read';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.categories(space_id, kind, name) values (business, 'expense', 'Anonymous');
    raise exception 'FAIL: anonymous write';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'PASS: category boundaries; rolling back fixtures';
end
$test$;
rollback;
