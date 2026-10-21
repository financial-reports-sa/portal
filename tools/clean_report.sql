create or replace function public.clean_branch_report(p_branch text, p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d1 date := att_bday(); d0 date; st date; res jsonb;
begin
  if not clean_can(p_branch, false) then raise exception 'غير مصرح'; end if;
  d0 := d1 - greatest(1, least(coalesce(p_days, 30), 120)) + 1;
  select greatest(d0, min(day)) into st from clean_checks where branch = p_branch;
  st := coalesce(st, d1);
  with c as (
    select * from clean_checks where branch = p_branch and day between d0 and d1 and shift in ('open', 'mid', 'close')
  ), it as (
    select c.id, c.day, c.shift, btrim(e.v->>'t') t, coalesce((e.v->>'ok')::boolean, false) ok, nullif(btrim(coalesce(e.v->>'n', '')), '') reason,
           (select a from jsonb_array_elements(c.ai_items) a where (a->>'i')::int = (e.n - 1)::int limit 1) ai
    from c, jsonb_array_elements(c.items) with ordinality e(v, n)
  ), agg as (
    select t, min(shift) shift, count(*) n, count(*) filter (where ok) done, count(*) filter (where not ok) missed,
           round(avg((ai->>'score')::numeric) filter (where ai is not null), 2) av,
           count(*) filter (where (ai->>'score')::int <= 2) low,
           count(*) filter (where ai is not null and (ai->>'match')::boolean is false) nomatch,
           (select coalesce(jsonb_agg(z), '[]') from (select distinct on (x.ai->>'note') x.ai->>'note' z from it x where x.t = it.t and x.ai is not null and (x.ai->>'score')::int <= 3 and coalesce(x.ai->>'note', '') <> '' order by x.ai->>'note', x.day desc limit 3) q) notes,
           (select coalesce(jsonb_agg(z), '[]') from (select distinct on (x.reason) x.reason z from it x where x.t = it.t and not x.ok and x.reason is not null order by x.reason, x.day desc limit 3) q) reasons
    from it group by t
  )
  select jsonb_build_object(
    'branch', p_branch, 'from', d0, 'to', d1, 'start', st, 'days', greatest(0, d1 - st + 1),
    'shifts', coalesce((select jsonb_object_agg(s, jsonb_build_object('done', n, 'avg', av, 'low', lw)) from (
        select shift s, count(*) n, round(avg(coalesce(rating, ai_rating)), 2) av, count(*) filter (where coalesce(rating, ai_rating) <= 3) lw from c group by shift) q), '{}'),
    'rated', (select count(*) from c where coalesce(rating, ai_rating) is not null),
    'avg', (select round(avg(coalesce(rating, ai_rating)), 2) from c),
    'items', coalesce((select jsonb_agg(to_jsonb(agg) order by coalesce(agg.av, 9), agg.missed desc) from agg), '[]'),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('d', day, 's', shift, 'r', coalesce(rating, ai_rating), 'n', ai_note) order by day desc) from (
        select * from c where coalesce(ai_note, '') <> '' and coalesce(rating, ai_rating) <= 3 order by day desc limit 5) q), '[]'),
    'maint', jsonb_build_object(
        'open', (select count(*) from maint_requests where branch = p_branch and status not in ('done', 'closed', 'cancelled', 'rejected')),
        'late', (select count(*) from maint_requests where branch = p_branch and status not in ('done', 'closed', 'cancelled', 'rejected') and created_at < now() - interval '3 days'),
        'list', coalesce((select jsonb_agg(jsonb_build_object('no', no, 't', title, 'st', status, 'days', greatest(0, floor(extract(epoch from (now() - created_at)) / 86400))::int) order by created_at) from (
            select * from maint_requests where branch = p_branch and status not in ('done', 'closed', 'cancelled', 'rejected') order by created_at limit 8) q), '[]'),
        'done30', (select count(*) from maint_requests where branch = p_branch and status in ('done', 'closed') and coalesce(done_at, closed_at) > now() - interval '30 days'))
  ) into res;
  return res;
end $$;
grant execute on function public.clean_branch_report(text, int) to authenticated;

select 'تم: تقرير النظافة لكل فرع' as result;
