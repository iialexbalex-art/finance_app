-- 017: Personal expense reconciliation; run the complete prepared file as postgres.
begin;
do $admin$ begin
  if current_user <> 'postgres' then raise exception 'Run as postgres'; end if;
  if not exists(select 1 from pg_attribute where attrelid='public.categories'::regclass and attname='revision' and not attisdropped) then
    raise exception 'Migration 016 is required';
  end if;
end $admin$;

create table if not exists finance_private.personal_expense_catalog (
  category_key text primary key, name text not null, parent_key text,
  sort_order integer not null, icon_id text not null
);
insert into finance_private.personal_expense_catalog values
  ('sasha','Саша лично',null,1,'personal_sasha'),
  ('sasha-haircut','Стрижка','sasha',1,'personal_haircut'),
  ('sasha-lenses','Для линз','sasha',2,'personal_lenses'),
  ('sasha-clothes','Одежда','sasha',3,'personal_clothes'),
  ('sasha-fishing','Рыбалка','sasha',4,'personal_fishing'),
  ('sasha-gift','Подарок','sasha',5,'bizexp_corporate-gifts-birthday-gifts'),
  ('sasha-hookah-supplies','Препараты для кальяна','sasha',6,'personal_hookah_supplies'),
  ('sasha-nails','Ногти','sasha',7,'personal_nails'),
  ('entertainment','Развлечения',null,2,'personal_entertainment'),
  ('entertainment-cafe','Кафе','entertainment',1,'personal_cafe'),
  ('entertainment-cinema','Кино','entertainment',2,'personal_cinema'),
  ('entertainment-concert','Концерт','entertainment',3,'personal_concert'),
  ('entertainment-home-party','Тусим дома','entertainment',4,'personal_home_party'),
  ('entertainment-birthday','День рождения','entertainment',5,'personal_birthday'),
  ('entertainment-hookah','Кальян','entertainment',6,'personal_hookah'),
  ('outings','Вылазки куда-нибудь',null,3,'personal_outings'),
  ('outings-fuel','Бензин','outings',1,'bizexp_lawyer-travel-fuel'),
  ('outings-car','Автомобиль','outings',2,'personal_car'),
  ('outings-parking','Парковка','outings',3,'personal_parking'),
  ('outings-shopping','Покупки','outings',4,'personal_shopping'),
  ('outings-trips','Поездки','outings',5,'personal_outings'),
  ('outings-phone','Связь','outings',6,'personal_phone'),
  ('outings-food','Еда','outings',7,'cat_exp_food'),
  ('outings-cafe','Кафе','outings',8,'personal_cafe'),
  ('outings-housing','Аренда жилья','outings',9,'personal_housing'),
  ('outings-entertainment','Развлечения','outings',10,'personal_entertainment'),
  ('outings-transport','Транспорт','outings',11,'personal_transport'),
  ('outings-taxi','Такси','outings',12,'personal_taxi'),
  ('outings-souvenirs','Сувениры','outings',13,'personal_souvenirs'),
  ('outings-airfare','Авиабилеты','outings',14,'bizexp_lawyer-travel-tickets'),
  ('outings-other','Другое','outings',15,'personal_other'),
  ('natasha','Наташа лично',null,4,'personal_natasha'),
  ('natasha-marketplaces','Маркетплейсы','natasha',1,'personal_shopping'),
  ('natasha-clothes-shoes','Одежда и обувь','natasha',2,'personal_clothes_shoes'),
  ('natasha-books','Книги','natasha',3,'personal_books'),
  ('natasha-learning','Обучение','natasha',4,'personal_education'),
  ('natasha-massage','Массаж','natasha',5,'personal_massage'),
  ('natasha-cosmetics','Косметика','natasha',6,'personal_cosmetics'),
  ('natasha-nails','Ногти','natasha',7,'personal_nails'),
  ('natasha-cosmetology','Косметолог','natasha',8,'personal_cosmetology'),
  ('natasha-eyelashes','Ресницы','natasha',9,'personal_eyelashes'),
  ('natasha-gifts','Подарки','natasha',10,'bizexp_corporate-gifts-birthday-gifts'),
  ('natasha-sport','Спорт','natasha',11,'personal_fitness'),
  ('misha','Миша',null,5,'personal_misha'),
  ('misha-student-money','Студенческие деньги','misha',1,'personal_allowance'),
  ('misha-clothes','Одежда','misha',2,'personal_clothes'),
  ('misha-entertainment','Развлечения','misha',3,'personal_entertainment'),
  ('misha-gifts','Подарки','misha',4,'bizexp_corporate-gifts-birthday-gifts'),
  ('misha-tutor','Репетитор','misha',5,'personal_tutor'),
  ('misha-earned','Заработал','misha',6,'personal_earned'),
  ('masha','Маша',null,6,'personal_masha'),
  ('masha-marketplaces','Маркетплейсы','masha',1,'personal_shopping'),
  ('masha-cosmetics','Косметика','masha',2,'personal_cosmetics'),
  ('masha-manicure','Маникюр','masha',3,'personal_nails'),
  ('masha-gym','Тренажёрный зал','masha',4,'personal_fitness'),
  ('masha-lenses','Линзы','masha',5,'personal_lenses'),
  ('masha-pocket-money','Карманные деньги','masha',6,'personal_allowance'),
  ('masha-learning','Обучение','masha',7,'personal_education'),
  ('masha-haircut','Стрижка','masha',8,'personal_haircut'),
  ('masha-gifts','Подарки','masha',9,'bizexp_corporate-gifts-birthday-gifts'),
  ('masha-school-fees','Сборы в школе','masha',10,'personal_school_fees'),
  ('masha-earned','Заработала','masha',11,'personal_earned'),
  ('masha-tutor','Репетитор','masha',12,'personal_tutor'),
  ('masha-books','Книги','masha',13,'personal_books'),
  ('home','Дом',null,7,'personal_home'),
  ('home-appliances','Бытовая техника','home',1,'personal_appliances'),
  ('home-renovation-materials','Материалы к ремонту','home',2,'bizexp_office-office-renovation'),
  ('home-builders','Строители','home',3,'personal_builders'),
  ('home-electronics','Мелкая электроника','home',4,'personal_electronics'),
  ('home-firewood','Дрова','home',5,'personal_firewood'),
  ('home-textiles','Текстиль','home',6,'personal_textiles'),
  ('home-household','Хозтовары для дома','home',7,'bizexp_office-office-supplies'),
  ('home-sauna-furniture','Мебель для бани','home',8,'personal_sauna_furniture'),
  ('home-small-household','По мелочи для хозяйства','home',9,'personal_other'),
  ('home-repair-appliance','Ремонт техники','home',10,'personal_repair_appliance'),
  ('home-property','Приобретение имущества','home',11,'personal_housing'),
  ('home-marketplace','Маркетплейс для дома','home',12,'personal_shopping'),
  ('home-services','Услуги для дома','home',13,'personal_builders'),
  ('home-utilities','Коммунальные услуги','home',14,'bizexp_office-utilities'),
  ('jaecoo','Авто Jaecoo',null,8,'personal_jaecoo'),
  ('jaecoo-other','Что-то другое к авто','jaecoo',1,'personal_car_accessories'),
  ('jaecoo-carwash','Мойка','jaecoo',2,'personal_carwash'),
  ('jaecoo-service','Техническое обслуживание','jaecoo',3,'personal_car_service'),
  ('jaecoo-parts','Запчасти','jaecoo',4,'personal_car_parts'),
  ('jaecoo-sim','SIM-карта','jaecoo',5,'personal_sim'),
  ('jaecoo-fines','Штрафы ГИБДД','jaecoo',6,'personal_fine'),
  ('jaecoo-kasko','Страховка КАСКО','jaecoo',7,'personal_kasko'),
  ('jaecoo-osago','Страховка ОСАГО','jaecoo',8,'personal_osago'),
  ('jaecoo-insurance-kz','Страховка Казахстан','jaecoo',9,'personal_insurance_kz'),
  ('mazda','Автомобиль Mazda',null,9,'personal_mazda'),
  ('mazda-carwash','Автомойка','mazda',1,'personal_carwash'),
  ('mazda-service','Техобслуживание','mazda',2,'personal_car_service'),
  ('mazda-sim','SIM-карта','mazda',3,'personal_sim'),
  ('mazda-kasko','Страховка КАСКО','mazda',4,'personal_kasko'),
  ('mazda-osago','Страховка ОСАГО','mazda',5,'personal_osago'),
  ('mazda-other','Что-то другое к авто','mazda',6,'personal_car_accessories'),
  ('subscriptions','Подписки',null,10,'bizexp_bank-fees-account-subscription'),
  ('subscriptions-hbo','HBO','subscriptions',1,'personal_hbo'),
  ('subscriptions-bukovitsa','Буковица','subscriptions',2,'personal_books'),
  ('subscriptions-mail','Облако Mail','subscriptions',3,'personal_mail_cloud'),
  ('subscriptions-start','Старт','subscriptions',4,'personal_start'),
  ('subscriptions-music','Яндекс Музыка','subscriptions',5,'personal_yandex_music'),
  ('subscriptions-finance','Финанс','subscriptions',6,'personal_finance_app'),
  ('subscriptions-pm','PM','subscriptions',7,'personal_pm'),
  ('subscriptions-disk','Яндекс Диск','subscriptions',8,'bizexp_advertising-services-yandex-disk'),
  ('subscriptions-ivi','ivi','subscriptions',9,'personal_ivi'),
  ('subscriptions-premier','Премьер','subscriptions',10,'personal_premier'),
  ('subscriptions-audiobooks','Аудиокниги','subscriptions',11,'personal_audiobooks'),
  ('subscriptions-mybook','MyBook','subscriptions',12,'personal_audiobooks'),
  ('subscriptions-kinopoisk','Кинопоиск','subscriptions',13,'personal_kinopoisk'),
  ('subscriptions-nikotin','Дмитрий Никотин','subscriptions',14,'personal_commentator'),
  ('subscriptions-telegram','Телеграм','subscriptions',15,'personal_telegram'),
  ('subscriptions-radar','Радар','subscriptions',16,'personal_radar'),
  ('subscriptions-chatgpt','ChatGPT','subscriptions',17,'personal_chatgpt'),
  ('subscriptions-vpn','VPN','subscriptions',18,'personal_vpn'),
  ('subscriptions-zoom','Zoom','subscriptions',19,'personal_zoom'),
  ('kazan','Квартира Казань',null,11,'personal_housing'),
  ('kazan-renovation','Ремонт','kazan',1,'bizexp_office-office-renovation'),
  ('kazan-furniture','Мебель','kazan',2,'personal_furniture'),
  ('kazan-other','Другое','kazan',3,'personal_other'),
  ('equipment','Техника',null,12,'personal_equipment'),
  ('equipment-snowmobile','Снегоход','equipment',1,'personal_snowmobile'),
  ('equipment-snowblower','Снегоуборщик','equipment',2,'personal_snowblower'),
  ('equipment-mower','Газонокосилка','equipment',3,'personal_mower'),
  ('equipment-trimmer','Триммер','equipment',4,'personal_trimmer'),
  ('loans','Кредиты',null,13,'personal_loans'),
  ('loans-jaecoo','Авто Jaecoo','loans',1,'personal_jaecoo'),
  ('loans-mortgage','Ипотека','loans',2,'personal_mortgage'),
  ('loans-masha-education','Маша — обучение','loans',3,'personal_education'),
  ('finance','Финансы',null,14,'bizexp_office-extra-accounting'),
  ('finance-mazda-tax','Налог на автомобиль Mazda','finance',1,'personal_car_tax'),
  ('finance-jaecoo-tax','Налог на автомобиль Jaecoo','finance',2,'personal_car_tax'),
  ('finance-land-rent','Аренда земли','finance',3,'personal_land_rent'),
  ('finance-fines','Штрафы','finance',4,'personal_fine'),
  ('finance-other','Иные','finance',5,'personal_other'),
  ('education','Образование',null,15,'personal_education'),
  ('education-online','Онлайн-тренинги','education',1,'personal_online_learning'),
  ('education-offline','Офлайн-тренинги','education',2,'personal_offline_learning'),
  ('education-english','Английский детям','education',3,'personal_english'),
  ('education-group-course','Складчина','education',4,'personal_group_course'),
  ('bank-fees','Банковские комиссии',null,16,'bizexp_bank-fees'),
  ('bank-fees-sber','Обслуживание карты Сбер Премьер','bank-fees',1,'card_sber_green'),
  ('bank-fees-tinkoff','Обслуживание карты Тиньков','bank-fees',2,'card_t_bank_black_hq_v1')
