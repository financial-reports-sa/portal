-- ============================================================
--  التطبيقات الكاملة داخل البوابة — مخزن المستندات + الصلاحيات
-- ============================================================

create table if not exists public.app_docs (
  app        text not null,
  coll       text not null,
  id         text not null,
  data       jsonb not null,
  branches   text[] not null default '{}',
  owner      uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (app, coll, id)
);
alter table public.app_docs enable row level security;

-- القسم المطلوب لكل تطبيق
create or replace function public.app_section(p_app text) returns text
language sql immutable as $$
  select case p_app when 'sales' then 'sales' when 'daily' then 'sales' when 'channels' then 'channels'
                    when 'income' then 'income' when 'wh' then 'wh' when 'prices' then 'chicken' else null end
$$;

-- فروع المستخدم الحالي (كل الفروع للمالك والآدمن والمزامنة)
create or replace function public.my_branches() returns text[]
language sql stable security definer set search_path = public as $$
  select case when is_writer() then (select coalesce(array_agg(id), '{}') from branches)
              else (select coalesce(array_agg(ub.branch_id), '{}') from user_branches ub join profiles p on p.id = ub.user_id
                    where ub.user_id = auth.uid() and p.active) end
$$;

-- هل يرى المستخدم كل الفروع؟ (للتقرير اليومي الشامل)
create or replace function public.has_all_branches() returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from branches b where not (b.id = any(my_branches())))
$$;
grant execute on function public.has_all_branches() to authenticated;

-- حذف بيانات الفروع غير المسموحة من المستند (المستوى الأول والثاني)
create or replace function public.strip_branches(j jsonb, deny text[]) returns jsonb
language sql immutable as $$
  select coalesce((select jsonb_object_agg(k, case when jsonb_typeof(v) = 'object' then v - deny else v end)
                   from jsonb_each(j - deny) as e(k, v)), '{}'::jsonb)
$$;

-- قراءة مستندات تطبيق حسب صلاحيات المستخدم
create or replace function public.app_list(p_app text, p_coll text)
returns table (id text, data jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  mine text[] := my_branches();
  deny text[];
  w boolean := is_writer();
begin
  if not has_section(app_section(p_app)) then return; end if;
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

drop policy if exists ad_select on public.app_docs;
drop policy if exists ad_insert on public.app_docs;
drop policy if exists ad_update on public.app_docs;
drop policy if exists ad_delete on public.app_docs;
create policy ad_select on public.app_docs for select to authenticated using (is_writer() or (coll = 'reports' and owner = auth.uid()));
create policy ad_insert on public.app_docs for insert to authenticated with check (
  is_writer() or (coll = 'reports' and has_section(app_section(app)) and cardinality(branches) > 0
                  and branches <@ my_branches() and owner = auth.uid()));
create policy ad_update on public.app_docs for update to authenticated using (is_writer()) with check (is_writer());
create policy ad_delete on public.app_docs for delete to authenticated using (
  is_writer() or (coll = 'reports' and owner = auth.uid()));

grant select, insert, update, delete on public.app_docs to authenticated;
revoke all on public.app_docs from anon;
grant execute on function public.app_list(text, text) to authenticated;
grant execute on function public.my_branches() to authenticated;

-- نسبة تكلفة المستودعات من قوائم الدخل الكاملة
create or replace function public.get_cogs_ratio()
returns table (branch_id text, month text, ratio numeric, is_estimate boolean)
language sql stable security definer set search_path = public as $$
  select d.data->>'br', d.data->>'month',
         round(
           (select coalesce(sum((a->>'v')::numeric),0) from jsonb_array_elements(d.data->'groups') g, jsonb_array_elements(g->'a') a where g->>'cat'='cogs')
           / nullif((select coalesce(sum((a->>'v')::numeric),0) from jsonb_array_elements(d.data->'groups') g, jsonb_array_elements(g->'a') a where g->>'cat'='rev'),0)
         , 6),
         coalesce((d.data->>'est')::boolean, false)
  from app_docs d
  where d.app = 'income' and d.coll = 'stmts'
    and has_section('wh') and has_branch(d.data->>'br')
  order by 2
$$;
grant execute on function public.get_cogs_ratio() to authenticated;

-- تكلفة المستودعات اليومية (app='wh', coll='daily': {br, date, rev, cogs})
-- الإيراد والتكلفة يظهران فقط لمن عنده صلاحية المبالغ (income)، والباقي يشوف النسبة فقط
create or replace function public.get_cogs_daily()
returns table (branch_id text, day text, rev numeric, cogs numeric, ratio numeric)
language sql stable security definer set search_path = public as $$
  select d.data->>'br', d.data->>'date',
         case when has_section('income') then (d.data->>'rev')::numeric end,
         case when has_section('income') then (d.data->>'cogs')::numeric end,
         round((d.data->>'cogs')::numeric / nullif((d.data->>'rev')::numeric, 0), 6)
  from app_docs d
  where d.app = 'wh' and d.coll = 'daily'
    and has_section('wh') and has_branch(d.data->>'br')
  order by 2, 1
$$;
grant execute on function public.get_cogs_daily() to authenticated;

select 'تم تفعيل التطبيقات الكاملة ✓' as result;
