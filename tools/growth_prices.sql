create or replace function public.growth_price_watch(p_to date default null, p_days int default 45, p_branches text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[] := growth_inv_bs(p_branches); t date := coalesce(p_to, (now() at time zone 'Asia/Riyadh' - interval '8 hours')::date); f date;
begin
  f := t - greatest(7, least(coalesce(p_days, 45), 120));
  return jsonb_build_object('to', t, 'from', f, 'last_run', (select last_run from growth_sync_state where id = 'inv'),
    'items', coalesce((
      with l as (select item, dt, line_id, qty, price, amount, party from growth_inv_lines
                 where kind = 'pur' and dt between f and t and qty > 0 and price > 0 and (bs is null or branch = any(bs))),
      la as (select distinct on (item) item, dt ld, price lp, party from l order by item, dt desc, line_id desc),
      -- previous purchase of the same item from the SAME supplier (any date before the last purchase), so supplier/pack switches don't fake a change
      pv as (select la.item, p.dt pd, p.price pp from la cross join lateral (select g.dt, g.price from growth_inv_lines g
               where g.kind = 'pur' and g.item = la.item and g.party = la.party and g.dt < la.ld and g.qty > 0 and g.price > 0 and (bs is null or g.branch = any(bs))
               order by g.dt desc, g.line_id desc limit 1) p),
      -- trend line = same supplier as the last purchase
      d as (select l.item, l.dt, round(sum(l.amount) / nullif(sum(l.qty), 0), 3) p, sum(l.qty) q from l join la on la.item = l.item and l.party = la.party group by l.item, l.dt),
      ag as (select item, round(sum(amount) / nullif(sum(qty), 0), 3) av,
                    round(sum(amount) filter (where dt > t - 7) / nullif(sum(qty) filter (where dt > t - 7), 0), 3) a7,
                    round(sum(amount) filter (where dt <= t - 7) / nullif(sum(qty) filter (where dt <= t - 7), 0), 3) ap,
                    sum(qty) q, sum(amount) a, count(*) c, min(price) mn, max(price) mx from l group by item)
      select jsonb_agg(jsonb_build_object('i', ag.item, 'n', coalesce(it.name, ag.item), 'u', coalesce(it.unit, ''), 'g', coalesce(it.grp, ''),
               'lp', la.lp, 'ld', la.ld, 'party', la.party, 'pp', pv.pp, 'pd', pv.pd, 'av', ag.av, 'a7', ag.a7, 'ap', ag.ap, 'q', ag.q, 'a', ag.a, 'c', ag.c, 'mn', ag.mn, 'mx', ag.mx,
               's', (select jsonb_agg(jsonb_build_object('d', d.dt, 'p', d.p, 'q', d.q) order by d.dt) from d where d.item = ag.item)) order by ag.a desc)
      from ag join la on la.item = ag.item left join pv on pv.item = ag.item left join growth_items it on it.item = ag.item), '[]'::jsonb));
end $$;
revoke all on function public.growth_price_watch(date, int, text[]) from public, anon;
grant execute on function public.growth_price_watch(date, int, text[]) to authenticated;
