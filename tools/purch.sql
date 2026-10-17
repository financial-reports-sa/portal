do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback','custody','hr','custody_holder','att','msgs_send','mkt','rets','purch','purch_sup']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create table if not exists public.purch_requests (
  id            uuid primary key default gen_random_uuid(),
  no            bigserial unique,
  branch        text not null,
  kind          text not null check (kind in ('equip','items')),
  title         text not null,
  items         jsonb not null default '[]',
  details       text,
  priority      text not null default 'normal' check (priority in ('urgent','normal')),
  need_by       date,
  status        text not null default 'new' check (status in ('new','progress','bought','closed','rejected','cancelled')),
  photo         text,
  inv_photo     text,
  requested_by  text,
  requested_uid uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  started_at    timestamptz,
  bought_at     timestamptz,
  closed_at     timestamptz,
  closed_by     text,
  handled_by    text,
  supplier      text,
  cost          numeric(12,2),
  sup_note      text,
  reject_reason text,
  updated_at    timestamptz not null default now(),
  log           jsonb not null default '[]'
);
create index if not exists purch_requests_branch_idx on public.purch_requests (branch, status);
alter table public.purch_requests enable row level security;
revoke all on public.purch_requests from anon, authenticated;

create or replace function public.pr_role() returns text
language sql stable security definer set search_path = public as $$
  select case when coalesce(is_admin(), false) then 'admin'
              when has_section('purch_sup') then 'sup'
              when has_section('purch') then 'mgr'
              else null end
$$;

create or replace function public.pr_who() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid()
$$;

create or replace function public.pr_sups() returns uuid[]
language sql stable security definer set search_path = public as $$
  select array(select distinct x from unnest(push_admins() || coalesce((select array_agg(distinct p.id) from profiles p
    where p.active and exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'purch_sup')), '{}')) x)
$$;

create or replace function public.pr_create(p_branch text, p_kind text, p_title text, p_items jsonb default '[]', p_details text default null,
  p_priority text default 'normal', p_need date default null, p_photo text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare r text := pr_role(); w text := pr_who(); nid uuid; nno bigint; it jsonb;
begin
  if r is null then raise exception 'ليس لديك صلاحية على طلبات الشراء'; end if;
  if r = 'mgr' and not (p_branch = any(my_branches())) then raise exception 'تقدر ترفع طلبات فرعك فقط'; end if;
  if p_kind not in ('equip','items') then raise exception 'اختر نوع الطلب'; end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'اكتب عنوان الطلب'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('n', left(btrim(x->>'n'), 80), 'q', round(greatest((x->>'q')::numeric, 0), 2), 'u', left(coalesce(x->>'u', ''), 20))), '[]')
    into it from (select x from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]' end) x limit 40) s
    where coalesce(btrim(x->>'n'), '') <> '' and coalesce((x->>'q')::numeric, 0) > 0;
  if p_kind = 'items' and jsonb_array_length(it) = 0 then raise exception 'أضف صنف واحد على الأقل'; end if;
  insert into purch_requests (branch, kind, title, items, details, priority, need_by, photo, requested_by, log)
  values (p_branch, p_kind, left(trim(p_title), 120), it, nullif(left(trim(coalesce(p_details, '')), 800), ''),
          case when p_priority = 'urgent' then 'urgent' else 'normal' end, p_need, p_photo, w,
          jsonb_build_array(jsonb_build_object('t', now(), 'by', w, 'a', 'new')))
  returning id, no into nid, nno;
  begin
    perform push_send(pr_sups(), case when p_priority = 'urgent' then '🚨 طلب شراء عاجل · ' else '🛒 طلب شراء جديد · ' end || coalesce((select name from branches where id = p_branch), p_branch),
      case when p_kind = 'equip' then 'معدات: ' else 'أصناف: ' end || left(trim(p_title), 80) || ' — ' || coalesce(w, ''), './?tab=purch', 'pr-' || nid);
  exception when others then null; end;
  return nid;
end $$;

