# Конкурентные проверки 004 — подготовлены, НЕ запускались

Только изолированный проект с 001–004. Нужны две постоянные независимые SQL-сессии
одной БД (например, psql), первоначально как postgres. SQL Editor с пулом сессий
не подходит для удержания транзакции между нажатиями Run.

## Подготовка (один раз как postgres)

Этот набор fixtures намеренно фиксируется, чтобы обе сессии видели его.
Совпадение UUID должно остановить вставку. Не применять к рабочему проекту.

```sql
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000050');
insert into public.spaces(id,owner_user_id,kind,name) values
 ('10000000-0000-4000-8000-000000000050','00000000-0000-4000-8000-000000000050','business','Concurrency fixtures');
insert into public.categories(id,space_id,kind,name) values
 ('20000000-0000-4000-8000-000000000051','10000000-0000-4000-8000-000000000050','expense','A'),
 ('20000000-0000-4000-8000-000000000052','10000000-0000-4000-8000-000000000050','expense','B'),
 ('20000000-0000-4000-8000-000000000053','10000000-0000-4000-8000-000000000050','expense','C'),
 ('20000000-0000-4000-8000-000000000054','10000000-0000-4000-8000-000000000050','expense','D');
update public.categories set parent_id='20000000-0000-4000-8000-000000000051'
 where id='20000000-0000-4000-8000-000000000052';
commit;
```

В каждой сессии **один раз** включите обычную роль владельца:

```sql
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000050',false);
```

Перед КАЖДЫМ сценарием завершите обе транзакции, затем в одной сессии восстановите:

```sql
begin;
update public.categories set parent_id=null,is_archived=false
 where space_id='10000000-0000-4000-8000-000000000050';
update public.categories set parent_id='20000000-0000-4000-8000-000000000051'
 where id='20000000-0000-4000-8000-000000000052';
commit;
```

## 1. Два переноса, вместе дающие четвёртый уровень

Сессия 1:
```sql
begin;
update public.categories set parent_id='20000000-0000-4000-8000-000000000052'
 where id='20000000-0000-4000-8000-000000000053'; -- A→B→C
```
Сессия 2:
```sql
begin;
update public.categories set parent_id='20000000-0000-4000-8000-000000000054'
 where id='20000000-0000-4000-8000-000000000051'; -- попытка D→A→B→C
```
Сессия 2 ждёт. Выполните `commit;` в 1. Во 2 ожидается `23514`, затем `rollback;`.
У A родитель NULL, у C родитель B. Повторите с обратным порядком запросов:
первый перенос проходит, второй отклоняется; четвёртого уровня нет.

## 2. Взаимные переносы (цикл)

После восстановления: в сессии 1 BEGIN и A.parent_id=C; в сессии 2 BEGIN и
C.parent_id=A (точные UUID выше). Пока 1 не завершена, 2 ждёт. После COMMIT 1
сессия 2 получает `23514`; ROLLBACK 2. Повторить в обратном порядке. Цикла нет.

## 3. Создание потомка одновременно с переносом ветви

После восстановления сессия 1:
```sql
begin;
insert into public.categories(space_id,kind,name,parent_id) values
 ('10000000-0000-4000-8000-000000000050','expense','Concurrent child','20000000-0000-4000-8000-000000000052');
```
Сессия 2 BEGIN и перенос A к D, как в сценарии 1. После COMMIT 1 ожидается
`23514` во 2. Обратный порядок: A→B сначала переносится в D, затем INSERT под B
отклоняется как четвёртый уровень. После проверки архивировать тестовые строки
недостаточно для сброса глубины: используйте восстановление parent_id=NULL выше.

## 4. Архивирование предка одновременно с созданием/переносом

После восстановления в сессии 1:
```sql
begin;
update public.categories set is_archived=true
 where id='20000000-0000-4000-8000-000000000051';
```
В сессии 2 BEGIN и перенос C к B (либо INSERT под B, как выше). После COMMIT 1
ожидается `23514` во 2: архивирован дедушка, хотя B сам не архивен.
Обратный порядок: запись/перенос проходит; архивирование ждёт, затем проходит
как последовательное архивирование уже существующей ветви. ID/связи сохраняются.

## 5. Устаревший snapshot REPEATABLE READ

После восстановления сессия 2:
```sql
begin isolation level repeatable read;
select count(*) from public.categories; -- зафиксировать snapshot
```
Сессия 1 архивирует A и COMMIT. Сессия 2 пытается перенести C к B. Ожидается
`40001` при UPDATE guard, а не запись по старому snapshot; затем ROLLBACK.
Повторить с SERIALIZABLE. Ошибки 40001/40P01 требуют повтора всей транзакции;
успех записи с нарушением инвариантов недопустим.

## Итоговая проверка и очистка

После каждого сценария как postgres проверьте отсутствие строк в запросе:
```sql
with recursive chain as (
 select id,parent_id,array[id] as path,1 as depth,false as cycle from public.categories
 union all
 select c.id,p.parent_id,c.path||p.id,c.depth+1,p.id=any(c.path)
 from chain c join public.categories p on p.id=c.parent_id where c.depth<4 and not c.cycle
) select * from chain where depth>3 or cycle;
```
Проверьте ожидаемые parent_id по сценарию. Для очистки только этих fixtures
после завершения обеих сессий выполните как postgres:
```sql
begin;
update public.categories set parent_id=null where space_id='10000000-0000-4000-8000-000000000050';
delete from public.categories where space_id='10000000-0000-4000-8000-000000000050';
delete from public.spaces where id='10000000-0000-4000-8000-000000000050';
delete from auth.users where id='00000000-0000-4000-8000-000000000050';
commit;
```
