create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

alter table public.mkt_ideas add column if not exists trends jsonb not null default '[]';
alter table public.mkt_ideas add column if not exists src text not null default 'app';

create table if not exists public.mkt_state (id int primary key default 1 check (id = 1), kicked_at timestamptz);
insert into public.mkt_state (id) values (1) on conflict (id) do nothing;
alter table public.mkt_state enable row level security;
revoke all on public.mkt_state from anon, authenticated;

create or replace function public.mkt_kick(p_replace boolean default false) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare c brief_cfg; d date := ((now() at time zone 'Asia/Riyadh') - interval '3 hours')::date; f jsonb; k timestamptz;
  prev jsonb; liked jsonb; disliked jsonb;
begin
  if auth.uid() is not null then
    if not coalesce(is_admin(), false) then raise exception 'التحديث للإدارة فقط'; end if;
    select kicked_at into k from mkt_state where id = 1;
    if k > now() - interval '3 minutes' then raise exception 'جاري التجهيز — انتظر دقيقتين'; end if;
  end if;
  update mkt_state set kicked_at = now() where id = 1;
  select * into c from brief_cfg where id = 1;
  if c.token is null then raise exception 'إعدادات التقرير المسائي غير موجودة'; end if;
  begin f := brief_facts(d - 1); exception when others then f := '{}'; end;
  select coalesce(jsonb_agg(x->>'title'), '[]') into prev from (select jsonb_array_elements(items) x from mkt_ideas where day >= d - 10 and day < d) s;
  select coalesce(jsonb_agg(distinct i.items->v.idx->>'title'), '[]') into liked from mkt_votes v join mkt_ideas i on i.day = v.day where v.vote > 0 or v.done;
  select coalesce(jsonb_agg(distinct i.items->v.idx->>'title'), '[]') into disliked from mkt_votes v join mkt_ideas i on i.day = v.day where v.vote < 0;
  perform net.http_post(
    url := replace(c.fn_url, 'daily-brief', 'mkt-trends'),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('day', d, 'token', c.token, 'apikey', c.api_key, 'facts', f, 'prev', prev, 'liked', liked, 'disliked', disliked),
    timeout_milliseconds := 150000);
  return true;
end $$;

create or replace function public.mkt_srv_save(p_token text, p_day date, p_occasion text, p_items jsonb, p_trends jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid[];
begin
  if not brief_auth(p_token) then raise exception 'unauthorized'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no ideas'; end if;
  delete from mkt_votes where day = p_day;
  insert into mkt_ideas (day, occasion, items, trends, made_by, src) values (p_day, left(coalesce(p_occasion, ''), 200), p_items, coalesce(p_trends, '[]'), 'المساعد الذكي', 'web')
  on conflict (day) do update set occasion = excluded.occasion, items = excluded.items, trends = excluded.trends, made_by = excluded.made_by, src = excluded.src, created_at = now();
  u := array(select p.id from profiles p where p.active and (p.role in ('owner','admin') or exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'mkt')));
  begin
    perform push_send(u, '💡 أفكار وترندات اليوم جاهزة', coalesce(nullif(p_occasion, ''), 'افتح «أفكار تسويقية» وشوف الجديد'), './?tab=mkt', 'mkt-' || p_day);
  exception when others then null; end;
end $$;

create or replace function public.mkt_get(p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not mkt_can() then raise exception 'ما عندك صلاحية على الأفكار التسويقية'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('day', i.day, 'occasion', i.occasion, 'items', i.items, 'trends', i.trends, 'src', i.src, 'by', i.made_by, 'at', i.created_at,
      'votes', coalesce((select jsonb_object_agg(v.idx::text, jsonb_build_object('up', v.up, 'down', v.down, 'done', v.dn, 'mine', v.mine, 'mdone', v.mdone))
        from (select idx, count(*) filter (where vote > 0) up, count(*) filter (where vote < 0) down, bool_or(done) dn,
                     max(case when user_id = auth.uid() then vote end) mine, bool_or(done and user_id = auth.uid()) mdone
                from mkt_votes where day = i.day group by idx) v), '{}')) order by i.day desc)
    from (select * from mkt_ideas order by day desc limit greatest(1, least(coalesce(p_days, 14), 60))) i), '[]');
end $$;

revoke all on function public.mkt_kick(boolean) from public, anon;
grant execute on function public.mkt_kick(boolean) to authenticated;
revoke all on function public.mkt_srv_save(text, date, text, jsonb, jsonb) from public, authenticated;
grant execute on function public.mkt_srv_save(text, date, text, jsonb, jsonb) to anon;

do $$ begin perform cron.unschedule('mkt-daily'); exception when others then null; end $$;
select cron.schedule('mkt-daily', '20 5 * * *', 'select public.mkt_kick(false)');

select 'تم: الترندات والأفكار تنزل كل يوم الساعة 8:20 الصبح تلقائياً' as result;
