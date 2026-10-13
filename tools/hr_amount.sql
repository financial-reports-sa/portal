alter table public.hr_requests add column if not exists amount numeric(12,2) check (amount is null or amount >= 0);

create or replace function public.hr_request_add(p_emp uuid, p_kind text, p_note text default '', p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e record; v_id uuid; v_who text := hr_who(); u uuid[];
begin
  select id, name, branch into e from employees where id = p_emp;
  if e.id is null then raise exception 'الموظف غير موجود'; end if;
  if not (hr_can() or employees_can(e.branch)) then raise exception 'ما عندك صلاحية على هذا الموظف'; end if;
  if exists (select 1 from hr_requests where emp_id = p_emp and kind = p_kind and status in ('new','progress')) then
    raise exception 'فيه طلب مفتوح من نفس النوع لهذا الموظف';
  end if;
  insert into hr_requests (kind, emp_id, emp_name, branch, note, requested_name, amount)
  values (p_kind, e.id, e.name, e.branch, left(coalesce(p_note, ''), 500), v_who, nullif(p_amount, 0)) returning id into v_id;
  begin
    if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is not null then
      u := array(select x from unnest(hr_staff()) x where x is distinct from auth.uid());
      perform push_send(u, '🗂️ طلب جديد: ' || hr_kind_name(p_kind),
        e.name || coalesce(' — ' || to_char(nullif(p_amount, 0), 'FM999,999,990.99') || ' ر.س', '') || coalesce(' — ' || nullif(v_who, ''), ''),
        './?tab=hr&hrt=req', 'hrreq-' || v_id);
    end if;
  exception when others then null;
  end;
  return v_id;
end $$;
grant execute on function public.hr_request_add(uuid, text, text, numeric) to authenticated;
drop function if exists public.hr_request_add(uuid, text, text);

select 'تمت إضافة المبلغ للطلبات ✓' as result;
