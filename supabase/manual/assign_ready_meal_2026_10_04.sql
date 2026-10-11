-- Одноразовое назначение утверждённого PNG существующим категориям.
-- Выполнить целиком как postgres после уже установленной схемы 013.
-- Повтор безопасен: журнал по ID не сбрасывает последующий ручной выбор.
-- Категории, операции, суммы, parent_id и собственная активность не меняются.
begin;
do $check$
begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
end
$check$;

create table if not exists finance_private.ready_meal_image_assignments (
  category_id uuid primary key references public.categories(id) on delete restrict,
  previous_icon_id text not null,
  applied_at timestamptz not null default now()
);
revoke all on finance_private.ready_meal_image_assignments from public, anon, authenticated;

-- Сериализация с обычными сохранениями: ручной выбор после этого COMMIT
-- никогда не переписывается повторным запуском этого файла.
lock table public.categories in share row exclusive mode;
with logged as (
  insert into finance_private.ready_meal_image_assignments(category_id, previous_icon_id)
  select id, icon_id from public.categories
  where name = 'Готовая еда' and kind = 'expense'
    and space_id in (
      '442a3d32-ed11-4075-9c3b-43e72d121ce8'::uuid,
      '41e63f8c-78c4-4e49-8195-c0ad3bd1e1ff'::uuid
    )
  on conflict (category_id) do nothing
  returning category_id
)
update public.categories c
set icon_id = 'ready_meal_plov_bread_tea_v1'
from logged where c.id = logged.category_id
returning c.id, c.space_id, c.name, c.parent_id, c.is_archived, c.icon_id;

-- Нулевое количество означает отсутствие ТОЧНОГО имени в этом пространстве.
-- В этом случае никакие категории не создаются; PNG доступен в выборе значка.
select s.id as space_id, s.name as space_name,
  count(c.id) as exact_matches,
  case when count(c.id) = 0 then 'Точное имя «Готовая еда» не найдено'
       else 'Точные записи обработаны или уже были обработаны' end as result
from public.spaces s
left join public.categories c on c.space_id = s.id
  and c.kind = 'expense' and c.name = 'Готовая еда'
where s.id in (
  '442a3d32-ed11-4075-9c3b-43e72d121ce8'::uuid,
  '41e63f8c-78c4-4e49-8195-c0ad3bd1e1ff'::uuid
)
group by s.id, s.name;
commit;
