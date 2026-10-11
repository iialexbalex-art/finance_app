-- Synthetic PostgreSQL fixture. Never execute on a production project.
begin;
insert into auth.users(id) values('18000000-0000-0000-0000-000000000001'),('18000000-0000-0000-0000-000000000002'),('18000000-0000-0000-0000-000000000003');
insert into public.spaces(id,owner_user_id,kind,name) values
 ('18100000-0000-0000-0000-000000000001','18000000-0000-0000-0000-000000000001','personal','Backup personal'),
 ('18100000-0000-0000-0000-000000000002','18000000-0000-0000-0000-000000000001','business','Backup business'),
 ('18100000-0000-0000-0000-000000000003','18000000-0000-0000-0000-000000000003','personal','Other owner');
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
insert into public.wallets(id,space_id,name,wallet_group,currency,icon_id) values
 ('18200000-0000-0000-0000-000000000001','18100000-0000-0000-0000-000000000001','RUB wallet','cash','RUB','cash'),
 ('18200000-0000-0000-0000-000000000002','18100000-0000-0000-0000-000000000002','KZT wallet','cash','KZT','cash'),
 ('18200000-0000-0000-0000-000000000003','18100000-0000-0000-0000-000000000001','RUB target','cash','RUB','cash');
insert into public.wallet_opening_balances(wallet_id,amount_minor) values('18200000-0000-0000-0000-000000000001',9007199254740993);
insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order) values
 ('18300000-0000-0000-0000-000000000001','18100000-0000-0000-0000-000000000001','expense','Parent',null,'cat_exp_food',1),
 ('18300000-0000-0000-0000-000000000003','18100000-0000-0000-0000-000000000001','income','Income',null,'income',1),
 ('18300000-0000-0000-0000-000000000004','18100000-0000-0000-0000-000000000002','expense','Business',null,'category',1);
insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order) values
 ('18300000-0000-0000-0000-000000000002','18100000-0000-0000-0000-000000000001','expense','Child','18300000-0000-0000-0000-000000000001','category',1);
select public.create_expense('18400000-0000-0000-0000-000000000001','18100000-0000-0000-0000-000000000001','18200000-0000-0000-0000-000000000001','18300000-0000-0000-0000-000000000002','9007199254740993','2026-10-07','exact');
select public.save_income('18400000-0000-0000-0000-000000000002','18100000-0000-0000-0000-000000000001',null,null,'18200000-0000-0000-0000-000000000001','18300000-0000-0000-0000-000000000003','12345','2026-10-07','','RUB',2);
select public.save_transfer('18400000-0000-0000-0000-000000000003',jsonb_build_object(
 'space_id','18100000-0000-0000-0000-000000000001','id',null,'revision',null,
 'source_id','18200000-0000-0000-0000-000000000001','target_id','18200000-0000-0000-0000-000000000003',
 'source_minor','100','target_minor','100','fee_minor','10','fee_category_id','18300000-0000-0000-0000-000000000002',
 'source_currency','RUB','target_currency','RUB','source_scale',2,'target_scale',2,'date','2026-10-07','comment','Transfer'));
select finance_private.backup_worker_release('test','{}');
do $$ declare owner uuid:='18000000-0000-0000-0000-000000000001'; snapshot uuid; before_restore uuid;
 data jsonb; current_data jsonb; request uuid; old_revision uuid; history_count integer; expected jsonb; t text; old_rows jsonb; new_rows jsonb; balances jsonb;
