create or replace function public.att_manual(p_emp uuid, p_day date, p_in time, p_out time, p_note text default '', p_seq int default 1) returns void
language plpgsql security definer set search_path = public as $$
declare e employees; tin timestamptz; tout timestamptz; sq int := greatest(1, least(2, coalesce(p_seq, 1)));
begin
  select * into e from employees where id = p_emp;
  if not exists (select 1 from profiles where id = auth.uid() and role = 'owner') then raise exception 'تصحيح سجل الحضور للمالك فقط'; end if;
  if e.id is null or not att_ok(p_emp) then raise exception 'ليس لديك صلاحية على هذا الموظف'; end if;
  if p_day is null or p_day > att_bday() then raise exception 'التاريخ غير صحيح'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'اكتب سبب التصحيح'; end if;
  tin := case when p_in is null then null else (p_day + p_in + case when p_in < time '05:00' then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh' end;
  tout := case when p_out is null then null else (p_day + p_out + case when p_out < time '05:00' or (p_in is not null and p_out < p_in and p_in >= time '05:00') then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh' end;
  if tin is null and tout is null then
    delete from attendance where emp_id = p_emp and day = p_day and seq = sq; return;
  end if;
  insert into attendance (emp_id, branch, day, seq, in_at, out_at, manual, edited_by, note)
  values (p_emp, e.branch, p_day, sq, tin, tout, true, att_who(), left(p_note, 300))
  on conflict (emp_id, day, seq) do update set in_at = excluded.in_at, out_at = excluded.out_at, manual = true, edited_by = excluded.edited_by, note = excluded.note;
end $$;
grant execute on function public.att_manual(uuid, date, time, time, text, int) to authenticated;

select 'تم: تصحيح سجلات الحضور للمالك فقط' as result;
