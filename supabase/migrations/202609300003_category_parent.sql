-- После 001 и 002. Выполнить целиком как postgres. Агентом НЕ выполнено.
begin;
do $migration$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
end
$migration$;

-- Существующие RLS и составной FK дерева остаются без изменений.
grant update (parent_id) on public.categories to authenticated;

create function finance_private.check_category_parent()
returns trigger language plpgsql security invoker set search_path = ''
as $function$
declare
  parent_row public.categories%rowtype;
begin
  if tg_op = 'UPDATE' then
    if new.parent_id is not distinct from old.parent_id then return new; end if;
  end if;
  if new.parent_id is null then return new; end if;
  -- SHARE, а не KEY SHARE: блокирует также UPDATE is_archived.
  -- После ожидания читается актуальная строка при READ COMMITTED;
  -- при более строгой изоляции конфликт может вызвать serialization_failure.
  select * into parent_row from public.categories
    where id = new.parent_id for share;
  if not found or parent_row.space_id <> new.space_id
     or parent_row.kind <> new.kind or parent_row.parent_id is not null
     or new.parent_id = new.id then
    raise exception using errcode = '23514', message = 'Invalid category parent';
  end if;
  if parent_row.is_archived then
    raise exception using errcode = '23514', message = 'Category parent is archived';
  end if;
  return new;
end
$function$;
revoke all on function finance_private.check_category_parent() from public, anon, authenticated;
-- Триггер вызывается сервером; прямой EXECUTE клиенту не требуется.
create trigger categories_check_parent
before insert or update of parent_id on public.categories
for each row execute function finance_private.check_category_parent();

comment on table public.categories is
  'Два уровня. Владелец меняет parent_id; составной FK защищает дерево. Новый родитель не архивный, проверяется под SHARE-блокировкой. Архивирование существующего родителя сохраняет поддерево для истории.';
notify pgrst, 'reload schema';
commit;
