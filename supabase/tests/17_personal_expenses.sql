-- Isolated fixtures. No production operations; rollback includes all assertions.
begin;
do $test$
declare
 actor uuid := '00000000-0000-4000-8000-000000000171';
 scope uuid := '10000000-0000-4000-8000-000000000171';
 other_scope uuid := '10000000-0000-4000-8000-000000000172';
 root uuid; leaf uuid; extra uuid; grandchild uuid; income uuid; sentinel uuid;
 wallet uuid; expense uuid; plan jsonb; expected jsonb; refs jsonb; result jsonb; snapshot jsonb;
begin
 if has_function_privilege('authenticated','finance_private.install_personal_expenses_20261006(uuid,uuid,jsonb,jsonb,jsonb)','EXECUTE')
   or has_table_privilege('authenticated','finance_private.personal_expense_mappings','SELECT') then raise exception 'Installer exposed'; end if;
 insert into auth.users(id) values(actor);
 insert into public.spaces(id,owner_user_id,kind,name) values(scope,actor,'personal','Personal QA'),(other_scope,actor,'business','Sentinel');
 insert into public.categories(space_id,kind,name) values(scope,'expense','Дом') returning id into root;
 insert into public.categories(space_id,kind,name) values(scope,'expense','Хозтовары для дома') returning id into leaf;
 insert into public.categories(space_id,kind,name,parent_id) values(scope,'expense','Retained child',leaf) returning id into grandchild;
 insert into public.categories(space_id,kind,name,is_archived) values(scope,'expense','Retained archived extra',true) returning id into extra;
 insert into public.categories(space_id,kind,name) values(scope,'income','Income sentinel') returning id into income;
 insert into public.categories(space_id,kind,name) values(other_scope,'expense','Business sentinel') returning id into sentinel;
 insert into public.wallets(space_id,name,wallet_group,currency) values(scope,'Cash','cash','RUB') returning id into wallet;
 perform set_config('request.jwt.claim.sub',actor::text,true);
 execute 'set local role authenticated';
 expense := public.create_expense(gen_random_uuid(),scope,wallet,leaf,'12345',date '2026-10-06','Preserve historical path');
 execute 'reset role';
 select jsonb_agg(jsonb_build_object('key',category_key,'id',case when category_key='home' then root when category_key='home-household' then leaf else gen_random_uuid() end,
   'reuse',category_key in ('home','home-household'),'icon_id',icon_id) order by category_key) into plan from finance_private.personal_expense_catalog;
 select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into expected from public.categories where space_id=scope and kind='expense';
 refs := finance_private.personal_expense_references(scope);
 begin
   perform finance_private.install_personal_expenses_20261006(scope,actor,plan,'[]',refs);
   raise exception 'FAIL stale snapshot';
 exception when sqlstate 'P1003' then null; end;
 begin
   perform finance_private.install_personal_expenses_20261006(scope,actor,plan,expected,'{}');
   raise exception 'FAIL stale references';
 exception when others then if sqlerrm<>'References changed since backup; prepare a fresh package' then raise; end if; end;
 begin
   perform finance_private.install_personal_expenses_20261006(scope,actor,plan||jsonb_build_array(plan->0),expected,refs);
   raise exception 'FAIL duplicate mapping';
 exception when others then if sqlerrm<>'Expected all 143 catalog mappings' then raise; end if; end;
 result := finance_private.install_personal_expenses_20261006(scope,actor,plan,expected,refs);
 if result->>'reused'<>'2' or result->>'created'<>'141' or result->>'moved'<>'1' then raise exception 'Counts wrong: %',result; end if;
 if (select parent_id from public.categories where id=leaf)<>root or (select parent_id from public.categories where id=grandchild)<>leaf then raise exception 'IDs or subtree lost'; end if;
 if finance_private.personal_expense_references(scope)<>refs then raise exception 'Operation/path/amount/revision changed'; end if;
 if not exists(select 1 from public.categories where id=extra and is_archived and parent_id is null and sort_order>16)
   or not exists(select 1 from public.categories where id=income and kind='income') or not exists(select 1 from public.categories where id=sentinel and space_id=other_scope) then raise exception 'Extras/scopes lost'; end if;
 -- Different people can share a label/image, never UUIDs.
 if (select count(distinct category_id) from finance_private.personal_expense_mappings where space_id=scope)<>143 then raise exception 'Conflated paths'; end if;
 update public.categories set name='User name',sort_order=900,icon_id='cat_exp_food' where id=leaf;
 delete from public.categories where id=(select category_id from finance_private.personal_expense_mappings where space_id=scope and category_key='outings-other');
 select jsonb_agg(to_jsonb(c) order by id) into snapshot from public.categories c;
 result := finance_private.install_personal_expenses_20261006(scope,actor,plan,'[]','{}');
 if result->>'replay'<>'true' or snapshot<>(select jsonb_agg(to_jsonb(c) order by id) from public.categories c) then raise exception 'Replay restored user edits/deletion'; end if;
end $test$;
rollback;
