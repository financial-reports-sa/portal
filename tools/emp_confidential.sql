alter table public.employees add column if not exists confidential boolean not null default false;

create or replace function public.emp_conf_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_writer(), false) then
    if tg_op = 'INSERT' then new.confidential := false;
    else new.confidential := old.confidential; end if;
  end if;
  return new;
end $$;
drop trigger if exists emp_conf_guard on public.employees;
create trigger emp_conf_guard before insert or update on public.employees for each row execute function public.emp_conf_guard();

create or replace function public.emp_ok(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from employees e where e.id = p_emp
    and (coalesce(is_writer(), false) or coalesce(hr_can(), false) or (employees_can(e.branch) and not e.confidential)))
$$;
grant execute on function public.emp_ok(uuid) to authenticated;

drop policy if exists emp_select on public.employees;
drop policy if exists emp_update on public.employees;
create policy emp_select on public.employees for select to authenticated using (
  (employees_can(branch) and (not confidential or coalesce(is_writer(), false))) or coalesce(hr_can(), false));
create policy emp_update on public.employees for update to authenticated
  using (employees_can(branch) and (not confidential or coalesce(is_writer(), false)))
  with check (employees_can(branch));

drop policy if exists elog_select on public.employee_log;
create policy elog_select on public.employee_log for select to authenticated using (
  coalesce(is_writer(), false) or (employees_can(branch) and emp_ok(emp_id)));

drop policy if exists ed_all on public.employee_deductions;
create policy ed_all on public.employee_deductions for all to authenticated
  using (employees_can(branch) and emp_ok(emp_id))
  with check (exists (select 1 from public.employees e where e.id = emp_id and employees_can(e.branch)) and emp_ok(emp_id));
drop policy if exists edp_all on public.employee_deduction_photos;
create policy edp_all on public.employee_deduction_photos for all to authenticated
  using (exists (select 1 from public.employee_deductions d where d.id = ded_id and employees_can(d.branch) and emp_ok(d.emp_id)))
  with check (exists (select 1 from public.employee_deductions d where d.id = ded_id and employees_can(d.branch) and emp_ok(d.emp_id)));

drop policy if exists ep_all on public.employee_photos;
create policy ep_all on public.employee_photos for all to authenticated
  using (emp_ok(emp_id)) with check (emp_ok(emp_id));

drop policy if exists ea_select on public.emp_accounts;
create policy ea_select on public.emp_accounts for select to authenticated using (user_id = auth.uid() or emp_ok(emp_id));

drop policy if exists adv_select on public.advances;
create policy adv_select on public.advances for select to authenticated using (
  (coalesce(is_admin(), false) and employees_can(branch))
  or (employees_can(branch) and status = 'pending_mgr' and emp_ok(emp_id))
  or emp_id = my_emp_id());

do $$
begin
  if to_regclass('public.hr_emp_docs') is not null then
    execute 'drop policy if exists hre_sel on public.hr_emp_docs';
    execute 'create policy hre_sel on public.hr_emp_docs for select to authenticated using (hr_can() or emp_ok(emp_id))';
  end if;
  if to_regclass('public.hr_emp_info') is not null then
    execute 'drop policy if exists hri_sel on public.hr_emp_info';
    execute 'create policy hri_sel on public.hr_emp_info for select to authenticated using (hr_can() or emp_ok(emp_id))';
  end if;
end $$;

create or replace function public.employees_hidden() returns table (branch text, n int)
language sql stable security definer set search_path = public as $$
  select e.branch, count(*)::int from employees e
  where e.confidential and e.status <> 'left' and employees_can(e.branch)
    and not coalesce(is_writer(), false) and not coalesce(hr_can(), false)
  group by e.branch
$$;
grant execute on function public.employees_hidden() to authenticated;

select 'تم: الموظفين الإداريين مخفيين عن مدير الفرع ✓' as result;
