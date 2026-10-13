create or replace function public.adv_request(p_amount numeric, p_months int, p_reason text, p_emp uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e record; me uuid := my_emp_id(); nid uuid; who text := who_am_i();
begin
  if p_emp is not null and p_emp is distinct from me then
    raise exception 'طلب السلفة يكون من الموظف نفسه من حسابه في التطبيق';
  end if;
  if me is null then raise exception 'حسابك غير مرتبط بموظف'; end if;
  select * into e from public.employees where id = me;
  if e.status = 'left' then raise exception 'الموظف منتهية خدماته'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغ السلفة'; end if;
  if e.salary > 0 and p_amount > e.salary then raise exception 'السلفة لا تزيد عن راتب شهر واحد (%)', e.salary; end if;
  if p_months is null or p_months < 1 or p_months > 6 then raise exception 'مدة السداد من 1 إلى 6 أشهر'; end if;
  if exists (select 1 from public.advances where emp_id = e.id and status in ('pending_mgr','pending_owner')) then
    raise exception 'فيه طلب سلفة سابق ما زال تحت الإجراء';
  end if;
  insert into public.advances (emp_id, branch, emp_name, amount, months, reason, status, requested_by)
  values (e.id, e.branch, e.name, round(p_amount, 2), p_months, left(coalesce(p_reason,''), 300), 'pending_owner', who)
  returning id into nid;
  return nid;
end $$;

create or replace function public.adv_decide(p_id uuid, p_ok boolean, p_note text default '', p_start text default null)
returns void language plpgsql security definer set search_path = public as $$
declare a record; who text := who_am_i();
begin
  select * into a from public.advances where id = p_id for update;
  if a.id is null then raise exception 'الطلب غير موجود'; end if;
  if a.status not in ('pending_mgr','pending_owner') then raise exception 'الطلب ما عاد تحت الإجراء'; end if;
  if not is_admin() then raise exception 'قرار السلفة للإدارة فقط'; end if;
  update public.advances set own_by = who, own_at = now(), own_note = left(coalesce(p_note,''),300),
    status = case when p_ok then 'approved' else 'rejected' end,
    start_month = case when p_ok then coalesce(nullif(p_start,''), next_month()) end
  where id = p_id;
end $$;

update public.advances set status = 'pending_owner' where status = 'pending_mgr';

select 'تم: طلبات السلف صارت تروح للإدارة مباشرة ✓' as result;
