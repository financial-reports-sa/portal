-- ============================================================
--  أسطول السيارات (أصول) — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  مدراء الفروع يضيفون ويعدّلون سيارات فروعهم مع الصور، والمالك والآدمن يشوفون الكل ومعها وفرة.
-- ============================================================
alter table public.user_sections drop constraint if exists user_sections_section_check;
alter table public.user_sections add constraint user_sections_section_check
  check (section in ('sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet'));

create or replace function public.app_section(p_app text) returns text
language sql immutable as $$
  select case p_app when 'sales' then 'sales' when 'daily' then 'sales' when 'channels' then 'channels'
                    when 'income' then 'income' when 'wh' then 'wh' when 'prices' then 'chicken'
                    when 'treasury' then 'treasury' when 'loans' then 'loans' when 'fleet' then 'fleet' else null end
$$;

-- هل يحق للمستخدم الحالي إدارة سيارات هذه الجهة؟ (وفرة للمالك والآدمن فقط)
create or replace function public.fleet_can(p_br text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_writer() or (p_br <> 'wafra' and has_section('fleet') and p_br = any(my_branches())), false)
$$;

-- إضافة / تعديل سيارة مع صورها
create or replace function public.fleet_save(p_id text, p_data jsonb, p_imgs jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  br text := p_data->>'br';
  old_br text;
  who text;
begin
  if p_id is null or p_id !~ '^[A-Za-z0-9_-]{6,60}$' then raise exception 'معرّف غير صالح'; end if;
  if br is null or br not in ('az','sh','pc','wafra') then raise exception 'اختر الجهة'; end if;
  if not fleet_can(br) then raise exception 'ليس لديك صلاحية على سيارات هذه الجهة'; end if;
  select data->>'br' into old_br from app_docs where app = 'fleet' and coll = 'vehicles' and id = p_id;
  if old_br is not null and not fleet_can(old_br) then raise exception 'ليس لديك صلاحية على هذه السيارة'; end if;
  select coalesce(nullif(full_name, ''), username) into who from profiles where id = auth.uid();
  insert into app_docs (app, coll, id, data, branches, updated_at)
  values ('fleet', 'vehicles', p_id,
          p_data || jsonb_build_object('updatedBy', who, 'updatedAt', now()),
          array[br], now())
  on conflict (app, coll, id) do update set data = excluded.data, branches = excluded.branches, updated_at = now();
  if p_imgs is not null then
    insert into app_docs (app, coll, id, data, branches, updated_at)
    values ('fleet', 'photos', p_id, jsonb_build_object('imgs', p_imgs), array[br], now())
    on conflict (app, coll, id) do update set data = excluded.data, branches = excluded.branches, updated_at = now();
  else
    update app_docs set branches = array[br] where app = 'fleet' and coll = 'photos' and id = p_id;
  end if;
end $$;

-- صور سيارة (تُحمَّل عند الطلب)
create or replace function public.fleet_photos(p_id text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d jsonb; b text[];
begin
  select data, branches into d, b from app_docs where app = 'fleet' and coll = 'photos' and id = p_id;
  if d is null then return '[]'::jsonb; end if;
  if not (is_writer() or (has_section('fleet') and b <@ my_branches())) then return '[]'::jsonb; end if;
  return coalesce(d->'imgs', '[]'::jsonb);
end $$;

-- حذف سيارة (المالك والآدمن فقط)
create or replace function public.fleet_delete(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'الحذف للمالك والآدمن فقط — يمكنك تغيير الحالة إلى «مباعة» أو «خارج الخدمة»'; end if;
  delete from app_docs where app = 'fleet' and coll in ('vehicles', 'photos') and id = p_id;
end $$;

revoke all on function public.fleet_save(text, jsonb, jsonb) from public, anon;
revoke all on function public.fleet_photos(text) from public, anon;
revoke all on function public.fleet_delete(text) from public, anon;
grant execute on function public.fleet_save(text, jsonb, jsonb) to authenticated;
grant execute on function public.fleet_photos(text) to authenticated;
grant execute on function public.fleet_delete(text) to authenticated;
grant execute on function public.fleet_can(text) to authenticated;

select 'تمت إضافة أسطول السيارات ✓' as result;
