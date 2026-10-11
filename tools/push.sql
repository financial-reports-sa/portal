-- ============================================================
--  إشعارات الجوال (Push) — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  يحتاج قبله: نشر دالة push في Edge Functions (الكود في tools/push-function.ts)
--  الإشعارات تصل حتى والتطبيق مقفل:
--   • الصيانة: طلب جديد للمشرف · إسناد/تعليق/رفض/إنجاز لمدير الفرع · رفض الإنجاز والإغلاق للمشرف
--   • السلف: طلب جديد لمدير الفرع · بانتظار الاعتماد للمالك · القبول/الرفض للموظف
-- ============================================================
create extension if not exists pg_net with schema extensions;

-- اشتراكات الأجهزة
create table if not exists public.push_subs (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  ua         text,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subs (user_id);
alter table public.push_subs enable row level security;
drop policy if exists ps_own on public.push_subs;
create policy ps_own on public.push_subs for select to authenticated using (user_id = auth.uid());
revoke all on public.push_subs from anon;
grant select on public.push_subs to authenticated;

-- إعدادات الإرسال (المفاتيح تولّدها دالة push بنفسها — لا أحد يقرأ هذا الجدول غير الخادم)
create table if not exists public.push_config (
  id          int primary key default 1 check (id = 1),
  public_key  text,
  private_key text,
  hook_secret text not null default encode(extensions.gen_random_bytes(24), 'hex')
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id) values (1) on conflict (id) do nothing;

-- تسجيل / إلغاء جهاز المستخدم الحالي
create or replace function public.push_register(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'سجّل دخولك أولاً'; end if;
  delete from push_subs where endpoint = p_endpoint;
  insert into push_subs (endpoint, user_id, p256dh, auth, ua) values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 200));
end $$;
create or replace function public.push_unregister(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subs where endpoint = p_endpoint and user_id = auth.uid()
$$;

-- الإرسال (يُستدعى من التريقرات فقط)
create or replace function public.push_send(p_users uuid[], p_title text, p_body text, p_url text default './', p_tag text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s text; u uuid[];
begin
  u := array(select distinct x from unnest(coalesce(p_users, '{}')) x where x is not null and x is distinct from auth.uid());
  if cardinality(u) = 0 then return; end if;
  if not exists (select 1 from push_subs where user_id = any(u)) then return; end if;
  select hook_secret into s from push_config where id = 1;
  perform net.http_post(
    url := 'https://olsqykputyhigalzmlbs.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook', s),
    body := jsonb_build_object('users', to_jsonb(u), 'title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag),
    timeout_milliseconds := 8000);
exception when others then
  null; -- الإشعار ما يوقف أي عملية
end $$;

-- إشعار تجريبي لجهازي
create or replace function public.push_test() returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare s text;
begin
  if not exists (select 1 from push_subs where user_id = auth.uid()) then return false; end if;
  select hook_secret into s from push_config where id = 1;
  perform net.http_post(
    url := 'https://olsqykputyhigalzmlbs.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook', s),
    body := jsonb_build_object('users', jsonb_build_array(auth.uid()), 'title', 'MyHub ✓', 'body', 'الإشعارات شغّالة على هذا الجهاز', 'url', './', 'tag', 'test'),
    timeout_milliseconds := 8000);
  return true;
end $$;

-- المستلمون
create or replace function public.push_admins() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from profiles where active and role in ('owner','admin')
$$;
create or replace function public.push_mgrs(p_section text, p_branch text) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p.id), '{}') from profiles p
  where p.active and p.role = 'user'
    and exists (select 1 from user_sections s where s.user_id = p.id and s.section = p_section)
    and (p_branch is null or exists (select 1 from user_branches b where b.user_id = p.id and b.branch_id = p_branch))
$$;
create or replace function public.push_brname(p_branch text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from branches where id = p_branch), p_branch)
$$;

-- ---------- الصيانة ----------
create or replace function public.maint_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare br text := push_brname(new.branch); ref text := 'WO-' || lpad(new.no::text, 5, '0');
  url text := './?tab=maint'; tg text := 'mt-' || new.id;
  sup uuid[] := push_mgrs('maint_sup', null) || push_admins();