create or replace function public.pr_update(p_id uuid, p_status text, p_note text default null, p_cost numeric default null,
  p_supplier text default null, p_inv_photo text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r text := pr_role(); w text := pr_who(); m purch_requests; ok boolean := false; n text := nullif(trim(coalesce(p_note, '')), ''); ttl text; bdy text;
begin
  select * into m from purch_requests where id = p_id for update;
  if m.id is null then raise exception 'الطلب غير موجود'; end if;
  if r is null then raise exception 'ليس لديك صلاحية'; end if;
  if r = 'mgr' and not (m.branch = any(my_branches())) then raise exception 'ليس لديك صلاحية على هذا الطلب'; end if;
  if r in ('admin','sup') then
    ok := (m.status = 'new' and p_status in ('progress','rejected')) or (m.status = 'progress' and p_status in ('bought','rejected'));
  end if;
  if not ok and r in ('mgr','admin') then
    ok := (m.status = 'new' and p_status = 'cancelled') or (m.status = 'bought' and p_status in ('closed','progress'));
  end if;
  if not ok then raise exception 'هذا الإجراء غير متاح في مرحلة الطلب الحالية'; end if;
  if p_status = 'rejected' and n is null then raise exception 'اكتب سبب الرفض'; end if;
  if p_status = 'progress' and m.status = 'bought' and n is null then raise exception 'اكتب وش الناقص أو غير المطابق'; end if;
  update purch_requests set
    status        = p_status,
    started_at    = case when p_status = 'progress' and started_at is null then now() else started_at end,
    bought_at     = case when p_status = 'bought' then now() when p_status = 'progress' then null else bought_at end,
    closed_at     = case when p_status = 'closed' then now() else closed_at end,
    closed_by     = case when p_status = 'closed' then w else closed_by end,
    handled_by    = case when r in ('admin','sup') and p_status in ('progress','bought','rejected') then w else handled_by end,
    supplier      = case when p_status = 'bought' then nullif(left(trim(coalesce(p_supplier, '')), 80), '') else supplier end,
    cost          = case when p_status = 'bought' then p_cost else cost end,
    sup_note      = case when p_status = 'bought' then n else sup_note end,
    inv_photo     = case when p_status = 'bought' then coalesce(p_inv_photo, inv_photo) else inv_photo end,
    reject_reason = case when p_status = 'rejected' or (p_status = 'progress' and m.status = 'bought') then n else reject_reason end,
    updated_at    = now(),
    log           = log || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('t', now(), 'by', w, 'a', p_status, 'n', n)))
  where id = p_id;
  ttl := case p_status when 'progress' then case when m.status = 'bought' then '↩️ رجع طلب الشراء للمشتريات' else '🛒 طلب الشراء قيد التنفيذ' end
                       when 'bought' then '📦 تم شراء طلبك — أكّد الاستلام' when 'rejected' then '❌ تم رفض طلب الشراء'
                       when 'closed' then '✅ الفرع أكّد استلام المشتريات' else null end;
  if ttl is not null then
    bdy := 'PR-' || lpad(m.no::text, 5, '0') || ' · ' || m.title || case when n is not null then ' — ' || n else '' end;
    begin
      if p_status in ('closed') or (p_status = 'progress' and m.status = 'bought') then
        perform push_send(pr_sups(), ttl, bdy, './?tab=purch', 'prs-' || p_id);
      elsif m.requested_uid is not null then
        perform push_send(array[m.requested_uid], ttl, bdy, './?tab=purch', 'prr-' || p_id);
      end if;
    exception when others then null; end;
  end if;
end $$;

create or replace function public.pr_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'no', x.no, 'branch', x.branch, 'kind', x.kind, 'title', x.title, 'items', x.items, 'details', x.details,
    'priority', x.priority, 'need_by', x.need_by, 'status', x.status, 'requested_by', x.requested_by, 'created_at', x.created_at, 'started_at', x.started_at,
    'bought_at', x.bought_at, 'closed_at', x.closed_at, 'closed_by', x.closed_by, 'handled_by', x.handled_by, 'supplier', x.supplier, 'cost', x.cost,
    'sup_note', x.sup_note, 'reject_reason', x.reject_reason, 'has_photo', (x.photo is not null or x.inv_photo is not null), 'log', x.log) order by x.created_at desc), '[]')
  from (select * from purch_requests p
        where pr_role() in ('admin','sup') or (pr_role() = 'mgr' and p.branch = any(my_branches()))
        order by created_at desc limit 500) x
$$;

create or replace function public.pr_photos(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m purch_requests; r text := pr_role();
begin
  select * into m from purch_requests where id = p_id;
  if m.id is null or r is null or (r = 'mgr' and not (m.branch = any(my_branches()))) then return '{}'; end if;
  return jsonb_build_object('photo', m.photo, 'inv_photo', m.inv_photo);
end $$;

create or replace function public.pr_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and role = 'owner' and active) then raise exception 'الحذف للمالك فقط'; end if;
  delete from purch_requests where id = p_id;
end $$;

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
  elsif k = 'purch' then
    return coalesce(pr_role() in ('admin', 'sup') or (pr_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'msg' then
    begin mid := br::bigint; exception when others then return false; end;
    if p_write then return exists (select 1 from msgs where id = mid and sender = auth.uid()); end if;
    return coalesce(msg_can_view(mid), false);
  end if;
  return false;
exception when others then return false;
end $$;

revoke all on function public.pr_role() from public, anon;
revoke all on function public.pr_sups() from public, anon, authenticated;
revoke all on function public.pr_create(text, text, text, jsonb, text, text, date, text) from public, anon;
revoke all on function public.pr_update(uuid, text, text, numeric, text, text) from public, anon;
revoke all on function public.pr_list() from public, anon;
revoke all on function public.pr_photos(uuid) from public, anon;
revoke all on function public.pr_delete(uuid) from public, anon;
grant execute on function public.pr_role() to authenticated;
grant execute on function public.pr_create(text, text, text, jsonb, text, text, date, text) to authenticated;
grant execute on function public.pr_update(uuid, text, text, numeric, text, text) to authenticated;
grant execute on function public.pr_list() to authenticated;
grant execute on function public.pr_photos(uuid) to authenticated;
grant execute on function public.pr_delete(uuid) to authenticated;

select 'تم: طلبات الشراء جاهزة' as result;
