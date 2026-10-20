drop function if exists public.alert_send(text, text, uuid, uuid[], text, text, text, text, boolean);
create or replace function public.alert_send(p_key text, p_kind text, p_emp uuid, p_users uuid[], p_title text, p_body text, p_url text, p_prio text default 'high', p_ack boolean default true, p_cc uuid[] default '{}')
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare u uuid[]; c uuid[]; mid bigint; snd uuid;
begin
  u := array(select distinct x from unnest(coalesce(p_users, '{}')) x where x is not null);
  if cardinality(u) = 0 then return false; end if;
  c := array(select distinct x from unnest(coalesce(p_cc, '{}')) x where x is not null and not (x = any(u)));
  insert into alert_log (key, kind, emp_id, users) values (p_key, p_kind, p_emp, u) on conflict (key) do nothing;
  if not found then return false; end if;
  select id into snd from profiles where role = 'owner' order by created_at limit 1;
  if snd is null then select id into snd from profiles where role = 'admin' order by created_at limit 1; end if;
  insert into msgs (kind, prio, title, body, need_ack, target, sender, sender_name)
  values ('warn', p_prio, p_title, p_body, p_ack, jsonb_build_object('auto', p_kind), snd, 'نظام المتابعة الآلي')
  returning id into mid;
  insert into msg_rcpt (msg_id, user_id, name, kind)
  select mid, p.id, coalesce(nullif(p.full_name, ''), p.username), case when p.role in ('owner', 'admin') then 'admin' when p.role = 'employee' then 'emp' else 'mgr' end
  from profiles p where p.id = any(u)
  on conflict do nothing;
  insert into msg_rcpt (msg_id, user_id, name, kind)
  select mid, p.id, coalesce(nullif(p.full_name, ''), p.username), 'cc'
  from profiles p where p.id = any(c) and coalesce(p.active, true)
  on conflict do nothing;
  perform push_send(u, p_title, left(split_part(p_body, chr(10) || '—' || chr(10), 1), 240), p_url, 'auto-' || p_kind);
  return true;
exception when others then
  return false;
end $$;
revoke all on function public.alert_send(text, text, uuid, uuid[], text, text, text, text, boolean, uuid[]) from public, anon, authenticated;

create or replace function public.alert_ops(p_sec text) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
declare r uuid[];
begin
  if to_regclass('public.user_ro') is not null then
    execute 'select coalesce(array_agg(distinct p.id), ''{}'') from profiles p join user_sections us on us.user_id = p.id and us.section = $1
             where coalesce(p.active, true) and p.role in (''user'', ''admin'')
               and not exists (select 1 from user_ro ro where ro.user_id = p.id and ro.section = $1)' into r using p_sec;
  else
    r := alert_sup(p_sec);
  end if;
  return r;
end $$;
revoke all on function public.alert_ops(text) from public, anon, authenticated;

create or replace function public.alert_ro(p_views text[], p_sec text, p_skip uuid[]) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
declare r uuid[];
begin
  select coalesce(array_agg(distinct p.id), '{}') into r from profiles p join user_sections us on us.user_id = p.id and us.section = any(p_views)
   where coalesce(p.active, true) and p.role in ('user', 'admin') and not (p.id = any(coalesce(p_skip, '{}')));
  if to_regclass('public.user_ro') is not null then
    execute 'select coalesce(array_agg(distinct x), ''{}'') from (select unnest($1) x union select p.id from profiles p join user_ro ro on ro.user_id = p.id and ro.section = $2
             where coalesce(p.active, true) and p.role in (''user'', ''admin'') and not (p.id = any(coalesce($3, ''{}'')))) t' into r using r, p_sec, p_skip;
  end if;
  return r;
end $$;
revoke all on function public.alert_ro(text[], text, uuid[]) from public, anon, authenticated;

create or replace function public.alert_names(p_users uuid[]) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(coalesce(nullif(full_name, ''), username), '، ' order by full_name), '') from profiles where id = any(coalesce(p_users, '{}'))
$$;
revoke all on function public.alert_names(uuid[]) from public, anon, authenticated;

