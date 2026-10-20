create or replace function public.msg_user_brs(p_uid uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array[e.branch] from emp_accounts a join employees e on e.id = a.emp_id where a.user_id = p_uid and coalesce(e.branch, '') <> '' limit 1),
    (select array_agg(ub.branch_id order by ub.branch_id) from user_branches ub join profiles p on p.id = ub.user_id where ub.user_id = p_uid and p.role = 'user'),
    '{}'::text[])
$$;
revoke all on function public.msg_user_brs(uuid) from public, anon, authenticated;

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

create or replace function public.msg_reply_feed(p_days int default 14) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('mid', m.id, 'title', m.title, 'by', case when msg_hid(q.user_id) then 'موظف' else coalesce(q.by_name, '') end,
             'body', q.body, 'at', q.created_at, 'br', to_jsonb(msg_user_brs(q.user_id))) x
      from msg_replies q join msgs m on m.id = q.msg_id
     where q.user_id <> m.sender and q.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 14), 60)))
       and (m.sender = auth.uid() or coalesce(is_admin(), false))
     order by q.id desc limit 60) t
$$;
revoke all on function public.msg_reply_feed(int) from public, anon;
grant execute on function public.msg_reply_feed(int) to authenticated;
