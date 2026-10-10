-- ============================================================
--  السلف + دخول الموظفين للتطبيق (يشغَّل مرة واحدة في Supabase → SQL Editor → Run)
--  الموظف يدخل برقم جواله ورمز من 6 أرقام ويطلب سلفة ← مدير الفرع يوافق ← المالك/الآدمن يعتمد
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

-- 1) دور «موظف»
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner','admin','user','sync','employee'));

-- 2) ربط حساب الدخول بالموظف
create table if not exists public.emp_accounts (
  emp_id     uuid primary key references public.employees(id) on delete cascade,
  user_id    uuid unique not null references auth.users(id) on delete cascade,
  phone      text unique not null,
  created_at timestamptz not null default now(),
  created_by text not null default ''
);
alter table public.emp_accounts enable row level security;
drop policy if exists ea_select on public.emp_accounts;
create policy ea_select on public.emp_accounts for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.employees e where e.id = emp_id and employees_can(e.branch)));
revoke all on public.emp_accounts from anon;
grant select on public.emp_accounts to authenticated;

create or replace function public.my_emp_id() returns uuid
language sql stable security definer set search_path = public as $$
  select emp_id from emp_accounts where user_id = auth.uid()
$$;

create or replace function public.who_am_i() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(full_name,''), username) from profiles where id = auth.uid()), '')
$$;

-- إنشاء حساب دخول لموظف (مدير الفرع / المالك / الآدمن)
create or replace function public.emp_account_create(p_emp uuid, p_phone text, p_pin text)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare e record; em text; uid uuid := gen_random_uuid(); ph text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
begin
  select * into e from public.employees where id = p_emp;
  if e.id is null then raise exception 'الموظف غير موجود'; end if;
  if not employees_can(e.branch) then raise exception 'ليس لديك صلاحية على موظفي هذا الفرع'; end if;
  if e.status = 'left' then raise exception 'الموظف منتهية خدماته'; end if;
  if ph ~ '^9665\d{8}$' then ph := '0' || substr(ph, 4); end if;
  if ph !~ '^05\d{8}$' then raise exception 'رقم الجوال لازم يبدأ بـ 05 ويكون 10 أرقام'; end if;
  if coalesce(p_pin,'') !~ '^\d{6}$' then raise exception 'الرمز 6 أرقام'; end if;
  if exists (select 1 from public.emp_accounts where emp_id = p_emp) then raise exception 'الموظف عنده حساب — استخدم «تغيير الرمز»'; end if;
  em := 'p' || ph || '@myreportshub.report';
  if exists (select 1 from auth.users where lower(email) = em) then raise exception 'رقم الجوال مسجل لحساب آخر'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', em,
          crypt(p_pin, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb,
          jsonb_build_object('username', 'p' || ph, 'full_name', e.name),
          now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, jsonb_build_object('sub', uid::text, 'email', em, 'email_verified', true),
          'email', now(), now(), now());
  update public.profiles set role = 'employee', full_name = e.name, username = 'p' || ph, active = true where id = uid;
  insert into public.emp_accounts (emp_id, user_id, phone, created_by) values (p_emp, uid, ph, who_am_i());
end $$;

create or replace function public.emp_set_pin(p_emp uuid, p_pin text)
returns void language plpgsql security definer set search_path = public, extensions, auth as $$
declare b text; uid uuid;
begin
  select e.branch, a.user_id into b, uid from public.employees e join public.emp_accounts a on a.emp_id = e.id where e.id = p_emp;
  if uid is null then raise exception 'الموظف ما عنده حساب'; end if;
  if not employees_can(b) then raise exception 'ليس لديك صلاحية'; end if;
  if coalesce(p_pin,'') !~ '^\d{6}$' then raise exception 'الرمز 6 أرقام'; end if;
  update auth.users set encrypted_password = crypt(p_pin, gen_salt('bf')), updated_at = now() where id = uid;
end $$;

create or replace function public.emp_account_delete(p_emp uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
declare b text; uid uuid;
begin
  select e.branch, a.user_id into b, uid from public.employees e join public.emp_accounts a on a.emp_id = e.id where e.id = p_emp;
  if uid is null then return; end if;
  if not employees_can(b) then raise exception 'ليس لديك صلاحية'; end if;
  delete from auth.users where id = uid;
end $$;

-- بيانات الموظف لنفسه
create or replace function public.my_emp() returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(x) from (
    select e.id, e.name, e.branch, b.name as branch_name, e.job, e.salary, e.start_date, e.status,
           e.health_exp, e.has_health, e.phone
    from public.employees e left join public.branches b on b.id = e.branch
    where e.id = my_emp_id()) x
$$;

-- 3) السلف
create table if not exists public.advances (
  id           uuid primary key default gen_random_uuid(),
  emp_id       uuid not null references public.employees(id) on delete cascade,
  branch       text not null,
  emp_name     text not null default '',
  amount       numeric(12,2) not null check (amount > 0),
  months       int not null check (months between 1 and 12),
  reason       text not null default '',
  status       text not null default 'pending_mgr' check (status in ('pending_mgr','pending_owner','approved','rejected','cancelled')),
  start_month  text,
  requested_by text not null default '',
  created_at   timestamptz not null default now(),
  mgr_by text, mgr_at timestamptz, mgr_note text,
  own_by text, own_at timestamptz, own_note text
);
create index if not exists advances_emp_idx on public.advances (emp_id);
alter table public.advances enable row level security;
drop policy if exists adv_select on public.advances;
create policy adv_select on public.advances for select to authenticated
  using (employees_can(branch) or emp_id = my_emp_id());
