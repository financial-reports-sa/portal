-- تحديث إشعارات الجوال: القاعدة ترسل للدالة المفاتيح والأجهزة مباشرة (يشغَّل بعد push.sql)
alter table public.push_config add column if not exists gen_req bigint;
alter table public.push_config add column if not exists gen_at timestamptz;

-- المفتاح العام للتسجيل (يولَّد تلقائياً أول مرة عن طريق الدالة)
create or replace function public.push_key() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare c public.push_config; r record;
begin
  select * into c from push_config where id = 1;
  if c.public_key is not null then return c.public_key; end if;
  if c.gen_req is not null then
    select status_code, content into r from net._http_response where id = c.gen_req;
    if found and r.status_code = 200 then
      update push_config set public_key = r.content::jsonb->>'publicKey', private_key = r.content::jsonb->>'privateKey'
        where id = 1 and public_key is null;
      return (select public_key from push_config where id = 1);
    end if;
    if not found and c.gen_at > now() - interval '1 minute' then return null; end if;
  end if;
  update push_config set gen_req = net.http_get('https://olsqykputyhigalzmlbs.supabase.co/functions/v1/push?gen=1'), gen_at = now() where id = 1;
  return null;
end $$;

-- الإرسال الفعلي لقائمة مستخدمين
create or replace function public.push_post(p_users uuid[], p_title text, p_body text, p_url text default './', p_tag text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare c public.push_config; s jsonb;
begin
  select * into c from push_config where id = 1;
  if c.public_key is null or c.private_key is null then return; end if;
  select jsonb_agg(jsonb_build_object('endpoint', endpoint, 'p256dh', p256dh, 'auth', auth)) into s
    from push_subs where user_id = any(p_users);
  if s is null then return; end if;
  perform net.http_post(
    url := 'https://olsqykputyhigalzmlbs.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('vapid', jsonb_build_object('pub', c.public_key, 'priv', c.private_key), 'subs', s,
            'payload', jsonb_build_object('title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag)),
    timeout_milliseconds := 10000);
exception when others then null;
end $$;

create or replace function public.push_send(p_users uuid[], p_title text, p_body text, p_url text default './', p_tag text default null)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid[];
begin
  u := array(select distinct x from unnest(coalesce(p_users, '{}')) x where x is not null and x is distinct from auth.uid());
  if cardinality(u) = 0 then return; end if;
  perform push_post(u, p_title, p_body, p_url, p_tag);
exception when others then null;
end $$;

create or replace function public.push_test() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from push_subs where user_id = auth.uid()) then return false; end if;
  perform push_post(array[auth.uid()], 'MyHub ✓', 'الإشعارات شغّالة على هذا الجهاز', './', 'test');
  return true;
end $$;

revoke all on function public.push_post(uuid[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_send(uuid[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_key() from public, anon;
grant execute on function public.push_key() to authenticated;
grant execute on function public.push_test() to authenticated;

select public.push_key() is null as "يولّد المفاتيح الحين", 'تم التحديث ✓' as result;
