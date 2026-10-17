alter table public.cashier_returns add column if not exists ack_at timestamptz;
alter table public.cashier_returns add column if not exists status text;
alter table public.cashier_returns add column if not exists mgr_id uuid;
alter table public.cashier_returns add column if not exists mgr_name text;
alter table public.cashier_returns add column if not exists mgr_at timestamptz;
alter table public.cashier_returns add column if not exists mgr_note text not null default '';
alter table public.cashier_returns drop constraint if exists cashier_returns_status_check;
alter table public.cashier_returns add constraint cashier_returns_status_check check (status is null or status in ('pending','approved','rejected'));
create index if not exists cashier_returns_pend_idx on public.cashier_returns (branch) where status = 'pending';

create or replace function public.ret_mgr_can(p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_writer(), false)
      or (exists (select 1 from user_sections us join profiles p on p.id = us.user_id where us.user_id = auth.uid() and us.section = 'rets' and p.active)
          and p_branch = any(my_branches()))
$$;

create or replace function public.ret_feed(p_days int default 7) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'branch', r.branch, 'cashier', r.cashier, 'bdate', r.bdate, 'inv', r.inv_no, 'at', r.inv_at,
    'amount', r.amount, 'reason', r.reason, 'note', r.note, 'created', r.created_at, 'mins', floor(extract(epoch from (r.created_at - r.inv_at)) / 60),
    'ack', r.ack_at is not null, 'status', r.status, 'mgr', r.mgr_name, 'mgr_at', r.mgr_at, 'mgr_note', r.mgr_note, 'can', ret_mgr_can(r.branch)) order by r.created_at desc), '[]')
  from cashier_returns r
  where (r.bdate >= ((now() at time zone 'Asia/Riyadh') - interval '6 hours')::date - greatest(0, least(coalesce(p_days, 7), 62)) or r.status = 'pending')
    and ret_view_can(r.branch)
$$;

create or replace function public.ret_decide(p_id bigint, p_ok boolean, p_note text default '') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r cashier_returns; nm text; bn text;
begin
  select * into r from cashier_returns where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'message', 'المرتجع غير موجود'); end if;
  if not ret_mgr_can(r.branch) then return jsonb_build_object('ok', false, 'message', 'الاعتماد لمدير الفرع فقط'); end if;
  if r.status is distinct from 'pending' then return jsonb_build_object('ok', false, 'message', 'تم البت في هذا المرتجع قبل'); end if;
  if not p_ok and length(btrim(coalesce(p_note, ''))) < 3 then return jsonb_build_object('ok', false, 'message', 'اكتب سبب الرفض'); end if;
  nm := coalesce((select coalesce(nullif(full_name, ''), username) from profiles where id = auth.uid()), '');
  update cashier_returns set status = case when p_ok then 'approved' else 'rejected' end, mgr_id = auth.uid(), mgr_name = nm, mgr_at = now(), mgr_note = left(btrim(coalesce(p_note, '')), 300)
   where id = p_id;
  if not p_ok then
    bn := coalesce((select name from branches where id = r.branch), r.branch);
    begin
      perform push_send(push_admins(), '⛔ مرتجع مرفوض ' || to_char(r.amount, 'FM999,990.00') || ' ر.س · ' || bn,
        coalesce(nullif(r.cashier, ''), r.code) || ' · فاتورة ' || r.inv_no || ' · رفضه ' || nm || ': ' || left(btrim(p_note), 80), './?tab=rets', 'retd-' || p_id);
    exception when others then null; end;
  end if;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.ret_add(text, text, text, text, text, numeric, text, text, text);