begin
 data:=finance_private.backup_data(owner);
 balances:=public.space_balances('18100000-0000-0000-0000-000000000001');
 if data->'wallet_opening_balances'->0->>'amount_minor'<>'9007199254740993' then raise exception 'Lost exact money'; end if;
 if jsonb_array_length(data->'spaces')<>2 then raise exception 'Owner scope leaked'; end if;
 snapshot:=public.backup_capture('18500000-0000-0000-0000-000000000001','manual','Original');
 if snapshot is distinct from public.backup_capture('18500000-0000-0000-0000-000000000001','manual','Original') then raise exception 'Capture not idempotent'; end if;
 if (select state from finance_private.backup_jobs where id=snapshot)<>'queued' then raise exception 'False ready'; end if;
 perform finance_private.backup_worker_claim(owner,snapshot);
 perform finance_private.backup_worker_seal(owner,snapshot,repeat('a',64),10,10,'test');
 select count(*) into history_count from finance_private.backup_actions;
 update public.categories set name='Changed' where id='18300000-0000-0000-0000-000000000002';
 if (select count(*) from finance_private.backup_actions)<>history_count+1 then raise exception 'Missing history'; end if;
 request:=gen_random_uuid(); before_restore:=public.backup_capture(request,'restore','Before restore');
 perform finance_private.backup_worker_claim(owner,before_restore);
 perform finance_private.backup_worker_seal(owner,before_restore,repeat('b',64),10,10,'test');
 select revision into old_revision from public.expenses where transfer_id is null limit 1;
 perform finance_private.backup_restore(owner,snapshot,request);
 current_data:=finance_private.backup_data(owner);
 foreach t in array array['spaces','wallets','categories','wallet_opening_balances','transfers','expenses','incomes'] loop
  select jsonb_agg(value-'revision') into old_rows from jsonb_array_elements(data->t);
  select jsonb_agg(value-'revision') into new_rows from jsonb_array_elements(current_data->t);
  if old_rows is distinct from new_rows then raise exception 'Primary fields changed during restore: %',t; end if;
 end loop;
 if public.space_balances('18100000-0000-0000-0000-000000000001') is distinct from balances then raise exception 'Restored balances differ'; end if;
 if exists(select 1 from public.expenses where revision=old_revision) then raise exception 'Stale revision survived'; end if;
 if (select name from public.categories where id='18300000-0000-0000-0000-000000000002')<>'Child' then raise exception 'Restore failed'; end if;
 if (select count(*) from public.transfers)<>1 or (select count(*) from public.expenses)<>2 then raise exception 'Transfer duplicated/lost'; end if;
 if not exists(select 1 from public.spaces where id='18100000-0000-0000-0000-000000000003' and name='Other owner') then raise exception 'Other owner changed'; end if;
 perform finance_private.backup_restore(owner,snapshot,request);
 if (select count(*) from finance_private.backup_restore_audit where request_id=request)<>1 then raise exception 'Restore duplicated'; end if;
 request:=gen_random_uuid(); before_restore:=public.backup_capture(request,'before','Stale');
 perform finance_private.backup_worker_claim(owner,before_restore); perform finance_private.backup_worker_seal(owner,before_restore,repeat('c',64),1,1,'test');
 update public.wallets set name='Later' where id='18200000-0000-0000-0000-000000000001';
 begin perform finance_private.backup_require(request); raise exception 'Stale snapshot accepted'; exception when sqlstate 'P1018' then null; end;
 select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into expected from public.categories where space_id='18100000-0000-0000-0000-000000000001' and kind='expense';
 begin
  perform public.mutate_categories(gen_random_uuid(),'18100000-0000-0000-0000-000000000001','expense','archive',array['18300000-0000-0000-0000-000000000002'::uuid],expected);
  raise exception 'Unprotected bulk accepted'; exception when sqlstate 'P1018' then null;
 end;
end $$;
commit;
begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
update public.categories set name='Undo me' where id='18300000-0000-0000-0000-000000000002';
commit;
begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
do $$ declare op uuid; begin
 select operation_id into op from finance_private.backup_actions where table_name='categories' and after_row->>'name'='Undo me' order by id desc limit 1;
 perform public.backup_undo(op,'18600000-0000-0000-0000-000000000001');
 if (select name from public.categories where id='18300000-0000-0000-0000-000000000002')<>'Child' then raise exception 'Undo failed'; end if;
 perform public.backup_undo(op,'18600000-0000-0000-0000-000000000001');
