create table if not exists public.leaves (
  id         uuid primary key default gen_random_uuid(),
  emp_id     uuid not null references public.employees(id) on delete cascade,
  branch     text not null default '',
  emp_name   text not null default '',
  kind       text not null check (kind in ('annual','sick','emergency','unpaid','other')),
  d_from     date not null,
  d_to       date not null,
  days       int not null default 1,
  reason     text not null default '',
  status     text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  created_at timestamptz not null default now(),
  dec_by     text not null default '',
  dec_at     timestamptz,
  dec_note   text not null default ''
);
create index if not exists leaves_emp_idx on public.leaves (emp_id, d_from);
alter table public.leaves enable row level security;
revoke all on public.leaves from anon, authenticated;

create or replace function public.lv_kind_ar(k text) returns text language sql immutable as $$
  select case k when 'annual' then 'إجازة سنوية' when 'sick' then 'إجازة مرضية' when 'emergency' then 'إجازة اضطرارية' when 'unpaid' then 'إجازة بدون راتب' else 'إجازة' end
$$;

create or replace function public.lv_request(p_kind text, p_from date, p_to date, p_reason text default '') returns uuid
language plpgsql security definer set search_path = public as $$
declare e record; me uuid := my_emp_id(); nid uuid; n int; td date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if me is null then raise exception 'حسابك غير مرتبط بموظف'; end if;
  select * into e from employees where id = me;
  if e.status = 'left' then raise exception 'الموظف منتهية خدماته'; end if;
  if p_kind is null or p_kind not in ('annual','sick','emergency','unpaid','other') then raise exception 'اختر نوع الإجازة'; end if;
  if p_from is null or p_to is null then raise exception 'حدد تاريخ البداية والنهاية'; end if;
  if p_to < p_from then raise exception 'تاريخ النهاية قبل البداية'; end if;
  if p_from < td - 7 then raise exception 'ما تقدر تطلب إجازة لتاريخ قديم'; end if;
  if p_from > td + 180 then raise exception 'التاريخ بعيد جداً'; end if;
  n := p_to - p_from + 1;
  if n > 60 then raise exception 'الإجازة ما تزيد عن ٦٠ يوم في الطلب الواحد'; end if;
  if exists (select 1 from leaves where emp_id = me and status in ('pending','approved') and d_from <= p_to and d_to >= p_from) then
    raise exception 'عندك طلب إجازة في نفس الفترة';
  end if;
  if (select count(*) from leaves where emp_id = me and status = 'pending') >= 2 then raise exception 'عندك طلبات إجازة تحت الإجراء'; end if;
  insert into leaves (emp_id, branch, emp_name, kind, d_from, d_to, days, reason)
  values (me, e.branch, e.name, p_kind, p_from, p_to, n, left(coalesce(p_reason, ''), 300)) returning id into nid;
  begin
    perform push_send(array(select distinct x from unnest(push_admins() || push_mgrs('att', e.branch)) x), '🌴 طلب إجازة · ' || e.name,
      lv_kind_ar(p_kind) || ' · ' || n || ' يوم · من ' || to_char(p_from, 'DD/MM') || ' إلى ' || to_char(p_to, 'DD/MM'), './?tab=att&lv=1', 'lv-' || nid);
  exception when others then null; end;
  return nid;
end $$;

create or replace function public.lv_mine() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'from', d_from, 'to', d_to, 'days', days, 'reason', reason, 'status', status,
    'at', created_at, 'by', dec_by, 'dec_at', dec_at, 'note', dec_note) order by d_from desc), '[]')
  from (select * from leaves where emp_id = my_emp_id() order by d_from desc limit 30) l
$$;

create or replace function public.lv_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update leaves set status = 'cancelled' where id = p_id and emp_id = my_emp_id() and status = 'pending';
  if not found then raise exception 'ما تقدر تلغي هذا الطلب'; end if;
end $$;

create or replace function public.lv_list(p_from date default null, p_to date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'emp', l.emp_id, 'name', l.emp_name, 'branch', l.branch, 'kind', l.kind, 'from', l.d_from, 'to', l.d_to,
    'days', l.days, 'reason', l.reason, 'status', l.status, 'at', l.created_at, 'by', l.dec_by, 'dec_at', l.dec_at, 'note', l.dec_note) order by (l.status = 'pending') desc, l.d_from desc), '[]')
  from leaves l
  where att_ok(l.emp_id) and l.status <> 'cancelled'
    and (l.status = 'pending' or (l.d_to >= coalesce(p_from, current_date - 60) and l.d_from <= coalesce(p_to, current_date + 180)))
$$;

create or replace function public.lv_decide(p_id uuid, p_ok boolean, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare l leaves; u uuid; who text := att_who();
begin
  select * into l from leaves where id = p_id for update;
  if l.id is null then raise exception 'الطلب غير موجود'; end if;
  if not att_ok(l.emp_id) then raise exception 'ليس لديك صلاحية على هذا الموظف'; end if;
  if l.status <> 'pending' and not coalesce(is_admin(), false) then raise exception 'الطلب ما عاد تحت الإجراء'; end if;
  update leaves set status = case when p_ok then 'approved' else 'rejected' end, dec_by = who, dec_at = now(), dec_note = left(coalesce(p_note, ''), 300) where id = p_id;
  select user_id into u from emp_accounts where emp_id = l.emp_id;
  if u is not null then
    begin
      perform push_send(array[u], case when p_ok then '✅ تمت الموافقة على إجازتك' else '❌ تم رفض طلب إجازتك' end,
        lv_kind_ar(l.kind) || ' · من ' || to_char(l.d_from, 'DD/MM') || ' إلى ' || to_char(l.d_to, 'DD/MM') || case when coalesce(p_note, '') <> '' then ' — ' || p_note else '' end, './?tab=me', 'lvd-' || p_id);
    exception when others then null; end;
  end if;
end $$;

revoke all on function public.lv_request(text, date, date, text) from public, anon;
revoke all on function public.lv_mine() from public, anon;
revoke all on function public.lv_cancel(uuid) from public, anon;
revoke all on function public.lv_list(date, date) from public, anon;
revoke all on function public.lv_decide(uuid, boolean, text) from public, anon;
grant execute on function public.lv_request(text, date, date, text) to authenticated;
grant execute on function public.lv_mine() to authenticated;
grant execute on function public.lv_cancel(uuid) to authenticated;
grant execute on function public.lv_list(date, date) to authenticated;
grant execute on function public.lv_decide(uuid, boolean, text) to authenticated;

select 'تم: طلبات الإجازة جاهزة' as result;
