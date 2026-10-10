-- تعديل اسم المستخدم (اسم الدخول بالإنجليزي) والاسم الظاهر من داخل البوابة
-- يشغَّل مرة واحدة في Supabase → SQL Editor → Run
-- المالك يعدّل أي حساب (ومنه حسابه)، الآدمن يعدّل حسابات المستخدمين. حساب المهام التلقائية (sync) لا يُعدَّل اسمه.

create or replace function public.set_full_name(p_uid uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := btrim(coalesce(p_name, ''));
begin
  if v = '' or length(v) > 60 then raise exception 'الاسم غير صالح'; end if;
  if not (p_uid = auth.uid() or my_role() = 'owner' or can_manage(p_uid)) then
    raise exception 'ليس لديك صلاحية تعديل هذا الحساب';
  end if;
  update profiles set full_name = v where id = p_uid;
end $$;
revoke all on function public.set_full_name(uuid, text) from public, anon;
grant execute on function public.set_full_name(uuid, text) to authenticated;

create or replace function public.set_username(p_uid uuid, p_username text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare
  u text := lower(btrim(coalesce(p_username, '')));
  dom text;
  em text;
  r text;
begin
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'اسم المستخدم بالإنجليزي: حروف وأرقام فقط من 3 إلى 30'; end if;
  select role into r from profiles where id = p_uid;
  if r is null then raise exception 'الحساب غير موجود'; end if;
  if r = 'sync' then raise exception 'حساب المهام التلقائية لا يُعدَّل اسمه (المهام تعتمد عليه)'; end if;
  if not ((p_uid = auth.uid() and r = 'owner') or my_role() = 'owner' or can_manage(p_uid)) then
    raise exception 'ليس لديك صلاحية تعديل هذا الحساب';
  end if;
  select split_part(email, '@', 2) into dom from auth.users where id = p_uid;
  em := u || '@' || coalesce(nullif(dom, ''), 'myreportshub.report');
  if exists (select 1 from auth.users where lower(email) = em and id <> p_uid)
     or exists (select 1 from profiles where username = u and id <> p_uid) then
    raise exception 'اسم المستخدم مستخدم لحساب آخر';
  end if;
  update auth.users
     set email = em,
         raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('username', u),
         updated_at = now()
   where id = p_uid;
  update auth.identities
     set identity_data = coalesce(identity_data, '{}'::jsonb) || jsonb_build_object('email', em),
         updated_at = now()
   where user_id = p_uid and provider = 'email';
  update profiles set username = u where id = p_uid;
end $$;
revoke all on function public.set_username(uuid, text) from public, anon;
grant execute on function public.set_username(uuid, text) to authenticated;
select 'تم ✓' as result;