begin
  if tg_op = 'INSERT' then
    perform push_send(sup, case when new.priority = 'urgent' then '🚨 طلب صيانة عاجل' else '🛠️ طلب صيانة جديد' end,
      new.title || ' · ' || br || ' · ' || ref, url, tg);
  elsif new.status is distinct from old.status then
    if new.status = 'assigned' then
      perform push_send(array[new.requested_uid], '👷 تم إسناد طلب الصيانة', new.title || ' — المنفّذ: ' || coalesce(new.assignee, ''), url, tg);
    elsif new.status = 'rejected' then
      perform push_send(array[new.requested_uid], '✕ رُفض طلب الصيانة', new.title || ' — ' || coalesce(new.reject_reason, ''), url, tg);
    elsif new.status = 'hold' then
      perform push_send(array[new.requested_uid], '⏸ تعليق طلب الصيانة', new.title || ' — ' || coalesce(new.hold_reason, ''), url, tg);
    elsif new.status = 'done' then
      perform push_send(array[new.requested_uid] || push_mgrs('maint', new.branch), '✅ تم إنجاز الصيانة — أكّد الاستلام', new.title || ' · ' || br, url, tg);
    elsif new.status = 'progress' and old.status = 'done' then
      perform push_send(sup, '↺ الفرع رفض الإنجاز', new.title || ' · ' || br || ' — ' || coalesce(new.reject_reason, ''), url, tg);
    elsif new.status = 'closed' then
      perform push_send(push_mgrs('maint_sup', null), '✓ أُغلق أمر العمل', new.title || ' · ' || br || coalesce(' · التقييم ' || new.rating || '/5', ''), url, tg);
    end if;
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.maint_requests') is not null then
    drop trigger if exists maint_push_trg on public.maint_requests;
    create trigger maint_push_trg after insert or update of status on public.maint_requests
      for each row execute function public.maint_push();
  end if;
end $$;

-- ---------- السلف ----------
create or replace function public.adv_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare br text := push_brname(new.branch); amt text := to_char(new.amount, 'FM999,999,990') || ' ر.س';
  emp uuid := (select user_id from emp_accounts where emp_id = new.emp_id);
begin
  if (tg_op = 'INSERT' or new.status is distinct from old.status) then
    if new.status = 'pending_mgr' then
      perform push_send(push_mgrs('employees', new.branch), '💵 طلب سلفة جديد', new.emp_name || ' · ' || amt || ' · ' || br, './?tab=advances', 'adv-' || new.id);
    elsif new.status = 'pending_owner' then
      perform push_send(push_admins(), '💵 سلفة بانتظار اعتمادك', new.emp_name || ' · ' || amt || ' · ' || br, './?tab=advances', 'adv-' || new.id);
    elsif new.status = 'approved' then
      perform push_send(array[emp], '✅ تمت الموافقة على سلفتك', amt || coalesce(' · يبدأ الخصم ' || new.start_month, ''), './?tab=me', 'adv-' || new.id);
    elsif new.status = 'rejected' then
      perform push_send(array[emp], 'تم رفض طلب السلفة', amt || coalesce(' — ' || nullif(coalesce(new.own_note, new.mgr_note), ''), ''), './?tab=me', 'adv-' || new.id);
    end if;
  end if;
  return new;
end $$;
do $$ begin
  if to_regclass('public.advances') is not null then
    drop trigger if exists adv_push_trg on public.advances;
    create trigger adv_push_trg after insert or update of status on public.advances
      for each row execute function public.adv_push();
  end if;
end $$;

revoke all on function public.push_send(uuid[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_register(text, text, text, text) from public, anon;
revoke all on function public.push_unregister(text) from public, anon;
revoke all on function public.push_test() from public, anon;
grant execute on function public.push_register(text, text, text, text) to authenticated;
grant execute on function public.push_unregister(text) to authenticated;
grant execute on function public.push_test() to authenticated;

select 'تم تفعيل إشعارات الجوال ✓' as result;
