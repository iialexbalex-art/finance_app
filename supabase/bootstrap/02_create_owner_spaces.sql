-- Выполнить ПОСЛЕ миграции, целиком, роль postgres в Supabase SQL Editor.
-- Заменить значение supplied_uuid ниже точным UUID
-- вашей учётной записи из Authentication -> Users. Не email и не UUID проекта.
-- Не выбирает первого пользователя, не использует auth.uid() SQL Editor.
begin;

do $bootstrap$
declare
  supplied_uuid text := '4e168f1a-df7f-40de-a8cb-2f311e6307c2';
  owner_uuid uuid;
begin
  if current_user <> 'postgres' then
    raise exception 'Run bootstrap as postgres in Supabase SQL Editor';
  end if;
  begin
    owner_uuid := supplied_uuid::uuid;
  exception when invalid_text_representation then
    raise exception 'Invalid UUID: copy the full user ID from Authentication > Users';
  end;

  -- Точное совпадение и блокировка строки для повторного/параллельного запуска.
  perform 1 from auth.users where id = owner_uuid for update;
  if not found then
    raise exception 'No Authentication user with the supplied UUID';
  end if;

  if not exists (select 1 from public.spaces where owner_user_id = owner_uuid and kind = 'personal') then
    insert into public.spaces(owner_user_id, kind, name)
    values (owner_uuid, 'personal', 'Личные финансы');
  end if;
  if not exists (select 1 from public.spaces where owner_user_id = owner_uuid and kind = 'business') then
    insert into public.spaces(owner_user_id, kind, name)
    values (owner_uuid, 'business', 'Бизнес');
  end if;

  raise notice 'Owner spaces prepared for exact Authentication UUID: %', owner_uuid;
  -- Сохраняем UUID только на время транзакции для вывода результата ниже.
  perform set_config('finance.bootstrap_owner', owner_uuid::text, true);
end
$bootstrap$;

select id as space_id, owner_user_id, kind, name
from public.spaces
where owner_user_id = current_setting('finance.bootstrap_owner')::uuid
order by kind, created_at;

commit;