end $$;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000002',true);
set local role authenticated;
do $$ begin
 begin perform public.backup_list(); raise exception 'Manager sees backups'; exception when insufficient_privilege then null; end;
 begin perform public.backup_history_list(); raise exception 'Manager sees history'; exception when insufficient_privilege then null; end;
 begin perform public.backup_capture(gen_random_uuid()); raise exception 'Manager creates backup'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000003',true);
set local role authenticated;
do $$ begin
 if jsonb_array_length(public.backup_list())<>0 then raise exception 'Other owner sees backups'; end if;
end $$;
reset role;
rollback;

begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
-- Actual narrow writes, request replay, stale revision, atomic history failure.
do $$ declare result jsonb; repeated jsonb; request uuid:=gen_random_uuid(); old_revision uuid;
 prior_name text; count_before integer; begin
 result:=public.backup_write(request,'wallets','create',null,null,'{"space_id":"18100000-0000-0000-0000-000000000001","name":"Created once","wallet_group":"cash","currency":"RUB"}');
 select count(*) into count_before from finance_private.backup_actions;
 repeated:=public.backup_write(request,'wallets','create',null,null,'{"space_id":"18100000-0000-0000-0000-000000000001","name":"Created once","wallet_group":"cash","currency":"RUB"}');
 if result<>repeated or (select count(*) from finance_private.backup_actions)<>count_before then raise exception 'Ordinary request duplicated'; end if;
 if result->>'icon_id'<>'cash' then raise exception 'Default icon changed'; end if;
 old_revision:=(result->>'revision')::uuid;
 result:=public.backup_write(gen_random_uuid(),'wallets','update',(result->>'id')::uuid,old_revision,'{"name":"Renamed"}');
 begin perform public.backup_write(gen_random_uuid(),'wallets','update',(result->>'id')::uuid,old_revision,'{"name":"Stale"}'); raise exception 'Stale wallet overwrite'; exception when sqlstate 'P1003' then null; end;
 if (select name from public.wallets where id=(result->>'id')::uuid)<>'Renamed' then raise exception 'Wallet update failed'; end if;
 begin perform public.backup_write(gen_random_uuid(),'wallets','delete','18200000-0000-0000-0000-000000000001',(select revision from public.wallets where id='18200000-0000-0000-0000-000000000001'),'{}'); raise exception 'Dependent wallet deleted'; exception when foreign_key_violation then null; end;
end $$;
create function finance_private.backup_test_history_failure() returns trigger language plpgsql as $$ begin raise exception 'Injected history failure'; end $$;
create trigger backup_test_failure before insert on finance_private.backup_actions for each row execute function finance_private.backup_test_history_failure();
do $$ declare old_name text; old_revision uuid; begin
 select name,revision into old_name,old_revision from public.categories where id='18300000-0000-0000-0000-000000000002';
 begin update public.categories set name='Must roll back' where id='18300000-0000-0000-0000-000000000002'; raise exception 'History failure accepted'; exception when raise_exception then if sqlerrm<>'Injected history failure' then raise; end if; end;
 if (select name from public.categories where id='18300000-0000-0000-0000-000000000002')<>old_name or (select revision from public.categories where id='18300000-0000-0000-0000-000000000002')<>old_revision then raise exception 'History failure changed data'; end if;
end $$;
drop trigger backup_test_failure on finance_private.backup_actions;
drop function finance_private.backup_test_history_failure();
rollback;

-- An isolated transaction contains exactly one transfer with its commission.
begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
select public.save_transfer('18700000-0000-0000-0000-000000000001',jsonb_build_object(
 'space_id','18100000-0000-0000-0000-000000000001','id',null,'revision',null,
 'source_id','18200000-0000-0000-0000-000000000001','target_id','18200000-0000-0000-0000-000000000003',
 'source_minor','20','target_minor','20','fee_minor','2','fee_category_id','18300000-0000-0000-0000-000000000002',
 'source_currency','RUB','target_currency','RUB','source_scale',2,'target_scale',2,'date','2026-10-07','comment','Undo transfer'));
