do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback','custody','hr','custody_holder','att','msgs_send']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

alter table public.employees add column if not exists confidential boolean not null default false;

create table if not exists public.msgs (
  id          bigint generated always as identity primary key,
  kind        text not null default 'gen' check (kind in ('dec','circ','offer','shift','warn','gen')),
  prio        text not null default 'normal' check (prio in ('normal','high','urgent')),
  title       text not null,
  body        text not null default '',
  need_ack    boolean not null default false,
  files       jsonb not null default '[]',
  target      jsonb not null default '{}',
  sender      uuid not null,
  sender_name text,
  reminded_at timestamptz,
  created_at  timestamptz not null default now()
);
create table if not exists public.msg_rcpt (
  msg_id  bigint not null references public.msgs(id) on delete cascade,
  user_id uuid not null,
  name    text,
  kind    text,
  hidden  boolean not null default false,
  read_at timestamptz,
  ack_at  timestamptz,
  primary key (msg_id, user_id)
);
create index if not exists msg_rcpt_user_idx on public.msg_rcpt (user_id, msg_id desc);
create table if not exists public.msg_replies (
  id         bigint generated always as identity primary key,
  msg_id     bigint not null references public.msgs(id) on delete cascade,
  user_id    uuid not null,
  by_name    text,
  to_user    uuid,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists msg_replies_msg_idx on public.msg_replies (msg_id, id);
alter table public.msgs enable row level security;
alter table public.msg_rcpt enable row level security;
alter table public.msg_replies enable row level security;
revoke all on public.msgs, public.msg_rcpt, public.msg_replies from anon, authenticated;

create or replace function public.msg_can_send() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active)
     and (coalesce(is_admin(), false) or exists (select 1 from user_sections where user_id = auth.uid() and section = 'msgs_send'))
$$;

create or replace function public.msg_people_rows() returns table (uid uuid, name text, kind text, branches text[], hidden boolean)
language sql stable security definer set search_path = public as $$
  with me as (select coalesce(is_admin(), false) adm, coalesce(my_branches(), '{}') brs),
  ppl as (
    select p.id uid, coalesce(nullif(p.full_name, ''), p.username) name,
           case when p.role in ('owner','admin') then 'admin' else 'mgr' end kind,
           case when p.role in ('owner','admin') then coalesce((select array_agg(id) from branches), '{}')
                else coalesce((select array_agg(b.branch_id) from user_branches b where b.user_id = p.id), '{}') end branches,
           false hidden
      from profiles p where p.active and p.role in ('owner','admin','user')
    union all
    select p.id, coalesce(nullif(e.name, ''), nullif(p.full_name, ''), p.username), 'emp',
           array[e.branch], coalesce(e.confidential, false)
      from profiles p join emp_accounts a on a.user_id = p.id join employees e on e.id = a.emp_id
     where p.active and p.role = 'employee' and coalesce(e.status, 'active') <> 'left'
  )
  select x.uid, x.name, x.kind, x.branches, x.hidden and not me.adm
    from ppl x, me
   where x.uid is distinct from auth.uid()
     and (me.adm or x.kind = 'admin' or x.branches && me.brs)
$$;
revoke all on function public.msg_people_rows() from public, anon, authenticated;

create or replace function public.msg_people() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when msg_can_send() then coalesce(jsonb_agg(jsonb_build_object('id', uid, 'name', name, 'kind', kind, 'br', branches) order by kind, name), '[]') else '[]' end
    from msg_people_rows() where not hidden
$$;

