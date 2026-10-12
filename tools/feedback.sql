-- ============================================================
--  تقييم العملاء — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  العميل يقيّم من QR في المطعم (بدون حساب) ← إشعار للإدارة ومدير الفرع
--  المراحل: استلام ← مراجعة ← تواصل مع العميل ← حل المشكلة ← إغلاق
-- ============================================================

-- 1) صلاحية القسم: feedback
do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

-- 2) الجدول
create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  no          bigserial unique,
  branch      text not null,
  rating      smallint not null check (rating between 1 and 5),
  tags        text[] not null default '{}',
  comment     text,
  name        text,
  phone       text,
  visit       text,
  lang        text,
  status      text not null default 'new' check (status in ('new','reviewed','contacted','resolved','closed')),
  resolution  text,
  comp        text,
  handled_by  text,
  ip          text,
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  contacted_at timestamptz,
  resolved_at timestamptz,
  closed_at   timestamptz,
  log         jsonb not null default '[]'::jsonb
);
create index if not exists feedback_branch_idx on public.feedback (branch, created_at desc);
alter table public.feedback enable row level security;
drop policy if exists fb_read on public.feedback;
create policy fb_read on public.feedback for select to authenticated
  using (is_admin() or (has_section('feedback') and branch = any(my_branches())));
revoke all on public.feedback from anon;
grant select on public.feedback to authenticated;

-- 3) العميل يرسل التقييم (متاحة للزوار)
create or replace function public.feedback_submit(p_branch text, p_rating int, p_tags text[] default '{}',
  p_comment text default null, p_name text default null, p_phone text default null, p_visit text default null, p_lang text default 'ar')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip text := coalesce(split_part(coalesce(current_setting('request.headers', true), '{}')::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_no bigint; v_ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
begin
  if not exists (select 1 from branches where id = p_branch) then return jsonb_build_object('ok', false, 'message', 'رابط غير صحيح'); end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then return jsonb_build_object('ok', false, 'message', 'اختر التقييم'); end if;
  if (select count(*) from feedback where ip = v_ip and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'message', 'تم استلام تقييمك مسبقاً — شكراً لك');
  end if;
  insert into feedback (branch, rating, tags, comment, name, phone, visit, lang, ip, log)
  values (p_branch, p_rating, coalesce(p_tags[1:12], '{}'), nullif(left(trim(coalesce(p_comment, '')), 1500), ''),
          nullif(left(trim(coalesce(p_name, '')), 80), ''), nullif(left(v_ph, 20), ''), left(p_visit, 20), left(p_lang, 5), v_ip,
          jsonb_build_array(jsonb_build_object('t', now(), 'a', 'new', 'by', 'العميل')))
  returning no into v_no;
  return jsonb_build_object('ok', true, 'ref', 'CF-' || lpad(v_no::text, 5, '0'));
end $$;

-- 4) المتابعة (مدير الفرع والإدارة)
create or replace function public.feedback_update(p_id uuid, p_status text, p_note text default null, p_comp text default null)
returns void language plpgsql security definer set search_path = public as $$
declare f feedback; w text := (select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid());
  n text := nullif(trim(coalesce(p_note, '')), ''); ok boolean;
begin
  select * into f from feedback where id = p_id for update;
  if f.id is null then raise exception 'التقييم غير موجود'; end if;
  if not (is_admin() or (has_section('feedback') and f.branch = any(my_branches()))) then raise exception 'ليس لديك صلاحية'; end if;
  ok := (f.status = 'new' and p_status in ('reviewed','contacted','resolved','closed'))
     or (f.status = 'reviewed' and p_status in ('contacted','resolved','closed'))
     or (f.status = 'contacted' and p_status in ('resolved','closed'))
     or (f.status = 'resolved' and p_status = 'closed')
     or (f.status = 'closed' and p_status = 'reviewed' and is_admin());
  if not ok then raise exception 'هذا الإجراء غير متاح في المرحلة الحالية'; end if;
  if p_status in ('contacted','resolved') and n is null then raise exception 'اكتب التفاصيل'; end if;
  update feedback set
    status       = p_status,
    reviewed_at  = coalesce(reviewed_at, case when p_status <> 'new' then now() end),
    contacted_at = case when p_status = 'contacted' then now() else contacted_at end,
    resolved_at  = case when p_status = 'resolved' then now() else resolved_at end,
    closed_at    = case when p_status = 'closed' then now() when p_status = 'reviewed' then null else closed_at end,
    resolution   = case when p_status = 'resolved' then n else resolution end,
    comp         = case when p_status = 'resolved' then nullif(trim(coalesce(p_comp, '')), '') else comp end,
    handled_by   = w,
    log          = log || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('t', now(), 'a', p_status, 'by', w, 'n', n,
                     'c', case when p_status = 'resolved' then nullif(trim(coalesce(p_comp, '')), '') end)))
  where id = p_id;
end $$;

create or replace function public.feedback_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'الحذف للمالك والآدمن فقط'; end if;
  delete from feedback where id = p_id;
end $$;

revoke all on function public.feedback_submit(text,int,text[],text,text,text,text,text) from public;
revoke all on function public.feedback_update(uuid,text,text,text) from public, anon;
revoke all on function public.feedback_delete(uuid) from public, anon;
grant execute on function public.feedback_submit(text,int,text[],text,text,text,text,text) to anon, authenticated;
grant execute on function public.feedback_update(uuid,text,text,text) to authenticated;
grant execute on function public.feedback_delete(uuid) to authenticated;

-- 5) إشعارات الجوال (إذا كانت مفعّلة)
create or replace function public.feedback_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare br text; ref text := 'CF-' || lpad(new.no::text, 5, '0'); st text := repeat('★', new.rating) || repeat('☆', 5 - new.rating);
begin
  if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is null then return new; end if;
  br := coalesce((select name from branches where id = new.branch), new.branch);
  if tg_op = 'INSERT' then
    perform push_send(push_mgrs('feedback', new.branch) || push_admins(),
      case when new.rating <= 2 then '⚠️ شكوى عميل — ' || br when new.rating = 3 then '📝 تقييم متوسط — ' || br else '⭐ تقييم جديد — ' || br end,
      st || coalesce(' · ' || left(new.comment, 100), '') || ' · ' || ref, './?tab=feedback', 'fb-' || new.id);
  elsif new.status = 'resolved' and old.status is distinct from 'resolved' then
    perform push_send(push_admins(), '✅ تم حل شكوى — ' || br, coalesce(left(new.resolution, 110), '') || ' · ' || ref, './?tab=feedback', 'fb-' || new.id);
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists feedback_push_trg on public.feedback;
create trigger feedback_push_trg after insert or update of status on public.feedback
  for each row execute function public.feedback_push();

select 'تم تفعيل تقييم العملاء ✓' as result;
