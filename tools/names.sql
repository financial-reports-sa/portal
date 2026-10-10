-- تعديل الاسم الظاهر للمستخدمين (يشغَّل مرة واحدة في Supabase → SQL Editor)
-- المالك يعدّل أي اسم (ومنها اسمه)، الآدمن يعدّل أسماء المستخدمين، وكل شخص يعدّل اسمه.
create or replace function public.set_full_name(p_uid uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := btrim(coalesce(p_name, ''));
begin
  if v = '' or length(v) > 60 then raise exception 'الاسم غير صالح'; end if;
  if not (p_uid = auth.uid() or my_role() = 'owner' or can_manage(p_uid)) then
    raise exception 'ليس لديك صلاحية تعديل هذا الاسم';
  end if;
  update profiles set full_name = v where id = p_uid;
end $$;
revoke all on function public.set_full_name(uuid, text) from public;
grant execute on function public.set_full_name(uuid, text) to authenticated;