on conflict(category_key) do nothing;

create table if not exists finance_private.personal_expense_installations (
  space_id uuid not null references public.spaces(id), package_key text not null,
  installed_at timestamptz not null default now(), result jsonb not null,
  categories_before jsonb not null, references_before jsonb not null,
  primary key(space_id,package_key)
);
-- No category FK: a later deliberate deletion must remain deleted on replay.
create table if not exists finance_private.personal_expense_mappings (
  space_id uuid not null, package_key text not null, category_key text not null,
  category_id uuid not null, resolution text not null check(resolution in ('created','reused')),
  primary key(space_id,package_key,category_key), unique(space_id,package_key,category_id)
);
revoke all on finance_private.personal_expense_catalog,finance_private.personal_expense_installations,
  finance_private.personal_expense_mappings from public,anon,authenticated;

create or replace function finance_private.personal_expense_references(p_space uuid)
returns jsonb language sql stable set search_path='' set timezone='UTC' as $fn$
select jsonb_build_object(
 'expenses',coalesce((select jsonb_agg(to_jsonb(e)||jsonb_build_object('amount_minor',e.amount_minor::text) order by e.id) from public.expenses e where e.space_id=p_space and not e.is_void),'[]'::jsonb),
 'incomes',coalesce((select jsonb_agg(to_jsonb(i)||jsonb_build_object('amount_minor',i.amount_minor::text) order by i.id) from public.incomes i where i.space_id=p_space),'[]'::jsonb),
 'transfers',coalesce((select jsonb_agg(to_jsonb(t)||jsonb_build_object('source_minor',t.source_minor::text,'target_minor',t.target_minor::text,'fee_minor',t.fee_minor::text) order by t.id) from public.transfers t where t.space_id=p_space),'[]'::jsonb)
);
$fn$;
revoke all on function finance_private.personal_expense_references(uuid) from public,anon,authenticated;