commit;
begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
do $$ declare op uuid; request uuid:=gen_random_uuid(); saved uuid; original_count integer; begin
 select operation_id into op from finance_private.backup_actions where table_name='transfers' and after_row->>'comment'='Undo transfer' order by id desc limit 1;
 if (select count(*) from finance_private.backup_actions where operation_id=op)<>2 then raise exception 'Transfer not grouped with commission'; end if;
 saved:=public.backup_capture(request,'before','Before undo');
 perform finance_private.backup_worker_claim(auth.uid(),saved);perform finance_private.backup_worker_seal(auth.uid(),saved,repeat('d',64),1,1,'test');
 perform public.backup_undo(op,request);
 if (select count(*) from public.transfers)<>1 or (select count(*) from public.expenses)<>2 then raise exception 'Transfer undo partially applied'; end if;
end $$;
commit;

begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
-- Ready pre-action content, bulk idempotence and scoped role enforcement.
do $$ declare request uuid:=gen_random_uuid(); saved uuid; expected jsonb; n integer; begin
 saved:=public.backup_capture(request,'before','Before archive');
 perform finance_private.backup_worker_claim(auth.uid(),saved);perform finance_private.backup_worker_seal(auth.uid(),saved,repeat('e',64),1,1,'test');
 select jsonb_agg(jsonb_build_object('id',id,'revision',revision) order by id) into expected from public.categories where space_id='18100000-0000-0000-0000-000000000001' and kind='expense';
 perform public.mutate_categories(request,'18100000-0000-0000-0000-000000000001','expense','archive',array['18300000-0000-0000-0000-000000000001'::uuid,'18300000-0000-0000-0000-000000000002'::uuid],expected);
 if exists(select 1 from jsonb_array_elements((select payload->'data'->'categories' from finance_private.backup_jobs where id=saved)) r where (r->>'is_archived')::boolean) then raise exception 'Pre-action snapshot is not before action'; end if;
 select count(*) into n from finance_private.backup_actions;
 perform public.mutate_categories(request,'18100000-0000-0000-0000-000000000001','expense','archive',array['18300000-0000-0000-0000-000000000001'::uuid,'18300000-0000-0000-0000-000000000002'::uuid],expected);
 if (select count(*) from finance_private.backup_actions)<>n then raise exception 'Bulk retry duplicated history'; end if;
end $$;
set local role authenticated;
do $$ begin
 begin update public.wallets set name='Old client' where id='18200000-0000-0000-0000-000000000001'; raise exception 'Old client bypassed revisions'; exception when insufficient_privilege then null; end;
 begin perform finance_private.backup_worker_owners(); raise exception 'Worker API leaked'; exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;

begin;
select set_config('request.jwt.claim.sub','18000000-0000-0000-0000-000000000001',true);
do $$ declare source uuid; before_id uuid; request uuid:=gen_random_uuid(); original_payload jsonb; before_data jsonb; pinned uuid:=gen_random_uuid(); begin
 select id,payload into source,original_payload from finance_private.backup_jobs where comment='Original';
 before_data:=finance_private.backup_data(auth.uid());
 before_id:=public.backup_capture(request,'restore','Before failing restore');
 perform finance_private.backup_worker_claim(auth.uid(),before_id);perform finance_private.backup_worker_seal(auth.uid(),before_id,repeat('f',64),1,1,'test');
 update finance_private.backup_jobs set payload=jsonb_set(payload,'{data,wallets}','[]') where id=source;
 begin perform finance_private.backup_restore(auth.uid(),source,request); raise exception 'Incomplete restore accepted'; exception when raise_exception then if sqlerrm='Incomplete restore accepted' then raise; end if; end;
 if finance_private.backup_data(auth.uid())<>before_data then raise exception 'Failed restore modified data'; end if;
 update finance_private.backup_jobs set payload=original_payload where id=source;
 perform finance_private.backup_worker_pin(auth.uid(),source,pinned);
 begin perform finance_private.backup_worker_delete(auth.uid(),source); raise exception 'Pinned export deleted'; exception when raise_exception then if sqlerrm='Pinned export deleted' then raise; end if; end;
 perform finance_private.backup_worker_unpin(auth.uid(),pinned);
end $$;
rollback;
