do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback','custody','hr']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner' and active)
$$;
grant execute on function public.is_owner() to authenticated;

create or replace function public.hr_can() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_admin(), false) or exists (select 1 from user_sections us join profiles p on p.id = us.user_id
                                                where us.user_id = auth.uid() and us.section = 'hr' and p.active)
$$;
grant execute on function public.hr_can() to authenticated;

create table if not exists public.hr_docs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('cr','muni','tm','civil','chamber','other')),
  entity text not null default '',
  branch text,
  title text not null default '',
  number text not null default '',
  issue_date date,
  expiry date,
  notes text not null default '',
  photo text,
  created_at timestamptz not null default now(),
  created_by text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text not null default ''
);

create table if not exists public.hr_emp_docs (
  id uuid primary key default gen_random_uuid(),
  emp_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('iqama','work_card','passport')),
  number text not null default '',
  expiry date,
  notes text not null default '',
  photo text,
  created_at timestamptz not null default now(),
  created_by text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text not null default '',
  unique (emp_id, kind)
);

create table if not exists public.hr_requests (
  id uuid primary key default gen_random_uuid(),
  no bigserial,
  kind text not null check (kind in ('iqama_renew','work_card_renew','passport_renew','exit_reentry','final_exit','transfer','other')),
  emp_id uuid references public.employees(id) on delete set null,
  emp_name text not null default '',
  branch text not null default '',
  note text not null default '',
  status text not null default 'new' check (status in ('new','progress','done','rejected')),
  requested_by uuid default auth.uid(),
  requested_name text not null default '',
  created_at timestamptz not null default now(),
  handled_name text not null default '',
  handled_at timestamptz,
  result_note text not null default '',
  new_expiry date
);
alter table public.hr_requests add column if not exists amount numeric(12,2) check (amount is null or amount >= 0);

create table if not exists public.hr_push_log (day date primary key, at timestamptz not null default now());

create or replace function public.hr_who() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid()), '')
$$;

create or replace function public.hr_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.number := left(btrim(coalesce(new.number, '')), 40);
  new.notes := left(coalesce(new.notes, ''), 600);
  if tg_table_name = 'hr_docs' then
    new.title := left(btrim(coalesce(new.title, '')), 120);
    new.entity := left(btrim(coalesce(new.entity, '')), 40);
  end if;
  if tg_op = 'INSERT' then new.created_at := now(); new.created_by := hr_who();
  else new.created_at := old.created_at; new.created_by := old.created_by; end if;
  new.updated_at := now(); new.updated_by := hr_who();
  return new;
end $$;
drop trigger if exists hr_docs_stamp on public.hr_docs;
create trigger hr_docs_stamp before insert or update on public.hr_docs for each row execute function public.hr_stamp();
drop trigger if exists hr_emp_docs_stamp on public.hr_emp_docs;
create trigger hr_emp_docs_stamp before insert or update on public.hr_emp_docs for each row execute function public.hr_stamp();

alter table public.hr_docs enable row level security;
alter table public.hr_emp_docs enable row level security;
alter table public.hr_requests enable row level security;
alter table public.hr_push_log enable row level security;

drop policy if exists hrd_sel on public.hr_docs;
drop policy if exists hrd_ins on public.hr_docs;
drop policy if exists hrd_upd on public.hr_docs;
drop policy if exists hrd_del on public.hr_docs;
create policy hrd_sel on public.hr_docs for select to authenticated using (hr_can());
create policy hrd_ins on public.hr_docs for insert to authenticated with check (hr_can());
create policy hrd_upd on public.hr_docs for update to authenticated using (hr_can()) with check (hr_can());
create policy hrd_del on public.hr_docs for delete to authenticated using (is_owner());

drop policy if exists hre_sel on public.hr_emp_docs;
drop policy if exists hre_ins on public.hr_emp_docs;
drop policy if exists hre_upd on public.hr_emp_docs;
drop policy if exists hre_del on public.hr_emp_docs;
create policy hre_sel on public.hr_emp_docs for select to authenticated using (
  hr_can() or exists (select 1 from employees e where e.id = emp_id and employees_can(e.branch)));
