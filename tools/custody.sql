-- ============================================================
--  العُهد النقدية — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  الإدارة/المحاسب يسجّل العهدة (حوالة أو نقد) ← الموظف يأكّد الاستلام (أو العكس)
--  الموظف يرفع فواتيره بصورة إلزامية ← المحاسب يعتمد أو يرفض ← التصفية ممنوعة قبل مراجعة كل شي
-- ============================================================

-- 1) صلاحية القسم: custody
do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback','custody']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner' and active)
$$;
grant execute on function public.is_owner() to authenticated;

create or replace function public.custody_can(p_branch text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or (has_section('custody') and p_branch = any(my_branches()))
$$;

-- 2) الجداول
create table if not exists public.custodies (
  id          uuid primary key default gen_random_uuid(),
  no          bigserial unique,
  emp_id      uuid not null references public.employees(id) on delete restrict,
  emp_name    text not null default '',
  branch      text not null,
  title       text not null default '',
  status      text not null default 'open' check (status in ('open','closed')),
  opened_by   text not null default '',
  created_at  timestamptz not null default now(),
  closed_at   timestamptz,
  closed_by   text,
  close_note  text,
  summary     jsonb
);
create index if not exists custodies_emp_idx on public.custodies (emp_id, status);
create index if not exists custodies_branch_idx on public.custodies (branch, status);

create table if not exists public.custody_tx (
  id          uuid primary key default gen_random_uuid(),
  no          bigserial unique,
  custody_id  uuid not null references public.custodies(id) on delete cascade,
  emp_id      uuid not null,
  branch      text not null,
  kind        text not null check (kind in ('fund','expense','return')),
  method      text check (method in ('transfer','cash')),
  amount      numeric(12,2) not null check (amount > 0),
  date        date not null,
  vendor      text not null default '',
  category    text not null default '',
  taxable     boolean,
  vat         numeric(12,2),
  invoice_no  text not null default '',
  note        text not null default '',
  has_photo   boolean not null default false,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  side        text not null check (side in ('emp','acc')),        -- مين سجّلها: الموظف أو الإدارة/المحاسب
  created_by  text not null default '',
  created_at  timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz,
  review_note text
);
create index if not exists custody_tx_c_idx on public.custody_tx (custody_id, date);
create index if not exists custody_tx_pending_idx on public.custody_tx (branch, status);

create table if not exists public.custody_photos (
  tx_id uuid primary key references public.custody_tx(id) on delete cascade,
  img   text not null
);

alter table public.custodies enable row level security;
alter table public.custody_tx enable row level security;
alter table public.custody_photos enable row level security;
drop policy if exists cu_read on public.custodies;
create policy cu_read on public.custodies for select to authenticated using (custody_can(branch) or emp_id = my_emp_id());
drop policy if exists ct_read on public.custody_tx;
create policy ct_read on public.custody_tx for select to authenticated using (custody_can(branch) or emp_id = my_emp_id());
revoke all on public.custodies, public.custody_tx, public.custody_photos from anon, authenticated;
grant select on public.custodies, public.custody_tx to authenticated;   -- الكتابة والصور عبر الدوال فقط

