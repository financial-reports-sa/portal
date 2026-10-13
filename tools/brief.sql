-- ============================================================
--  التقرير المسائي — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  أول ما ينرفع «التقرير اليومي» لأي يوم ← القاعدة تجمع كل أرقام وملاحظات اليوم
--  ← دالة daily-brief تكتب التقرير بالذكاء الاصطناعي ← ينحفظ في المنصة ويوصلك إشعار
-- ============================================================
create extension if not exists pg_net with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.brief_cfg (
  id      int primary key default 1 check (id = 1),
  token   text not null,
  fn_url  text not null,
  sb_url  text not null,
  api_key text not null
);
insert into public.brief_cfg (id, token, fn_url, sb_url, api_key)
values (1, encode(extensions.gen_random_bytes(24), 'hex'),
        'https://olsqykputyhigalzmlbs.supabase.co/functions/v1/daily-brief',
        'https://olsqykputyhigalzmlbs.supabase.co',
        'sb_publishable_KLB7HL6IGxhNj_8PSebE6w_F_CpCM8r')
on conflict (id) do nothing;
alter table public.brief_cfg enable row level security;
revoke all on public.brief_cfg from anon, authenticated;

create table if not exists public.daily_briefs (
  day        date primary key,
  text       text not null,
  facts      jsonb,
  pushed     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.daily_briefs enable row level security;
drop policy if exists db_read on public.daily_briefs;
create policy db_read on public.daily_briefs for select to authenticated using (is_admin());
revoke all on public.daily_briefs from anon;
grant select on public.daily_briefs to authenticated;

create or replace function public.brief_html_text(h text) returns text
language plpgsql immutable as $$
declare t text := coalesce(h, ''); i int; j int;
begin
  i := position('<body' in t); if i > 0 then t := substr(t, i); end if;
  loop
    i := position('<script' in t); exit when i = 0;
    j := position('</script>' in substr(t, i)); if j = 0 then t := left(t, i - 1); exit; end if;
    t := left(t, i - 1) || substr(t, i + j + 8);
  end loop;
  loop
    i := position('<style' in t); exit when i = 0;
    j := position('</style>' in substr(t, i)); if j = 0 then t := left(t, i - 1); exit; end if;
    t := left(t, i - 1) || substr(t, i + j + 7);
  end loop;
  t := regexp_replace(t, '<(td|th)[^>]*>', ' ؛ ', 'gi');
  t := regexp_replace(t, '<(br|/p|/div|/tr|/li|/h[1-6])[^>]*>', E'\n', 'gi');
  t := regexp_replace(t, '<[^>]+>', ' ', 'g');
  t := replace(replace(replace(t, '&nbsp;', ' '), '&amp;', '&'), '&quot;', '"');
  t := regexp_replace(t, '[ \t]+', ' ', 'g');
  t := regexp_replace(t, '\s*\n\s*', E'\n', 'g');
  return btrim(t);
end $$;

create or replace function public.brief_facts(p_day date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f jsonb; s jsonb; lw jsonb; x jsonb; ms text := to_char(p_day, 'YYYY-MM-01'); pm date := (p_day - interval '1 month')::date;
  wd text[] := array['الأحد','الإثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
begin
  f := jsonb_build_object('day', p_day, 'weekday', wd[extract(dow from p_day)::int + 1], 'currency', 'ريال سعودي');

  begin
    select data into s from app_docs where app = 'sales' and coll = 'sales' and id = p_day::text;
    select data into lw from app_docs where app = 'sales' and coll = 'sales' and id = (p_day - 7)::text;
    select jsonb_object_agg(br.name, jsonb_strip_nulls(jsonb_build_object(
        'sales_day', round((s->>br.id)::numeric),
        'same_weekday_last_week', round((lw->>br.id)::numeric),
        'change_vs_last_week_pct', round(((s->>br.id)::numeric / nullif((lw->>br.id)::numeric, 0) - 1) * 100, 1),
        'month_to_date', round(a.mtd),
        'prev_month_same_days', round(a.pmd),
        'mtd_change_vs_prev_month_pct', round((a.mtd / nullif(a.pmd, 0) - 1) * 100, 1),
        'month_target', a.tg,
        'target_achieved_pct', round(a.mtd / nullif(a.tg, 0) * 100, 1))))
      into x
      from branches br,
      lateral (select
        (select sum((d.data->>br.id)::numeric) from app_docs d where d.app = 'sales' and d.coll = 'sales' and d.id between ms and p_day::text) mtd,
        (select sum((d.data->>br.id)::numeric) from app_docs d where d.app = 'sales' and d.coll = 'sales' and d.id between to_char(pm, 'YYYY-MM-01') and pm::text) pmd,
        (select (t.data->>br.id)::numeric from app_docs t where t.app = 'sales' and t.coll = 'targets' and t.id = to_char(p_day, 'YYYY-MM')) tg) a
      where s ? br.id;
    f := f || jsonb_build_object('branch_sales_incl_vat', coalesce(x, '"لا توجد مبيعات مسجلة لهذا اليوم"'::jsonb));
    if s is not null then
      f := f || jsonb_build_object('all_branches_sales_day', (select round(sum(v::numeric)) from jsonb_each_text(s) e(k, v) where k <> 'date' and v ~ '^-?[0-9.]+$'));
    end if;
  exception when others then null; end;

  begin
    select jsonb_object_agg(br.name, jsonb_build_object(
        'ratio_pct', round(w.cogs / nullif(w.rev, 0) * 100, 2), 'warehouse_cost', round(w.cogs), 'warehouse_revenue', round(w.rev),
        'month_ratio_pct', round(m.c / nullif(m.r, 0) * 100, 2)))
      into x
      from branches br
      join lateral (select (d.data->>'rev')::numeric rev, (d.data->>'cogs')::numeric cogs from app_docs d
                    where d.app = 'wh' and d.coll = 'daily' and d.data->>'br' = br.id and d.data->>'date' = p_day::text limit 1) w on true
      left join lateral (select sum((d.data->>'rev')::numeric) r, sum((d.data->>'cogs')::numeric) c from app_docs d
                    where d.app = 'wh' and d.coll = 'daily' and d.data->>'br' = br.id and d.data->>'date' between ms and p_day::text) m on true;
    if x is not null then f := f || jsonb_build_object('warehouse_cost_ratio', x); end if;
  exception when others then null; end;

  begin
    select jsonb_object_agg(br.name, jsonb_strip_nulls(jsonb_build_object(
        'handovers', h.n, 'total', round(h.tot, 2), 'cash', round(h.cash, 2), 'card', round(h.card, 2),
        'shortages', round(h.shrt, 2), 'overages', round(h.ovr, 2), 'pending_review', h.pend,
        'difference_vs_branch_sales', round(h.tot - (s->>br.id)::numeric, 2),
        'cashiers_with_shortage', h.who)))
      into x
      from branches br
      join lateral (
        select count(*) n, sum(total) tot, sum(cash) cash, sum(card) card,
               sum(greatest(0, -coalesce(adj, case when system is not null then total - system end, 0))) shrt,
               sum(greatest(0, coalesce(adj, case when system is not null then total - system end, 0))) ovr,
               count(*) filter (where review_status = '') pend,
               nullif(string_agg(case when coalesce(adj, case when system is not null then total - system end, 0) < -0.004
                 then cashier || ' (' || round(-coalesce(adj, total - system), 2) || ')' end, '، '), '') who
        from handovers where date = p_day and branch = br.id having count(*) > 0) h on true;
    f := f || jsonb_build_object('cashier_handover', coalesce(x, '"لا توجد تسليمات مسجلة لهذا اليوم"'::jsonb));
  exception when others then null; end;

  begin
    select jsonb_build_object(
        'reviews_today', count(*) filter (where (created_at at time zone 'Asia/Riyadh')::date = p_day),
        'avg_rating_today', round(avg(rating) filter (where (created_at at time zone 'Asia/Riyadh')::date = p_day), 2),
        'complaints_today', coalesce(jsonb_agg(jsonb_build_object('branch', (select name from branches where id = feedback.branch), 'rating', rating, 'comment', left(coalesce(comment, ''), 140)))
            filter (where (created_at at time zone 'Asia/Riyadh')::date = p_day and rating <= 3), '[]'::jsonb),
        'open_complaints_total', count(*) filter (where rating <= 3 and status not in ('resolved', 'closed')))
      into x from feedback where created_at > now() - interval '90 days';
    f := f || jsonb_build_object('customer_feedback', x);
  exception when others then null; end;

  begin
    select jsonb_build_object(
        'open', count(*),
        'overdue', count(*) filter (where now() - created_at > case priority when 'urgent' then interval '24 hours' when 'high' then interval '72 hours' else interval '168 hours' end),
        'overdue_list', coalesce(jsonb_agg((select name from branches where id = maint_requests.branch) || ': ' || title)
            filter (where now() - created_at > case priority when 'urgent' then interval '24 hours' when 'high' then interval '72 hours' else interval '168 hours' end), '[]'::jsonb))
      into x from maint_requests where status in ('new', 'assigned', 'progress', 'hold');
    f := f || jsonb_build_object('maintenance', x);
  exception when others then null; end;

  begin
    select jsonb_build_object('pending_items', count(*), 'pending_amount', coalesce(sum(amount), 0),
        'non_tax_pending', coalesce(sum(amount) filter (where kind = 'expense' and taxable is false), 0))
      into x from custody_tx t where status = 'pending' and exists (select 1 from custodies c where c.id = t.custody_id and c.status = 'open');
    f := f || jsonb_build_object('custody', x || jsonb_build_object('open_over_30_days',
        (select count(*) from custodies where status = 'open' and created_at < now() - interval '30 days')));
  exception when others then null; end;

  begin
    f := f || jsonb_build_object('salary_advances_pending', (select count(*) from advances where status in ('pending_mgr', 'pending_owner')));
  exception when others then null; end;

  begin
    select coalesce(jsonb_agg(jsonb_build_object('contract', d.data->>'name', 'date', e->>'date', 'amount', (e->>'inst')::numeric) order by e->>'date'), '[]'::jsonb)
      into x from app_docs d, jsonb_array_elements(d.data->'sched') e
      where d.app = 'loans' and d.coll = 'contracts' and (e->>'date')::date between current_date and current_date + 7;
    f := f || jsonb_build_object('installments_next_7_days', x);
  exception when others then null; end;

  begin
    select to_jsonb(price_alerts_of(data->>'html')) into x from app_docs
      where app = 'prices' and coll = 'pages' and id <= (p_day + 1)::text order by id desc limit 1;
    f := f || jsonb_build_object('purchase_price_increases', coalesce(x, '[]'::jsonb));
  exception when others then null; end;

  begin
    f := f || jsonb_build_object('daily_report_text',
      (select left(brief_html_text(data->>'html'), 7000) from app_docs where app = 'daily' and coll = 'pages' and id = p_day::text));
  exception when others then null; end;

  return f;
end $$;

create or replace function public.brief_send(p_day date) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c brief_cfg;
begin
  select * into c from brief_cfg where id = 1;
  if c.token is null then return; end if;
  perform net.http_post(
    url := c.fn_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('day', p_day, 'token', c.token, 'sb_url', c.sb_url, 'apikey', c.api_key, 'facts', brief_facts(p_day)),
    timeout_milliseconds := 120000);
end $$;

create or replace function public.brief_request(p_day date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'للإدارة فقط'; end if;
  perform brief_send(p_day);
end $$;

create or replace function public.brief_auth(p_token text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from brief_cfg where id = 1 and token = p_token)
$$;

create or replace function public.brief_save(p_token text, p_day date, p_text text, p_facts jsonb default null) returns void
language plpgsql security definer set search_path = public as $$
declare was boolean; head text;
begin
  if not brief_auth(p_token) then raise exception 'unauthorized'; end if;
  select pushed into was from daily_briefs where day = p_day;
  insert into daily_briefs (day, text, facts) values (p_day, left(p_text, 20000), p_facts)
  on conflict (day) do update set text = excluded.text, facts = excluded.facts, updated_at = now();
  if coalesce(was, false) then return; end if;
  head := btrim(regexp_replace(split_part(btrim(p_text), E'\n', 1), '[*#]', '', 'g'));
  begin
    if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is not null then
      perform push_send((select coalesce(array_agg(id), '{}') from profiles where active and role in ('owner', 'admin')),
        '📊 التقرير المسائي — ' || to_char(p_day, 'DD/MM'), left(head, 160), './?tab=home&brief=' || p_day, 'brief-' || p_day);
    end if;
  exception when others then null; end;
  update daily_briefs set pushed = true where day = p_day;
end $$;

create or replace function public.brief_on_upload() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.app = 'daily' and new.coll = 'pages' and new.id ~ '^\d{4}-\d{2}-\d{2}$'
     and (tg_op = 'INSERT' or old.data->>'html' is distinct from new.data->>'html') then
    perform brief_send(new.id::date);
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists brief_on_upload_trg on public.app_docs;
create trigger brief_on_upload_trg after insert or update of data on public.app_docs
  for each row execute function public.brief_on_upload();

revoke all on function public.brief_facts(date), public.brief_send(date), public.brief_request(date), public.brief_auth(text), public.brief_save(text,date,text,jsonb) from public, anon, authenticated;
grant execute on function public.brief_request(date) to authenticated;
grant execute on function public.brief_auth(text), public.brief_save(text,date,text,jsonb) to anon, authenticated;

select 'تم تفعيل التقرير المسائي ✓ — آخر تقرير يومي: ' || coalesce((select max(id) from app_docs where app = 'daily' and coll = 'pages'), 'لا يوجد') as result;
