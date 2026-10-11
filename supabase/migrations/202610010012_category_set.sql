-- Prepared after 001-011. Run once as postgres. The application never calls this installer.
begin;
do $migration$ begin
  if current_user <> 'postgres' then raise exception 'Run migration as postgres'; end if;
end $migration$;

create table finance_private.category_set_items (
  set_version text not null,
  set_key text not null,
  kind text not null check(kind in ('expense','income')),
  display_order integer not null check(display_order > 0),
  name text not null check(char_length(btrim(name)) between 1 and 100),
  icon_id text not null check(icon_id ~ '^[a-z][a-z0-9_]{0,47}$'),
  primary key(set_version,set_key),
  unique(set_version,kind,display_order),
  unique(set_version,icon_id)
);
revoke all on finance_private.category_set_items from public,anon,authenticated;

insert into finance_private.category_set_items(set_version,set_key,kind,display_order,name,icon_id) values
  ('category_set_2026_10_01','exp_food','expense',1,'Еда','cat_exp_food'),
  ('category_set_2026_10_01','exp_money_transfer','expense',2,'Перевод денег','cat_exp_money_transfer'),
  ('category_set_2026_10_01','exp_parking','expense',3,'Парковка','cat_exp_parking'),
  ('category_set_2026_10_01','exp_toll_road','expense',4,'Платная дорога','cat_exp_toll_road'),
  ('category_set_2026_10_01','exp_fuel','expense',5,'Бензин','cat_exp_fuel'),
  ('category_set_2026_10_01','exp_car','expense',6,'Автомобиль','cat_exp_car'),
  ('category_set_2026_10_01','exp_household_goods','expense',7,'Хозяйственные товары','cat_exp_household_goods'),
  ('category_set_2026_10_01','exp_hygiene','expense',8,'Гигиена','cat_exp_hygiene'),
  ('category_set_2026_10_01','exp_pharmacy','expense',9,'Аптека','cat_exp_pharmacy'),
  ('category_set_2026_10_01','exp_taxi','expense',10,'Такси','cat_exp_taxi'),
  ('category_set_2026_10_01','exp_cosmetics','expense',11,'Косметика','cat_exp_cosmetics'),
  ('category_set_2026_10_01','exp_phone','expense',12,'Телефон','cat_exp_phone'),
  ('category_set_2026_10_01','exp_intercom','expense',13,'Домофон','cat_exp_intercom'),
  ('category_set_2026_10_01','exp_internet','expense',14,'Интернет','cat_exp_internet'),
  ('category_set_2026_10_01','exp_utilities','expense',15,'Коммунальные услуги','cat_exp_utilities'),
  ('category_set_2026_10_01','exp_marketplaces','expense',16,'Маркетплейсы','cat_exp_marketplaces'),
  ('category_set_2026_10_01','exp_apartment','expense',17,'Квартира','cat_exp_apartment'),
  ('category_set_2026_10_01','exp_repair','expense',18,'Ремонт','cat_exp_repair'),
  ('category_set_2026_10_01','exp_appliances','expense',19,'Техника','cat_exp_appliances'),
  ('category_set_2026_10_01','exp_furniture','expense',20,'Мебель','cat_exp_furniture'),
  ('category_set_2026_10_01','exp_construction','expense',21,'Стройка','cat_exp_construction'),
  ('category_set_2026_10_01','exp_water','expense',22,'Вода','cat_exp_water'),
  ('category_set_2026_10_01','exp_rent','expense',23,'Аренда','cat_exp_rent'),
  ('category_set_2026_10_01','exp_office_equipment','expense',24,'Оргтехника','cat_exp_office_equipment'),
  ('category_set_2026_10_01','exp_business_cards','expense',25,'Визитки','cat_exp_business_cards'),
  ('category_set_2026_10_01','exp_cameras','expense',26,'Камеры','cat_exp_cameras'),
  ('category_set_2026_10_01','exp_cleaning','expense',27,'Уборка','cat_exp_cleaning'),
  ('category_set_2026_10_01','exp_delivery','expense',28,'Доставка','cat_exp_delivery'),
  ('category_set_2026_10_01','exp_haircut','expense',29,'Стрижка','cat_exp_haircut'),
  ('category_set_2026_10_01','exp_lenses_glasses','expense',30,'Линзы / очки','cat_exp_lenses_glasses'),
  ('category_set_2026_10_01','exp_clothing','expense',31,'Одежда','cat_exp_clothing'),
  ('category_set_2026_10_01','exp_shoes','expense',32,'Обувь','cat_exp_shoes'),
  ('category_set_2026_10_01','exp_fishing','expense',33,'Рыбалка','cat_exp_fishing'),
  ('category_set_2026_10_01','exp_gifts','expense',34,'Подарки','cat_exp_gifts'),
  ('category_set_2026_10_01','exp_hookah','expense',35,'Кальян','cat_exp_hookah'),
  ('category_set_2026_10_01','exp_manicure','expense',36,'Маникюр','cat_exp_manicure'),
  ('category_set_2026_10_01','exp_massage','expense',37,'Массаж','cat_exp_massage'),
  ('category_set_2026_10_01','exp_hair','expense',38,'Волосы','cat_exp_hair'),
  ('category_set_2026_10_01','exp_epilation','expense',39,'Эпиляция','cat_exp_epilation'),
  ('category_set_2026_10_01','exp_cosmetologist','expense',40,'Косметолог','cat_exp_cosmetologist'),
  ('category_set_2026_10_01','exp_model','expense',41,'Модель','cat_exp_model'),
  ('category_set_2026_10_01','exp_eyelashes','expense',42,'Ресницы','cat_exp_eyelashes'),
  ('category_set_2026_10_01','exp_electronics','expense',43,'Электроника','cat_exp_electronics'),
  ('category_set_2026_10_01','exp_sport','expense',44,'Спорт','cat_exp_sport'),
  ('category_set_2026_10_01','exp_sports_nutrition','expense',45,'Спортивное питание','cat_exp_sports_nutrition'),
  ('category_set_2026_10_01','exp_cafe_restaurant','expense',46,'Кафе / ресторан','cat_exp_cafe_restaurant'),
  ('category_set_2026_10_01','exp_cinema','expense',47,'Кино','cat_exp_cinema'),
  ('category_set_2026_10_01','exp_concert','expense',48,'Концерт','cat_exp_concert'),
  ('category_set_2026_10_01','exp_party','expense',49,'Вечеринка','cat_exp_party'),
  ('category_set_2026_10_01','exp_birthday','expense',50,'День рождения','cat_exp_birthday'),
  ('category_set_2026_10_01','exp_entertainment','expense',51,'Развлечения','cat_exp_entertainment'),
  ('category_set_2026_10_01','exp_travel','expense',52,'Путешествия','cat_exp_travel'),
  ('category_set_2026_10_01','exp_sim_card','expense',53,'SIM-карта','cat_exp_sim_card'),
  ('category_set_2026_10_01','exp_housing','expense',54,'Жильё','cat_exp_housing'),
  ('category_set_2026_10_01','exp_transport','expense',55,'Транспорт','cat_exp_transport'),
  ('category_set_2026_10_01','exp_souvenirs','expense',56,'Сувениры','cat_exp_souvenirs'),
  ('category_set_2026_10_01','exp_air_tickets','expense',57,'Авиабилеты','cat_exp_air_tickets'),
  ('category_set_2026_10_01','exp_education','expense',58,'Обучение','cat_exp_education'),
  ('category_set_2026_10_01','exp_tutor','expense',59,'Репетитор','cat_exp_tutor'),
  ('category_set_2026_10_01','exp_books','expense',60,'Книги','cat_exp_books'),
  ('category_set_2026_10_01','exp_public_speaking','expense',61,'Ораторское мастерство','cat_exp_public_speaking'),
  ('category_set_2026_10_01','exp_parkour','expense',62,'Паркур','cat_exp_parkour'),
  ('category_set_2026_10_01','exp_speech_therapist','expense',63,'Логопед','cat_exp_speech_therapist'),
  ('category_set_2026_10_01','exp_school','expense',64,'Школа','cat_exp_school'),
  ('category_set_2026_10_01','exp_trampoline','expense',65,'Батут','cat_exp_trampoline'),
  ('category_set_2026_10_01','exp_computer','expense',66,'Компьютер','cat_exp_computer'),
  ('category_set_2026_10_01','exp_driving_school','expense',67,'Автошкола','cat_exp_driving_school'),
  ('category_set_2026_10_01','exp_clubs_sections','expense',68,'Кружки / секции','cat_exp_clubs_sections'),
  ('category_set_2026_10_01','exp_acrobatics','expense',69,'Акробатика','cat_exp_acrobatics'),
  ('category_set_2026_10_01','exp_psychologist','expense',70,'Психолог','cat_exp_psychologist'),
  ('category_set_2026_10_01','exp_mentorship','expense',71,'Наставничество','cat_exp_mentorship'),
  ('category_set_2026_10_01','exp_mens_accessories','expense',72,'Мужские принадлежности','cat_exp_mens_accessories'),
  ('category_set_2026_10_01','exp_gym','expense',73,'Тренажёрный зал','cat_exp_gym'),
  ('category_set_2026_10_01','exp_sculpting','expense',74,'Лепка','cat_exp_sculpting'),
  ('category_set_2026_10_01','exp_drawing','expense',75,'Рисование','cat_exp_drawing'),
  ('category_set_2026_10_01','exp_pool','expense',76,'Бассейн','cat_exp_pool'),
  ('category_set_2026_10_01','exp_dance','expense',77,'Танцы','cat_exp_dance'),
  ('category_set_2026_10_01','exp_toys','expense',78,'Игрушки','cat_exp_toys'),
  ('category_set_2026_10_01','exp_theater','expense',79,'Театр','cat_exp_theater'),
  ('category_set_2026_10_01','exp_english','expense',80,'Английский язык','cat_exp_english'),
  ('category_set_2026_10_01','exp_stationery','expense',81,'Канцтовары','cat_exp_stationery'),
  ('category_set_2026_10_01','exp_sewing','expense',82,'Шитьё','cat_exp_sewing'),
  ('category_set_2026_10_01','exp_house','expense',83,'Дом','cat_exp_house'),
  ('category_set_2026_10_01','exp_garage','expense',84,'Гараж','cat_exp_garage'),
  ('category_set_2026_10_01','exp_lawn','expense',85,'Газон','cat_exp_lawn'),
  ('category_set_2026_10_01','exp_sewerage','expense',86,'Канализация','cat_exp_sewerage'),
  ('category_set_2026_10_01','exp_gas_utility','expense',87,'Газ','cat_exp_gas_utility'),
  ('category_set_2026_10_01','exp_electricity','expense',88,'Электроэнергия','cat_exp_electricity'),
  ('category_set_2026_10_01','exp_snow_blower','expense',89,'Снегоуборщик','cat_exp_snow_blower'),
  ('category_set_2026_10_01','exp_car_wash','expense',90,'Автомойка','cat_exp_car_wash'),
  ('category_set_2026_10_01','exp_maintenance','expense',91,'Техобслуживание','cat_exp_maintenance'),
  ('category_set_2026_10_01','exp_spare_parts','expense',92,'Запчасти','cat_exp_spare_parts'),
  ('category_set_2026_10_01','exp_fine','expense',93,'Штраф','cat_exp_fine'),
  ('category_set_2026_10_01','exp_insurance','expense',94,'Страхование','cat_exp_insurance'),
  ('category_set_2026_10_01','exp_snowmobile','expense',95,'Снегоход','cat_exp_snowmobile'),
  ('category_set_2026_10_01','exp_subscriptions','expense',96,'Подписки','cat_exp_subscriptions'),
  ('category_set_2026_10_01','exp_cloud_storage','expense',97,'Облачное хранилище','cat_exp_cloud_storage'),
  ('category_set_2026_10_01','exp_music','expense',98,'Музыка','cat_exp_music'),
  ('category_set_2026_10_01','exp_apps','expense',99,'Приложения','cat_exp_apps'),
  ('category_set_2026_10_01','exp_movies','expense',100,'Фильмы','cat_exp_movies'),
  ('category_set_2026_10_01','exp_audiobooks','expense',101,'Аудиокниги','cat_exp_audiobooks'),
  ('category_set_2026_10_01','exp_antivirus','expense',102,'Антивирус','cat_exp_antivirus'),
  ('category_set_2026_10_01','exp_telegram','expense',103,'Telegram','cat_exp_telegram'),
  ('category_set_2026_10_01','exp_vpn','expense',104,'VPN','cat_exp_vpn'),
  ('category_set_2026_10_01','exp_gpt_ai','expense',105,'GPT / ИИ','cat_exp_gpt_ai'),
  ('category_set_2026_10_01','exp_video_calls','expense',106,'Видеосвязь','cat_exp_video_calls'),
  ('category_set_2026_10_01','exp_parent_support','expense',107,'Помощь родителям','cat_exp_parent_support'),
  ('category_set_2026_10_01','exp_building_materials','expense',108,'Строительные материалы','cat_exp_building_materials'),
  ('category_set_2026_10_01','exp_workers','expense',109,'Рабочие','cat_exp_workers'),
  ('category_set_2026_10_01','exp_loan','expense',110,'Кредит','cat_exp_loan'),
  ('category_set_2026_10_01','exp_mortgage','expense',111,'Ипотека','cat_exp_mortgage'),
  ('category_set_2026_10_01','exp_credit_card','expense',112,'Кредитная карта','cat_exp_credit_card'),
  ('category_set_2026_10_01','exp_installment','expense',113,'Рассрочка','cat_exp_installment'),
  ('category_set_2026_10_01','exp_taxes','expense',114,'Налоги','cat_exp_taxes'),
  ('category_set_2026_10_01','exp_duties','expense',115,'Пошлины','cat_exp_duties'),
  ('category_set_2026_10_01','exp_land','expense',116,'Земля','cat_exp_land'),
  ('category_set_2026_10_01','exp_government_services','expense',117,'Госуслуги','cat_exp_government_services'),
  ('category_set_2026_10_01','exp_bank_fees','expense',118,'Банковские комиссии','cat_exp_bank_fees'),
  ('category_set_2026_10_01','exp_treatment','expense',119,'Лечение','cat_exp_treatment'),
  ('category_set_2026_10_01','exp_lab_tests','expense',120,'Анализы','cat_exp_lab_tests'),
  ('category_set_2026_10_01','exp_medicines','expense',121,'Лекарства','cat_exp_medicines'),
  ('category_set_2026_10_01','exp_doctor','expense',122,'Врач','cat_exp_doctor'),
  ('category_set_2026_10_01','exp_dentist','expense',123,'Стоматолог','cat_exp_dentist'),
  ('category_set_2026_10_01','exp_hospital','expense',124,'Больница','cat_exp_hospital'),
  ('category_set_2026_10_01','exp_supplements','expense',125,'БАДы','cat_exp_supplements'),
  ('category_set_2026_10_01','exp_charity','expense',126,'Благотворительность','cat_exp_charity'),
  ('category_set_2026_10_01','exp_training','expense',127,'Тренинг','cat_exp_training'),
  ('category_set_2026_10_01','exp_lending_money','expense',128,'Деньги в долг','cat_exp_lending_money'),
  ('category_set_2026_10_01','exp_bailiffs','expense',129,'Приставы','cat_exp_bailiffs'),
  ('category_set_2026_10_01','exp_pension_contributions','expense',130,'Пенсионные взносы','cat_exp_pension_contributions'),
  ('category_set_2026_10_01','inc_agent_counterparty','income',1,'Агентское вознаграждение за Контрагента','cat_inc_agent_counterparty'),
  ('category_set_2026_10_01','inc_agent_office_rent','income',2,'Агентское вознаграждение за Аренду офиса','cat_inc_agent_office_rent'),
  ('category_set_2026_10_01','inc_property_lease','income',3,'Сдача недвижимости','cat_inc_property_lease'),
  ('category_set_2026_10_01','inc_legal_services_contract','income',4,'Договор на юр услуги','cat_inc_legal_services_contract'),
  ('category_set_2026_10_01','inc_bonuses','income',5,'Бонусы','cat_inc_bonuses'),
  ('category_set_2026_10_01','inc_apartment_rent_income','income',6,'Доход от Аренда квартиры','cat_inc_apartment_rent_income'),
  ('category_set_2026_10_01','inc_extra_income','income',7,'Дополнительный доход','cat_inc_extra_income'),
  ('category_set_2026_10_01','inc_temporary_income','income',8,'Временный доход','cat_inc_temporary_income'),
  ('category_set_2026_10_01','inc_adjustment','income',9,'Корректировка','cat_inc_adjustment'),
  ('category_set_2026_10_01','inc_mentorship','income',10,'Наставничество','cat_inc_mentorship'),
  ('category_set_2026_10_01','inc_interest','income',11,'Проценты','cat_inc_interest'),
  ('category_set_2026_10_01','inc_gift','income',12,'Подарок','cat_inc_gift'),
  ('category_set_2026_10_01','inc_property_sale','income',13,'Продажа имущества','cat_inc_property_sale'),
  ('category_set_2026_10_01','inc_compensation','income',14,'Компенсация за что то','cat_inc_compensation'),
  ('category_set_2026_10_01','inc_debt_repayment','income',15,'Возврат долга','cat_inc_debt_repayment'),
  ('category_set_2026_10_01','inc_chargeback_refund','income',16,'Возврат списанных денег','cat_inc_chargeback_refund');