-- 3) أدوات مساعدة
create or replace function public.custody_emp_user(p_emp uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select user_id from emp_accounts where emp_id = p_emp
$$;

create or replace function public.custody_push(p_users uuid[], p_title text, p_body text, p_tag text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is null then return; end if;
  if coalesce(array_length(p_users, 1), 0) = 0 then return; end if;
  perform push_send(p_users, p_title, p_body, './?tab=custody', p_tag);
exception when others then null;
end $$;

create or replace function public.custody_staff(p_branch text) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
begin
  return (select coalesce(array_agg(distinct p.id), '{}') from profiles p
          where p.active and (p.role in ('owner','admin')
             or (p.role = 'user' and exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'custody')
                 and exists (select 1 from user_branches b where b.user_id = p.id and b.branch_id = p_branch))));
exception when others then return '{}';
end $$;

-- الرصيد: الحوالات المؤكدة − المصروفات المعتمدة − المبالغ المرجعة
create or replace function public.custody_balance(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'funds',    coalesce(sum(amount) filter (where kind = 'fund'    and status = 'approved'), 0),
    'expenses', coalesce(sum(amount) filter (where kind = 'expense' and status = 'approved'), 0),
    'returns',  coalesce(sum(amount) filter (where kind = 'return'  and status = 'approved'), 0),
    'balance',  coalesce(sum(case when status <> 'approved' then 0 when kind = 'fund' then amount else -amount end), 0),
    'pending',  count(*) filter (where status = 'pending'),
    'pending_expenses', coalesce(sum(amount) filter (where kind = 'expense' and status = 'pending'), 0),
    'non_tax',  coalesce(sum(amount) filter (where kind = 'expense' and status <> 'rejected' and taxable is false), 0))
  from custody_tx where custody_id = p_id
$$;

-- قائمة الموظفين اللي ينفع تُسجّل عليهم عهدة (للمحاسب حتى لو ما عنده قسم الموظفين)
create or replace function public.custody_emps() returns table (id uuid, name text, branch text, job text, has_account boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.name, e.branch, e.job, exists (select 1 from emp_accounts a where a.emp_id = e.id)
  from employees e where e.status <> 'left' and custody_can(e.branch) order by e.name
$$;

-- 4) فتح عهدة (الإدارة/المحاسب) مع أول مبلغ اختياري
create or replace function public.custody_open(p_emp uuid, p_title text, p_amount numeric default null, p_method text default 'transfer',
  p_date date default null, p_note text default '', p_img text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare e employees; cid uuid; who text := who_am_i(); acc uuid;
begin
  select * into e from employees where id = p_emp;
  if e.id is null then raise exception 'الموظف غير موجود'; end if;
  if not custody_can(e.branch) then raise exception 'ليس لديك صلاحية على عهد هذا الفرع'; end if;
  if e.status = 'left' then raise exception 'الموظف منتهية خدماته'; end if;
  if exists (select 1 from custodies where emp_id = p_emp and status = 'open') then
    raise exception 'الموظف عنده عهدة مفتوحة — أضف المبلغ عليها أو صفّها أولاً';
  end if;
  insert into custodies (emp_id, emp_name, branch, title, opened_by)
  values (p_emp, e.name, e.branch, left(coalesce(nullif(btrim(p_title), ''), 'عهدة نقدية'), 80), who) returning id into cid;
  if coalesce(p_amount, 0) > 0 then
    perform custody_add(cid, 'fund', p_amount, coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date), p_method,
                        '', '', null, null, '', coalesce(p_note, ''), p_img);
  end if;
  return cid;
end $$;

-- 5) إضافة حركة: حوالة/نقد مستلم (fund) — فاتورة (expense) — إرجاع مبلغ (return)
create or replace function public.custody_add(p_custody uuid, p_kind text, p_amount numeric, p_date date, p_method text default null,
  p_vendor text default '', p_category text default '', p_taxable boolean default null, p_vat numeric default null,
  p_invoice text default '', p_note text default '', p_img text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c custodies; me uuid := my_emp_id(); side text; stt text; tid uuid; who text := who_am_i(); img text := nullif(btrim(coalesce(p_img, '')), '');
  br text; empu uuid;
begin
  select * into c from custodies where id = p_custody for update;
  if c.id is null then raise exception 'العهدة غير موجودة'; end if;
  if c.status <> 'open' then raise exception 'العهدة مصفّاة ومقفلة'; end if;
  if me is not null and me = c.emp_id then side := 'emp';
  elsif custody_can(c.branch) then side := 'acc';
  else raise exception 'ليس لديك صلاحية'; end if;
  if p_kind not in ('fund','expense','return') then raise exception 'نوع الحركة غير صحيح'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'اكتب المبلغ صحيح'; end if;
  if p_date is null or p_date > (now() at time zone 'Asia/Riyadh')::date + 1 or p_date < (now() at time zone 'Asia/Riyadh')::date - 400 then raise exception 'التاريخ غير صحيح'; end if;
  if p_kind = 'expense' and img is null then raise exception 'صورة الفاتورة إلزامية — صوّر الفاتورة وأرفقها'; end if;
  if img is not null and length(img) > 1200000 then raise exception 'الصورة كبيرة — صوّرها مرة ثانية'; end if;
  if p_kind = 'expense' and p_taxable is null then raise exception 'حدد هل الفاتورة ضريبية أو غير ضريبية'; end if;
  empu := custody_emp_user(c.emp_id);
  -- الفاتورة من الموظف تنتظر المحاسب، ومن المحاسب نيابة عنه معتمدة
  -- الحوالة/الإرجاع: اللي سجّلها طرف، والطرف الثاني يأكّد (وإذا الموظف ما عنده حساب تعتمد مباشرة)
  stt := case when side = 'emp' then 'pending'
              when p_kind = 'expense' then 'approved'
              when empu is null then 'approved'
              else 'pending' end;
  insert into custody_tx (custody_id, emp_id, branch, kind, method, amount, date, vendor, category, taxable, vat, invoice_no, note,
                          has_photo, status, side, created_by, reviewed_by, reviewed_at)
  values (c.id, c.emp_id, c.branch, p_kind, case when p_kind <> 'expense' then coalesce(p_method, 'transfer') end, round(p_amount, 2), p_date,
          left(btrim(coalesce(p_vendor, '')), 80), left(btrim(coalesce(p_category, '')), 40),
          case when p_kind = 'expense' then p_taxable end, case when p_kind = 'expense' and p_taxable then round(p_vat, 2) end,
          left(btrim(coalesce(p_invoice, '')), 40), left(btrim(coalesce(p_note, '')), 300),
          img is not null, stt, side, who, case when stt = 'approved' then who end, case when stt = 'approved' then now() end)
  returning id into tid;
  if img is not null then insert into custody_photos (tx_id, img) values (tid, img); end if;
  br := coalesce((select name from branches where id = c.branch), c.branch);
  if side = 'emp' then
    perform custody_push(custody_staff(c.branch),
      case when p_kind = 'expense' then '🧾 فاتورة عهدة' || case when p_taxable then '' else ' (غير ضريبية)' end || ' — ' || c.emp_name
           when p_kind = 'fund' then '💵 ' || c.emp_name || ' سجّل استلام مبلغ' else '↩️ ' || c.emp_name || ' سجّل إرجاع مبلغ' end,
      to_char(p_amount, 'FM999,999,990.00') || ' ر.س' || coalesce(' · ' || nullif(left(btrim(p_vendor), 40), ''), '') || ' · ' || br || ' — تحتاج مراجعتك',
      'cu-' || tid);
  elsif stt = 'pending' then
    perform custody_push(array[empu],
      case when p_kind = 'fund' then '💵 تم تسجيل عهدة عليك' else '↩️ تم تسجيل إرجاع مبلغ' end,
      to_char(p_amount, 'FM999,999,990.00') || ' ر.س — افتح التطبيق وأكّد الاستلام', 'cu-' || tid);
  end if;
  return tid;
end $$;

-- 6) المراجعة: المحاسب يعتمد/يرفض حركات الموظف، والموظف يأكّد حركات المحاسب
create or replace function public.custody_review(p_tx uuid, p_ok boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare t custody_tx; c custodies; who text := who_am_i(); n text := nullif(btrim(coalesce(p_note, '')), ''); me uuid := my_emp_id();
begin
  select * into t from custody_tx where id = p_tx for update;
  if t.id is null then raise exception 'الحركة غير موجودة'; end if;
  select * into c from custodies where id = t.custody_id;
  if c.status <> 'open' then raise exception 'العهدة مصفّاة ومقفلة'; end if;
  if t.status <> 'pending' then raise exception 'الحركة تمت مراجعتها مسبقاً'; end if;
  if t.side = 'emp' then
    if not custody_can(t.branch) then raise exception 'المراجعة للمحاسب أو الإدارة'; end if;
    if p_ok and t.kind = 'expense' and not t.has_photo then raise exception 'ما ينقبل مصروف بدون صورة فاتورة'; end if;
  else
    if not ((me is not null and me = t.emp_id) or is_admin()) then raise exception 'التأكيد يكون من الموظف صاحب العهدة'; end if;
  end if;
  if not p_ok and n is null then raise exception 'اكتب سبب الرفض'; end if;
  update custody_tx set status = case when p_ok then 'approved' else 'rejected' end, reviewed_by = who, reviewed_at = now(), review_note = n
  where id = p_tx;
  if t.side = 'emp' then
    perform custody_push(array[custody_emp_user(t.emp_id)],
      case when p_ok then '✅ تم اعتماد ' else '❌ تم رفض ' end || case t.kind when 'expense' then 'فاتورتك' when 'fund' then 'المبلغ المستلم' else 'المبلغ المرجع' end,
      to_char(t.amount, 'FM999,999,990.00') || ' ر.س' || coalesce(' — ' || left(n, 100), ''), 'cu-' || t.id);
  elsif not p_ok then
    perform custody_push(custody_staff(t.branch), '⚠️ ' || c.emp_name || ' ما أكّد استلام المبلغ',
      to_char(t.amount, 'FM999,999,990.00') || ' ر.س — ' || left(n, 100), 'cu-' || t.id);
  end if;
end $$;

-- 7) حذف حركة: صاحبها وهي بانتظار المراجعة، أو المالك
create or replace function public.custody_tx_delete(p_tx uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t custody_tx; me uuid := my_emp_id(); st_ text;
begin
  select * into t from custody_tx where id = p_tx;
  if t.id is null then return; end if;
  select status into st_ from custodies where id = t.custody_id;
  if is_owner() and st_ = 'open' then delete from custody_tx where id = p_tx; return; end if;
  if st_ <> 'open' then raise exception 'العهدة مصفّاة ومقفلة'; end if;
  if t.status <> 'pending' then raise exception 'الحركة تمت مراجعتها — الحذف للمالك فقط'; end if;
  if not ((t.side = 'emp' and me is not null and me = t.emp_id) or (t.side = 'acc' and custody_can(t.branch))) then raise exception 'ليس لديك صلاحية'; end if;
  delete from custody_tx where id = p_tx;
end $$;

-- 8) صورة الفاتورة
create or replace function public.custody_photo(p_tx uuid) returns text
language sql stable security definer set search_path = public as $$
  select p.img from custody_photos p join custody_tx t on t.id = p.tx_id
  where p.tx_id = p_tx and (custody_can(t.branch) or t.emp_id = my_emp_id())