create or replace function public.msg_inbox() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'body', left(m.body, 160),
             'ack', m.need_ack and coalesce(r.kind, '') <> 'cc', 'from', m.sender_name, 'at', m.created_at, 'read', r.read_at, 'acked', r.ack_at,
             'files', jsonb_array_length(m.files), 'auto', m.target->>'auto', 'target', m.target, 'mine', m.sender = auth.uid(), 'sbr', to_jsonb(msg_user_brs(m.sender)),
             'cc', coalesce(r.kind, '') = 'cc',
             'to', case when r.kind = 'cc' then (select string_agg(coalesce(z.name, ''), '، ') from msg_rcpt z where z.msg_id = m.id and coalesce(z.kind, '') <> 'cc') end) x
      from msg_rcpt r join msgs m on m.id = r.msg_id
     where r.user_id = auth.uid()
     order by m.id desc limit 300) t
$$;

create or replace function public.msg_sent() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'ack', m.need_ack,
             'from', m.sender_name, 'mine', m.sender = auth.uid(), 'at', m.created_at, 'target', m.target, 'auto', m.target->>'auto', 'sbr', to_jsonb(msg_user_brs(m.sender)),
             'to', (select string_agg(coalesce(r.name, ''), '، ' order by case when r.kind = 'emp' then 0 when r.kind = 'mgr' then 1 else 2 end) from msg_rcpt r where r.msg_id = m.id and coalesce(r.kind, '') <> 'cc'),
             'n', (select count(*) from msg_rcpt r where r.msg_id = m.id and coalesce(r.kind, '') <> 'cc'),
             'nr', (select count(*) from msg_rcpt r where r.msg_id = m.id and r.read_at is not null and coalesce(r.kind, '') <> 'cc'),
             'na', (select count(*) from msg_rcpt r where r.msg_id = m.id and r.ack_at is not null and coalesce(r.kind, '') <> 'cc'),
             'nrep', (select count(*) from msg_replies q where q.msg_id = m.id and q.user_id <> m.sender)) x
      from msgs m
     where m.sender = auth.uid() or coalesce(is_admin(), false)
     order by m.id desc limit 400) t
$$;

create or replace function public.msg_read_all() returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  update msg_rcpt r set read_at = now() from msgs m
   where m.id = r.msg_id and r.user_id = auth.uid() and r.read_at is null and (not m.need_ack or r.kind = 'cc');
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.msg_read_all() to authenticated;

create or replace function public.msg_get(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m msgs; boss boolean; res jsonb; cc boolean;
begin
  select * into m from msgs where id = p_id;
  if not found or not msg_can_view(p_id) then raise exception 'المراسلة غير موجودة'; end if;
  boss := m.sender = auth.uid() or coalesce(is_admin(), false);
  cc := exists (select 1 from msg_rcpt where msg_id = p_id and user_id = auth.uid() and kind = 'cc');
  update msg_rcpt set read_at = now() where msg_id = p_id and user_id = auth.uid() and read_at is null;
  res := jsonb_build_object('id', m.id, 'kind', m.kind, 'prio', m.prio, 'title', m.title, 'body', m.body, 'ack', m.need_ack and not cc, 'cc', cc,
    'to', case when cc then (select string_agg(coalesce(z.name, ''), '، ') from msg_rcpt z where z.msg_id = p_id and coalesce(z.kind, '') <> 'cc') end,
    'files', m.files, 'from', m.sender_name, 'at', m.created_at, 'target', m.target, 'boss', boss, 'mine', m.sender = auth.uid(),
    'reminded', m.reminded_at,
    'me', (select jsonb_build_object('read', read_at, 'acked', ack_at) from msg_rcpt where msg_id = p_id and user_id = auth.uid()),
    'replies', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'by', case when msg_hid(q.user_id) then 'موظف' else q.by_name end,
                 'uid', q.user_id, 'to', q.to_user, 'body', q.body, 'at', q.created_at, 'me', q.user_id = auth.uid()) order by q.id)
               from msg_replies q
              where q.msg_id = p_id and (boss or q.user_id = auth.uid() or q.to_user = auth.uid())), '[]'));
  if boss then
    res := res || jsonb_build_object('rcpt', coalesce((select jsonb_agg(jsonb_build_object('uid', case when msg_hid(user_id) then null else user_id end,
             'name', case when msg_hid(user_id) then 'موظف' else name end, 'kind', kind, 'read', read_at, 'acked', ack_at) order by (kind = 'cc'), ack_at nulls first, read_at nulls first, name)
           from msg_rcpt where msg_id = p_id), '[]'));
  end if;
  return res;
