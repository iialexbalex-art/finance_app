-- Подготовлено для ручного применения после 001–006. Права записи не меняются.
begin;
create function public.query_expenses(
  p_space_id uuid, p_wallet_ids uuid[] default '{}', p_category_ids uuid[] default '{}',
  p_from date default null, p_to date default null,
  p_before_date date default null, p_before_id uuid default null,
  p_include_totals boolean default false
) returns jsonb language plpgsql stable security invoker set search_path = ''
as $function$
declare result jsonb;
begin
  if p_include_totals and not finance_private.owns_space(p_space_id) then
    raise exception using errcode='42501', message='Expense totals access denied';
  end if;
  if p_from > p_to or ((p_before_date is null) <> (p_before_id is null)) then
    raise exception using errcode='22023', message='Invalid period or cursor';
  end if;
  -- RLS remains active for BOTH expenses and categories. UNION removes overlapping
  -- branches and repeated IDs; EXISTS never multiplies an expense row.
  with recursive branches(id) as (
    select c.id from public.categories c
    where c.space_id=p_space_id and c.kind='expense' and c.id=any(p_category_ids)
    union
    select c.id from public.categories c join branches b on c.parent_id=b.id
    where c.space_id=p_space_id and c.kind='expense'
  ), matched as materialized (
    select e.* from public.expenses e where e.space_id=p_space_id
      and (coalesce(cardinality(p_wallet_ids),0)=0 or e.wallet_id=any(p_wallet_ids))
      and (coalesce(cardinality(p_category_ids),0)=0 or exists(select 1 from branches b where b.id=e.category_id))
      and (p_from is null or e.expense_date>=p_from)
      and (p_to is null or e.expense_date<=p_to)
  ), page as (
    select * from matched e where p_before_date is null
      or (e.expense_date,e.id)<(p_before_date,p_before_id)
    order by e.expense_date desc,e.id desc limit 26
  ), scales as (
    select currency,max(currency_scale) as currency_scale from matched
    where p_include_totals group by currency
  ), totals as (
    select e.currency,s.currency_scale,
      trunc(sum(e.amount_minor * power(10::numeric,s.currency_scale-e.currency_scale)))::text as amount_minor
    from matched e join scales s on s.currency=e.currency
    group by e.currency,s.currency_scale
  )
  select jsonb_build_object(
    'items',coalesce((select jsonb_agg(
      jsonb_build_object('id',id,'wallet_id',wallet_id,'category_id',category_id,
        'revision',revision,'expense_date',expense_date,'amount_minor',amount_minor::text,
        'currency',currency,'currency_scale',currency_scale,'wallet_name',wallet_name,
        'category_path',category_path,'comment',comment)
      order by expense_date desc,id desc) from page),'[]'::jsonb),
    'totals',coalesce((select jsonb_agg(to_jsonb(t) order by currency,currency_scale) from totals t),'[]'::jsonb)
  ) into result;
  return result;
end
$function$;
revoke all on function public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean) from public,anon,authenticated;
grant execute on function public.query_expenses(uuid,uuid[],uuid[],date,date,date,uuid,boolean) to authenticated;
create index expenses_space_wallet_date on public.expenses(space_id,wallet_id,expense_date desc,id desc);
create index expenses_space_category_date on public.expenses(space_id,category_id,expense_date desc,id desc);
notify pgrst,'reload schema';
commit;
