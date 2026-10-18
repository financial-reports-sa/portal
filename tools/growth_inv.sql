create table if not exists public.growth_items (
  item   text primary key,
  name   text not null default '',
  unit   text not null default '',
  grp    text not null default ''
);
alter table public.growth_items enable row level security;
revoke all on public.growth_items from anon, authenticated;

create table if not exists public.growth_stock (
  branch text not null default '',
  wh     text not null default '',
  item   text not null,
  qty    numeric(16,3) not null default 0,
  cost   numeric(16,4) not null default 0,
  value  numeric(16,2) not null default 0,
  primary key (branch, wh, item)
);
alter table public.growth_stock enable row level security;
revoke all on public.growth_stock from anon, authenticated;

create table if not exists public.growth_inv_lines (
  kind    text not null check (kind in ('pur', 'pret', 'iss')),
  branch  text not null default '',
  line_id text not null,
  dt      date not null,
  wh      text not null default '',
  doc     text not null default '',
  party   text not null default '',
  item    text not null,
  qty     numeric(16,3) not null default 0,
  price   numeric(16,4) not null default 0,
  amount  numeric(16,2) not null default 0,
  tax     numeric(16,2) not null default 0,
  primary key (kind, branch, line_id)
);
create index if not exists growth_inv_lines_dt_idx on public.growth_inv_lines (dt, kind);
alter table public.growth_inv_lines enable row level security;
revoke all on public.growth_inv_lines from anon, authenticated;

create or replace function public.growth_ingest_items(p_items jsonb, p_stock jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; m int := 0;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_array_length(coalesce(p_items, '[]')) > 20000 or jsonb_array_length(coalesce(p_stock, '[]')) > 20000 then
    raise exception 'دفعة غير صالحة';
  end if;
  insert into growth_items (item, name, unit, grp)
  select x->>'item', left(coalesce(x->>'name', ''), 160), left(coalesce(x->>'unit', ''), 30), left(coalesce(x->>'grp', ''), 80)
  from jsonb_array_elements(coalesce(p_items, '[]')) x where coalesce(x->>'item', '') <> ''
  on conflict (item) do update set name = excluded.name, unit = excluded.unit, grp = excluded.grp;
  get diagnostics n = row_count;
  if p_stock is not null then
    delete from growth_stock where true;
    insert into growth_stock (branch, wh, item, qty, cost, value)
    select coalesce(x->>'branch', ''), left(coalesce(x->>'wh', ''), 80), x->>'item', coalesce((x->>'qty')::numeric, 0),
           coalesce((x->>'cost')::numeric, 0), coalesce((x->>'value')::numeric, 0)
    from jsonb_array_elements(p_stock) x where coalesce(x->>'item', '') <> ''
    on conflict (branch, wh, item) do update set qty = excluded.qty, cost = excluded.cost, value = excluded.value;
    get diagnostics m = row_count;
  end if;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('stock', now(), m, jsonb_build_object('items', n))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'items', n, 'stock', m);
end $$;

create or replace function public.growth_ingest_inv(p_rows jsonb, p_from date default null, p_reset boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; d int := 0;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 8000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if p_reset and p_from is not null then
    delete from growth_inv_lines where dt >= p_from; get diagnostics d = row_count;
  end if;
  insert into growth_inv_lines (kind, branch, line_id, dt, wh, doc, party, item, qty, price, amount, tax)
  select x->>'kind', coalesce(x->>'branch', ''), x->>'line_id', (x->>'dt')::date, left(coalesce(x->>'wh', ''), 80), left(coalesce(x->>'doc', ''), 40),
         left(coalesce(x->>'party', ''), 160), x->>'item', coalesce((x->>'qty')::numeric, 0), coalesce((x->>'price')::numeric, 0),
         coalesce((x->>'amount')::numeric, 0), coalesce((x->>'tax')::numeric, 0)
  from jsonb_array_elements(coalesce(p_rows, '[]')) x
  where x->>'kind' in ('pur', 'pret', 'iss') and coalesce(x->>'line_id', '') <> '' and coalesce(x->>'item', '') <> '' and x->>'dt' is not null
  on conflict (kind, branch, line_id) do update set dt = excluded.dt, wh = excluded.wh, doc = excluded.doc, party = excluded.party, item = excluded.item,
    qty = excluded.qty, price = excluded.price, amount = excluded.amount, tax = excluded.tax;
  get diagnostics n = row_count;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('inv', now(), n, jsonb_build_object('from', p_from, 'reset', p_reset, 'deleted', d))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'rows', n, 'deleted', d);
