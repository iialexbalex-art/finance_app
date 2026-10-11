-- НЕ ЗАПУЩЕНО. Отдельный тестовый проект после 001–004.
-- Целиком как postgres. Все fixtures откатываются; UUID не заменять.
begin;
do $test$
declare
  owner_id uuid := '00000000-0000-4000-8000-000000000041';
  manager uuid := '00000000-0000-4000-8000-000000000042';
  outsider uuid := '00000000-0000-4000-8000-000000000043';
  other_owner uuid := '00000000-0000-4000-8000-000000000044';
  personal uuid := '10000000-0000-4000-8000-000000000041';
  business uuid := '10000000-0000-4000-8000-000000000042';
  foreign_space uuid := '10000000-0000-4000-8000-000000000043';
  a uuid; b uuid; c uuid; d uuid; other_type uuid; foreign_cat uuid; personal_cat uuid;
  snapshot jsonb; changed integer;
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres in test project'; end if;
  if not (select relrowsecurity from pg_class where oid = 'public.categories'::regclass)
    or has_table_privilege('anon', 'public.categories', 'SELECT')
    or has_table_privilege('authenticated', 'public.categories', 'DELETE')
    or has_table_privilege('authenticated', 'public.categories', 'TRUNCATE')
    or has_table_privilege('authenticated', 'public.categories', 'TRIGGER')
    or has_table_privilege('authenticated', 'public.categories', 'REFERENCES')
    or has_column_privilege('authenticated', 'public.categories', 'id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.categories', 'space_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.categories', 'kind', 'UPDATE')
    or has_table_privilege('authenticated', 'finance_private.category_tree_guard', 'UPDATE')
    or has_table_privilege('authenticated', 'finance_private.category_tree_guard', 'SELECT')
    or has_function_privilege('authenticated', 'finance_private.lock_category_tree()', 'EXECUTE')
    or has_function_privilege('authenticated', 'finance_private.validate_category_tree()', 'EXECUTE')
    or has_function_privilege('authenticated', 'finance_private.check_category_parent()', 'EXECUTE')
  then raise exception 'FAIL: grants/RLS'; end if;
  insert into auth.users(id) values(owner_id),(manager),(outsider),(other_owner);
  insert into public.spaces(id,owner_user_id,kind,name) values
    (personal,owner_id,'personal','Test personal'),(business,owner_id,'business','Test business'),
    (foreign_space,other_owner,'business','Test foreign');
  insert into public.space_members(space_id,user_id) values(business,manager);
  insert into public.categories(space_id,kind,name) values(foreign_space,'expense','Foreign') returning id into foreign_cat;

  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',owner_id,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  insert into public.categories(space_id,kind,name) values(personal,'expense','Personal') returning id into personal_cat;
  insert into public.categories(space_id,kind,name) values(business,'income','Income') returning id into other_type;
  insert into public.categories(space_id,kind,name) values(business,'expense','Daily') returning id into a;
  insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Food',a) returning id into b;
  insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Groceries',b) returning id into c;
  insert into public.categories(space_id,kind,name) values(business,'expense','Other') returning id into d;
  if not exists(select 1 from public.categories where id=c and parent_id=b)
    or (select count(*) from public.categories) <> 6 then raise exception 'FAIL: three levels/owner scope'; end if;
  begin
    insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Fourth',c);
    raise exception 'FAIL: fourth level accepted';
  exception when check_violation then null; end;

  -- Сохраняем неизменяемую полезную нагрузку ВСЕХ записей, включая created_at.
  select jsonb_agg(jsonb_build_array(id,space_id,kind,name,is_archived,created_at) order by id)
    into snapshot from public.categories;
  update public.categories set parent_id=d where id=b; -- ветвь B→C целиком
  if not exists(select 1 from public.categories where id=b and parent_id=d)
    or not exists(select 1 from public.categories where id=c and parent_id=b)
  then raise exception 'FAIL: subtree move'; end if;
  update public.categories set parent_id=null where id=c;
  update public.categories set parent_id=a where id=c; -- лист к другому родителю
  update public.categories set parent_id=b where id=c;
  begin
    update public.categories set parent_id=a where id=d; -- A→D→B→C = 4
    raise exception 'FAIL: subtree exceeds depth';
  exception when check_violation then null; end;
  if not exists(select 1 from public.categories where id=d and parent_id is null)
  then raise exception 'FAIL: failed move not atomic'; end if;
  begin
    update public.categories set parent_id=id where id=b;
    raise exception 'FAIL: self cycle';
  exception when check_violation then null; end;
  begin
    update public.categories set parent_id=c where id=d; -- дальний потомок
    raise exception 'FAIL: descendant cycle';
  exception when check_violation then null; end;
  begin
    update public.categories set parent_id=b where id=d;
    raise exception 'FAIL: direct child cycle';
  exception when check_violation then null; end;
  begin
    update public.categories set parent_id=personal_cat where id=b;
    raise exception 'FAIL: cross space';
  exception when check_violation or foreign_key_violation then null; end;
  begin
    update public.categories set parent_id=other_type where id=b;
    raise exception 'FAIL: cross type';
  exception when check_violation or foreign_key_violation then null; end;
  begin
    update public.categories set parent_id=foreign_cat where id=b;
    raise exception 'FAIL: foreign owner';
  exception when check_violation or foreign_key_violation then null; end;
  if snapshot is distinct from (select jsonb_agg(jsonb_build_array(id,space_id,kind,name,is_archived,created_at) order by id) from public.categories)
  then raise exception 'FAIL: data or IDs changed'; end if;

  update public.categories set is_archived=true where id=d;
  -- Текущий архивный предок не мешает переименованию/сохранению старого parent_id.
  update public.categories set name='Groceries renamed',parent_id=b where id=c;
  begin
    update public.categories set parent_id=d where id=a;
    raise exception 'FAIL: archived parent';
  exception when check_violation then null; end;
  begin
    update public.categories set parent_id=b where id=a;
    raise exception 'FAIL: archived grandparent';
  exception when check_violation then null; end;
  begin
    insert into public.categories(space_id,kind,name,parent_id) values(business,'expense','Archived ancestor',b);
    raise exception 'FAIL: create below archived ancestor';
  exception when check_violation then null; end;
  update public.categories set is_archived=true where id=b;
  update public.categories set parent_id=a where id=b; -- собственный архив сохраняется
  if not exists(select 1 from public.categories where id=b and is_archived and parent_id=a)
    or not exists(select 1 from public.categories where id=c and parent_id=b)
  then raise exception 'FAIL: archived subtree preservation'; end if;
  begin
    update public.categories set space_id=personal where id=a;
    raise exception 'FAIL: space grant';
  exception when insufficient_privilege then null; end;
  begin
    update public.categories set kind='income' where id=a;
    raise exception 'FAIL: kind grant';
  exception when insufficient_privilege then null; end;
  begin
    update public.categories set id=gen_random_uuid() where id=a;
    raise exception 'FAIL: id grant';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',manager,'role','authenticated','user_metadata',json_build_object('role','owner'))::text,true);
  execute 'set local role authenticated';
  if (select count(*) from public.categories) <> 4 or exists(select 1 from public.categories where space_id<>business or kind<>'expense')
  then raise exception 'FAIL: manager visibility'; end if;
  update public.categories set parent_id=null,name='Forbidden',is_archived=false where id=b;
  get diagnostics changed=row_count;
  if changed<>0 then raise exception 'FAIL: manager mutation'; end if;
  begin
    insert into public.categories(space_id,kind,name) values(business,'expense','Forbidden');
    raise exception 'FAIL: manager create';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.categories where id=c;
    raise exception 'FAIL: manager delete';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',other_owner::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',other_owner,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if (select count(*) from public.categories)<>1 then raise exception 'FAIL: other owner scope'; end if;
  update public.categories set parent_id=foreign_cat where id=a;
  get diagnostics changed=row_count;
  if changed<>0 then raise exception 'FAIL: foreign mutation'; end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',outsider,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.categories) then raise exception 'FAIL: outsider read'; end if;
  begin
    insert into public.categories(space_id,kind,name) values(business,'expense','Forbidden');
    raise exception 'FAIL: outsider write';
  exception when insufficient_privilege then null; end;

  execute 'reset role';
  delete from public.space_members where space_id=business and user_id=manager;
  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform set_config('request.jwt.claims',json_build_object('sub',manager,'role','authenticated')::text,true);
  execute 'set local role authenticated';
  if exists(select 1 from public.categories) then raise exception 'FAIL: revoked manager'; end if;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub','',true);
  perform set_config('request.jwt.claims','{}',true);
  execute 'set local role anon';
  begin
    perform 1 from public.categories;
    raise exception 'FAIL: anon';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
  raise notice 'PASS: three-level tree and access; rollback fixtures';
end
$test$;
rollback;
