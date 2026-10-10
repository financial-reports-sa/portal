-- ============================================================
--  خصومات الموظفين — مدير الفرع يسجّل خصم (المبلغ، السبب، صورة المخالفة)
--  ينخصم من مستحق الموظف في كشف الشهر. يشغَّل مرة واحدة في Supabase → SQL Editor → Run
-- ============================================================
create table if not exists public.employee_deductions (
  id         uuid primary key default gen_random_uuid(),
  emp_id     uuid not null references public.employees(id) on delete cascade,
  branch     text not null default '',
  date       date not null,
  amount     numeric(12,2) not null check (amount > 0),
  reason     text not null check (length(btrim(reason)) > 0),
  notes      text not null default '',
  has_photo  boolean not null default false,
  created_at timestamptz not null default now(),
  created_by text not null default ''
);
create index if not exists employee_deductions_emp_idx on public.employee_deductions (emp_id, date);
create index if not exists employee_deductions_branch_idx on public.employee_deductions (branch, date);

-- صورة المخالفة (تُحمَّل عند الطلب فقط)
create table if not exists public.employee_deduction_photos (
  ded_id uuid primary key references public.employee_deductions(id) on delete cascade,
  img    text not null
);

-- الفرع يُؤخذ من الموظف نفسه + اسم اللي سجّل الخصم
create or replace function public.employee_deductions_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text;
begin
  select branch into new.branch from employees where id = new.emp_id;
  if new.branch is null then raise exception 'الموظف غير موجود'; end if;
  if new.date > current_date + 1 or new.date < current_date - 400 then raise exception 'تاريخ الخصم غير صحيح'; end if;
  new.reason := left(btrim(new.reason), 60);
  new.notes := left(coalesce(new.notes, ''), 300);
  if tg_op = 'INSERT' then
    select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
    new.created_by := coalesce(v_who, ''); new.created_at := now();
  else
    new.emp_id := old.emp_id; new.created_by := old.created_by; new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists employee_deductions_stamp on public.employee_deductions;
create trigger employee_deductions_stamp before insert or update on public.employee_deductions
  for each row execute function public.employee_deductions_stamp();

-- يسجّل الخصم وإلغاءه في سجل تعديلات الموظف
create or replace function public.employee_deductions_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_who text; v_name text; d employee_deductions;
begin
  d := case when tg_op = 'DELETE' then old else new end;
  select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
  select name into v_name from employees where id = d.emp_id;
  insert into employee_log (emp_id, branch, name, by_name, action, changes)
  values (d.emp_id, d.branch, coalesce(v_name, ''), coalesce(v_who, ''),
          case when tg_op = 'DELETE' then 'undeduct' else 'deduct' end,
          jsonb_build_object('amount', d.amount, 'reason', d.reason, 'date', d.date));
  return d;
end $$;
drop trigger if exists employee_deductions_audit on public.employee_deductions;
create trigger employee_deductions_audit after insert or delete on public.employee_deductions
  for each row execute function public.employee_deductions_audit();

create or replace function public.employee_deduction_photos_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if length(new.img) > 700000 then raise exception 'الصورة كبيرة'; end if;
  update employee_deductions set has_photo = true where id = new.ded_id and not has_photo;
  return new;
end $$;
drop trigger if exists employee_deduction_photos_check on public.employee_deduction_photos;
create trigger employee_deduction_photos_check before insert or update on public.employee_deduction_photos
  for each row execute function public.employee_deduction_photos_check();

-- الحماية: مدير الفرع على فرعه فقط
alter table public.employee_deductions enable row level security;
alter table public.employee_deduction_photos enable row level security;
drop policy if exists ed_all on public.employee_deductions;
create policy ed_all on public.employee_deductions for all to authenticated
  using (employees_can(branch))
  with check (exists (select 1 from public.employees e where e.id = emp_id and employees_can(e.branch)));
drop policy if exists edp_all on public.employee_deduction_photos;
create policy edp_all on public.employee_deduction_photos for all to authenticated
  using (exists (select 1 from public.employee_deductions d where d.id = ded_id and employees_can(d.branch)))
  with check (exists (select 1 from public.employee_deductions d where d.id = ded_id and employees_can(d.branch)));
revoke all on public.employee_deductions, public.employee_deduction_photos from anon;
grant select, insert, update, delete on public.employee_deductions, public.employee_deduction_photos to authenticated;

select 'تم تفعيل خصومات الموظفين ✓' as result;
