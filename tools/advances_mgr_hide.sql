-- ============================================================
--  السلف: مدير الفرع يشوف فقط الطلبات اللي بانتظار موافقته
--  (قرارات القبول والرفض والسلف القائمة للمالك والآدمن فقط)
--  يشغَّل مرة واحدة في Supabase → SQL Editor → Run
-- ============================================================
drop policy if exists adv_select on public.advances;
create policy adv_select on public.advances for select to authenticated
  using (
    (coalesce(is_admin(), false) and employees_can(branch))
    or (employees_can(branch) and status = 'pending_mgr')
    or emp_id = my_emp_id()
  );

select 'تم: تقارير قبول ورفض السلف صارت للمالك والآدمن فقط ✓' as result;