create or replace function finance_private.install_personal_expenses_20261006(
  p_space uuid,p_owner uuid,p_plan jsonb,p_expected jsonb,p_references jsonb
) returns jsonb language plpgsql volatile security invoker set search_path='' as $fn$
declare
  package constant text := 'personal_expenses_20261006_v1';
  before_categories jsonb; before_refs jsonb; untouched jsonb; money jsonb;
  result jsonb; created integer; reused integer; moved integer;
begin
  if current_user <> 'postgres' then raise exception using errcode='42501',message='Run as postgres'; end if;
  update finance_private.category_tree_guard set flip=not flip where singleton;
  if not found then raise exception 'Missing category tree guard'; end if;
  if not exists(select 1 from public.spaces where id=p_space and kind='personal' and owner_user_id=p_owner) then
    raise exception 'Wrong personal space or owner';
  end if;
  select i.result into result from finance_private.personal_expense_installations i where i.space_id=p_space and i.package_key=package;
  if found then return result||jsonb_build_object('replay',true); end if;
  perform finance_private.check_category_snapshot(p_space,'expense',p_expected);
  before_refs := finance_private.personal_expense_references(p_space);
  if before_refs <> p_references then raise exception 'References changed since backup; prepare a fresh package'; end if;
  if jsonb_typeof(p_plan)<>'array' or jsonb_array_length(p_plan)<>143 then raise exception 'Expected all 143 catalog mappings'; end if;
  if exists(select 1 from pg_constraint k where k.contype='f' and k.confrelid='public.categories'::regclass
    and k.conrelid in (select oid from pg_class where relnamespace='public'::regnamespace)
    and k.conrelid not in ('public.categories'::regclass,'public.expenses'::regclass,'public.incomes'::regclass,'public.transfers'::regclass)) then
    raise exception 'Unexpected public category references; review before import';
  end if;
  create temporary table personal_plan on commit drop as
    select x.key category_key,x.id,x.reuse,x.icon_id,c.name,c.parent_key,c.sort_order
    from jsonb_to_recordset(p_plan) as x(key text,id uuid,reuse boolean,icon_id text)
    join finance_private.personal_expense_catalog c on c.category_key=x.key;
  if (select count(*) from personal_plan)<>143 or (select count(distinct id) from personal_plan)<>143
    or (select count(distinct category_key) from personal_plan)<>143
    or exists(select 1 from personal_plan where id is null or reuse is null or icon_id is null or icon_id!~'^[a-z][a-z0-9_-]{0,95}$') then
    raise exception 'Incomplete or duplicate plan';
  end if;
  if exists(select 1 from personal_plan p left join public.categories c on c.id=p.id
      where (p.reuse and (c.id is null or c.space_id<>p_space or c.kind<>'expense')) or (not p.reuse and c.id is not null)) then
    raise exception 'Invalid reused category or colliding new UUID';
  end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) into before_categories from public.categories c where c.space_id=p_space and c.kind='expense';
  select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) into untouched from public.categories c where c.space_id<>p_space or c.kind<>'expense';
  money := jsonb_build_object(
    'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]'::jsonb) from public.expenses e),
    'incomes',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]'::jsonb) from public.incomes i),
    'transfers',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb) from public.transfers t),
    'wallets',(select coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb) from public.wallets w),
    'opening',(select coalesce(jsonb_agg(to_jsonb(o) order by wallet_id),'[]'::jsonb) from public.wallet_opening_balances o));
  select count(*) filter(where not reuse),count(*) filter(where reuse) into created,reused from personal_plan;
  select count(*) into moved from personal_plan p join public.categories c on c.id=p.id
    left join personal_plan parent on parent.category_key=p.parent_key where p.reuse and c.parent_id is distinct from parent.id;
  -- Insert/activate roots before children. Detaching roots cannot increase depth.
  insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order)
    select id,p_space,'expense',name,null,icon_id,sort_order from personal_plan where not reuse and parent_key is null;
  update public.categories c set name=p.name,parent_id=null,icon_id=p.icon_id,sort_order=p.sort_order,is_archived=false
    from personal_plan p where p.reuse and p.parent_key is null and c.id=p.id;
  insert into public.categories(id,space_id,kind,name,parent_id,icon_id,sort_order)
    select p.id,p_space,'expense',p.name,parent.id,p.icon_id,p.sort_order from personal_plan p
    join personal_plan parent on parent.category_key=p.parent_key where not p.reuse;
  -- One statement validates the final state for every retained subtree.
  update public.categories c set name=p.name,parent_id=parent.id,icon_id=p.icon_id,sort_order=p.sort_order,is_archived=false
    from personal_plan p join personal_plan parent on parent.category_key=p.parent_key
    where p.reuse and c.id=p.id;
  -- Retained siblings follow the catalog without changing relative order/links.
  with extras as (
    select c.id,c.parent_id,row_number() over(partition by c.parent_id order by nullif(c.sort_order,0) nulls last,c.created_at,c.id) ordinal
    from public.categories c where c.space_id=p_space and c.kind='expense'
      and not exists(select 1 from personal_plan p where p.id=c.id)
      and (c.parent_id is null or exists(select 1 from personal_plan p where p.id=c.parent_id))
  ), ranked as (
    select e.id,e.ordinal+coalesce((select max(p.sort_order) from personal_plan p
      left join personal_plan parent on parent.category_key=p.parent_key where parent.id is not distinct from e.parent_id),0) position from extras e
  ) update public.categories c set sort_order=r.position::integer from ranked r where c.id=r.id;
  if finance_private.personal_expense_references(p_space)<>before_refs then raise exception 'Financial references changed'; end if;
  if untouched is distinct from (select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) from public.categories c where c.space_id<>p_space or c.kind<>'expense') then
    raise exception 'Unrelated scope changed';
  end if;
  if money <> jsonb_build_object(
    'expenses',(select coalesce(jsonb_agg(to_jsonb(e) order by id),'[]'::jsonb) from public.expenses e),
    'incomes',(select coalesce(jsonb_agg(to_jsonb(i) order by id),'[]'::jsonb) from public.incomes i),
    'transfers',(select coalesce(jsonb_agg(to_jsonb(t) order by id),'[]'::jsonb) from public.transfers t),
    'wallets',(select coalesce(jsonb_agg(to_jsonb(w) order by id),'[]'::jsonb) from public.wallets w),
    'opening',(select coalesce(jsonb_agg(to_jsonb(o) order by wallet_id),'[]'::jsonb) from public.wallet_opening_balances o)) then raise exception 'Financial data changed'; end if;
  if (select count(*) from personal_plan p join public.categories c on c.id=p.id and c.space_id=p_space and c.kind='expense'
    left join personal_plan parent on parent.category_key=p.parent_key
    where c.name=p.name and c.parent_id is not distinct from parent.id and c.sort_order=p.sort_order and c.icon_id=p.icon_id and not c.is_archived)<>143 then
    raise exception 'Final catalog validation failed';
  end if;
  insert into finance_private.personal_expense_mappings(space_id,package_key,category_key,category_id,resolution)
    select p_space,package,category_key,id,case when reuse then 'reused' else 'created' end from personal_plan;
  result := jsonb_build_object('installed',143,'roots',16,'children',127,'reused',reused,'moved',moved,'created',created,'merged',0,'replay',false);
  insert into finance_private.personal_expense_installations(space_id,package_key,result,categories_before,references_before)
    values(p_space,package,result,before_categories,before_refs);
  return result;
end $fn$;
revoke all on function finance_private.install_personal_expenses_20261006(uuid,uuid,jsonb,jsonb,jsonb) from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