$$;

-- 9) التصفية: ممنوعة إذا فيه حركة ما تراجعت أو مصروف بدون صورة
--    p_mode: 'settle' = تسوية الرصيد (الموظف رجّع الباقي / الشركة عوّضته) ثم إقفال
--            'carry'  = إقفال وترحيل الرصيد لعهدة جديدة لنفس الموظف
create or replace function public.custody_settle(p_custody uuid, p_mode text default 'settle', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare c custodies; b jsonb; bal numeric; who text := who_am_i(); nid uuid; today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  select * into c from custodies where id = p_custody for update;
  if c.id is null then raise exception 'العهدة غير موجودة'; end if;
  if not custody_can(c.branch) then raise exception 'التصفية للمحاسب أو الإدارة'; end if;
  if c.status <> 'open' then raise exception 'العهدة مصفّاة مسبقاً'; end if;
  if exists (select 1 from custody_tx where custody_id = c.id and status = 'pending') then
    raise exception 'ما تنصفى العهدة وفيه حركات بانتظار المراجعة أو التأكيد';
  end if;
  if exists (select 1 from custody_tx where custody_id = c.id and kind = 'expense' and status = 'approved' and not has_photo) then
    raise exception 'فيه مصروف بدون صورة فاتورة — ما تنصفى العهدة';
  end if;
  b := custody_balance(c.id); bal := (b->>'balance')::numeric;
  if p_mode = 'carry' then
    update custodies set status = 'closed', closed_at = now(), closed_by = who, close_note = left(coalesce(p_note, ''), 300),
      summary = b || jsonb_build_object('mode', 'carry', 'carried', bal) where id = c.id;
    insert into custodies (emp_id, emp_name, branch, title, opened_by) values (c.emp_id, c.emp_name, c.branch, c.title, who) returning id into nid;
    if bal > 0 then
      insert into custody_tx (custody_id, emp_id, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (nid, c.emp_id, c.branch, 'fund', 'cash', bal, today, 'رصيد مرحّل من العهدة رقم ' || c.no, 'approved', 'acc', who, who, now());
    elsif bal < 0 then
      insert into custody_tx (custody_id, emp_id, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (nid, c.emp_id, c.branch, 'return', 'cash', -bal, today, 'مبلغ مستحق للموظف مرحّل من العهدة رقم ' || c.no, 'approved', 'acc', who, who, now());
    end if;
  else
    if bal > 0 then
      insert into custody_tx (custody_id, emp_id, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (c.id, c.emp_id, c.branch, 'return', 'cash', bal, today, 'تسوية: الموظف أرجع الرصيد المتبقي', 'approved', 'acc', who, who, now());
    elsif bal < 0 then
      insert into custody_tx (custody_id, emp_id, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (c.id, c.emp_id, c.branch, 'fund', 'cash', -bal, today, 'تسوية: تعويض الموظف عن الزيادة', 'approved', 'acc', who, who, now());
    end if;
    update custodies set status = 'closed', closed_at = now(), closed_by = who, close_note = left(coalesce(p_note, ''), 300),
      summary = b || jsonb_build_object('mode', 'settle', 'settled', bal) where id = c.id;
  end if;
  perform custody_push(array[custody_emp_user(c.emp_id)], '📁 تم تصفية عهدتك',
    case when bal > 0 then 'المتبقي عندك ' || to_char(bal, 'FM999,999,990.00') || ' ر.س' || case when p_mode = 'carry' then ' — انرحّل لعهدة جديدة' else ' — تم استلامه' end
         when bal < 0 then 'لك ' || to_char(-bal, 'FM999,999,990.00') || ' ر.س' || case when p_mode = 'carry' then ' — انرحّل لعهدة جديدة' else ' — تم تعويضك' end
         else 'العهدة مطابقة ✓' end, 'cu-' || c.id);
  return b || jsonb_build_object('new_id', nid);
end $$;

-- حذف عهدة كاملة: المالك فقط
create or replace function public.custody_delete(p_custody uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_owner() then raise exception 'الحذف للمالك فقط'; end if;
  delete from custodies where id = p_custody;
end $$;

revoke all on function public.custody_open(uuid,text,numeric,text,date,text,text), public.custody_add(uuid,text,numeric,date,text,text,text,boolean,numeric,text,text,text),
  public.custody_review(uuid,boolean,text), public.custody_tx_delete(uuid), public.custody_photo(uuid), public.custody_settle(uuid,text,text),
  public.custody_delete(uuid), public.custody_balance(uuid), public.custody_push(uuid[],text,text,text), public.custody_staff(text), public.custody_emp_user(uuid) from public, anon;
grant execute on function public.custody_open(uuid,text,numeric,text,date,text,text), public.custody_add(uuid,text,numeric,date,text,text,text,boolean,numeric,text,text,text),
  public.custody_review(uuid,boolean,text), public.custody_tx_delete(uuid), public.custody_photo(uuid), public.custody_settle(uuid,text,text),
  public.custody_delete(uuid), public.custody_can(text), public.custody_emps() to authenticated;

select 'تم تفعيل العُهد النقدية ✓' as result;
