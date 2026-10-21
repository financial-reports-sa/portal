do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['glq']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')
           || coalesce((select ('{' || (regexp_match(pg_get_constraintdef(c.oid), '\{([^}]*)\}'))[1] || '}')::text[]
                       from pg_constraint c where c.conname = 'user_sections_section_check'), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create table if not exists public.gl_queue (
  id          bigint generated always as identity primary key,
  kind        text not null default 'jv' check (kind in ('jv', 'bank')),
  branch      text not null,
  dt          date not null,
  narration   text not null,
  lines       jsonb not null,
  total       numeric(16,2) not null default 0,
  status      text not null default 'pending' check (status in ('pending', 'posted', 'cancelled')),
  created_by  uuid,
  created_name text not null default '',
  created_at  timestamptz not null default now(),
  posted_doc  text,
  posted_at   timestamptz,
  posted_how  text,
  note        text not null default ''
);
create index if not exists gl_queue_status_idx on public.gl_queue (status, created_at desc);
alter table public.gl_queue enable row level security;
revoke all on public.gl_queue from anon, authenticated;

create or replace function public.glq_can() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_admin(), false) or coalesce(has_section('glq'), false)
$$;

create or replace function public.glq_accounts() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not glq_can() then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('c', c, 'n', n, 't', t) order by c) from (
      select acc c, name n, 1 t from growth_coa where leaf
      union all
      select code, name, case kind when 'vend' then 3 else 2 end from growth_accounts where coalesce(code, '') <> ''
    ) q), '[]'::jsonb) end
$$;

create or replace function public.glq_save(p_id bigint, p_kind text, p_branch text, p_dt date, p_narr text, p_lines jsonb) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare d numeric; c numeric; n int; rid bigint; nm text; u uuid[];
begin
  if not coalesce(is_admin(), false) then raise exception 'اعتماد القيود للإدارة فقط'; end if;
  if nullif(btrim(coalesce(p_narr, '')), '') is null then raise exception 'اكتب البيان'; end if;
  if coalesce(p_branch, '') = '' then raise exception 'اختر الفرع'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then raise exception 'القيد يحتاج سطرين على الأقل'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) x where coalesce(x->>'c', '') = '') then raise exception 'فيه سطر بدون حساب'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) x where coalesce((x->>'d')::numeric, 0) < 0 or coalesce((x->>'k')::numeric, 0) < 0
             or (coalesce((x->>'d')::numeric, 0) > 0 and coalesce((x->>'k')::numeric, 0) > 0) or (coalesce((x->>'d')::numeric, 0) = 0 and coalesce((x->>'k')::numeric, 0) = 0)) then
    raise exception 'كل سطر يكون مدين أو دائن فقط بمبلغ أكبر من صفر'; end if;
  select sum(coalesce((x->>'d')::numeric, 0)), sum(coalesce((x->>'k')::numeric, 0)), count(*) into d, c, n from jsonb_array_elements(p_lines) x;
  if round(d, 2) <> round(c, 2) then raise exception 'القيد غير متوازن: المدين % والدائن %', d, c; end if;
  select coalesce(nullif(full_name, ''), username) into nm from profiles where id = auth.uid();
  if p_id is null then
    insert into gl_queue (kind, branch, dt, narration, lines, total, created_by, created_name)
    values (coalesce(nullif(p_kind, ''), 'jv'), p_branch, coalesce(p_dt, att_bday()), btrim(p_narr), p_lines, round(d, 2), auth.uid(), coalesce(nm, ''))
    returning id into rid;
    select coalesce(array_agg(distinct p.id), '{}') into u from profiles p join user_sections us on us.user_id = p.id and us.section = 'glq' where coalesce(p.active, true);
    if cardinality(u) > 0 then
      perform push_send(u, '🧾 قيد جديد بانتظار التسجيل في جروث', btrim(p_narr) || ' — ' || to_char(round(d, 2), 'FM999,999,990.00') || ' ر.س', './?tab=glq', 'glq-' || rid);
    end if;
  else
    update gl_queue set kind = coalesce(nullif(p_kind, ''), kind), branch = p_branch, dt = coalesce(p_dt, dt), narration = btrim(p_narr), lines = p_lines, total = round(d, 2)
     where id = p_id and status = 'pending' returning id into rid;
    if rid is null then raise exception 'القيد غير موجود أو تم تسجيله'; end if;
  end if;
  return rid;
