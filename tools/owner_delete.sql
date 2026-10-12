create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner' and active)
$$;
grant execute on function public.is_owner() to authenticated;

create or replace function public.maint_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'الحذف للمالك فقط'; end if;
  delete from maint_requests where id = p_id;
end $$;

do $$ begin
  if to_regclass('public.feedback') is not null then
    execute $f$create or replace function public.feedback_delete(p_id uuid) returns void
      language plpgsql security definer set search_path = public as $b$
      begin
        if not is_owner() then raise exception 'الحذف للمالك فقط'; end if;
        delete from feedback where id = p_id;
      end $b$;$f$;
  end if;
  if to_regclass('public.cashier_msgs') is not null then
    execute $f$create or replace function public.cmsg_delete(p_id bigint) returns void
      language plpgsql security definer set search_path = public as $b$
      begin
        if not is_owner() then raise exception 'الحذف للمالك فقط'; end if;
        delete from cashier_msgs where id = p_id;
      end $b$;$f$;
  end if;
  if to_regclass('public.advances') is not null then
    execute $f$create or replace function public.adv_delete(p_id uuid) returns void
      language plpgsql security definer set search_path = public as $b$
      begin
        if not is_owner() then raise exception 'الحذف للمالك فقط'; end if;
        delete from public.advances where id = p_id;
        if not found then raise exception 'الطلب غير موجود'; end if;
      end $b$;$f$;
    grant execute on function public.adv_delete(uuid) to authenticated;
  end if;
end $$;

select 'تم — الحذف صار للمالك فقط ✓' as result;