create or replace function public.ret_add(p_branch text, p_pin text, p_cashier text, p_inv text, p_inv_time text, p_amount numeric, p_reason text, p_note text, p_img text, p_ack boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_code text; nr timestamp := now() at time zone 'Asia/Riyadh'; t time; cand timestamp; v_at timestamptz; v_bd date; nid bigint; mins int;
  v_inv text := left(regexp_replace(btrim(coalesce(p_inv, '')), '\s+', '', 'g'), 40); bn text;
begin
  begin v_code := ret_pin(p_branch, p_pin); exception when others then return jsonb_build_object('ok', false, 'error', 'pin', 'message', sqlerrm); end;
  if not coalesce(p_ack, false) then return jsonb_build_object('ok', false, 'message', 'لازم توافق على الإقرار قبل التوثيق'); end if;
  if v_inv = '' then return jsonb_build_object('ok', false, 'message', 'اكتب رقم الفاتورة'); end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > 50000 then return jsonb_build_object('ok', false, 'message', 'اكتب مبلغ المرتجع'); end if;
  if coalesce(p_reason, '') = '' then return jsonb_build_object('ok', false, 'message', 'اختر سبب المرتجع'); end if;
  if coalesce(p_img, '') !~ '^data:image/' or length(p_img) < 2000 then return jsonb_build_object('ok', false, 'message', 'صورة الفاتورة إلزامية'); end if;
  if length(p_img) > 1200000 then return jsonb_build_object('ok', false, 'message', 'الصورة كبيرة — صوّر مرة ثانية'); end if;
  begin t := p_inv_time::time; exception when others then return jsonb_build_object('ok', false, 'message', 'اكتب وقت الفاتورة'); end;
  cand := nr::date + t;
  if cand > nr + interval '3 minutes' then cand := cand - interval '1 day'; end if;
  mins := floor(extract(epoch from (nr - cand)) / 60);
  if mins > 30 then
    return jsonb_build_object('ok', false, 'error', 'late', 'message', 'انتهت مهلة التوثيق — المرتجع لازم يتوثّق خلال نص ساعة من وقت الفاتورة (مرّ ' || mins || ' دقيقة). المرتجع غير الموثّق يُحسب عجز عليك.');
  end if;
  v_at := cand at time zone 'Asia/Riyadh';
  v_bd := (nr - interval '6 hours')::date;
  if exists (select 1 from cashier_returns where branch = p_branch and bdate = v_bd and inv_no = v_inv) then
    return jsonb_build_object('ok', false, 'message', 'مرتجع هذه الفاتورة موثّق قبل');
  end if;
  insert into cashier_returns (branch, code, cashier, bdate, inv_no, inv_at, amount, reason, note, ack_at, status)
  values (p_branch, v_code, left(btrim(coalesce(p_cashier, '')), 60), v_bd, v_inv, v_at, round(p_amount, 2), left(p_reason, 60), left(coalesce(p_note, ''), 300), now(), 'pending')
  returning id into nid;
  insert into cashier_return_photos (ret_id, img) values (nid, p_img);
  bn := coalesce((select name from branches where id = p_branch), p_branch);
  begin
    perform push_send(array(select distinct x from unnest(push_admins() || push_mgrs('rets', p_branch)) x), case when p_amount >= 100 then '🚨 مرتجع كبير ' else '↩️ مرتجع ' end || to_char(round(p_amount, 2), 'FM999,990.00') || ' ر.س · ' || bn || ' — بانتظار اعتماد المدير',
      coalesce(nullif(btrim(p_cashier), ''), v_code) || ' · ' || p_reason || ' · فاتورة ' || v_inv, './?tab=rets', 'ret-' || nid);
  exception when others then null; end;
  return jsonb_build_object('ok', true, 'id', nid, 'bdate', v_bd);
end $$;

create or replace function public.ret_mine(p_branch text, p_pin text, p_date date default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_code text; v_bd date := coalesce(p_date, ((now() at time zone 'Asia/Riyadh') - interval '6 hours')::date);
begin
  begin v_code := ret_pin(p_branch, p_pin); exception when others then return jsonb_build_object('ok', false, 'error', 'pin', 'message', sqlerrm); end;
  return jsonb_build_object('ok', true, 'bdate', v_bd, 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'inv', inv_no, 'at', inv_at, 'amount', amount, 'reason', reason, 'created', created_at, 'status', status, 'mgr_note', mgr_note) order by id)
    from cashier_returns where code = v_code and bdate = v_bd), '[]'));
end $$;

create or replace function public.ret_list(p_month text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'branch', r.branch, 'code', r.code, 'cashier', r.cashier, 'bdate', r.bdate, 'inv', r.inv_no, 'at', r.inv_at,
    'amount', r.amount, 'reason', r.reason, 'note', r.note, 'created', r.created_at, 'mins', floor(extract(epoch from (r.created_at - r.inv_at)) / 60),
    'status', r.status, 'mgr', r.mgr_name, 'mgr_note', r.mgr_note) order by r.created_at desc), '[]')
  from cashier_returns r where to_char(r.bdate, 'YYYY-MM') = p_month and handover_can(r.branch)
$$;

revoke all on function public.ret_mgr_can(text) from public, anon;
grant execute on function public.ret_mgr_can(text) to authenticated;
revoke all on function public.ret_feed(int) from public, anon;
grant execute on function public.ret_feed(int) to authenticated;
revoke all on function public.ret_decide(bigint, boolean, text) from public, anon;
grant execute on function public.ret_decide(bigint, boolean, text) to authenticated;
revoke all on function public.ret_add(text, text, text, text, text, numeric, text, text, text, boolean) from public;
grant execute on function public.ret_add(text, text, text, text, text, numeric, text, text, text, boolean) to anon, authenticated;

select 'تم: إقرار الكاشير واعتماد مدير الفرع للمرتجعات' as result;
