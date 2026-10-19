create or replace function public.growth_day_detail(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date; bs text[]; days date[];
begin
  if not (coalesce(is_writer(), false) or exists (select 1 from user_sections us join profiles p on p.id = us.user_id
          where us.user_id = auth.uid() and us.section in ('sales', 'wh') and coalesce(p.active, true))) then
    raise exception 'غير مصرح';
  end if;
  d := coalesce(p_day, (now() at time zone 'Asia/Riyadh' - interval '8 hours')::date);
  bs := case when coalesce(is_writer(), false) then null else my_branches() end;
  days := array[d, d - 1, d - 7];
  return jsonb_build_object('day', d,
    'cats', coalesce((select jsonb_agg(jsonb_build_object('d', day, 'br', branch, 'c', cat, 'n', name, 'q', qty, 'v', net))
        from growth_cats_daily where day = any(days) and (bs is null or branch = any(bs))), '[]'::jsonb),
    'ch', coalesce((select jsonb_agg(jsonb_build_object('d', day, 'br', branch, 'c', channel, 'n', name, 'v', net, 'b', bills))
        from growth_channels_daily where day = any(days) and (bs is null or branch = any(bs))), '[]'::jsonb));
end $$;
revoke all on function public.growth_day_detail(date) from public, anon;
grant execute on function public.growth_day_detail(date) to authenticated;
