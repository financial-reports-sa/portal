-- ============================================================
--  جدول الموظفين — مدير الفرع يضيف ويعدّل موظفي فرعه (مع الراتب)
--  والمالك/الآدمن يشوفون كل الفروع ويقدرون يحذفون
-- ============================================================

-- 1) القسم الجديد في الصلاحيات
alter table public.user_sections drop constraint if exists user_sections_section_check;
alter table public.user_sections add constraint user_sections_section_check
  check (section in ('sales','channels','income','wh','chicken','carcass','treasury','handover','employees'));

-- 2) الموظفين
create table if not exists public.employees (
  id          uuid primary key default gen_random_uuid(),
  branch      text not null,
  name        text not null check (length(btrim(name)) > 0),
  job         text not null default '',
  nationality text not null default '',
  phone       text not null default '',
  iqama       text not null default '',
  iqama_exp   date,
  health_exp  date,
  start_date  date not null,
  salary      numeric(12,2) not null default 0 check (salary >= 0),
  status      text not null default 'active' check (status in ('active','vacation','left')),
  left_date   date,
  notes       text not null default '',
  created_at  timestamptz not null default now(),
  created_by  text not null default '',
  updated_at  timestamptz not null default now(),
  updated_by  text not null default ''
);
create index if not exists employees_branch_idx on public.employees (branch);
-- سبب إنهاء الخدمات (استقالة، إنهاء، انتهاء عقد…)
alter table public.employees add column if not exists end_reason text not null default '';
-- هل يوجد إقامة / شهادة صحية؟ (إذا نعم: الرقم وتاريخ الانتهاء مطلوبين)
alter table public.employees add column if not exists has_iqama  boolean not null default false;
alter table public.employees add column if not exists has_health boolean not null default false;
alter table public.employees add column if not exists health_no  text    not null default '';
update public.employees set has_iqama = true  where not has_iqama  and iqama <> '';
update public.employees set has_health = true where not has_health and health_exp is not null;

-- 3) سجل التعديلات (مين أضاف / عدّل / حذف وإيش تغيّر)
create table if not exists public.employee_log (
  id      bigserial primary key,
  emp_id  uuid not null,
  branch  text not null,
  name    text not null default '',
  at      timestamptz not null default now(),
  by_name text not null default '',
  action  text not null,            -- add / edit / delete
  changes jsonb not null default '{}'
);
create index if not exists employee_log_emp_idx on public.employee_log (emp_id, at desc);

-- هل المستخدم الحالي يقدر يشوف ويعدّل موظفي هذا الفرع؟
create or replace function public.employees_can(p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_writer(), false)
      or (exists (select 1 from user_sections us join profiles p on p.id = us.user_id
                  where us.user_id = auth.uid() and us.section = 'employees' and p.active)
          and p_branch = any(my_branches()))
$$;

-- اسم المستخدم الحالي + ختم الوقت
create or replace function public.employees_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text;
begin
  select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
  v_who := coalesce(v_who, '');
  new.name := left(btrim(new.name), 80);
  new.job := left(btrim(coalesce(new.job, '')), 60);
  new.nationality := left(btrim(coalesce(new.nationality, '')), 40);
  new.phone := left(btrim(coalesce(new.phone, '')), 20);
  new.iqama := left(btrim(coalesce(new.iqama, '')), 20);
  new.notes := left(coalesce(new.notes, ''), 500);
  new.end_reason := left(btrim(coalesce(new.end_reason, '')), 80);
  new.health_no := left(btrim(coalesce(new.health_no, '')), 30);
  if not new.has_iqama then new.iqama := ''; new.iqama_exp := null;
  elsif new.iqama = '' then raise exception 'رقم الإقامة مطلوب';
  end if;
  if not new.has_health then new.health_no := ''; new.health_exp := null;
  elsif new.health_no = '' or new.health_exp is null then raise exception 'رقم الشهادة الصحية وتاريخ انتهائها مطلوبين';
  end if;
  if new.status <> 'left' then new.left_date := null; new.end_reason := ''; end if;
  if tg_op = 'INSERT' then
    new.created_at := now(); new.created_by := v_who;
  else
    new.created_at := old.created_at; new.created_by := old.created_by;
  end if;
  new.updated_at := now(); new.updated_by := v_who;
  return new;
end $$;
drop trigger if exists employees_stamp on public.employees;
create trigger employees_stamp before insert or update on public.employees
  for each row execute function public.employees_stamp();

create or replace function public.employees_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text; v_ch jsonb := '{}'; k text;
  skip text[] := array['created_at','created_by','updated_at','updated_by','id'];
begin
  select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
  if tg_op = 'INSERT' then
    insert into employee_log (emp_id, branch, name, by_name, action) values (new.id, new.branch, new.name, coalesce(v_who, ''), 'add');
    return new;
  elsif tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(to_jsonb(new)) loop
      if not (k = any(skip)) and (to_jsonb(new)->k) is distinct from (to_jsonb(old)->k) then
        v_ch := v_ch || jsonb_build_object(k, jsonb_build_array(to_jsonb(old)->k, to_jsonb(new)->k));
      end if;
    end loop;
    if v_ch <> '{}' then
      insert into employee_log (emp_id, branch, name, by_name, action, changes) values (new.id, new.branch, new.name, coalesce(v_who, ''), 'edit', v_ch);
    end if;
    return new;
  else
    insert into employee_log (emp_id, branch, name, by_name, action) values (old.id, old.branch, old.name, coalesce(v_who, ''), 'delete');
    return old;
  end if;
end $$;
drop trigger if exists employees_audit on public.employees;
create trigger employees_audit after insert or update or delete on public.employees
  for each row execute function public.employees_audit();

-- 4) الحماية في قاعدة البيانات
alter table public.employees enable row level security;
alter table public.employee_log enable row level security;
drop policy if exists emp_select on public.employees;
drop policy if exists emp_insert on public.employees;
drop policy if exists emp_update on public.employees;
drop policy if exists emp_delete on public.employees;
create policy emp_select on public.employees for select to authenticated using (employees_can(branch));
create policy emp_insert on public.employees for insert to authenticated with check (employees_can(branch));
create policy emp_update on public.employees for update to authenticated using (employees_can(branch)) with check (employees_can(branch));
create policy emp_delete on public.employees for delete to authenticated using (coalesce(is_writer(), false));
drop policy if exists elog_select on public.employee_log;
create policy elog_select on public.employee_log for select to authenticated using (employees_can(branch));

revoke all on public.employees from anon;
revoke all on public.employee_log from anon, authenticated;
grant select, insert, update, delete on public.employees to authenticated;
grant select on public.employee_log to authenticated;
revoke all on function public.employees_can(text) from public;
grant execute on function public.employees_can(text) to authenticated;

-- 5) تفعيل القسم لمدراء الفروع الحاليين (اللي عندهم قسم المبيعات)
insert into public.user_sections (user_id, section)
select distinct us.user_id, 'employees' from public.user_sections us
where us.section = 'sales'
  and not exists (select 1 from public.user_sections x where x.user_id = us.user_id and x.section = 'employees');

select 'تم تفعيل جدول الموظفين (مع الإقامة والشهادة الصحية) ✓' as result;
