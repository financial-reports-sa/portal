create table if not exists public.growth_bills (
  branch     text not null,
  bill_id    text not null,
  bdate      date not null,
  dt         timestamptz not null,
  bill_type  int,
  channel    int,
  channel_name text not null default '',
  cashier_id text not null default '',
  cashier    text not null default '',
  gross      numeric(14,2) not null default 0,
  tax        numeric(14,2) not null default 0,
  net        numeric(14,2) not null default 0,
  disc       numeric(14,2) not null default 0,
  extra      numeric(14,2) not null default 0,
  cash       numeric(14,2) not null default 0,
  visa       numeric(14,2) not null default 0,
  master     numeric(14,2) not null default 0,
  pay_type   text not null default '',
  synced_at  timestamptz not null default now(),
  primary key (branch, bill_id)
);
create index if not exists growth_bills_day_idx on public.growth_bills (bdate, branch);
alter table public.growth_bills enable row level security;
revoke all on public.growth_bills from anon, authenticated;

create table if not exists public.growth_sync_state (
  id         text primary key,
  last_run   timestamptz not null default now(),
  rows_in    int not null default 0,
  info       jsonb not null default '{}'
);
alter table public.growth_sync_state enable row level security;
revoke all on public.growth_sync_state from anon, authenticated;

create or replace function public.growth_ingest(p_rows jsonb, p_days date[] default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; d date; v jsonb; t numeric; b text;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 8000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if p_days is not null then
    delete from growth_bills g where g.bdate = any(p_days)
      and not exists (select 1 from jsonb_array_elements(p_rows) x where x->>'branch' = g.branch and x->>'bill_id' = g.bill_id);
  end if;
  insert into growth_bills (branch, bill_id, bdate, dt, bill_type, channel, channel_name, cashier_id, cashier, gross, tax, net, disc, extra, cash, visa, master, pay_type, synced_at)
  select x->>'branch', x->>'bill_id', (x->>'bdate')::date, (x->>'dt')::timestamptz, nullif(x->>'bill_type', '')::int, nullif(x->>'channel', '')::int,
         left(coalesce(x->>'channel_name', ''), 60), left(coalesce(x->>'cashier_id', ''), 40), left(coalesce(x->>'cashier', ''), 80),
         coalesce((x->>'gross')::numeric, 0), coalesce((x->>'tax')::numeric, 0), coalesce((x->>'net')::numeric, 0), coalesce((x->>'disc')::numeric, 0),
         coalesce((x->>'extra')::numeric, 0), coalesce((x->>'cash')::numeric, 0), coalesce((x->>'visa')::numeric, 0), coalesce((x->>'master')::numeric, 0),
         left(coalesce(x->>'pay_type', ''), 30), now()
  from jsonb_array_elements(coalesce(p_rows, '[]')) x
  where coalesce(x->>'branch', '') <> '' and coalesce(x->>'bill_id', '') <> '' and x->>'bdate' is not null and x->>'dt' is not null
  on conflict (branch, bill_id) do update set bdate = excluded.bdate, dt = excluded.dt, bill_type = excluded.bill_type, channel = excluded.channel,
    channel_name = excluded.channel_name, cashier_id = excluded.cashier_id, cashier = excluded.cashier, gross = excluded.gross, tax = excluded.tax,
    net = excluded.net, disc = excluded.disc, extra = excluded.extra, cash = excluded.cash, visa = excluded.visa, master = excluded.master,
    pay_type = excluded.pay_type, synced_at = now();
  get diagnostics n = row_count;
  for d in select distinct bdate from growth_bills where bdate = any(coalesce(p_days, '{}'::date[]))
           union select distinct (x->>'bdate')::date from jsonb_array_elements(coalesce(p_rows, '[]')) x where x->>'bdate' is not null loop
    v := coalesce((select data from app_docs where app = 'sales' and coll = 'sales' and id = d::text), '{}'::jsonb) || jsonb_build_object('date', d::text);
    for b, t in select branch, round(sum(net), 2) from growth_bills where bdate = d group by branch loop
      v := v || jsonb_build_object(b, t);
    end loop;
    insert into app_docs (app, coll, id, data, branches, updated_at) values ('sales', 'sales', d::text, v, '{}', now())
    on conflict (app, coll, id) do update set data = excluded.data, updated_at = now();
  end loop;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('pos', now(), n, jsonb_build_object('days', p_days))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'rows', n);
end $$;

create or replace function public.growth_live(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, (select max(bdate) from growth_bills), (now() at time zone 'Asia/Riyadh')::date); bs text[];
begin
  if not exists (select 1 from profiles where id = auth.uid() and coalesce(active, true)) then raise exception 'غير مصرح'; end if;
  bs := case when coalesce(is_writer(), false) then null else my_branches() end;
  return jsonb_build_object('day', d, 'last_run', (select last_run from growth_sync_state where id = 'pos'),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('branch', branch, 'bills', c, 'net', s, 'tax', tx, 'disc', ds, 'last_bill', lb) order by s desc)
       from (select branch, count(*) filter (where net > 0) c, sum(net) s, sum(tax) tx, sum(disc) ds, max(dt) lb from growth_bills where bdate = d and (bs is null or branch = any(bs)) group by branch) q), '[]'),
    'channels', coalesce((select jsonb_agg(jsonb_build_object('branch', branch, 'channel', channel_name, 'bills', c, 'net', s) order by branch, s desc)
       from (select branch, channel_name, count(*) filter (where net > 0) c, sum(net) s from growth_bills where bdate = d and (bs is null or branch = any(bs)) group by branch, channel_name) q), '[]'),
    'cashiers', coalesce((select jsonb_agg(jsonb_build_object('branch', branch, 'cashier', cashier, 'bills', c, 'net', s, 'refunds', r) order by branch, s desc)
       from (select branch, cashier, count(*) filter (where net > 0) c, sum(net) s, -sum(net) filter (where net < 0) r from growth_bills where bdate = d and (bs is null or branch = any(bs)) group by branch, cashier) q), '[]'),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('h', h, 'net', s) order by h)
       from (select extract(hour from dt at time zone 'Asia/Riyadh')::int h, sum(net) s from growth_bills where bdate = d and (bs is null or branch = any(bs)) group by 1) q), '[]'));
end $$;

revoke all on function public.growth_ingest(jsonb, date[]) from public, anon;
grant execute on function public.growth_ingest(jsonb, date[]) to authenticated;
revoke all on function public.growth_live(date) from public, anon;
grant execute on function public.growth_live(date) to authenticated;

select 'تم: استقبال مبيعات جروث اللحظية' as result;
