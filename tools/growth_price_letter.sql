create or replace function public.growth_price_letter(p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[] := growth_inv_bs(null);
begin
  return jsonb_build_object('day', p_day,
    'up', coalesce((
      with d as (select item, n, u, party, round(price, 4) price, sum(qty) qty, sum(amount) amount, string_agg(distinct nullif(doc, ''), ' و') docs
                 from gpp_lines where dt = p_day and (bs is null or branch = any(bs)) group by item, n, u, party, round(price, 4))
      select jsonb_agg(jsonb_build_object('n', d.n, 'u', d.u, 'party', d.party, 'price', d.price, 'qty', d.qty, 'docs', d.docs,
               'pp', pv.price, 'pd', pv.dt, 'pdoc', pv.doc) order by (d.price - pv.price) * d.qty desc)
      from d join lateral (select l.price, l.dt, l.doc from gpp_lines l where l.item = d.item and l.party = d.party and l.dt < p_day
                           order by l.dt desc, l.line_id desc limit 1) pv on true
      where d.price > pv.price * 1.0005), '[]'::jsonb),
    'alt', coalesce((
      with d as (select item, n, u, party, round(price, 4) price, sum(qty) qty from gpp_lines where dt = p_day and (bs is null or branch = any(bs)) group by item, n, u, party, round(price, 4))
      select jsonb_agg(jsonb_build_object('n', d.n, 'u', d.u, 'party', d.party, 'price', d.price, 'qty', d.qty, 'ap', al.price, 'aparty', al.party, 'ad', al.dt) order by (d.price - al.price) * d.qty desc)
      from d join lateral (select x.price, x.party, x.dt from (select distinct on (l.party) l.party, l.price, l.dt from gpp_lines l
                             where l.item = d.item and l.party <> d.party and l.dt <= p_day and l.dt > p_day - 45 order by l.party, l.dt desc, l.line_id desc) x
                           where x.price < d.price * 0.995 order by x.price limit 1) al on true), '[]'::jsonb),
    'prev', coalesce((
      select jsonb_agg(z order by z->>'d' desc) from (
        select jsonb_build_object('d', x.dt, 'n', x.n, 'u', x.u, 'party', x.party, 'price', x.price, 'pp', x.pp, 'qty', x.qty) z
        from (select l.dt, l.item, min(l.n) n, min(l.u) u, l.party, round(l.price, 4) price, sum(l.qty) qty,
                     (select p.price from gpp_lines p where p.item = l.item and p.party = l.party and p.dt < l.dt order by p.dt desc, p.line_id desc limit 1) pp
              from gpp_lines l where l.dt between p_day - 7 and p_day - 1 and (bs is null or l.branch = any(bs)) group by l.dt, l.item, l.party, round(l.price, 4)) x
        where x.pp is not null and x.price > x.pp * 1.0005 order by (x.price - x.pp) * x.qty desc limit 10) q), '[]'::jsonb));
end $$;
revoke all on function public.growth_price_letter(date) from public, anon;
grant execute on function public.growth_price_letter(date) to authenticated;
