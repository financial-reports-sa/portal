-- ============================================================
--  إضافة خزينة الأرصدة للبوابة
-- ============================================================
alter table public.user_sections drop constraint if exists user_sections_section_check;
alter table public.user_sections add constraint user_sections_section_check
  check (section in ('sales','channels','income','wh','chicken','carcass','treasury'));

create or replace function public.app_section(p_app text) returns text
language sql immutable as $$
  select case p_app when 'sales' then 'sales' when 'daily' then 'sales' when 'channels' then 'channels'
                    when 'income' then 'income' when 'wh' then 'wh' when 'prices' then 'chicken'
                    when 'treasury' then 'treasury' else null end
$$;

select 'تمت إضافة خزينة الأرصدة ✓' as result;
