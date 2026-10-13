do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['sales','channels','income','wh','chicken','carcass','treasury','handover','employees','loans','fleet','maint','maint_sup','feedback','custody','hr','custody_holder']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

alter table public.custodies add column if not exists holder_user uuid references public.profiles(id) on delete set null;
alter table public.custodies alter column emp_id drop not null;
alter table public.custody_tx add column if not exists holder_user uuid;
alter table public.custody_tx alter column emp_id drop not null;
create index if not exists custodies_holder_idx on public.custodies (holder_user, status);

create or replace function public.custody_mine(p_emp uuid, p_holder uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((p_holder is not null and p_holder = auth.uid()) or (p_emp is not null and p_emp = my_emp_id()), false)
$$;

create or replace function public.custody_user(p_emp uuid, p_holder uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(p_holder, (select user_id from emp_accounts where emp_id = p_emp))
$$;

drop policy if exists cu_read on public.custodies;
create policy cu_read on public.custodies for select to authenticated using (custody_can(branch) or custody_mine(emp_id, holder_user));
drop policy if exists ct_read on public.custody_tx;
create policy ct_read on public.custody_tx for select to authenticated using (custody_can(branch) or custody_mine(emp_id, holder_user));

create or replace function public.custody_holders() returns table (id uuid, name text, branches text[])
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name, ''), p.username),
         coalesce((select array_agg(b.branch_id order by b.branch_id) from user_branches b where b.user_id = p.id), '{}')
  from profiles p
  where p.active and exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'custody_holder')
    and (is_admin() or has_section('custody'))
  order by 2
$$;