end $$;

create or replace function public.glq_list(p_status text default 'pending') returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not glq_can() then '[]'::jsonb else coalesce((
    select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
      select id, kind, branch, dt, narration, lines, total, status, created_name, created_at, posted_doc, posted_at, posted_how, note
      from gl_queue where status = coalesce(p_status, 'pending') or (p_status = 'all')
      order by created_at desc limit 300) q), '[]'::jsonb) end
$$;

create or replace function public.glq_mark(p_id bigint, p_doc text, p_cancel boolean default false) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not glq_can() then raise exception 'غير مصرح'; end if;
  if p_cancel then
    if not coalesce(is_admin(), false) then raise exception 'الإلغاء للإدارة فقط'; end if;
    update gl_queue set status = 'cancelled', note = coalesce(nullif(btrim(p_doc), ''), note) where id = p_id and status = 'pending';
  else
    update gl_queue set status = 'posted', posted_doc = nullif(btrim(coalesce(p_doc, '')), ''), posted_at = now(), posted_how = 'يدوي — ' || who_am_i() where id = p_id and status = 'pending';
  end if;
end $$;

create or replace function public.glq_match() returns int
language plpgsql volatile security definer set search_path = public as $$
declare e record; m record; n int := 0; cnt int;
begin
  for e in select * from gl_queue where status = 'pending' order by id loop
    cnt := jsonb_array_length(e.lines);
    select g.typ || ' رقم ' || g.doc doc, g.branch, min(g.dt) dt into m
      from growth_gl_lines g
     where g.dt between e.dt - 3 and e.dt + 10
       and g.doc <> '' and (g.typ || ' رقم ' || g.doc) not in (select posted_doc from gl_queue where status = 'posted' and posted_doc is not null and posted_at > now() - interval '120 days')
     group by g.doc, g.typ, g.branch
    having count(*) = cnt
       and bool_and(exists (select 1 from jsonb_array_elements(e.lines) x
                             where x->>'c' = g.acc and round(coalesce((x->>'d')::numeric, 0), 2) = g.debit and round(coalesce((x->>'k')::numeric, 0), 2) = g.credit))
     order by min(g.dt) limit 1;
    if m.doc is not null then
      update gl_queue set status = 'posted', posted_doc = m.doc, posted_at = now(), posted_how = 'تلقائي من جروث' where id = e.id;
      n := n + 1;
    elsif e.created_at < now() - interval '24 hours' and to_regprocedure('public.alert_send(text,text,uuid,uuid[],text,text,text,text,boolean,uuid[])') is not null then
      perform alert_send('glq:late:' || e.id, 'glq_late', null, alert_owners(), 'قيد لم يُسجل في جروث بعد',
        'القيد «' || e.narration || '» بمبلغ ' || to_char(e.total, 'FM999,999,990.00') || ' ر.س (فرع ' || coalesce((select name from branches where id = e.branch), e.branch) || ') معتمد منذ أكثر من 24 ساعة ولم يظهر في جروث حتى الآن.' || chr(10) || '— نظام المتابعة الآلي',
        './?tab=glq', 'high', false, '{}');
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.glq_match() from public, anon, authenticated;

grant execute on function public.glq_can(), public.glq_accounts(), public.glq_save(bigint, text, text, date, text, jsonb), public.glq_list(text), public.glq_mark(bigint, text, boolean) to authenticated;

do $$
begin
  begin perform cron.unschedule('auto-glq'); exception when others then null; end;
  perform cron.schedule('auto-glq', '*/10 * * * *', 'select public.glq_match()');
end $$;

select 'تم: طابور القيود (قيود جروث)' as result;
