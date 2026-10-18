create table if not exists public.growth_channels_daily (
  branch  text not null,
  day     date not null,
  channel text not null,
  name    text not null default '',
  net     numeric(16,2) not null default 0,
  tax     numeric(16,2) not null default 0,
  bills   int not null default 0,
  primary key (branch, day, channel)
);
alter table public.growth_channels_daily enable row level security;
revoke all on public.growth_channels_daily from anon, authenticated;

create table if not exists public.growth_channel_map (
  branch  text not null default '*',
  name    text not null,
  code    text not null,
  primary key (branch, name)
);
alter table public.growth_channel_map enable row level security;
revoke all on public.growth_channel_map from anon, authenticated;

create or replace function public.growth_ch_code(p_branch text, p_name text) returns text
language plpgsql stable security definer set search_path = public as $$
declare n text := regexp_replace(coalesce(p_name, ''), '[أإآ]', 'ا', 'g'); c text;
begin
  select code into c from growth_channel_map where name = p_name and branch in (p_branch, '*') order by (branch = p_branch) desc limit 1;
  if c is not null then return nullif(c, '-'); end if;
  n := replace(replace(n, 'ة', 'ه'), 'ى', 'ي');
  if n ~ '(كيتا|keeta)' then return 'keeta'; end if;
  if n ~ '(هنقر|هنجر|هانقر|هانجر|hunger)' then return 'hs'; end if;
  if n ~ 'نينجا|ninja' then return 'ninja'; end if;
  if n ~ 'بونات|bonat' then return 'bonat'; end if;
  if n ~ 'الشادن' then return 'shaden'; end if;
  if n ~ 'قسم العائلات|العائلات' then return 'family'; end if;
  if n ~ 'عوائل' then return 'awail'; end if;
  if n ~ 'وجبات' then return 'meals'; end if;
  if n ~ 'توصيل' then return 'dlv'; end if;
  if n ~ 'اجل' then return 'ajl'; end if;
  if n ~ 'سفري' then return case when p_branch = 'pc' then 'sfr' else 'tkl' end; end if;
  if n ~ 'محلي' then return case when p_branch = 'pc' then 'mhl' else 'tkl' end; end if;
  return null;
end $$;

create or replace function public.growth_channels_rebuild(p_month text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare prev jsonb; doc jsonb; b text; o jsonb; unm jsonb;
begin
  prev := coalesce((select data from app_docs where app = 'channels' and coll = 'periods' and id = p_month), '{}'::jsonb);
  doc := prev || jsonb_build_object('month', p_month);
  for b in select distinct branch from growth_channels_daily where to_char(day, 'YYYY-MM') = p_month loop
    select coalesce(jsonb_object_agg(code, v), '{}'::jsonb) into o from (
      select growth_ch_code(branch, name) code, round(sum(net), 2) v from growth_channels_daily
      where branch = b and to_char(day, 'YYYY-MM') = p_month group by 1) t where code is not null;
    doc := jsonb_set(doc, array[b], o, true);
    doc := jsonb_set(doc, '{inv}', coalesce(doc->'inv', '{}'::jsonb) || jsonb_build_object(b,
             (select sum(bills) from growth_channels_daily where branch = b and to_char(day, 'YYYY-MM') = p_month and growth_ch_code(branch, name) is not null)), true);
    doc := jsonb_set(doc, '{days}', coalesce(doc->'days', '{}'::jsonb) || jsonb_build_object(b,
             (select count(distinct day) from growth_channels_daily where branch = b and to_char(day, 'YYYY-MM') = p_month and net > 0)), true);
    doc := jsonb_set(doc, '{asOf}', coalesce(doc->'asOf', '{}'::jsonb) || jsonb_build_object(b,
             (select max(day)::text from growth_channels_daily where branch = b and to_char(day, 'YYYY-MM') = p_month)), true);
  end loop;
  doc := jsonb_set(doc, '{source}', '"growth"', true);
  insert into app_docs (app, coll, id, data, branches, updated_at) values ('channels', 'periods', p_month, doc, '{}', now())
  on conflict (app, coll, id) do update set data = excluded.data, updated_at = now();
  select coalesce(jsonb_agg(distinct jsonb_build_object('branch', branch, 'name', name)), '[]'::jsonb) into unm
  from growth_channels_daily where to_char(day, 'YYYY-MM') = p_month and growth_ch_code(branch, name) is null and net <> 0;
  return jsonb_build_object('month', p_month, 'unmapped', unm);
end $$;

create or replace function public.growth_ingest_channels(p_rows jsonb, p_from date default null, p_reset boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; d int := 0; m text; res jsonb := '[]'::jsonb;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role in ('sync', 'owner') and coalesce(active, true)) then
    raise exception 'غير مصرح';
  end if;
  if jsonb_typeof(coalesce(p_rows, '[]')) <> 'array' or jsonb_array_length(coalesce(p_rows, '[]')) > 8000 then
    raise exception 'دفعة غير صالحة';
  end if;
  if p_reset and p_from is not null then
    delete from growth_channels_daily where day >= p_from; get diagnostics d = row_count;
  end if;
  insert into growth_channels_daily (branch, day, channel, name, net, tax, bills)
  select coalesce(x->>'branch', ''), (x->>'day')::date, coalesce(x->>'channel', x->>'name'), left(coalesce(x->>'name', ''), 80),
         coalesce((x->>'net')::numeric, 0), coalesce((x->>'tax')::numeric, 0), coalesce((x->>'bills')::int, 0)
  from jsonb_array_elements(coalesce(p_rows, '[]')) x
  where coalesce(x->>'branch', '') <> '' and x->>'day' is not null and coalesce(x->>'channel', x->>'name', '') <> ''
  on conflict (branch, day, channel) do update set name = excluded.name, net = excluded.net, tax = excluded.tax, bills = excluded.bills;
  get diagnostics n = row_count;
  for m in select distinct to_char((x->>'day')::date, 'YYYY-MM') from jsonb_array_elements(coalesce(p_rows, '[]')) x where x->>'day' is not null
           union select to_char(p_from, 'YYYY-MM') where p_reset and p_from is not null loop
    res := res || jsonb_build_array(growth_channels_rebuild(m));
  end loop;
  insert into growth_sync_state (id, last_run, rows_in, info) values ('ch', now(), n, jsonb_build_object('from', p_from, 'deleted', d))
  on conflict (id) do update set last_run = now(), rows_in = excluded.rows_in, info = excluded.info;
  return jsonb_build_object('ok', true, 'rows', n, 'deleted', d, 'months', res);
end $$;

revoke all on function public.growth_ch_code(text, text) from public, anon;
revoke all on function public.growth_channels_rebuild(text) from public, anon, authenticated;
revoke all on function public.growth_ingest_channels(jsonb, date, boolean) from public, anon;
grant execute on function public.growth_ingest_channels(jsonb, date, boolean) to authenticated;
