do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['rets_view', 'purch_view', 'maint_view']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')
           || coalesce((select ('{' || (regexp_match(pg_get_constraintdef(c.oid), '\{([^}]*)\}'))[1] || '}')::text[]
                       from pg_constraint c where c.conname = 'user_sections_section_check'), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create or replace function public.obs_can(p_sec text, p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_sections us join profiles p on p.id = us.user_id
                 where us.user_id = auth.uid() and us.section = p_sec and p.active)
     and p_branch = any(my_branches())
$$;
revoke all on function public.obs_can(text, text) from public, anon;
grant execute on function public.obs_can(text, text) to authenticated;

create or replace function public.ret_view_can(p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(handover_can(p_branch), false)
      or (exists (select 1 from user_sections us join profiles p on p.id = us.user_id where us.user_id = auth.uid() and us.section = 'rets' and p.active)
          and p_branch = any(my_branches()))
      or obs_can('rets_view', p_branch)
$$;

create or replace function public.pr_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'no', x.no, 'branch', x.branch, 'kind', x.kind, 'title', x.title, 'items', x.items, 'details', x.details,
    'priority', x.priority, 'need_by', x.need_by, 'status', x.status, 'requested_by', x.requested_by, 'created_at', x.created_at, 'started_at', x.started_at,
    'bought_at', x.bought_at, 'closed_at', x.closed_at, 'closed_by', x.closed_by, 'handled_by', x.handled_by, 'supplier', x.supplier, 'cost', x.cost,
    'sup_note', x.sup_note, 'reject_reason', x.reject_reason, 'has_photo', (x.photo is not null or x.inv_photo is not null), 'log', x.log,
    'can_edit', (x.requested_uid = auth.uid() and x.status = 'new' and x.created_at > now() - interval '12 hours'),
    'edit_until', x.created_at + interval '12 hours') order by x.created_at desc), '[]')
  from (select * from purch_requests p
        where pr_role() in ('admin','sup') or (pr_role() = 'mgr' and p.branch = any(my_branches()))
           or (pr_role() is null and obs_can('purch_view', p.branch))
        order by created_at desc limit 500) x
$$;

create or replace function public.pr_photos(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m purch_requests; r text := pr_role();
begin
  select * into m from purch_requests where id = p_id;
  if m.id is null then return '{}'; end if;
  if (r is null and not obs_can('purch_view', m.branch)) or (r = 'mgr' and not (m.branch = any(my_branches()))) then return '{}'; end if;
  return jsonb_build_object('photo', m.photo, 'inv_photo', m.inv_photo);
end $$;

drop policy if exists maint_read on public.maint_requests;
create policy maint_read on public.maint_requests for select to authenticated
  using (maint_role() in ('admin','sup') or (maint_role() = 'mgr' and branch = any(my_branches())) or (maint_role() is null and obs_can('maint_view', branch)));

create or replace function public.maint_photos(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m maint_requests; r text := maint_role();
begin
  select * into m from maint_requests where id = p_id;
  if m.id is null then return '{}'::jsonb; end if;
  if (r is null and not obs_can('maint_view', m.branch)) or (r = 'mgr' and not (m.branch = any(my_branches()))) then return '{}'::jsonb; end if;
  return jsonb_build_object('photo', m.photo, 'done_photo', m.done_photo);
end $$;

revoke all on function public.ret_view_can(text) from public, anon;
grant execute on function public.ret_view_can(text) to authenticated;
revoke all on function public.pr_list() from public, anon;
grant execute on function public.pr_list() to authenticated;
revoke all on function public.pr_photos(uuid) from public, anon;
grant execute on function public.pr_photos(uuid) to authenticated;
revoke all on function public.maint_photos(uuid) from public, anon;
grant execute on function public.maint_photos(uuid) to authenticated;

select 'تم: صلاحيات المراقب (قراءة فقط) للمرتجعات وطلبات الشراء والصيانة' as result;
