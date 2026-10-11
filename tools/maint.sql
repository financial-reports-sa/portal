-- ============================================================
--  طلبات الصيانة (أوامر العمل) — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  دورة العمل:
--   1) مدير الفرع يرفع الطلب (النوع، الوصف، الأولوية، صورة)
--   2) مشرف الصيانة يراجع: يقبل ويسند لفني مع موعد متوقع — أو يرفض مع السبب
--   3) بدء التنفيذ  (ويقدر يعلّق الطلب مع السبب، مثل انتظار قطعة غيار)
--   4) إنجاز الطلب (ملاحظة + تكلفة + صورة بعد الإصلاح)
--   5) مدير الفرع يؤكد الاستلام ويقيّم ← يُغلق الطلب — أو يرفض الإنجاز ويرجع للتنفيذ
--  مهلة الإنجاز حسب الأولوية: عاجل 24 ساعة · عالي 3 أيام · عادي 7 أيام
-- ============================================================

-- 1) صلاحيتان: maint (مدير فرع يرفع طلبات فرعه) و maint_sup (مشرف الصيانة)
do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

-- 2) جدول الطلبات
create table if not exists public.maint_requests (
  id            uuid primary key default gen_random_uuid(),
  no            bigserial unique,
  branch        text not null,
  category      text not null,
  title         text not null,
  details       text,
  priority      text not null default 'normal',
  status        text not null default 'new',
  photo         text,
  done_photo    text,
  requested_by  text,
  requested_uid uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  assigned_at   timestamptz,
  assignee      text,
  due_date      date,
  started_at    timestamptz,
  done_at       timestamptz,
  closed_at     timestamptz,
  closed_by     text,
  rating        smallint,
  hold_reason   text,
  reject_reason text,
  sup_note      text,
  cost          numeric(12,2),
  handled_by    text,
  updated_at    timestamptz not null default now(),
  log           jsonb not null default '[]'::jsonb
);
alter table public.maint_requests drop constraint if exists maint_requests_priority_check;
alter table public.maint_requests add constraint maint_requests_priority_check check (priority in ('urgent','high','normal'));
alter table public.maint_requests drop constraint if exists maint_requests_status_check;
alter table public.maint_requests add constraint maint_requests_status_check
  check (status in ('new','assigned','progress','hold','done','closed','rejected','cancelled'));
alter table public.maint_requests add column if not exists has_photo boolean
  generated always as (photo is not null or done_photo is not null) stored;
create index if not exists maint_requests_branch_idx on public.maint_requests (branch, status);

-- دور المستخدم الحالي
create or replace function public.maint_role() returns text
language sql stable security definer set search_path = public as $$
  select case when is_admin() then 'admin'
              when has_section('maint_sup') then 'sup'
              when has_section('maint') then 'mgr'
              else null end
$$;
create or replace function public.maint_who() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid()
$$;

alter table public.maint_requests enable row level security;
drop policy if exists maint_read on public.maint_requests;
create policy maint_read on public.maint_requests for select to authenticated
  using (maint_role() in ('admin','sup') or (maint_role() = 'mgr' and branch = any(my_branches())));
-- لا إدخال ولا تعديل مباشر — فقط عبر الدوال تحت

-- 3) رفع طلب جديد
create or replace function public.maint_create(p_branch text, p_category text, p_title text,
  p_details text default null, p_priority text default 'normal', p_photo text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare r text := maint_role(); w text := maint_who(); nid uuid;
begin
  if r is null then raise exception 'ليس لديك صلاحية على طلبات الصيانة'; end if;
  if r = 'mgr' and not (p_branch = any(my_branches())) then raise exception 'تقدر ترفع طلبات فرعك فقط'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'اكتب وصف المشكلة'; end if;
  if coalesce(trim(p_category), '') = '' then raise exception 'اختر نوع الصيانة'; end if;
  if p_photo is not null and length(p_photo) > 1500000 then raise exception 'الصورة كبيرة'; end if;
  insert into maint_requests (branch, category, title, details, priority, photo, requested_by, log)
  values (p_branch, p_category, trim(p_title), nullif(trim(coalesce(p_details, '')), ''),
          case when p_priority in ('urgent','high') then p_priority else 'normal' end, p_photo, w,
          jsonb_build_array(jsonb_build_object('t', now(), 'by', w, 'a', 'new')))
  returning id into nid;
  return nid;
end $$;

-- 4) الانتقال بين مراحل الطلب
drop function if exists public.maint_update(uuid, text, text, numeric, text);
create or replace function public.maint_update(p_id uuid, p_status text, p_note text default null,
  p_cost numeric default null, p_done_photo text default null, p_assignee text default null,
  p_due date default null, p_rating int default null)