create table finance_private.category_set_imports (
  space_id uuid not null references public.spaces(id) on delete cascade,
  set_version text not null,
  set_key text not null,
  kind text not null check(kind in ('expense','income')),
  original_name text not null,
  category_id uuid,
  resolution text not null check(resolution in ('created','reused')),
  imported_at timestamptz not null default now(),
  primary key(space_id,set_version,set_key)
);
revoke all on finance_private.category_set_imports from public,anon,authenticated;

create function finance_private.install_category_set_2026_10_01(p_space_id uuid)
returns jsonb language plpgsql volatile security invoker set search_path='' as $function$
declare
  item finance_private.category_set_items%rowtype;
  matched uuid[]; chosen uuid; created_count integer:=0; reused_count integer:=0;
  skipped_count integer:=0; ambiguous_count integer:=0; archived_conflict_count integer:=0;
  ambiguities jsonb:='[]'::jsonb; conflicts jsonb:='[]'::jsonb; archive_details jsonb;
begin
  if current_user <> 'postgres' then raise exception using errcode='42501',message='Run installer as postgres'; end if;
  if p_space_id is null then raise exception using errcode='22004',message='Target space UUID is required'; end if;
  perform 1 from public.spaces where id=p_space_id for update;
  if not found then raise exception using errcode='P0002',message='Target space not found'; end if;
  for item in select * from finance_private.category_set_items where set_version='category_set_2026_10_01' order by kind,display_order loop
    if exists(select 1 from finance_private.category_set_imports i where i.space_id=p_space_id and i.set_version=item.set_version and i.set_key=item.set_key) then
      skipped_count:=skipped_count+1; continue;
    end if;
    select coalesce(array_agg(c.id order by c.created_at,c.id),'{}'::uuid[]) into matched
    from public.categories c where c.space_id=p_space_id and c.kind=item.kind
      and lower(regexp_replace(btrim(c.name),'[[:space:]]+',' ','g'))=lower(regexp_replace(btrim(item.name),'[[:space:]]+',' ','g'));
    -- A matching category is reusable only when both it and every ancestor are
    -- active. Archived matches remain unresolved so a later run can reuse them
    -- after the user explicitly resolves the archive conflict.
    with recursive ancestry(match_id,id,parent_id,is_archived) as (
      select c.id,c.id,c.parent_id,c.is_archived from public.categories c where c.id=any(matched)
      union all
      select a.match_id,p.id,p.parent_id,p.is_archived from ancestry a
      join public.categories p on p.id=a.parent_id
    ), archived as (
      select match_id,array_agg(id order by id) filter(where is_archived) archived_ids
      from ancestry group by match_id having bool_or(is_archived)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'category_id',match_id,
      'reason',case when match_id=any(archived_ids) then 'category_archived' else 'archived_ancestor' end,
      'archived_category_ids',to_jsonb(archived_ids)
    ) order by match_id),'[]'::jsonb) into archive_details from archived;
    if jsonb_array_length(archive_details)>0 then
      archived_conflict_count:=archived_conflict_count+1;
      conflicts:=conflicts||jsonb_build_array(jsonb_build_object('set_key',item.set_key,'kind',item.kind,'name',item.name,'reason','archived_match','matches',archive_details));
      continue;
    elsif cardinality(matched)>1 then
      ambiguous_count:=ambiguous_count+1;
      ambiguities:=ambiguities||jsonb_build_array(jsonb_build_object('set_key',item.set_key,'kind',item.kind,'name',item.name,'category_ids',to_jsonb(matched)));
      continue;
    elsif cardinality(matched)=1 then
      chosen:=matched[1]; reused_count:=reused_count+1;
      insert into finance_private.category_set_imports(space_id,set_version,set_key,kind,original_name,category_id,resolution)
      values(p_space_id,item.set_version,item.set_key,item.kind,item.name,chosen,'reused');
    else
      insert into public.categories(space_id,kind,name,parent_id,icon_id) values(p_space_id,item.kind,item.name,null,item.icon_id) returning id into chosen;
      created_count:=created_count+1;
      insert into finance_private.category_set_imports(space_id,set_version,set_key,kind,original_name,category_id,resolution)
      values(p_space_id,item.set_version,item.set_key,item.kind,item.name,chosen,'created');
    end if;
  end loop;
  return jsonb_build_object('space_id',p_space_id,'set_version','category_set_2026_10_01','created',created_count,'reused',reused_count,'skipped',skipped_count,'ambiguous',ambiguous_count,'ambiguities',ambiguities,'archived_conflicts',archived_conflict_count,'conflicts',conflicts);
end $function$;
revoke all on function finance_private.install_category_set_2026_10_01(uuid) from public,anon,authenticated;
comment on function finance_private.install_category_set_2026_10_01(uuid) is 'Postgres-only explicit-space category installer. Ledger prevents deleted entries or later user edits being restored.';
commit;