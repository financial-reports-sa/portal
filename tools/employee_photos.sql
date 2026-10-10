-- ============================================================
--  صور الموظفين — مدير الفرع يرفق صورة لكل موظف (يشغَّل مرة واحدة في Supabase → SQL Editor → Run)
-- ============================================================
create table if not exists public.employee_photos (
  emp_id     uuid primary key references public.employees(id) on delete cascade,
  thumb      text not null,
  img        text not null,
  updated_at timestamptz not null default now(),
  updated_by text not null default ''
);

create or replace function public.employee_photos_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if length(new.img) > 600000 or length(new.thumb) > 60000 then raise exception 'الصورة كبيرة'; end if;
  select coalesce(nullif(full_name, ''), username) into new.updated_by from profiles where id = auth.uid();
  new.updated_by := coalesce(new.updated_by, ''); new.updated_at := now();
  return new;
end $$;
drop trigger if exists employee_photos_stamp on public.employee_photos;
create trigger employee_photos_stamp before insert or update on public.employee_photos
  for each row execute function public.employee_photos_stamp();

alter table public.employee_photos enable row level security;
drop policy if exists ep_all on public.employee_photos;
create policy ep_all on public.employee_photos for all to authenticated
  using (exists (select 1 from public.employees e where e.id = emp_id and employees_can(e.branch)))
  with check (exists (select 1 from public.employees e where e.id = emp_id and employees_can(e.branch)));
revoke all on public.employee_photos from anon;
grant select, insert, update, delete on public.employee_photos to authenticated;

select 'تم تفعيل صور الموظفين ✓' as result;