returns void language plpgsql security definer set search_path = public as $$
declare r text := maint_role(); w text := maint_who(); m maint_requests; ok boolean := false;
  n text := nullif(trim(coalesce(p_note, '')), '');
begin
  select * into m from maint_requests where id = p_id for update;
  if m.id is null then raise exception 'الطلب غير موجود'; end if;
  if r is null then raise exception 'ليس لديك صلاحية'; end if;
  if r = 'mgr' and not (m.branch = any(my_branches())) then raise exception 'ليس لديك صلاحية على هذا الطلب'; end if;

  -- المسارات المسموحة
  if r in ('admin','sup') then
    ok := (m.status = 'new' and p_status in ('assigned','rejected'))
       or (m.status in ('assigned','hold') and p_status = 'progress')
       or (m.status in ('assigned','progress') and p_status = 'hold')
       or (m.status in ('assigned','progress','hold') and p_status = 'done');
  end if;
  if not ok and (r = 'mgr' or r = 'admin') then
    ok := (m.status = 'new' and p_status = 'cancelled')
       or (m.status = 'done' and p_status in ('closed','progress'));
  end if;
  if not ok then raise exception 'هذا الإجراء غير متاح في مرحلة الطلب الحالية'; end if;

  if p_status = 'assigned' and coalesce(trim(p_assignee), '') = '' then raise exception 'اكتب اسم الفني أو الجهة المنفذة'; end if;
  if p_status in ('rejected','hold') and n is null then raise exception 'اكتب السبب'; end if;
  if p_status = 'progress' and m.status = 'done' and n is null then raise exception 'اكتب سبب رفض الإنجاز'; end if;
  if p_done_photo is not null and length(p_done_photo) > 1500000 then raise exception 'الصورة كبيرة'; end if;
  if p_rating is not null and (p_rating < 1 or p_rating > 5) then raise exception 'التقييم من 1 إلى 5'; end if;

  update maint_requests set
    status        = p_status,
    assignee      = case when p_status = 'assigned' then trim(p_assignee) else assignee end,
    due_date      = case when p_status = 'assigned' then p_due else due_date end,
    assigned_at   = case when p_status = 'assigned' then now() else assigned_at end,
    started_at    = case when p_status in ('progress','done') and started_at is null then now() else started_at end,
    done_at       = case when p_status = 'done' then now() when p_status = 'progress' then null else done_at end,
    closed_at     = case when p_status = 'closed' then now() else closed_at end,
    closed_by     = case when p_status = 'closed' then w else closed_by end,
    rating        = case when p_status = 'closed' then p_rating else rating end,
    hold_reason   = case when p_status = 'hold' then n when p_status in ('progress','done') then null else hold_reason end,
    reject_reason = case when p_status = 'rejected' then n when p_status = 'progress' and m.status = 'done' then n else reject_reason end,
    sup_note      = case when p_status = 'done' then n else sup_note end,
    cost          = case when p_status = 'done' then p_cost else cost end,
    done_photo    = case when p_status = 'done' then coalesce(p_done_photo, done_photo) else done_photo end,
    handled_by    = case when r in ('admin','sup') and p_status not in ('closed','cancelled') then w else handled_by end,
    updated_at    = now(),
    log           = log || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('t', now(), 'by', w, 'a', p_status,
                      'n', n, 'as', case when p_status = 'assigned' then trim(p_assignee) end, 'rt', p_rating)))
  where id = p_id;
end $$;

-- 5) صور الطلب (تُحمَّل عند الطلب)
create or replace function public.maint_photos(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m maint_requests; r text := maint_role();
begin
  select * into m from maint_requests where id = p_id;
  if m.id is null or r is null or (r = 'mgr' and not (m.branch = any(my_branches()))) then return '{}'::jsonb; end if;
  return jsonb_build_object('photo', m.photo, 'done_photo', m.done_photo);
end $$;

-- 6) حذف (المالك والآدمن فقط)
create or replace function public.maint_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'الحذف للمالك والآدمن فقط'; end if;
  delete from maint_requests where id = p_id;
end $$;

revoke all on function public.maint_create(text, text, text, text, text, text) from public, anon;
revoke all on function public.maint_update(uuid, text, text, numeric, text, text, date, int) from public, anon;
revoke all on function public.maint_photos(uuid) from public, anon;
revoke all on function public.maint_delete(uuid) from public, anon;
grant execute on function public.maint_create(text, text, text, text, text, text) to authenticated;
grant execute on function public.maint_update(uuid, text, text, numeric, text, text, date, int) to authenticated;
grant execute on function public.maint_photos(uuid) to authenticated;
grant execute on function public.maint_delete(uuid) to authenticated;
grant execute on function public.maint_role() to authenticated;
grant select on public.maint_requests to authenticated;

select 'تمت إضافة طلبات الصيانة ✓' as result;
