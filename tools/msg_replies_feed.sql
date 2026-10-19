create or replace function public.msg_reply_feed(p_days int default 14) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('mid', m.id, 'title', m.title, 'by', case when msg_hid(q.user_id) then 'موظف' else coalesce(q.by_name, '') end,
             'body', q.body, 'at', q.created_at) x
      from msg_replies q join msgs m on m.id = q.msg_id
     where q.user_id <> m.sender and q.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 14), 60)))
       and (m.sender = auth.uid() or coalesce(is_admin(), false))
     order by q.id desc limit 30) t
$$;
revoke all on function public.msg_reply_feed(int) from public, anon;
grant execute on function public.msg_reply_feed(int) to authenticated;