create or replace function public.custody_open_user(p_user uuid, p_branch text, p_title text, p_amount numeric default null, p_method text default 'transfer',
  p_date date default null, p_note text default '', p_img text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare pr profiles; cid uuid; who text := who_am_i();
begin
  select * into pr from profiles where id = p_user;
  if pr.id is null or not pr.active then raise exception 'المستخدم غير موجود أو موقوف'; end if;
  if not exists (select 1 from user_sections where user_id = p_user and section = 'custody_holder') then
    raise exception 'المستخدم ما عنده صلاحية «مسؤول العهدة»';
  end if;
  if p_branch is null or not custody_can(p_branch) then raise exception 'ليس لديك صلاحية على عهد هذا الفرع'; end if;
  if exists (select 1 from custodies where holder_user = p_user and status = 'open') then
    raise exception 'عنده عهدة مفتوحة — أضف المبلغ عليها أو صفّها أولاً';
  end if;
  insert into custodies (holder_user, emp_name, branch, title, opened_by)
  values (p_user, coalesce(nullif(pr.full_name, ''), pr.username), p_branch, left(coalesce(nullif(btrim(p_title), ''), 'عهدة نقدية'), 80), who)
  returning id into cid;
  if coalesce(p_amount, 0) > 0 then
    perform custody_add(cid, 'fund', p_amount, coalesce(p_date, (now() at time zone 'Asia/Riyadh')::date), p_method,
                        '', '', null, null, '', coalesce(p_note, ''), p_img);
  end if;
  return cid;
end $$;

create or replace function public.custody_add(p_custody uuid, p_kind text, p_amount numeric, p_date date, p_method text default null,
  p_vendor text default '', p_category text default '', p_taxable boolean default null, p_vat numeric default null,
  p_invoice text default '', p_note text default '', p_img text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c custodies; side text; stt text; tid uuid; who text := who_am_i(); img text := nullif(btrim(coalesce(p_img, '')), '');
  br text; empu uuid;
begin
  select * into c from custodies where id = p_custody for update;
  if c.id is null then raise exception 'العهدة غير موجودة'; end if;
  if c.status <> 'open' then raise exception 'العهدة مصفّاة ومقفلة'; end if;
  if custody_mine(c.emp_id, c.holder_user) then side := 'emp';
  elsif custody_can(c.branch) then side := 'acc';
  else raise exception 'ليس لديك صلاحية'; end if;
  if p_kind not in ('fund','expense','return') then raise exception 'نوع الحركة غير صحيح'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception 'اكتب المبلغ صحيح'; end if;
  if p_date is null or p_date > (now() at time zone 'Asia/Riyadh')::date + 1 or p_date < (now() at time zone 'Asia/Riyadh')::date - 400 then raise exception 'التاريخ غير صحيح'; end if;
  if p_kind = 'expense' and img is null then raise exception 'صورة الفاتورة إلزامية — صوّر الفاتورة وأرفقها'; end if;
  if img is not null and length(img) > 1200000 then raise exception 'الصورة كبيرة — صوّرها مرة ثانية'; end if;
  if p_kind = 'expense' and p_taxable is null then raise exception 'حدد هل الفاتورة ضريبية أو غير ضريبية'; end if;
  empu := custody_user(c.emp_id, c.holder_user);
  stt := case when side = 'emp' then 'pending'
              when p_kind = 'expense' then 'approved'
              when empu is null then 'approved'
              else 'pending' end;
  insert into custody_tx (custody_id, emp_id, holder_user, branch, kind, method, amount, date, vendor, category, taxable, vat, invoice_no, note,
                          has_photo, status, side, created_by, reviewed_by, reviewed_at)
  values (c.id, c.emp_id, c.holder_user, c.branch, p_kind, case when p_kind <> 'expense' then coalesce(p_method, 'transfer') end, round(p_amount, 2), p_date,
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

create or replace function public.custody_review(p_tx uuid, p_ok boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare t custody_tx; c custodies; who text := who_am_i(); n text := nullif(btrim(coalesce(p_note, '')), '');
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
    if not (custody_mine(c.emp_id, c.holder_user) or is_admin()) then raise exception 'التأكيد يكون من مسؤول العهدة'; end if;
  end if;
  if not p_ok and n is null then raise exception 'اكتب سبب الرفض'; end if;
  update custody_tx set status = case when p_ok then 'approved' else 'rejected' end, reviewed_by = who, reviewed_at = now(), review_note = n
  where id = p_tx;
  if t.side = 'emp' then
    perform custody_push(array[custody_user(c.emp_id, c.holder_user)],
      case when p_ok then '✅ تم اعتماد ' else '❌ تم رفض ' end || case t.kind when 'expense' then 'فاتورتك' when 'fund' then 'المبلغ المستلم' else 'المبلغ المرجع' end,
      to_char(t.amount, 'FM999,999,990.00') || ' ر.س' || coalesce(' — ' || left(n, 100), ''), 'cu-' || t.id);
  elsif not p_ok then
    perform custody_push(custody_staff(t.branch), '⚠️ ' || c.emp_name || ' ما أكّد استلام المبلغ',
      to_char(t.amount, 'FM999,999,990.00') || ' ر.س — ' || left(n, 100), 'cu-' || t.id);
  end if;
end $$;

create or replace function public.custody_tx_delete(p_tx uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t custody_tx; c custodies;
begin
  select * into t from custody_tx where id = p_tx;
  if t.id is null then return; end if;
  select * into c from custodies where id = t.custody_id;
  if is_owner() and c.status = 'open' then delete from custody_tx where id = p_tx; return; end if;
  if c.status <> 'open' then raise exception 'العهدة مصفّاة ومقفلة'; end if;
  if t.status <> 'pending' then raise exception 'الحركة تمت مراجعتها — الحذف للمالك فقط'; end if;
  if not ((t.side = 'emp' and custody_mine(c.emp_id, c.holder_user)) or (t.side = 'acc' and custody_can(t.branch))) then raise exception 'ليس لديك صلاحية'; end if;
  delete from custody_tx where id = p_tx;
end $$;

create or replace function public.custody_photo(p_tx uuid) returns text
language sql stable security definer set search_path = public as $$
  select p.img from custody_photos p join custody_tx t on t.id = p.tx_id join custodies c on c.id = t.custody_id
  where p.tx_id = p_tx and (custody_can(t.branch) or custody_mine(c.emp_id, c.holder_user))
$$;

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
    insert into custodies (emp_id, holder_user, emp_name, branch, title, opened_by) values (c.emp_id, c.holder_user, c.emp_name, c.branch, c.title, who) returning id into nid;
    if bal > 0 then
      insert into custody_tx (custody_id, emp_id, holder_user, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (nid, c.emp_id, c.holder_user, c.branch, 'fund', 'cash', bal, today, 'رصيد مرحّل من العهدة رقم ' || c.no, 'approved', 'acc', who, who, now());
    elsif bal < 0 then
      insert into custody_tx (custody_id, emp_id, holder_user, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (nid, c.emp_id, c.holder_user, c.branch, 'return', 'cash', -bal, today, 'مبلغ مستحق لمسؤول العهدة مرحّل من العهدة رقم ' || c.no, 'approved', 'acc', who, who, now());
    end if;
  else
    if bal > 0 then
      insert into custody_tx (custody_id, emp_id, holder_user, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (c.id, c.emp_id, c.holder_user, c.branch, 'return', 'cash', bal, today, 'تسوية: مسؤول العهدة أرجع الرصيد المتبقي', 'approved', 'acc', who, who, now());
    elsif bal < 0 then
      insert into custody_tx (custody_id, emp_id, holder_user, branch, kind, method, amount, date, note, status, side, created_by, reviewed_by, reviewed_at)
      values (c.id, c.emp_id, c.holder_user, c.branch, 'fund', 'cash', -bal, today, 'تسوية: تعويض مسؤول العهدة عن الزيادة', 'approved', 'acc', who, who, now());
    end if;
    update custodies set status = 'closed', closed_at = now(), closed_by = who, close_note = left(coalesce(p_note, ''), 300),
      summary = b || jsonb_build_object('mode', 'settle', 'settled', bal) where id = c.id;
  end if;
  perform custody_push(array[custody_user(c.emp_id, c.holder_user)], '📁 تم تصفية عهدتك',
    case when bal > 0 then 'المتبقي عندك ' || to_char(bal, 'FM999,999,990.00') || ' ر.س' || case when p_mode = 'carry' then ' — انرحّل لعهدة جديدة' else ' — تم استلامه' end
         when bal < 0 then 'لك ' || to_char(-bal, 'FM999,999,990.00') || ' ر.س' || case when p_mode = 'carry' then ' — انرحّل لعهدة جديدة' else ' — تم تعويضك' end
         else 'العهدة مطابقة ✓' end, 'cu-' || c.id);
  return b || jsonb_build_object('new_id', nid);
end $$;

create or replace function public.media_ok(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p text[] := string_to_array(coalesce(p_name, ''), '/'); k text; br text;
begin
  k := p[1]; br := p[2];
  if k is null or br is null then return false; end if;
  if k = 'custody' then
    return coalesce(custody_can(br), false) or coalesce(p[3] = my_emp_id()::text, false) or coalesce(p[3] = auth.uid()::text, false);
  elsif k = 'maint' then
    return coalesce(maint_role() in ('admin', 'sup') or (maint_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'fleet' then
    return coalesce(is_writer(), false) or coalesce(has_section('fleet') and br = any(my_branches()), false);
  elsif k in ('ded', 'emp') then
    return coalesce(employees_can(br), false);
  elsif k = 'hr' then
    return coalesce(hr_can(), false) or (not p_write and br <> 'co' and coalesce(employees_can(br), false));
  end if;
  return false;
exception when others then return false;
end $$;

revoke all on function public.custody_mine(uuid, uuid), public.custody_user(uuid, uuid) from public, anon;
grant execute on function public.custody_mine(uuid, uuid), public.custody_user(uuid, uuid) to authenticated;
grant execute on function public.custody_holders(), public.custody_open_user(uuid, text, text, numeric, text, date, text, text) to authenticated;

select 'تم تفعيل «مسؤول العهدة» ✓' as result;
