-- ============================================================
--  الصلاحيات بالشاشات — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  فصل ثلاث شاشات كانت مربوطة بصلاحية شاشة ثانية:
--    التقرير اليومي (كان مع مبيعات الفروع) ← daily
--    مراقبة الهدر (كانت مع نسبة تكلفة المستودعات) ← waste
--    السلف (كانت مع الموظفين) ← advances
--  المستخدمين الحاليين ما يفقدون شي: اللي عنده الشاشة الأم تنضاف له الشاشة الجديدة تلقائياً.
-- ============================================================

-- 1) السماح بالصلاحيات الجديدة
do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','daily','channels','income','wh','waste','chicken','carcass','treasury','handover','employees','advances',
                 'loans','fleet','maint','maint_sup','feedback','custody','custody_holder','hr']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

-- 2) نقل الصلاحيات الحالية (بدون تكرار)
insert into public.user_sections (user_id, section)
select distinct us.user_id, m.new_sec
from public.user_sections us
join (values ('sales','daily'), ('wh','waste'), ('employees','advances')) as m(old_sec, new_sec) on m.old_sec = us.section
where not exists (select 1 from public.user_sections x where x.user_id = us.user_id and x.section = m.new_sec);

-- 3) التقرير اليومي صار صلاحية مستقلة
create or replace function public.app_section(p_app text) returns text
language sql immutable as $$
  select case p_app when 'sales' then 'sales' when 'daily' then 'daily' when 'channels' then 'channels'
                    when 'income' then 'income' when 'wh' then 'wh' when 'prices' then 'chicken'
                    when 'treasury' then 'treasury' when 'loans' then 'loans' when 'fleet' then 'fleet' else null end
$$;

-- 4) مراقبة الهدر تقرأ بيانات الصرف المخزني ومبيعات الفئات حتى لو ما عنده نسبة التكلفة أو المنافذ
create or replace function public.app_list(p_app text, p_coll text)
returns table (id text, data jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  mine text[] := my_branches();
  deny text[];
  w boolean := is_writer();
begin
  if not (has_section(app_section(p_app))
          or (has_section('waste') and ((p_app = 'wh' and p_coll in ('cfg','issue')) or (p_app = 'channels' and p_coll = 'periods')))) then
    return;
  end if;
  -- التقرير اليومي الشامل: للي يشوف كل الفروع فقط
  if p_app = 'daily' and not w and exists (select 1 from branches b where not (b.id = any(mine))) then return; end if;
  select coalesce(array_agg(b.id), '{}') into deny from branches b where not (b.id = any(mine));
  return query
    select d.id,
           case when w or cardinality(deny) = 0 or p_coll in ('reports','stmts','pages') then d.data
                else strip_branches(d.data, deny) end
    from app_docs d
    where d.app = p_app and d.coll = p_coll
      and (w or cardinality(d.branches) = 0 or d.branches <@ mine);
end $$;
