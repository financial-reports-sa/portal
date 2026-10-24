do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['salaries']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')
           || coalesce((select ('{' || (regexp_match(pg_get_constraintdef(c.oid), '\{([^}]*)\}'))[1] || '}')::text[]
                       from pg_constraint c where c.conname = 'user_sections_section_check'), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create or replace function public.salary_can() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_owner(), false) or exists (select 1 from user_sections s join profiles p on p.id = s.user_id
    where s.user_id = auth.uid() and s.section = 'salaries' and coalesce(p.active, true) and p.role <> 'employee')
$$;

create or replace function public.emp_salaries() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not salary_can() then '{}'::jsonb else coalesce((select jsonb_object_agg(id, salary) from employees), '{}'::jsonb) end
$$;

create or replace function public.emp_salary_totals() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(branch, jsonb_build_object('sum', s, 'n', n)), '{}'::jsonb) from (
    select branch, sum(salary) s, count(*) n from employees
    where status <> 'left' and (coalesce(employees_can(branch), false) or coalesce(hr_can(), false)) and not coalesce(confidential, false)
    group by branch) q
$$;

create or replace function public.employees_salary_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or salary_can() then return new; end if;
  if tg_op = 'INSERT' then new.salary := 0;
  else new.salary := old.salary; end if;
  return new;
end $$;
drop trigger if exists employees_salary_guard on public.employees;
create trigger employees_salary_guard before insert or update on public.employees for each row execute function public.employees_salary_guard();

do $$
declare cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'employees' and column_name <> 'salary';
  execute 'revoke select on public.employees from authenticated';
  execute format('grant select (%s) on public.employees to authenticated', cols);
end $$;

revoke all on function public.salary_can(), public.emp_salaries(), public.emp_salary_totals() from public, anon;
grant execute on function public.salary_can(), public.emp_salaries(), public.emp_salary_totals() to authenticated;

select 'تم: الرواتب مخفية إلا للمالك ومن عنده صلاحية «الرواتب»' as result;
