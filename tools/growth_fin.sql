create table if not exists public.growth_coa (
  acc     text primary key,
  name    text not null default '',
  parent  text not null default '',
  lvl     int not null default 0,
  leaf    boolean not null default true,
  synced_at timestamptz not null default now()
);
alter table public.growth_coa enable row level security;
revoke all on public.growth_coa from anon, authenticated;

create table if not exists public.growth_branches (
  code    text primary key,
  name    text not null default '',
  entity  text not null default ''
);
alter table public.growth_branches enable row level security;
revoke all on public.growth_branches from anon, authenticated;

create table if not exists public.growth_tb (
  branch  text not null,
  acc     text not null,
  ym      text not null,
  debit   numeric(16,2) not null default 0,
  credit  numeric(16,2) not null default 0,
  primary key (branch, acc, ym)
);
alter table public.growth_tb enable row level security;
revoke all on public.growth_tb from anon, authenticated;

create or replace function public.growth_ingest_coa(p_rows jsonb, p_branches jsonb default '[]') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 20000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if jsonb_array_length(coalesce(p_rows, '[]')) > 0 then
    delete from growth_coa g where not exists (select 1 from jsonb_array_elements(p_rows) x where x->>'acc' = g.acc);
  end if;
  insert into growth_coa (acc, name, parent, lvl, leaf, synced_at)
  select x->>'acc', left(coalesce(x->>'name', ''), 160), coalesce(x->>'parent', ''), coalesce((x->>'lvl')::int, 0),
         coalesce((x->>'leaf')::boolean, true), now()
  from jsonb_array_elements(coalesce(p_rows, '[]')) x where coalesce(x->>'acc', '') <> ''
  on conflict (acc) do update set name = excluded.name, parent = excluded.parent, lvl = excluded.lvl, leaf = excluded.leaf, synced_at = now();
  get diagnostics n = row_count;
  insert into growth_branches (code, name, entity)
  select x->>'code', left(coalesce(x->>'name', ''), 120), left(coalesce(x->>'entity', ''), 60)
  from jsonb_array_elements(coalesce(p_branches, '[]')) x where coalesce(x->>'code', '') <> ''
  on conflict (code) do update set name = excluded.name, entity = excluded.entity;
  return jsonb_build_object('ok', true, 'rows', n);
end $$;

create or replace function public.growth_ingest_tb(p_rows jsonb, p_from_ym text default null, p_reset boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; d int := 0;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 8000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if p_reset and p_from_ym is not null then
    delete from growth_tb where ym >= p_from_ym; get diagnostics d = row_count;
  end if;
  insert into growth_tb (branch, acc, ym, debit, credit)
  select coalesce(x->>'branch', ''), x->>'acc', x->>'ym', coalesce((x->>'debit')::numeric, 0), coalesce((x->>'credit')::numeric, 0)
  from jsonb_array_elements(coalesce(p_rows, '[]')) x
  where coalesce(x->>'acc', '') <> '' and coalesce(x->>'ym', '') ~ '^[0-9]{4}-[0-9]{2}$'
  on conflict (branch, acc, ym) do update set debit = excluded.debit, credit = excluded.credit;
  get diagnostics n = row_count;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('tb', now(), n, jsonb_build_object('from', p_from_ym, 'reset', p_reset, 'deleted', d))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'rows', n, 'deleted', d);
end $$;

create or replace function public.growth_fin(p_from text, p_to text, p_branches text[] default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bs text[];
begin
  if not (coalesce(is_writer(), false) or exists (select 1 from user_sections us join profiles p on p.id = us.user_id
          where us.user_id = auth.uid() and us.section in ('income', 'fin_is', 'fin_bs', 'fin_tb') and coalesce(p.active, true))) then
    raise exception 'غير مصرح';
  end if;
  bs := p_branches;
  if not coalesce(is_writer(), false) then
    bs := array(select unnest(coalesce(p_branches, my_branches())) intersect select unnest(my_branches()));
  end if;
  return jsonb_build_object(
    'last_run', (select last_run from growth_sync_state where id = 'tb'),
    'writer', coalesce(is_writer(), false),
    'branches', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'name', name, 'entity', entity) order by code) from growth_branches), '[]'::jsonb),
    'coa', coalesce((select jsonb_agg(jsonb_build_object('a', acc, 'n', name, 'p', parent, 'l', lvl, 'f', leaf)) from growth_coa), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('a', acc, 'ob', ob, 'dr', dr, 'cr', cr)) from (
        select acc,
               sum(case when ym < p_from then debit - credit else 0 end) ob,
               sum(case when ym >= p_from and ym <= p_to then debit else 0 end) dr,
               sum(case when ym >= p_from and ym <= p_to then credit else 0 end) cr
        from growth_tb where ym <= p_to and (bs is null or branch = any(bs))
        group by acc) t where ob <> 0 or dr <> 0 or cr <> 0), '[]'::jsonb));
end $$;

revoke all on function public.growth_ingest_coa(jsonb, jsonb) from public, anon;
grant execute on function public.growth_ingest_coa(jsonb, jsonb) to authenticated;
revoke all on function public.growth_ingest_tb(jsonb, text, boolean) from public, anon;
grant execute on function public.growth_ingest_tb(jsonb, text, boolean) to authenticated;
revoke all on function public.growth_fin(text, text, text[]) from public, anon;
grant execute on function public.growth_fin(text, text, text[]) to authenticated;
