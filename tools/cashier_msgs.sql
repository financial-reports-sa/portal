-- ============================================================
--  مراسلة الكاشيرات (تنبيه / إنذار / إنذار نهائي) — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  الإدارة ترسل من «تسليم الورديات» داخل المنصة، والكاشير يشوفها في رابط التسليم برمزه الشخصي
--  ولازم يقرّ بالاستلام ويكتب السبب — والرد يوصل للإدارة (تنبيه + إشعار جوال)
-- ============================================================
create table if not exists public.cashier_msgs (
  id         bigint generated always as identity primary key,
  code       text not null,
  branch     text not null,
  side       text not null check (side in ('admin','cashier')),
  kind       text not null default 'msg' check (kind in ('msg','notice','warn','final','reply')),
  body       text not null,
  by_name    text,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists cashier_msgs_code_idx on public.cashier_msgs (code, created_at);
alter table public.cashier_msgs enable row level security;
revoke all on public.cashier_msgs from anon, authenticated;   -- كل الوصول عبر الدوال

-- قائمة الكاشيرات للمراسلة (بدون الرموز) مع آخر رسالة وغير المقروء
create or replace function public.cmsg_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'code', c.code, 'branch', c.branch,
    'name', (select h.cashier from handovers h where h.code = c.code order by h.submitted_at desc limit 1),
    'last', (select jsonb_build_object('side', m.side, 'kind', m.kind, 'body', left(m.body, 80), 'at', m.created_at, 'read', m.read_at is not null)
               from cashier_msgs m where m.code = c.code order by m.id desc limit 1),
    'unread', (select count(*) from cashier_msgs m where m.code = c.code and m.side = 'cashier' and m.read_at is null),
    'warns', (select count(*) from cashier_msgs m where m.code = c.code and m.side = 'admin' and m.kind in ('warn','final'))
  ) order by c.branch, c.code), '[]'::jsonb)
  from cashier_codes c where handover_can(c.branch)
$$;

-- المحادثة مع كاشير (الإدارة) — وتعليم ردوده كمقروءة
create or replace function public.cmsg_thread(p_code text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b text;
begin
  select branch into b from cashier_codes where code = p_code;
  if b is null or not handover_can(b) then raise exception 'ليس لديك صلاحية'; end if;
  update cashier_msgs set read_at = now() where code = p_code and side = 'cashier' and read_at is null;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'side', side, 'kind', kind, 'body', body, 'by', by_name,
                    'at', created_at, 'read', read_at) order by id) from cashier_msgs where code = p_code), '[]'::jsonb);
end $$;

-- إرسال من الإدارة
create or replace function public.cmsg_send(p_code text, p_kind text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare b text;
begin
  select branch into b from cashier_codes where code = p_code;
  if b is null or not handover_can(b) then raise exception 'ليس لديك صلاحية'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'اكتب نص الرسالة'; end if;
  insert into cashier_msgs (code, branch, side, kind, body, by_name)
  values (p_code, b, 'admin', case when p_kind in ('notice','warn','final') then p_kind else 'msg' end, left(trim(p_body), 2000),
          (select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid()));
end $$;

-- حذف رسالة (المالك والآدمن)
create or replace function public.cmsg_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'الحذف للمالك والآدمن فقط'; end if;
  delete from cashier_msgs where id = p_id;
end $$;

-- عدد الردود غير المقروءة (لجرس التنبيهات)
create or replace function public.cmsg_unread() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'code', m.code, 'branch', m.branch, 'body', left(m.body, 90), 'at', m.created_at,
    'name', (select h.cashier from handovers h where h.code = m.code order by h.submitted_at desc limit 1))), '[]'::jsonb)
  from cashier_msgs m where m.side = 'cashier' and m.read_at is null and handover_can(m.branch)
$$;

-- الكاشير: رسائله برمزه الشخصي (وتتعلّم كمقروءة)
create or replace function public.cmsg_mine(p_branch text, p_pin text, p_mark boolean default true) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip   text := coalesce(split_part(coalesce(current_setting('request.headers', true), '{}')::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_code text;
begin
  if (select count(*) from handover_fails where ip = v_ip and at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'message', 'محاولات كثيرة — انتظر ربع ساعة');
  end if;
  select code into v_code from cashier_codes where pin = btrim(coalesce(p_pin, '')) and branch = p_branch;
  if v_code is null then
    insert into handover_fails (ip) values (v_ip);
    return jsonb_build_object('ok', false, 'message', 'رمزك الشخصي غلط أو مو لهذا الفرع');
  end if;
  if p_mark then update cashier_msgs set read_at = now() where code = v_code and side = 'admin' and read_at is null; end if;
  return jsonb_build_object('ok', true, 'msgs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'side', side, 'kind', kind,
    'body', body, 'by', by_name, 'at', created_at, 'read', read_at) order by id)
    from (select * from cashier_msgs where code = v_code order by id desc limit 60) x), '[]'::jsonb));
end $$;

-- الكاشير يرد
create or replace function public.cmsg_reply(p_branch text, p_pin text, p_body text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_code text; v_name text;
begin
  select code into v_code from cashier_codes where pin = btrim(coalesce(p_pin, '')) and branch = p_branch;
  if v_code is null then return jsonb_build_object('ok', false, 'message', 'رمزك الشخصي غلط'); end if;
  if coalesce(trim(p_body), '') = '' then return jsonb_build_object('ok', false, 'message', 'اكتب ردك'); end if;
  if (select count(*) from cashier_msgs where code = v_code and side = 'cashier' and created_at > now() - interval '1 hour') >= 15 then
    return jsonb_build_object('ok', false, 'message', 'أرسلت رسائل كثيرة — حاول بعد شوي');
  end if;
  v_name := (select h.cashier from handovers h where h.code = v_code order by h.submitted_at desc limit 1);
  insert into cashier_msgs (code, branch, side, kind, body, by_name) values (v_code, p_branch, 'cashier', 'reply', left(trim(p_body), 2000), v_name);
  begin
    if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is not null then
      perform push_send(push_mgrs('handover', p_branch) || push_admins(), '💬 رد من الكاشير',
        coalesce(v_name, v_code) || ': ' || left(trim(p_body), 120), './?tab=handover', 'cm-' || v_code);
    end if;
  exception when others then null; end;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.cmsg_list(), public.cmsg_thread(text), public.cmsg_send(text,text,text), public.cmsg_delete(bigint),
  public.cmsg_unread(), public.cmsg_mine(text,text,boolean), public.cmsg_reply(text,text,text) from public;
grant execute on function public.cmsg_list(), public.cmsg_thread(text), public.cmsg_send(text,text,text), public.cmsg_delete(bigint),
  public.cmsg_unread() to authenticated;
grant execute on function public.cmsg_mine(text,text,boolean), public.cmsg_reply(text,text,text) to anon, authenticated;

select 'تم تفعيل مراسلة الكاشيرات ✓' as result;