end $$;

create or replace function public.ops_alerts_run() returns int
language plpgsql volatile security definer set search_path = public as $$
declare u record; n int := 0; lst text; cnt int; dk text := to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD'); nl text := chr(10);
  rep text := ''; to_u uuid[]; cc_u uuid[]; nms text; mc int := 0; pc int := 0; bc int := 0;
begin
  if not coalesce((select ops from alert_cfg where id = 1), true) then return 0; end if;

  select count(*), string_agg('• #' || m.no || ' ' || m.title || ' — ' || coalesce((select name from branches where id = m.branch), m.branch) || ' — ' ||
           case m.status when 'new' then 'لم يُسند لفني' when 'assigned' then 'مُسند ولم يبدأ' when 'progress' then 'قيد التنفيذ ولم يُنجز' when 'hold' then 'متوقف' else m.status end ||
           ' منذ ' || greatest(1, floor(extract(epoch from (now() - m.created_at)) / 86400))::int || ' يوم' || case when m.due_date < current_date then ' (تجاوز الموعد ' || m.due_date || ')' else '' end, nl order by m.created_at)
    into mc, lst
  from maint_requests m
  where (m.status = 'new' and m.created_at < now() - interval '24 hours')
     or (m.status in ('assigned', 'progress', 'hold') and (m.due_date < (now() at time zone 'Asia/Riyadh')::date or coalesce(m.started_at, m.assigned_at, m.created_at) < now() - interval '3 days'));
  if mc > 0 then
    to_u := alert_ops('maint_sup'); cc_u := alert_ro(array['maint_view'], 'maint_sup', to_u); nms := alert_names(to_u);
    if cardinality(to_u) > 0 and alert_send('ops:maint:' || dk, 'maint_late', null, to_u, 'إشعار تقصير: طلبات صيانة متأخرة',
        case when cardinality(to_u) > 1 then 'السادة/ ' else 'السيد/ ' end || nms || '،' || nl || 'لوحظ وجود ' || mc || ' طلب صيانة متأخر لم يتم إتمامه حتى تاريخه:' || nl || lst || nl ||
        'يُعد التأخر في إتمام الطلبات تقصيراً في أداء المهام الموكلة إليك، وسيُرفع تقرير بذلك للإدارة. المطلوب إتمام الطلبات أو تحديث حالتها مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
        './?tab=maint', 'urgent', true, cc_u) then n := n + 1; end if;
    rep := rep || '🔧 الصيانة: ' || mc || ' طلب متأخر — وُجّه إلى: ' || coalesce(nullif(nms, ''), 'لا يوجد مسؤول صيانة محدد بصلاحية عمليات') || nl || lst || nl || nl;
  end if;

  select count(*), string_agg('• #' || r.no || ' ' || r.title || ' — ' || coalesce((select name from branches where id = r.branch), r.branch) || ' — ' ||
           case r.status when 'new' then 'لم يبدأ التنفيذ' when 'progress' then 'قيد التنفيذ ولم يُشترَ' else r.status end ||
           ' منذ ' || greatest(1, floor(extract(epoch from (now() - r.created_at)) / 86400))::int || ' يوم' || case when r.priority = 'urgent' then ' ⚠️ عاجل' else '' end ||
           case when r.need_by < (now() at time zone 'Asia/Riyadh')::date then ' (مطلوب قبل ' || r.need_by || ')' else '' end, nl order by r.created_at)
    into pc, lst
  from purch_requests r
  where (r.status = 'new' and r.created_at < now() - case when r.priority = 'urgent' then interval '4 hours' else interval '24 hours' end)
     or (r.status = 'progress' and (r.need_by < (now() at time zone 'Asia/Riyadh')::date or coalesce(r.started_at, r.created_at) < now() - interval '3 days'));
  if pc > 0 then
    to_u := alert_ops('purch_sup'); cc_u := alert_ro(array['purch_view'], 'purch_sup', to_u); nms := alert_names(to_u);
    if cardinality(to_u) > 0 and alert_send('ops:purch:' || dk, 'purch_late', null, to_u, 'إشعار تقصير: طلبات شراء متأخرة',
        case when cardinality(to_u) > 1 then 'السادة/ ' else 'السيد/ ' end || nms || '،' || nl || 'لوحظ وجود ' || pc || ' طلب شراء متأخر لم يتم إتمامه حتى تاريخه:' || nl || lst || nl ||
        'يُعد التأخر في إتمام الطلبات تقصيراً في أداء المهام الموكلة إليك، وسيُرفع تقرير بذلك للإدارة. المطلوب إتمام الطلبات أو تحديث حالتها مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
        './?tab=purch', 'urgent', true, cc_u) then n := n + 1; end if;
    rep := rep || '🛒 المشتريات: ' || pc || ' طلب متأخر — وُجّه إلى: ' || coalesce(nullif(nms, ''), 'لا يوجد مسؤول مشتريات محدد بصلاحية عمليات') || nl || lst || nl || nl;
  end if;

  for u in
    select p.id, coalesce(nullif(p.full_name, ''), p.username) nm, count(*) c,
           string_agg('• ' || k || ' #' || no || ' ' || title, nl) lst
    from (
      select 'صيانة' k, m.no, m.title, m.requested_uid uid from maint_requests m where m.status = 'done' and m.done_at < now() - interval '48 hours'
      union all
      select 'شراء', r.no, r.title, r.requested_uid from purch_requests r where r.status = 'bought' and r.bought_at < now() - interval '48 hours'
    ) x join profiles p on p.id = x.uid and coalesce(p.active, true)
    group by p.id, p.full_name, p.username
  loop
    if alert_send('ops:close:' || u.id || ':' || dk, 'ops_close', null, array[u.id], 'تذكير: طلبات بانتظار تأكيد الاستلام',
      'السيد/ ' || u.nm || '،' || nl || 'يوجد ' || u.c || ' طلب منفّذ بانتظار تأكيدك للاستلام وإغلاق الطلب:' || nl || u.lst || nl ||
      'المطلوب تأكيد الاستلام أو الاعتراض مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
      './?tab=maint', 'high', false) then n := n + 1; bc := bc + u.c; end if;
  end loop;

  if rep <> '' then
    perform alert_send('ops:report:' || dk, 'ops_report', null, alert_owners(), 'تقرير يومي: الطلبات المتأخرة',
      'تقرير المتابعة الآلية ليوم ' || dk || nl || nl || rep || 'تم إرسال إشعار تقصير رسمي للمسؤول المختص، ومن لديه صلاحية القراءة يطّلع عليه فقط.' || nl || '— نظام المتابعة الآلي',
      './?tab=maint', 'high', false);
  end if;
  return n;
end $$;
revoke all on function public.ops_alerts_run() from public, anon, authenticated;

select 'تم: تنبيهات الصيانة والمشتريات تروح لصاحب صلاحية العمليات، وصاحب القراءة يطّلع فقط' as result, public.alert_names(public.alert_ops('maint_sup')) as maint_to, public.alert_names(public.alert_ops('purch_sup')) as purch_to, public.alert_names(public.alert_ro(array['maint_view'], 'maint_sup', public.alert_ops('maint_sup'))) as maint_cc, public.alert_names(public.alert_ro(array['purch_view'], 'purch_sup', public.alert_ops('purch_sup'))) as purch_cc;