revoke all on public.advances from anon;
grant select on public.advances to authenticated;

create or replace function public.next_month() returns text language sql stable as $$
  select to_char(date_trunc('month', (now() at time zone 'Asia/Riyadh')) + interval '1 month', 'YYYY-MM')
$$;

-- طلب سلفة: الموظف لنفسه (p_emp فاضي) أو المدير/المالك نيابة عن موظف
create or replace function public.adv_request(p_amount numeric, p_months int, p_reason text, p_emp uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e record; me uuid := my_emp_id(); st text; nid uuid; who text := who_am_i();
begin
  if p_emp is null then
    if me is null then raise exception 'حسابك غير مرتبط بموظف'; end if;
    select * into e from public.employees where id = me; st := 'pending_mgr';
  else
    select * into e from public.employees where id = p_emp;
    if e.id is null then raise exception 'الموظف غير موجود'; end if;
    if not employees_can(e.branch) then raise exception 'ليس لديك صلاحية على موظفي هذا الفرع'; end if;
    st := case when is_admin() then 'approved' else 'pending_owner' end;
  end if;
  if e.status = 'left' then raise exception 'الموظف منتهية خدماته'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغ السلفة'; end if;
  if e.salary > 0 and p_amount > e.salary then raise exception 'السلفة لا تزيد عن راتب شهر واحد (%)', e.salary; end if;
  if p_months is null or p_months < 1 or p_months > 6 then raise exception 'مدة السداد من 1 إلى 6 أشهر'; end if;
  if exists (select 1 from public.advances where emp_id = e.id and status in ('pending_mgr','pending_owner')) then
    raise exception 'فيه طلب سلفة سابق ما زال تحت الإجراء';
  end if;
  insert into public.advances (emp_id, branch, emp_name, amount, months, reason, status, start_month, requested_by,
                               mgr_by, mgr_at, own_by, own_at)
  values (e.id, e.branch, e.name, round(p_amount, 2), p_months, left(coalesce(p_reason,''), 300), st,
          case when st = 'approved' then next_month() else null end, who,
          case when p_emp is not null then who end, case when p_emp is not null then now() end,
          case when st = 'approved' then who end, case when st = 'approved' then now() end)
  returning id into nid;
  return nid;
end $$;

-- موافقة / رفض
create or replace function public.adv_decide(p_id uuid, p_ok boolean, p_note text default '', p_start text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a record; who text := who_am_i();
begin
  select * into a from public.advances where id = p_id for update;
  if a.id is null then raise exception 'الطلب غير موجود'; end if;
  if a.emp_id = my_emp_id() then raise exception 'ما تقدر توافق على طلبك'; end if;
  if a.status = 'pending_mgr' then
    if not employees_can(a.branch) then raise exception 'ليس لديك صلاحية'; end if;
    update public.advances set mgr_by = who, mgr_at = now(), mgr_note = left(coalesce(p_note,''),300),
      status = case when not p_ok then 'rejected' when is_admin() then 'approved' else 'pending_owner' end,
      own_by = case when p_ok and is_admin() then who end, own_at = case when p_ok and is_admin() then now() end,
      start_month = case when p_ok and is_admin() then coalesce(nullif(p_start,''), next_month()) end
    where id = p_id;
  elsif a.status = 'pending_owner' then
    if not is_admin() then raise exception 'الاعتماد النهائي للمالك أو الآدمن'; end if;
    update public.advances set own_by = who, own_at = now(), own_note = left(coalesce(p_note,''),300),
      status = case when p_ok then 'approved' else 'rejected' end,
      start_month = case when p_ok then coalesce(nullif(p_start,''), next_month()) end
    where id = p_id;
  else
    raise exception 'الطلب ما عاد تحت الإجراء';
  end if;
end $$;

create or replace function public.adv_cancel(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.advances set status = 'cancelled'
   where id = p_id and status in ('pending_mgr','pending_owner') and (emp_id = my_emp_id() or is_admin());
  if not found then raise exception 'ما يمكن إلغاء الطلب'; end if;
end $$;

revoke all on function public.emp_account_create(uuid,text,text), public.emp_set_pin(uuid,text), public.emp_account_delete(uuid),
  public.my_emp(), public.adv_request(numeric,int,text,uuid), public.adv_decide(uuid,boolean,text,text), public.adv_cancel(uuid) from public, anon;
grant execute on function public.emp_account_create(uuid,text,text), public.emp_set_pin(uuid,text), public.emp_account_delete(uuid),
  public.my_emp(), public.my_emp_id(), public.who_am_i(), public.next_month(),
  public.adv_request(numeric,int,text,uuid), public.adv_decide(uuid,boolean,text,text), public.adv_cancel(uuid) to authenticated;

select 'تم تفعيل السلف ودخول الموظفين ✓' as result;