create or replace function public.msg_hid(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce(is_admin(), false) and exists (select 1 from emp_accounts a join employees e on e.id = a.emp_id where a.user_id = p_uid and e.confidential)
$$;
revoke all on function public.msg_hid(uuid) from public, anon, authenticated;

create or replace function public.msg_can_view(p_id bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_admin(), false)
      or exists (select 1 from msgs where id = p_id and sender = auth.uid())
      or exists (select 1 from msg_rcpt where msg_id = p_id and user_id = auth.uid())
$$;

create or replace function public.msg_send(p_kind text, p_prio text, p_title text, p_body text, p_ack boolean, p_target jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare adm boolean := coalesce(is_admin(), false); sc text := coalesce(p_target->>'scope', 'branches');
  who text := coalesce(p_target->>'who', 'all'); brs text[]; us uuid[]; nid bigint; n int; rc uuid[];
  ic text := case p_kind when 'dec' then '⚖️ قرار إداري' when 'circ' then '📢 تعميم' when 'offer' then '🏷️ عرض جديد'
                         when 'shift' then '🕒 الدوامات' when 'warn' then '⚠️ تنبيه' else '✉️ رسالة' end;
begin
  if not msg_can_send() then raise exception 'ما عندك صلاحية إرسال المراسلات'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'اكتب عنوان المراسلة'; end if;
  if who not in ('all','mgr','emp') then raise exception 'المستلمين غير صحيحين'; end if;
  brs := array(select jsonb_array_elements_text(coalesce(p_target->'branches', '[]')));
  us := array(select (jsonb_array_elements_text(coalesce(p_target->'users', '[]')))::uuid);
  if sc = 'all' and not adm then raise exception 'الإرسال للجميع للإدارة فقط'; end if;
  if sc = 'branches' and not adm and exists (select 1 from unnest(brs) b where not b = any(coalesce(my_branches(), '{}'))) then
    raise exception 'تقدر ترسل لفروعك فقط';
  end if;
  insert into msgs (kind, prio, title, body, need_ack, target, sender, sender_name)
  values (coalesce(p_kind, 'gen'), coalesce(p_prio, 'normal'), left(trim(p_title), 200), left(coalesce(p_body, ''), 8000), coalesce(p_ack, false),
          jsonb_build_object('scope', sc, 'who', who, 'branches', to_jsonb(brs), 'users', to_jsonb(us)), auth.uid(), who_am_i())
  returning id into nid;
  insert into msg_rcpt (msg_id, user_id, name, kind, hidden)
  select distinct on (r.uid) nid, r.uid, r.name, r.kind, r.hidden from msg_people_rows() r
   where case when sc = 'users' then r.uid = any(us)
              else (who = 'all' or (who = 'mgr' and r.kind <> 'emp') or (who = 'emp' and r.kind = 'emp'))
                   and (sc = 'all' or (r.kind <> 'admin' and r.branches && brs)) end;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'ما فيه مستلمين بهذا الاختيار'; end if;
  rc := array(select user_id from msg_rcpt where msg_id = nid);
  perform push_send(rc, case when p_prio = 'urgent' then '🚨 ' else '' end || ic || ' · ' || coalesce(who_am_i(), ''),
                    left(trim(p_title), 120), './?tab=msgs&m=' || nid, 'msg-' || nid);
  return nid;
end $$;

create or replace function public.msg_attach(p_id bigint, p_files jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from msgs where id = p_id and sender = auth.uid()) then raise exception 'غير مسموح'; end if;
  update msgs set files = coalesce(p_files, '[]') where id = p_id;
end $$;

create or replace function public.msg_inbox() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'body', left(m.body, 160),
             'ack', m.need_ack, 'from', m.sender_name, 'at', m.created_at, 'read', r.read_at, 'acked', r.ack_at,
             'files', jsonb_array_length(m.files)) x
      from msg_rcpt r join msgs m on m.id = r.msg_id
     where r.user_id = auth.uid()
     order by m.id desc limit 300) t
$$;

create or replace function public.msg_sent() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'ack', m.need_ack,
             'from', m.sender_name, 'mine', m.sender = auth.uid(), 'at', m.created_at, 'target', m.target,
             'n', (select count(*) from msg_rcpt r where r.msg_id = m.id),
             'nr', (select count(*) from msg_rcpt r where r.msg_id = m.id and r.read_at is not null),
             'na', (select count(*) from msg_rcpt r where r.msg_id = m.id and r.ack_at is not null),
             'nrep', (select count(*) from msg_replies q where q.msg_id = m.id and q.user_id <> m.sender)) x
      from msgs m
     where m.sender = auth.uid() or coalesce(is_admin(), false)
     order by m.id desc limit 300) t
$$;

create or replace function public.msg_get(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m msgs; boss boolean; res jsonb;
begin
  select * into m from msgs where id = p_id;
  if not found or not msg_can_view(p_id) then raise exception 'المراسلة غير موجودة'; end if;
  boss := m.sender = auth.uid() or coalesce(is_admin(), false);
  update msg_rcpt set read_at = now() where msg_id = p_id and user_id = auth.uid() and read_at is null;
  res := jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'body', m.body, 'ack', m.need_ack,
    'files', m.files, 'from', m.sender_name, 'at', m.created_at, 'target', m.target, 'boss', boss, 'mine', m.sender = auth.uid(),
    'reminded', m.reminded_at,
    'me', (select jsonb_build_object('read', read_at, 'acked', ack_at) from msg_rcpt where msg_id = p_id and user_id = auth.uid()),
    'replies', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'by', case when msg_hid(q.user_id) then 'موظف' else q.by_name end,
                 'uid', q.user_id, 'to', q.to_user, 'body', q.body, 'at', q.created_at, 'me', q.user_id = auth.uid()) order by q.id)
               from msg_replies q
              where q.msg_id = p_id and (boss or q.user_id = auth.uid() or q.to_user = auth.uid())), '[]'));
  if boss then
    res := res || jsonb_build_object('rcpt', coalesce((select jsonb_agg(jsonb_build_object('uid', case when msg_hid(user_id) then null else user_id end,
             'name', case when msg_hid(user_id) then 'موظف' else name end, 'kind', kind, 'read', read_at, 'acked', ack_at) order by ack_at nulls first, read_at nulls first, name)
           from msg_rcpt where msg_id = p_id), '[]'));
  end if;
  return res;
end $$;

