create or replace function public.att_set_exempt(p_emp uuid, p_exempt boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_admin(), false) then raise exception 'الإعفاء من البصمة للآدمن فقط'; end if;
  if not att_ok(p_emp) then raise exception 'ليس لديك صلاحية على هذا الموظف'; end if;
  insert into att_emp (emp_id, exempt, updated_by) values (p_emp, coalesce(p_exempt, false), att_who())
  on conflict (emp_id) do update set exempt = excluded.exempt, updated_by = excluded.updated_by, updated_at = now();
end $$;
grant execute on function public.att_set_exempt(uuid, boolean) to authenticated;