create policy hre_ins on public.hr_emp_docs for insert to authenticated with check (hr_can());
create policy hre_upd on public.hr_emp_docs for update to authenticated using (hr_can()) with check (hr_can());
create policy hre_del on public.hr_emp_docs for delete to authenticated using (is_owner());

drop policy if exists hrr_sel on public.hr_requests;
drop policy if exists hrr_del on public.hr_requests;
create policy hrr_sel on public.hr_requests for select to authenticated using (hr_can() or employees_can(branch) or requested_by = auth.uid());
create policy hrr_del on public.hr_requests for delete to authenticated using (is_owner());

drop policy if exists emp_select on public.employees;
create policy emp_select on public.employees for select to authenticated using (employees_can(branch) or hr_can());

revoke all on public.hr_docs, public.hr_emp_docs, public.hr_requests, public.hr_push_log from anon;
grant select, insert, update, delete on public.hr_docs, public.hr_emp_docs to authenticated;
grant select, delete on public.hr_requests to authenticated;
revoke all on public.hr_push_log from authenticated;

create or replace function public.hr_staff() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p.id), '{}') from profiles p
  where p.active and (p.role in ('owner','admin') or exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'hr'))
$$;

create or replace function public.hr_kind_name(k text) returns text
language sql immutable as $$
  select case k when 'iqama_renew' then 'تجديد إقامة' when 'work_card_renew' then 'تجديد كرت عمل' when 'passport_renew' then 'تجديد جواز'
    when 'exit_reentry' then 'خروج وعودة' when 'final_exit' then 'خروج نهائي' when 'transfer' then 'نقل كفالة' else 'طلب' end
$$;

