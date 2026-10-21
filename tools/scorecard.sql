create or replace function public.branch_scorecard(p_month text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m text := coalesce(nullif(p_month, ''), to_char(att_bday(), 'YYYY-MM'));
  d0 date := (m || '-01')::date;
  d1 date := least((d0 + interval '1 month' - interval '1 day')::date, att_bday());
  nd int := greatest(1, d1 - d0 + 1);
  p0 date := (d0 - interval '1 month')::date;
  p1 date := p0 + (d1 - d0);
  res jsonb := '[]'::jsonb; b record;
  c_done int; c_exp int; c_rate numeric; c_score numeric;
  a_n int; a_emp int; a_score numeric;
  r_ref numeric; r_gross numeric; r_score numeric;
  mt_n int; mt_ok int; mt_open int; mt_score numeric;
  s_cur numeric; s_prev numeric; s_score numeric;
  w numeric; tot numeric; mgr text;
begin
  if not coalesce(is_admin(), false) then raise exception 'بطاقة الأداء للإدارة فقط'; end if;
  if d1 < d0 then d1 := d0; end if;
  for b in select id, name from branches order by sort, id loop
    select count(*), avg(coalesce(rating, ai_rating)) into c_done, c_rate from clean_checks
     where branch = b.id and day between d0 and d1 and shift in ('open', 'mid', 'close');
    c_exp := 3 * greatest(0, d1 - greatest(d0, coalesce((select min(day) from clean_checks where branch = b.id), d1 + 1)) + 1);
    c_score := case when c_exp = 0 then null
                    else round(0.5 * least(100, c_done * 100.0 / c_exp) + 0.5 * coalesce(c_rate / 5 * 100, least(100, c_done * 100.0 / c_exp)), 1) end;

    select count(*) into a_n from alert_log l join employees e on e.id = l.emp_id
     where e.branch = b.id and l.kind in ('att_late', 'att_abs', 'att_early', 'att_noout', 'att_sh2')
       and (l.created_at at time zone 'Asia/Riyadh')::date between d0 and d1;
    select count(*) into a_emp from employees e where e.branch = b.id and e.status = 'active'
       and exists (select 1 from emp_accounts x where x.emp_id = e.id)
       and not coalesce((select exempt from att_emp z where z.emp_id = e.id), false);
    a_score := case when a_emp = 0 or not exists (select 1 from alert_log where kind like 'att_%' and (created_at at time zone 'Asia/Riyadh')::date <= d1) then null
                    else round(greatest(0, 100 - (a_n::numeric / (a_emp * nd)) * 500), 1) end;

    select coalesce(sum(refunds), 0), coalesce(sum(sales + credit), 0) into r_ref, r_gross from growth_cashier_daily where branch = b.id and bdate between d0 and d1;
    r_score := case when r_gross <= 0 then null else round(greatest(0, 100 - (r_ref / r_gross * 100) * 40), 1) end;

    select count(*), count(*) filter (where coalesce(done_at, closed_at) is not null and coalesce(done_at, closed_at) <= created_at + interval '3 days'),
           count(*) filter (where status not in ('done', 'closed', 'cancelled', 'rejected'))
      into mt_n, mt_ok, mt_open from maint_requests where branch = b.id and (created_at at time zone 'Asia/Riyadh')::date between d0 and d1 and status not in ('cancelled', 'rejected');
    mt_score := case when mt_n = 0 then null else round(mt_ok * 100.0 / mt_n, 1) end;

    select coalesce(sum(sales + credit - refunds), 0) into s_cur from growth_cashier_daily where branch = b.id and bdate between d0 and d1;
    select coalesce(sum(sales + credit - refunds), 0) into s_prev from growth_cashier_daily where branch = b.id and bdate between p0 and p1;
    s_score := case when s_prev <= 0 or s_cur <= 0 then null else round(greatest(0, least(100, 50 + ((s_cur / s_prev - 1) * 100) * 2.5)), 1) end;

    w := 0; tot := 0;
    if c_score is not null then w := w + 30; tot := tot + c_score * 30; end if;
    if a_score is not null then w := w + 25; tot := tot + a_score * 25; end if;
    if s_score is not null then w := w + 20; tot := tot + s_score * 20; end if;
    if r_score is not null then w := w + 15; tot := tot + r_score * 15; end if;
    if mt_score is not null then w := w + 10; tot := tot + mt_score * 10; end if;

    select string_agg(distinct coalesce(nullif(p.full_name, ''), p.username), '، ') into mgr
      from profiles p join user_branches ub on ub.user_id = p.id and ub.branch_id = b.id
      join user_sections us on us.user_id = p.id and us.section = 'clean'
     where p.role = 'user' and coalesce(p.active, true);

    res := res || jsonb_build_array(jsonb_build_object(
      'b', b.id, 'name', b.name, 'mgr', coalesce(mgr, ''),
      'score', case when w = 0 then null else round(tot / w, 1) end,
      'clean', jsonb_build_object('s', c_score, 'done', c_done, 'exp', c_exp, 'rate', round(c_rate, 2)),
      'att', jsonb_build_object('s', a_score, 'n', a_n, 'emps', a_emp),
      'sales', jsonb_build_object('s', s_score, 'cur', round(s_cur), 'prev', round(s_prev), 'g', case when s_prev > 0 then round((s_cur / s_prev - 1) * 100, 1) end),
      'ret', jsonb_build_object('s', r_score, 'r', round(r_ref), 'pct', case when r_gross > 0 then round(r_ref / r_gross * 100, 2) end),
      'maint', jsonb_build_object('s', mt_score, 'n', mt_n, 'ok', mt_ok, 'open', mt_open)));
  end loop;
  return jsonb_build_object('month', m, 'from', d0, 'to', d1, 'days', nd, 'prev_from', p0, 'prev_to', p1, 'rows', res);
end $$;
revoke all on function public.branch_scorecard(text) from public, anon;
grant execute on function public.branch_scorecard(text) to authenticated;

select 'تم: بطاقة أداء الفروع' as result;