create or replace function public.msg_ack(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare m msgs;
begin
  update msg_rcpt set ack_at = coalesce(ack_at, now()), read_at = coalesce(read_at, now())
   where msg_id = p_id and user_id = auth.uid();
  if not found then raise exception 'المراسلة غير موجودة'; end if;
end $$;

create or replace function public.msg_reply(p_id bigint, p_body text, p_to uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare m msgs; boss boolean; who text := who_am_i();
begin
  select * into m from msgs where id = p_id;
  if not found or not msg_can_view(p_id) then raise exception 'المراسلة غير موجودة'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'اكتب الرد'; end if;
  boss := m.sender = auth.uid() or coalesce(is_admin(), false);
  if boss and p_to is not null and not exists (select 1 from msg_rcpt where msg_id = p_id and user_id = p_to) then raise exception 'المستلم غير صحيح'; end if;
  if not boss then p_to := null; end if;
  insert into msg_replies (msg_id, user_id, by_name, to_user, body) values (p_id, auth.uid(), who, p_to, left(trim(p_body), 2000));
  update msg_rcpt set read_at = coalesce(read_at, now()) where msg_id = p_id and user_id = auth.uid();
  if boss and p_to is not null then
    perform push_send(array[p_to], '💬 رد على: ' || left(m.title, 60), coalesce(who, '') || ': ' || left(trim(p_body), 120), './?tab=msgs&m=' || p_id, 'msgr-' || p_id);
  elsif not boss then
    perform push_send(array[m.sender], '💬 رد على: ' || left(m.title, 60),
      (select case when msg_hid(user_id) then 'موظف' else coalesce(name, who) end from msg_rcpt where msg_id = p_id and user_id = auth.uid()) || ': ' || left(trim(p_body), 120),
      './?tab=msgs&m=' || p_id, 'msgr-' || p_id);
  end if;
end $$;

create or replace function public.msg_remind(p_id bigint) returns int
language plpgsql security definer set search_path = public as $$
declare m msgs; u uuid[];
begin
  select * into m from msgs where id = p_id;
  if not found or not (m.sender = auth.uid() or coalesce(is_admin(), false)) then raise exception 'غير مسموح'; end if;
  if m.reminded_at > now() - interval '30 minutes' then raise exception 'تم التذكير قبل شوي — حاول بعد نص ساعة'; end if;
  u := array(select user_id from msg_rcpt where msg_id = p_id and (case when m.need_ack then ack_at is null else read_at is null end));
  if cardinality(u) = 0 then return 0; end if;
  update msgs set reminded_at = now() where id = p_id;
  perform push_send(u, '🔔 تذكير' || case when m.need_ack then ' — مطلوب إقرارك' else '' end, left(m.title, 120), './?tab=msgs&m=' || p_id, 'msg-' || p_id);
  return cardinality(u);
end $$;

create or replace function public.msg_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and role = 'owner' and active) then raise exception 'الحذف للمالك فقط'; end if;
  delete from msgs where id = p_id;
end $$;

create or replace function public.msg_unread() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from msg_rcpt r join msgs m on m.id = r.msg_id
   where r.user_id = auth.uid() and (r.read_at is null or (m.need_ack and r.ack_at is null))
$$;

do $$
declare f text;
begin
  foreach f in array array['msg_can_send()','msg_people()','msg_can_view(bigint)','msg_send(text,text,text,text,boolean,jsonb)','msg_attach(bigint,jsonb)',
    'msg_inbox()','msg_sent()','msg_get(bigint)','msg_ack(bigint)','msg_reply(bigint,text,uuid)','msg_remind(bigint)','msg_delete(bigint)','msg_unread()'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

update storage.buckets set allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'], file_size_limit = 8388608 where id = 'media';

create or replace function public.media_ok(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p text[] := string_to_array(coalesce(p_name, ''), '/'); k text; br text; e uuid; mid bigint;
begin
  k := p[1]; br := p[2];
  if k is null or br is null then return false; end if;
  begin e := p[3]::uuid; exception when others then e := null; end;
  if k = 'custody' then
    return coalesce(custody_can(br), false) or coalesce(p[3] = my_emp_id()::text, false) or coalesce(p[3] = auth.uid()::text, false);
  elsif k = 'maint' then
    return coalesce(maint_role() in ('admin', 'sup') or (maint_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'fleet' then
    return coalesce(is_writer(), false) or coalesce(has_section('fleet') and br = any(my_branches()), false);
  elsif k in ('ded', 'emp') then
    return coalesce(employees_can(br), false);
  elsif k = 'hr' then
    return coalesce(hr_can(), false)
        or (not p_write and br <> 'co' and coalesce(employees_can(br), false) and (e is null or coalesce(emp_ok(e), false)));
  elsif k = 'att' then
    return coalesce(p[3] = my_emp_id()::text, false)
        or (not p_write and (coalesce(hr_can(), false) or (coalesce(att_branch_ok(br), false) and (e is null or coalesce(emp_ok(e), false)))));
  elsif k = 'msg' then
    begin mid := br::bigint; exception when others then return false; end;
    if p_write then return exists (select 1 from msgs where id = mid and sender = auth.uid()); end if;
    return coalesce(msg_can_view(mid), false);
  end if;
  return false;
exception when others then return false;
end $$;

select 'تم: نظام المراسلات جاهز' as result;
