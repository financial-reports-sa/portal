-- ============================================================
--  تسليم الورديات — الكاشير يسلّم برمزه الشخصي (بدون حساب)
--  والمحاسب/المالك يراجعون من داخل البوابة حسب الصلاحيات
-- ============================================================

-- 1) القسم الجديد في الصلاحيات
alter table public.user_sections drop constraint if exists user_sections_section_check;
alter table public.user_sections add constraint user_sections_section_check
  check (section in ('sales','channels','income','wh','chicken','carcass','treasury','handover'));

-- 2) رموز الكاشيرات (سرّية — لا يقرأها إلا المالك والآدمن عبر الدالة)
create table if not exists public.cashier_codes (
  pin    text primary key,
  code   text not null unique,      -- az1 .. az5 / sh1 .. sh3 / pc1 .. pc3
  branch text not null
);
alter table public.cashier_codes enable row level security;
revoke all on public.cashier_codes from anon, authenticated;
insert into public.cashier_codes (pin, code, branch) values
  ('6528','az1','az'),('6883','az2','az'),('8499','az3','az'),('2457','az4','az'),('9958','az5','az'),
  ('0640','sh1','sh'),('4320','sh2','sh'),('8700','sh3','sh'),
  ('6592','pc1','pc'),('4852','pc2','pc'),('0056','pc3','pc')
on conflict (pin) do nothing;

-- 3) التسليمات
create table if not exists public.handovers (
  hid           text primary key,            -- date_branch_shift_code
  date          date not null,
  month         text not null,
  branch        text not null,
  shift         text not null check (shift in ('am','pm')),
  code          text not null,
  cashier       text not null,
  cash          numeric not null default 0,
  card          numeric not null default 0,
  credit        numeric not null default 0,
  transfer      numeric not null default 0,
  reserve       numeric not null default 0,
  returns_total numeric not null default 0,
  total         numeric not null default 0,
  system        numeric,
  apps          jsonb not null default '{}',
  transfers     jsonb not null default '[]',
  reservations  jsonb not null default '[]',
  returns       jsonb not null default '[]',
  notes         text not null default '',
  review_status text not null default '' check (review_status in ('','ok','issue')),
  review_note   text not null default '',
  reviewed_at   timestamptz,
  reviewed_by   text not null default '',
  submitted_at  timestamptz not null default now()
);
create index if not exists handovers_month_idx on public.handovers (month, branch);
alter table public.handovers enable row level security;
revoke all on public.handovers from anon, authenticated;   -- كل الوصول عبر الدوال تحت

-- محاولات الرمز الخاطئ (حماية من التخمين)
create table if not exists public.handover_fails (ip text not null, at timestamptz not null default now());
create index if not exists handover_fails_idx on public.handover_fails (ip, at);
alter table public.handover_fails enable row level security;
revoke all on public.handover_fails from anon, authenticated;

-- هل المستخدم الحالي يقدر يشوف تسليمات هذا الفرع؟
create or replace function public.handover_can(p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_writer(), false)
      or (exists (select 1 from user_sections us join profiles p on p.id = us.user_id
                  where us.user_id = auth.uid() and us.section = 'handover' and p.active)
          and p_branch = any(my_branches()))
$$;