end $$;

create or replace function public.growth_inv_bs(p_branches text[]) returns text[]
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(is_writer(), false) then return p_branches; end if;
  if not exists (select 1 from user_sections us join profiles p on p.id = us.user_id
                 where us.user_id = auth.uid() and us.section in ('wh', 'chicken') and coalesce(p.active, true)) then
    raise exception 'غير مصرح';
  end if;
  return array(select unnest(coalesce(p_branches, my_branches())) intersect select unnest(my_branches()));
end $$;

create or replace function public.growth_inv(p_from date, p_to date, p_branches text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[] := growth_inv_bs(p_branches);
begin
  return jsonb_build_object(
    'last_run', (select last_run from growth_sync_state where id = 'inv'),
    'stock_run', (select last_run from growth_sync_state where id = 'stock'),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'entity', entity) order by code) from growth_branches), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('k', kind, 'i', l.item, 'n', coalesce(it.name, l.item), 'u', coalesce(it.unit, ''), 'g', coalesce(it.grp, ''),
                        'q', q, 'a', a, 'c', c, 'mn', mn, 'mx', mx, 'last', lp))
        from (select kind, item, sum(qty) q, sum(amount) a, count(*) c, min(nullif(price, 0)) mn, max(price) mx,
                     (array_agg(price order by dt desc, line_id desc))[1] lp
              from growth_inv_lines where dt between p_from and p_to and (bs is null or branch = any(bs)) group by kind, item) l
        left join growth_items it on it.item = l.item), '[]'::jsonb),
    'parties', coalesce((select jsonb_agg(jsonb_build_object('k', kind, 'p', party, 'a', a, 'c', c))
        from (select kind, party, sum(amount) a, count(distinct doc) c from growth_inv_lines
              where dt between p_from and p_to and (bs is null or branch = any(bs)) group by kind, party) t), '[]'::jsonb),
    'sales_days', coalesce((select jsonb_agg(jsonb_build_object('d', bdate, 'net', n, 'ex', n - t) order by bdate)
        from (select bdate, sum(net) n, sum(tax) t from growth_bills where bdate between p_from and p_to and (bs is null or branch = any(bs)) group by bdate) q), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('k', kind, 'd', dt, 'a', a) order by dt)
        from (select kind, dt, sum(amount) a from growth_inv_lines where dt between p_from and p_to and (bs is null or branch = any(bs)) group by kind, dt) t), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object('i', s.item, 'n', coalesce(it.name, s.item), 'u', coalesce(it.unit, ''), 'g', coalesce(it.grp, ''), 'q', q, 'v', v))
        from (select item, sum(qty) q, sum(value) v from growth_stock where (bs is null or branch = any(bs)) group by item having sum(qty) <> 0 or sum(value) <> 0) s
        left join growth_items it on it.item = s.item), '[]'::jsonb));
end $$;

create or replace function public.growth_inv_item(p_item text, p_from date, p_to date, p_branches text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[] := growth_inv_bs(p_branches);
begin
  return jsonb_build_object('item', (select jsonb_build_object('n', name, 'u', unit, 'g', grp) from growth_items where item = p_item),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('k', kind, 'd', dt, 'br', branch, 'w', wh, 'doc', doc, 'p', party, 'q', qty, 'pr', price, 'a', amount) order by dt desc, line_id desc)
       from growth_inv_lines where item = p_item and dt between p_from and p_to and (bs is null or branch = any(bs))), '[]'::jsonb),
    'stock', coalesce((select jsonb_agg(jsonb_build_object('br', branch, 'w', wh, 'q', qty, 'c', cost, 'v', value))
       from growth_stock where item = p_item and (bs is null or branch = any(bs))), '[]'::jsonb));
end $$;

revoke all on function public.growth_ingest_items(jsonb, jsonb) from public, anon;
grant execute on function public.growth_ingest_items(jsonb, jsonb) to authenticated;
revoke all on function public.growth_ingest_inv(jsonb, date, boolean) from public, anon;
grant execute on function public.growth_ingest_inv(jsonb, date, boolean) to authenticated;
revoke all on function public.growth_inv_bs(text[]) from public, anon;
grant execute on function public.growth_inv_bs(text[]) to authenticated;
revoke all on function public.growth_inv(date, date, text[]) from public, anon;
grant execute on function public.growth_inv(date, date, text[]) to authenticated;
revoke all on function public.growth_inv_item(text, date, date, text[]) from public, anon;
grant execute on function public.growth_inv_item(text, date, date, text[]) to authenticated;
