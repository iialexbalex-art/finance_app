-- Выполнить один раз как postgres ПОСЛЕ миграции 013.
-- Повтор безопасен: ранее обработанные ключи будут возвращены в skipped.
begin;

select finance_private.install_wallet_set_2026_10_02(
  '442a3d32-ed11-4075-9c3b-43e72d121ce8'::uuid, -- Личные финансы
  '41e63f8c-78c4-4e49-8195-c0ad3bd1e1ff'::uuid  -- Бизнес
) as import_result;

-- Контроль: должно быть 18 личных и 4 бизнес-кошелька из набора,
-- с нулевыми начальными остатками. Редактирование или удаление после импорта
-- не отменяется повторным запуском благодаря журналу стабильных set_key.
select s.kind,w.sort_order,w.name,w.wallet_group,w.currency,w.icon_id,
  coalesce(b.amount_minor,0) as opening_minor
from finance_private.wallet_set_imports i
join public.wallets w on w.id=i.wallet_id
join public.spaces s on s.id=i.space_id
left join public.wallet_opening_balances b on b.wallet_id=w.id
where i.set_version='wallet_set_2026_10_02'
  and i.space_id in(
    '442a3d32-ed11-4075-9c3b-43e72d121ce8'::uuid,
    '41e63f8c-78c4-4e49-8195-c0ad3bd1e1ff'::uuid
  )
order by case s.kind when 'personal' then 1 else 2 end,w.sort_order;

commit;