-- 4) الكاشير يسلّم (متاحة للزوار)
create or replace function public.submit_handover(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip      text := coalesce(split_part(coalesce(current_setting('request.headers', true), '{}')::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_branch  text := p->>'branch';
  v_code    text;
  v_date    date;
  v_shift   text := p->>'shift';
  v_cashier text := left(btrim(coalesce(p->>'cashier', '')), 60);
  v_allowed text[];
  v_apps    jsonb := '{}';
  v_tr jsonb; v_rs jsonb; v_rt jsonb;
  v_cash numeric; v_card numeric; v_credit numeric; v_transfer numeric; v_reserve numeric; v_ret numeric; v_total numeric; v_sys numeric;
  v_hid text; k text;
begin
  if (select count(*) from handover_fails where ip = v_ip and at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('ok', false, 'error', 'locked', 'message', 'محاولات كثيرة — انتظر ربع ساعة وحاول مرة ثانية');
  end if;
  v_allowed := case v_branch
    when 'az' then array['تطبيق الشادن','هنقرستيشن','كيتا','نينجا']
    when 'sh' then array['هنقرستيشن','كيتا','فرصة','نينجا']
    when 'pc' then array['هنقرستيشن','كيتا','نينجا'] end;
  if v_allowed is null then return jsonb_build_object('ok', false, 'error', 'branch', 'message', 'الفرع غير معروف'); end if;
  select code into v_code from cashier_codes where pin = btrim(coalesce(p->>'pin', '')) and branch = v_branch;
  if v_code is null then
    insert into handover_fails (ip) values (v_ip);
    delete from handover_fails where at < now() - interval '1 day';
    return jsonb_build_object('ok', false, 'error', 'pin', 'message', 'رمزك الشخصي غلط أو مو لهذا الفرع');
  end if;
  begin v_date := (p->>'date')::date; exception when others then v_date := null; end;
  if v_date is null or v_date > current_date + 1 or v_date < current_date - 60 then
    return jsonb_build_object('ok', false, 'error', 'date', 'message', 'التاريخ غير صحيح');
  end if;
  if v_shift is null or v_shift not in ('am','pm') then return jsonb_build_object('ok', false, 'error', 'shift', 'message', 'اختر الوردية'); end if;
  if v_cashier = '' then return jsonb_build_object('ok', false, 'error', 'cashier', 'message', 'اكتب اسم الكاشير'); end if;

  v_cash   := greatest(coalesce((p->>'cash')::numeric, 0), 0);
  v_card   := greatest(coalesce((p->>'card')::numeric, 0), 0);
  v_credit := greatest(coalesce((p->>'credit')::numeric, 0), 0);
  foreach k in array v_allowed loop
    if coalesce((p->'apps'->>k)::numeric, 0) > 0 then v_apps := v_apps || jsonb_build_object(k, round((p->'apps'->>k)::numeric, 2)); end if;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('a', round((x->>'a')::numeric, 2), 'n', left(btrim(coalesce(x->>'n','')), 120))), '[]')
    into v_tr from (select x from jsonb_array_elements(case when jsonb_typeof(p->'transfers') = 'array' then p->'transfers' else '[]' end) x limit 60) s
    where coalesce((x->>'a')::numeric, 0) > 0;
  select coalesce(jsonb_agg(jsonb_build_object('a', round((x->>'a')::numeric, 2), 'n', left(btrim(coalesce(x->>'n','')), 120))), '[]')
    into v_rs from (select x from jsonb_array_elements(case when jsonb_typeof(p->'reservations') = 'array' then p->'reservations' else '[]' end) x limit 60) s
    where coalesce((x->>'a')::numeric, 0) > 0;
  select coalesce(jsonb_agg(jsonb_build_object('a', round((x->>'a')::numeric, 2), 'n', left(btrim(coalesce(x->>'n','')), 120))), '[]')
    into v_rt from (select x from jsonb_array_elements(case when jsonb_typeof(p->'returns') = 'array' then p->'returns' else '[]' end) x limit 60) s
    where coalesce((x->>'a')::numeric, 0) > 0;
  select coalesce(sum((x->>'a')::numeric), 0) into v_transfer from jsonb_array_elements(v_tr) x;
  select coalesce(sum((x->>'a')::numeric), 0) into v_reserve  from jsonb_array_elements(v_rs) x;
  select coalesce(sum((x->>'a')::numeric), 0) into v_ret      from jsonb_array_elements(v_rt) x;
  v_total := round(v_cash + v_card + v_credit + v_transfer + v_reserve
                   + coalesce((select sum(value::numeric) from jsonb_each_text(v_apps)), 0), 2);
  if v_total <= 0 and v_ret <= 0 then return jsonb_build_object('ok', false, 'error', 'empty', 'message', 'ما فيه أي مبلغ'); end if;
  v_sys := case when p->>'system' is null or p->>'system' = '' then null else greatest((p->>'system')::numeric, 0) end;

  v_hid := v_date::text || '_' || v_branch || '_' || v_shift || '_' || v_code;
  insert into handovers as h (hid, date, month, branch, shift, code, cashier, cash, card, credit, transfer, reserve, returns_total, total, system,
                              apps, transfers, reservations, returns, notes)
  values (v_hid, v_date, to_char(v_date, 'YYYY-MM'), v_branch, v_shift, v_code, v_cashier, v_cash, v_card, v_credit, v_transfer, v_reserve, v_ret, v_total, v_sys,
          v_apps, v_tr, v_rs, v_rt, left(coalesce(p->>'notes', ''), 500))
  on conflict (hid) do update set
    cashier = excluded.cashier, cash = excluded.cash, card = excluded.card, credit = excluded.credit, transfer = excluded.transfer,
    reserve = excluded.reserve, returns_total = excluded.returns_total, total = excluded.total, system = excluded.system,
    apps = excluded.apps, transfers = excluded.transfers, reservations = excluded.reservations, returns = excluded.returns,
    notes = excluded.notes, submitted_at = now(),
    review_status = '', review_note = '', reviewed_at = null, reviewed_by = '';
  return jsonb_build_object('ok', true, 'hid', v_hid);
exception when invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok', false, 'error', 'bad', 'message', 'فيه رقم مكتوب غلط');
end $$;

-- 5) قائمة الشهر (حسب صلاحيات الفروع)
create or replace function public.handover_list(p_month text) returns setof public.handovers
language sql stable security definer set search_path = public as $$
  select * from handovers h where h.month = p_month and handover_can(h.branch) order by h.date, h.branch, h.shift, h.code
$$;

-- 6) تعليم المراجعة
create or replace function public.handover_mark(p_hid text, p_status text, p_note text default '') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_branch text; v_who text;
begin
  select branch into v_branch from handovers where hid = p_hid;
  if v_branch is null then return jsonb_build_object('ok', false, 'message', 'التسليم غير موجود'); end if;
  if not handover_can(v_branch) then return jsonb_build_object('ok', false, 'message', 'ما عندك صلاحية على هذا الفرع'); end if;
  if p_status not in ('','ok','issue') then return jsonb_build_object('ok', false, 'message', 'طلب غير صحيح'); end if;
  select coalesce(nullif(full_name, ''), username) into v_who from profiles where id = auth.uid();
  update handovers set review_status = p_status,
    review_note = case when p_status = '' then '' else left(coalesce(p_note, ''), 300) end,
    reviewed_at = case when p_status = '' then null else now() end,
    reviewed_by = case when p_status = '' then '' else coalesce(v_who, '') end
  where hid = p_hid;
  return jsonb_build_object('ok', true, 'who', coalesce(v_who, ''));
end $$;

-- 7) للمالك والآدمن: حذف تسليم، وعرض رموز الكاشيرات
create or replace function public.handover_delete(p_hid text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_writer(), false) then return jsonb_build_object('ok', false, 'message', 'للمالك والآدمن فقط'); end if;
  delete from handovers where hid = p_hid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.handover_codes() returns table (pin text, code text, branch text)
language sql stable security definer set search_path = public as $$
  select c.pin, c.code, c.branch from cashier_codes c where coalesce(is_writer(), false) order by c.branch, c.code
$$;

revoke all on function public.submit_handover(jsonb) from public;
revoke all on function public.handover_list(text) from public;
revoke all on function public.handover_mark(text, text, text) from public;
revoke all on function public.handover_delete(text) from public;
revoke all on function public.handover_codes() from public;
revoke all on function public.handover_can(text) from public;
grant execute on function public.submit_handover(jsonb) to anon, authenticated;
grant execute on function public.handover_list(text) to authenticated;
grant execute on function public.handover_mark(text, text, text) to authenticated;
grant execute on function public.handover_delete(text) to authenticated;
grant execute on function public.handover_codes() to authenticated;
grant execute on function public.handover_can(text) to authenticated;

select 'تم تفعيل تسليم الورديات ✓' as result;
