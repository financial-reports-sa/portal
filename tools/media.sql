insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

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
  end if;
  return false;
exception when others then return false;
end $$;
grant execute on function public.media_ok(text, boolean) to authenticated;

drop policy if exists media_read on storage.objects;
drop policy if exists media_write on storage.objects;
create policy media_read on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.media_ok(name, false));
create policy media_write on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.media_ok(name, true));

select 'تم تفعيل مساحة الصور ✓' as result;
