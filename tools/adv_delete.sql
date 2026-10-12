create or replace function public.adv_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'الحذف للمالك والآدمن فقط'; end if;
  delete from public.advances where id = p_id;
  if not found then raise exception 'الطلب غير موجود'; end if;
end $$;
revoke all on function public.adv_delete(uuid) from public, anon;
grant execute on function public.adv_delete(uuid) to authenticated;
select 'تم ✓' as result;
