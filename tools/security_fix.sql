do $$
declare r record; np text;
begin
  for r in select pin from public.cashier_codes loop
    loop
      np := lpad((floor(random() * 1000000))::int::text, 6, '0');
      exit when np !~ '^(\d)\1+$' and not exists (select 1 from public.cashier_codes where pin = np);
    end loop;
    update public.cashier_codes set pin = np where pin = r.pin;
  end loop;
end $$;

create or replace function public.handover_fail_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from handover_fails where at > now() - interval '15 minutes') >= 40 then
    raise exception 'محاولات كثيرة — انتظر ربع ساعة وحاول مرة ثانية';
  end if;
  return new;
end $$;
drop trigger if exists handover_fail_guard on public.handover_fails;
create trigger handover_fail_guard before insert on public.handover_fails for each row execute function public.handover_fail_guard();

create table if not exists public.ai_usage (
  user_id uuid not null,
  day date not null default ((now() at time zone 'Asia/Riyadh')::date),
  n int not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from anon, authenticated;

create or replace function public.ai_allowed() returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare d date := (now() at time zone 'Asia/Riyadh')::date; c int;
begin
  if auth.uid() is null then return false; end if;
  if not exists (select 1 from profiles where id = auth.uid() and active) then return false; end if;
  insert into ai_usage (user_id, day, n) values (auth.uid(), d, 1)
  on conflict (user_id, day) do update set n = ai_usage.n + 1
  returning n into c;
  return c <= 150;
end $$;
revoke all on function public.ai_allowed() from public, anon;
grant execute on function public.ai_allowed() to authenticated;

create or replace function public.media_ok(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p text[] := string_to_array(coalesce(p_name, ''), '/'); k text; br text; e uuid;
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
        or (not p_write and (coalesce(hr_can(), false) or (coalesce(att_branch_ok(br), false) and (e is null or coalesce(att_ok(e), false)))));
  end if;
  return false;
exception when others then return false;
end $$;

select 'تم: الرموز الجديدة جاهزة — شوفها من «تسليم الورديات» ← «رابط ورموز الكاشيرات»' as result;
