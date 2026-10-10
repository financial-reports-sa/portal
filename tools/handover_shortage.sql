-- ============================================================
--  تسليم الورديات — تسجيل العجز / الزيادة من المحاسب
--  + الكاشير يشوف تسليماته وعجوزاته برمزه
-- ============================================================
alter table public.handovers add column if not exists adj    numeric;              -- سالب = عجز، موجب = زيادة، صفر = مطابق
alter table public.handovers add column if not exists adj_by text not null default '';
alter table public.handovers add column if not exists adj_at timestamptz;

-- المحاسب يسجّل نتيجة المطابقة (null = حذف القيد)
create or replace function public.handover_adj(p_hid text, p_amount numeric, p_note text default '') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_branch text; v_who text;
begin
  select branch into v_branch from handovers where hid = p_hid;
  if v_branch is null then return jsonb_build_object('ok', false, 'message', 'التسليم غير موجود'); end if;
  if not handover_can(v_branch) then return jsonb_build_object('ok', false, 'message', 'ما عندك صلاحية على هذا الفرع'); end if;
  if p_amount is not null and abs(p_amount) > 1000000 then return jsonb_build_object('ok', false, 'message', 'المبلغ غير صحيح'); end if;
  select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
  if p_amount is null then
    update handovers set adj = null, adj_by = '', adj_at = null where hid = p_hid;
  else
    update handovers set adj = round(p_amount, 2), adj_by = coalesce(v_who, ''), adj_at = now(),
      review_status = case when round(p_amount, 2) = 0 then 'ok' else 'issue' end,
      review_note = left(coalesce(p_note, ''), 300), reviewed_at = now(), reviewed_by = coalesce(v_who, '')
    where hid = p_hid;
  end if;
  return jsonb_build_object('ok', true, 'who', coalesce(v_who, ''));
end $$;

-- الكاشير يشوف آخر تسليماته (٤٥ يوم) مع المراجعة والعجز — برمزه الشخصي
create or replace function public.handover_mine(p_branch text, p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip   text := coalesce(split_part(coalesce(current_setting('request.headers', true), '{}')::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_code text;
begin
  if (select count(*) from handover_fails where ip = v_ip and at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'locked', 'message', 'محاولات كثيرة — انتظر ربع ساعة وحاول مرة ثانية');
  end if;
  select code into v_code from cashier_codes where pin = btrim(coalesce(p_pin, '')) and branch = p_branch;
  if v_code is null then
    insert into handover_fails (ip) values (v_ip);
    return jsonb_build_object('ok', false, 'error', 'pin', 'message', 'رمزك الشخصي غلط أو مو لهذا الفرع');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('date', h.date, 'cashier', h.cashier, 'total', h.total, 'status', h.review_status,
                                        'note', h.review_note, 'adj', h.adj) order by h.date desc)
    from (select * from handovers where code = v_code and date >= current_date - 45 order by date desc limit 60) h), '[]'::jsonb));
end $$;

revoke all on function public.handover_adj(text, numeric, text) from public;
revoke all on function public.handover_mine(text, text) from public;
grant execute on function public.handover_adj(text, numeric, text) to authenticated;
grant execute on function public.handover_mine(text, text) to anon, authenticated;

select 'تم تفعيل تسجيل العجز ✓' as result;