create or replace function public.hr_request_add(p_emp uuid, p_kind text, p_note text default '', p_amount numeric default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare e record; v_id uuid; v_who text := hr_who(); u uuid[];
begin
  select id, name, branch into e from employees where id = p_emp;
  if e.id is null then raise exception 'الموظف غير موجود'; end if;
  if not (hr_can() or employees_can(e.branch)) then raise exception 'ما عندك صلاحية على هذا الموظف'; end if;
  if exists (select 1 from hr_requests where emp_id = p_emp and kind = p_kind and status in ('new','progress')) then
    raise exception 'فيه طلب مفتوح من نفس النوع لهذا الموظف';
  end if;
  insert into hr_requests (kind, emp_id, emp_name, branch, note, requested_name, amount)
  values (p_kind, e.id, e.name, e.branch, left(coalesce(p_note, ''), 500), v_who, nullif(p_amount, 0)) returning id into v_id;
  begin
    if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is not null then
      u := array(select x from unnest(hr_staff()) x where x is distinct from auth.uid());
      perform push_send(u, '🗂️ طلب جديد: ' || hr_kind_name(p_kind),
        e.name || coalesce(' — ' || to_char(nullif(p_amount, 0), 'FM999,999,990.99') || ' ر.س', '') || coalesce(' — ' || nullif(v_who, ''), ''),
        './?tab=hr&hrt=req', 'hrreq-' || v_id);
    end if;
  exception when others then null;
  end;
  return v_id;
end $$;
grant execute on function public.hr_request_add(uuid, text, text, numeric) to authenticated;
drop function if exists public.hr_request_add(uuid, text, text);


create or replace function public.hr_request_set(p_id uuid, p_status text, p_note text default '', p_new_expiry date default null) returns void
language plpgsql security definer set search_path = public as $$
declare r record; k text;
begin
  if not hr_can() then raise exception 'ما عندك صلاحية'; end if;
  if p_status not in ('new','progress','done','rejected') then raise exception 'حالة غير صحيحة'; end if;
  select * into r from hr_requests where id = p_id;
  if r.id is null then raise exception 'الطلب غير موجود'; end if;
  update hr_requests set status = p_status, result_note = left(coalesce(p_note, ''), 500), new_expiry = p_new_expiry,
    handled_name = hr_who(), handled_at = now() where id = p_id;
  k := case r.kind when 'iqama_renew' then 'iqama' when 'work_card_renew' then 'work_card' when 'passport_renew' then 'passport' end;
  if p_status = 'done' and p_new_expiry is not null and k is not null and r.emp_id is not null then
    insert into hr_emp_docs (emp_id, kind, expiry) values (r.emp_id, k, p_new_expiry)
    on conflict (emp_id, kind) do update set expiry = excluded.expiry;
  end if;
  begin
    if p_status in ('done','rejected') and r.requested_by is not null and r.requested_by is distinct from auth.uid()
       and to_regprocedure('public.push_send(uuid[],text,text,text,text)') is not null then
      perform push_send(array[r.requested_by], case when p_status = 'done' then '✅ تم: ' else '❌ مرفوض: ' end || hr_kind_name(r.kind),
        r.emp_name || coalesce(' — ' || nullif(p_note, ''), ''), './?tab=hr&hrt=req', 'hrreq-' || r.id);
    end if;
  exception when others then null;
  end;
end $$;
grant execute on function public.hr_request_set(uuid, text, text, date) to authenticated;

create or replace function public.hr_expiry_counts() returns table (expired int, soon int, first_name text)
language sql stable security definer set search_path = public as $$
  with a as (
    select d.expiry, coalesce(nullif(d.title, ''), d.kind) as nm, 60 as win from hr_docs d where d.expiry is not null
    union all
    select x.expiry, e.name, 30 from hr_emp_docs x join employees e on e.id = x.emp_id
    where x.expiry is not null and coalesce(e.status, 'active') <> 'left'
  )
  select count(*) filter (where expiry < current_date)::int,
         count(*) filter (where expiry >= current_date and expiry <= current_date + win)::int,
         (select nm from a where expiry <= current_date + win order by expiry limit 1)
  from a
$$;

create or replace function public.hr_expiry_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare c record; v_day date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if new.app <> 'daily' or new.coll <> 'pages' then return new; end if;
  if exists (select 1 from hr_push_log where day = v_day) then return new; end if;
  if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is null then return new; end if;
  select * into c from hr_expiry_counts();
  if coalesce(c.expired, 0) + coalesce(c.soon, 0) = 0 then return new; end if;
  insert into hr_push_log (day) values (v_day) on conflict do nothing;
  perform push_send(hr_staff(), '🗂️ وثائق تحتاج تجديد',
    case when c.expired > 0 then c.expired || ' منتهية' else '' end
    || case when c.expired > 0 and c.soon > 0 then ' · ' else '' end
    || case when c.soon > 0 then c.soon || ' تنتهي قريباً' else '' end
    || coalesce(' — أقربها: ' || c.first_name, ''), './?tab=hr', 'hr-exp-' || v_day);
  return new;
exception when others then return new;
end $$;
drop trigger if exists hr_expiry_push_trg on public.app_docs;
create trigger hr_expiry_push_trg after insert or update of data on public.app_docs
  for each row execute function public.hr_expiry_push();

create or replace function public.media_ok(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p text[] := string_to_array(coalesce(p_name, ''), '/'); k text; br text;
begin
  k := p[1]; br := p[2];
  if k is null or br is null then return false; end if;
  if k = 'custody' then
    return coalesce(custody_can(br), false) or coalesce(p[3] = my_emp_id()::text, false);
  elsif k = 'maint' then
    return coalesce(maint_role() in ('admin', 'sup') or (maint_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'fleet' then
    return coalesce(is_writer(), false) or coalesce(has_section('fleet') and br = any(my_branches()), false);
  elsif k in ('ded', 'emp') then
    return coalesce(employees_can(br), false);
  elsif k = 'hr' then
    return coalesce(hr_can(), false) or (not p_write and br <> 'co' and coalesce(employees_can(br), false));
  end if;
  return false;
exception when others then return false;
end $$;
grant execute on function public.media_ok(text, boolean) to authenticated;

select 'تم تفعيل قسم الموارد البشرية ✓' as result;
