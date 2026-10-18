create or replace function public.growth_daily_cmp(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date; bs text[]; days date[];
begin
  if not (coalesce(is_writer(), false) or exists (select 1 from user_sections us join profiles p on p.id = us.user_id
          where us.user_id = auth.uid() and us.section in ('sales', 'wh') and coalesce(p.active, true))) then
    raise exception 'غير مصرح';
  end if;
  d := coalesce(p_day, (now() at time zone 'Asia/Riyadh' - interval '8 hours')::date);
  bs := case when coalesce(is_writer(), false) then null else my_branches() end;
  days := array[d, d - 1, d - 7];
  return jsonb_build_object('day', d,
    'last_pos', (select last_run from growth_sync_state where id = 'pos'),
    'last_inv', (select last_run from growth_sync_state where id = 'inv'),
    'sales', coalesce((select jsonb_agg(jsonb_build_object('d', bdate, 'br', branch, 'net', s, 'tax', tx, 'bills', c))
        from (select bdate, branch, sum(net) s, sum(tax) tx, count(*) filter (where net > 0) c from growth_bills
              where bdate = any(days) and (bs is null or branch = any(bs)) group by bdate, branch) q), '[]'::jsonb),
    'sales_doc', coalesce((select jsonb_agg(jsonb_build_object('d', id, 'v', data)) from app_docs
        where app = 'sales' and coll = 'sales' and id = any(array(select x::text from unnest(days) x))), '[]'::jsonb),
    'inv', coalesce((select jsonb_agg(jsonb_build_object('d', dt, 'br', branch, 'k', kind, 'a', a, 'c', c))
        from (select dt, branch, kind, sum(amount) a, count(distinct doc) c from growth_inv_lines
              where dt = any(days) and (bs is null or branch = any(bs)) group by dt, branch, kind) q), '[]'::jsonb),
    'top_iss', coalesce((select jsonb_agg(jsonb_build_object('br', branch, 'i', l.item, 'n', coalesce(it.name, l.item), 'u', coalesce(it.unit, ''), 'q', q, 'a', a, 'qy', qy, 'ay', ay))
        from (select branch, item, sum(qty) filter (where dt = d) q, sum(amount) filter (where dt = d) a,
                     sum(qty) filter (where dt = d - 1) qy, sum(amount) filter (where dt = d - 1) ay
              from growth_inv_lines where kind = 'iss' and dt in (d, d - 1) and (bs is null or branch = any(bs)) group by branch, item) l
        left join growth_items it on it.item = l.item), '[]'::jsonb),
    'price_up', coalesce((select jsonb_agg(jsonb_build_object('br', branch, 'i', t.item, 'n', coalesce(it.name, t.item), 'u', coalesce(it.unit, ''), 'p', t.price, 'pp', t.prev, 'party', t.party))
        from (select distinct on (l.branch, l.item) l.branch, l.item, l.price, l.party,
                     (select p.price from growth_inv_lines p where p.kind = 'pur' and p.item = l.item and p.dt < d and p.price > 0 order by p.dt desc, p.line_id desc limit 1) prev
              from growth_inv_lines l where l.kind = 'pur' and l.dt = d and l.price > 0 and (bs is null or l.branch = any(bs))
              order by l.branch, l.item, l.price desc) t
        left join growth_items it on it.item = t.item
        where t.prev is not null and t.price > t.prev * 1.02), '[]'::jsonb));
end $$;
revoke all on function public.growth_daily_cmp(date) from public, anon;
grant execute on function public.growth_daily_cmp(date) to authenticated;
