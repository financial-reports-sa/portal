do $$
declare lst text[];
begin
  select array(select distinct x from unnest(
           array['clean']
           || coalesce((select array_agg(distinct section) from public.user_sections), '{}')
           || coalesce((select ('{' || (regexp_match(pg_get_constraintdef(c.oid), '\{([^}]*)\}'))[1] || '}')::text[]
                       from pg_constraint c where c.conname = 'user_sections_section_check'), '{}')) x) into lst;
  alter table public.user_sections drop constraint if exists user_sections_section_check;
  execute format('alter table public.user_sections add constraint user_sections_section_check check (section = any (%L::text[]))', lst);
end $$;

create table if not exists public.clean_items (
  id         uuid primary key default gen_random_uuid(),
  branch     text,
  shift      text not null check (shift in ('open', 'mid', 'close', 'weekly')),
  title      text not null,
  need_photo boolean not null default false,
  sort       int not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.clean_items enable row level security;
revoke all on public.clean_items from anon, authenticated;

create table if not exists public.clean_checks (
  id          uuid primary key default gen_random_uuid(),
  branch      text not null,
  day         date not null,
  shift       text not null check (shift in ('open', 'mid', 'close', 'weekly')),
  items       jsonb not null default '[]',
  total       int not null default 0,
  ok          int not null default 0,
  by_uid      uuid,
  by_name     text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  rating      smallint check (rating between 1 and 5),
  review      text not null default '',
  reviewed_by text not null default '',
  reviewed_at timestamptz,
  unique (branch, day, shift)
);
create index if not exists clean_checks_day_idx on public.clean_checks (day, branch);
alter table public.clean_checks enable row level security;
revoke all on public.clean_checks from anon, authenticated;

create table if not exists public.clean_cfg (
  shift text primary key check (shift in ('open', 'mid', 'close', 'weekly')),
  due   time not null
);
insert into public.clean_cfg (shift, due) values ('open', '12:00'), ('close', '04:00'), ('weekly', '22:00') on conflict (shift) do nothing;
alter table public.clean_cfg enable row level security;
revoke all on public.clean_cfg from anon, authenticated;

alter table public.clean_items drop constraint if exists clean_items_shift_check;
alter table public.clean_items add constraint clean_items_shift_check check (shift in ('open', 'mid', 'close', 'weekly'));
alter table public.clean_checks drop constraint if exists clean_checks_shift_check;
alter table public.clean_checks add constraint clean_checks_shift_check check (shift in ('open', 'mid', 'close', 'weekly'));
alter table public.clean_cfg drop constraint if exists clean_cfg_shift_check;
alter table public.clean_cfg add constraint clean_cfg_shift_check check (shift in ('open', 'mid', 'close', 'weekly'));
insert into public.clean_cfg (shift, due) values ('mid', '21:00') on conflict (shift) do nothing;

insert into public.clean_items (branch, shift, title, need_photo, sort)
select null, x.s, x.t, x.p, x.o from (values
  ('mid', 'الصالة والطاولات نظيفة بعد ذروة الغداء', true, 1),
  ('mid', 'دورات المياه نظيفة ومزودة بالصابون والمناديل', true, 2),
  ('mid', 'أسطح المطبخ ومنطقة التجهيز نظيفة', true, 3),
  ('mid', 'أرضية المطبخ والصالة ممسوحة', false, 4),
  ('mid', 'سلال النفايات فُرّغت وبأكياس جديدة', false, 5),
  ('mid', 'الموظفين ملتزمين بالزي والنظافة الشخصية', false, 6)
) x(s, t, p, o)
where not exists (select 1 from public.clean_items where shift = 'mid');

insert into public.clean_items (branch, shift, title, need_photo, sort)
select null, x.s, x.t, x.p, x.o from (values
  ('open', 'أرضية الصالة نظيفة وجافة', true, 1),
  ('open', 'الطاولات والكراسي ممسوحة ومرتبة', false, 2),
  ('open', 'دورات المياه نظيفة ومزودة بالصابون والمناديل', true, 3),
  ('open', 'المطبخ: الأسطح ولوحات التقطيع نظيفة ومعقمة', true, 4),
  ('open', 'الثلاجات نظيفة والأكل مغطى ومؤرخ', false, 5),
  ('open', 'منطقة الكاشير مرتبة ونظيفة', false, 6),
  ('open', 'المدخل والواجهة الخارجية نظيفة', false, 7),
  ('open', 'الموظفين بالزي الرسمي وغطاء الشعر والقفازات', true, 8),
  ('open', 'سلال النفايات فاضية وبأكياس جديدة', false, 9),
  ('close', 'القلايات نظيفة والزيت مصفّى أو متغيّر', true, 1),
  ('close', 'الشفاط والفلاتر نظيفة', false, 2),
  ('close', 'الأرضيات ممسوحة بالمطهر', true, 3),
  ('close', 'الأسطح والمغاسل والمصارف نظيفة', false, 4),
  ('close', 'الثلاجات مرتبة والأكل مغطى ومؤرخ', false, 5),
  ('close', 'النفايات طالعة برا الفرع', false, 6),
  ('close', 'دورات المياه نظيفة', false, 7),
  ('close', 'الأجهزة مطفية والغاز مقفل', true, 8),
  ('weekly', 'تنظيف عميق للشفاط والقنوات', true, 1),
  ('weekly', 'تنظيف خلف وتحت الأجهزة', true, 2),
  ('weekly', 'غسل الثلاجات والفريزرات من الداخل', true, 3),
  ('weekly', 'تنظيف الجدران والسقف والإضاءة', false, 4),
  ('weekly', 'فحص مصائد الحشرات ومكافحتها', false, 5),
  ('weekly', 'تنظيف خزان المياه والفلاتر', false, 6)
) x(s, t, p, o)
where not exists (select 1 from public.clean_items where shift <> 'mid');

delete from public.clean_items where shift = 'weekly' and not exists (select 1 from public.clean_checks where shift = 'weekly');
update public.clean_items set active = false where shift = 'weekly';

create or replace function public.clean_ro() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r boolean := false;
begin
  if to_regclass('public.user_ro') is not null then
    execute 'select exists (select 1 from user_ro where user_id = auth.uid() and section = ''clean'')' into r;
  end if;
  return coalesce(r, false);
end $$;

create or replace function public.clean_can(p_branch text, p_write boolean default false) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(is_writer(), false)
      or (coalesce(has_section('clean'), false) and p_branch = any(coalesce(my_branches(), '{}')) and (not p_write or not clean_ro()))
$$;

create or replace function public.clean_week(p_day date) returns date
language sql immutable as $$ select p_day - ((extract(dow from p_day)::int + 1) % 7) $$;

create or replace function public.clean_board(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, att_bday()); bs text[];
begin
  if not (coalesce(is_writer(), false) or coalesce(has_section('clean'), false)) then raise exception 'غير مصرح'; end if;
  bs := case when coalesce(is_writer(), false) then (select array_agg(id) from branches) else coalesce(my_branches(), '{}') end;
  return jsonb_build_object(
    'day', d, 'today', att_bday(), 'week', clean_week(d), 'admin', coalesce(is_admin(), false), 'ro', clean_ro(),
    'branches', to_jsonb(bs),
    'cfg', coalesce((select jsonb_object_agg(shift, to_char(due, 'HH24:MI')) from clean_cfg), '{}'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'br', branch, 's', shift, 't', title, 'p', need_photo, 'o', sort, 'a', active) order by shift, sort, created_at)
                       from clean_items where branch is null or branch = any(bs)), '[]'),
    'checks', coalesce((select jsonb_agg(to_jsonb(c) order by c.branch, c.shift) from clean_checks c
                        where c.branch = any(bs) and ((c.shift <> 'weekly' and c.day = d) or (c.shift = 'weekly' and clean_week(c.day) = clean_week(d)))), '[]'),
    'hist', coalesce((select jsonb_agg(jsonb_build_object('b', branch, 'd', day, 's', shift, 'ok', ok, 't', total, 'r', rating, 'at', created_at)) from clean_checks
                      where branch = any(bs) and day > d - 31 and day <= d), '[]'));
end $$;
grant execute on function public.clean_board(date) to authenticated;

create or replace function public.clean_submit(p_branch text, p_shift text, p_items jsonb) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare d date := att_bday(); rid uuid; nm text; t int; k int; bad text; o uuid[];
begin
  if not clean_can(p_branch, true) then raise exception 'ليس لديك صلاحية على نظافة هذا الفرع'; end if;
  if p_shift not in ('open', 'mid', 'close', 'weekly') then raise exception 'نوع غير صحيح'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'القائمة فاضية'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x where (x->>'p')::boolean and coalesce(x->>'ph', '') = '' and coalesce((x->>'ok')::boolean, false)) then
    raise exception 'فيه بنود تحتاج صورة'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) x where not coalesce((x->>'ok')::boolean, false) and coalesce(btrim(x->>'n'), '') = '') then
    raise exception 'اكتب سبب كل بند ما تم'; end if;
  select coalesce(nullif(full_name, ''), username) into nm from profiles where id = auth.uid();
  t := jsonb_array_length(p_items);
  select count(*) into k from jsonb_array_elements(p_items) x where coalesce((x->>'ok')::boolean, false);
  if p_shift = 'weekly' then
    delete from clean_checks where branch = p_branch and shift = 'weekly' and clean_week(day) = clean_week(d) and day <> d;
  end if;
  insert into clean_checks (branch, day, shift, items, total, ok, by_uid, by_name)
  values (p_branch, d, p_shift, p_items, t, k, auth.uid(), coalesce(nm, ''))
  on conflict (branch, day, shift) do update set items = excluded.items, total = excluded.total, ok = excluded.ok, by_uid = excluded.by_uid,
    by_name = excluded.by_name, updated_at = now(), rating = null, review = '', reviewed_by = '', reviewed_at = null
  returning id into rid;
  if k < t then
    select string_agg('• ' || (x->>'t') || ' — ' || coalesce(x->>'n', ''), chr(10)) into bad from jsonb_array_elements(p_items) x where not coalesce((x->>'ok')::boolean, false);
    select coalesce(array_agg(id), '{}') into o from profiles where role = 'owner' and coalesce(active, true);
    perform push_send(o, '⚠️ نظافة ' || coalesce((select name from branches where id = p_branch), p_branch) || ': ' || (t - k) || ' بند ما تم',
      left(case p_shift when 'open' then 'قائمة الفتح' when 'mid' then 'قائمة منتصف اليوم' when 'close' then 'قائمة الإغلاق' else 'التنظيف الأسبوعي' end || ' — ' || coalesce(nm, '') || chr(10) || bad, 240), './?tab=clean', 'clean-' || p_branch);
  end if;
  return rid;
end $$;
grant execute on function public.clean_submit(text, text, jsonb) to authenticated;

create or replace function public.clean_review(p_id uuid, p_rating int, p_note text default '') returns void
language plpgsql volatile security definer set search_path = public as $$
declare c clean_checks; nm text;
begin
  if not coalesce(is_admin(), false) then raise exception 'التقييم للإدارة فقط'; end if;
  select * into c from clean_checks where id = p_id;
  if c.id is null then raise exception 'غير موجود'; end if;
  select coalesce(nullif(full_name, ''), username) into nm from profiles where id = auth.uid();
  update clean_checks set rating = greatest(1, least(5, p_rating)), review = coalesce(btrim(p_note), ''), reviewed_by = coalesce(nm, ''), reviewed_at = now() where id = p_id;
  if c.by_uid is not null then
    perform push_send(array[c.by_uid], 'تقييم النظافة: ' || repeat('★', greatest(1, least(5, p_rating))) || repeat('☆', 5 - greatest(1, least(5, p_rating))),
      coalesce(nullif(btrim(p_note), ''), 'تمت مراجعة قائمة النظافة'), './?tab=clean', 'clean-rev-' || p_id);
  end if;
end $$;
grant execute on function public.clean_review(uuid, int, text) to authenticated;

create or replace function public.clean_item_save(p_id uuid, p_branch text, p_shift text, p_title text, p_photo boolean, p_sort int, p_active boolean) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare rid uuid;
begin
  if not coalesce(is_admin(), false) then raise exception 'تعديل البنود للإدارة فقط'; end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'اكتب البند'; end if;
  if p_id is null then
    insert into clean_items (branch, shift, title, need_photo, sort, active) values (nullif(p_branch, ''), p_shift, btrim(p_title), coalesce(p_photo, false), coalesce(p_sort, 99), coalesce(p_active, true)) returning id into rid;
  else
    update clean_items set branch = nullif(p_branch, ''), shift = p_shift, title = btrim(p_title), need_photo = coalesce(p_photo, false), sort = coalesce(p_sort, sort), active = coalesce(p_active, true) where id = p_id returning id into rid;
  end if;
  return rid;
end $$;
grant execute on function public.clean_item_save(uuid, text, text, text, boolean, int, boolean) to authenticated;

create or replace function public.clean_cfg_save(p_shift text, p_due time) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_admin(), false) then raise exception 'للإدارة فقط'; end if;
  update clean_cfg set due = p_due where shift = p_shift;
end $$;
grant execute on function public.clean_cfg_save(text, time) to authenticated;

create or replace function public.media_ok(p_name text, p_write boolean) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare p text[] := string_to_array(coalesce(p_name, ''), '/'); k text; br text; e uuid; mid bigint;
begin
  k := p[1]; br := p[2];
  if k is null or br is null then return false; end if;
  begin e := p[3]::uuid; exception when others then e := null; end;
  if k = 'custody' then
    return coalesce(custody_can(br), false) or coalesce(p[3] = my_emp_id()::text, false) or coalesce(p[3] = auth.uid()::text, false);
  elsif k = 'maint' then
    return coalesce(maint_role() in ('admin', 'sup') or (maint_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'fleet' then
    return coalesce(is_writer(), false) or coalesce(has_section('fleet') and br = any(my_branches()), false);
  elsif k in ('ded', 'emp') then
    return coalesce(employees_can(br), false);
  elsif k = 'hr' then
    return coalesce(hr_can(), false)
        or (not p_write and br <> 'co' and coalesce(employees_can(br), false) and (e is null or coalesce(emp_ok(e), false)));
  elsif k = 'att' then
    return coalesce(p[3] = my_emp_id()::text, false)
        or (not p_write and (coalesce(hr_can(), false) or (coalesce(att_branch_ok(br), false) and (e is null or coalesce(emp_ok(e), false)))));
  elsif k = 'purch' then
    return coalesce(pr_role() in ('admin', 'sup') or (pr_role() = 'mgr' and br = any(my_branches())), false);
  elsif k = 'msg' then
    begin mid := br::bigint; exception when others then return false; end;
    if p_write then return exists (select 1 from msgs where id = mid and sender = auth.uid()); end if;
    return coalesce(msg_can_view(mid), false);
  elsif k = 'clean' then
    return coalesce(clean_can(br, p_write), false);
  end if;
  return false;
exception when others then return false;
end $$;

create or replace function public.clean_alerts_run() returns int
language plpgsql volatile security definer set search_path = public as $$
declare d date := att_bday(); b record; sh text; due timestamptz; n int := 0; u uuid[]; lbl text; bn text; nl text := chr(10); late int;
begin
  if to_regprocedure('public.alert_send(text,text,uuid,uuid[],text,text,text,text,boolean,uuid[])') is null and to_regprocedure('public.alert_send(text,text,uuid,uuid[],text,text,text,text,boolean)') is null then return 0; end if;
  for b in select br.id, br.name from branches br
           where exists (select 1 from user_sections us join user_branches ub on ub.user_id = us.user_id and ub.branch_id = br.id
                         join profiles p on p.id = us.user_id and coalesce(p.active, true) and p.role = 'user' where us.section = 'clean') loop
    u := alert_mgrs(b.id, array['clean']);
    if cardinality(u) = 0 then continue; end if;
    foreach sh in array array['open', 'mid', 'close'] loop
      if sh = 'weekly' then
        if extract(dow from d) <> 4 then continue; end if;
        if exists (select 1 from clean_checks where branch = b.id and shift = 'weekly' and clean_week(day) = clean_week(d)) then continue; end if;
      else
        if exists (select 1 from clean_checks where branch = b.id and shift = sh and day = d) then continue; end if;
      end if;
      select ((d + c.due) + case when c.due < time '05:00' then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh' into due from clean_cfg c where c.shift = sh;
      if due is null or now() < due then continue; end if;
      if due < coalesce((select since from alert_cfg where id = 1), now()) then continue; end if;
      if d <= ((select min(created_at) from clean_items) at time zone 'Asia/Riyadh' - interval '5 hours')::date then continue; end if;
      late := floor(extract(epoch from (now() - due)) / 60)::int;
      lbl := case sh when 'open' then 'قائمة نظافة الفتح' when 'mid' then 'قائمة نظافة منتصف اليوم' when 'close' then 'قائمة نظافة الإغلاق' else 'التنظيف الأسبوعي' end;
      if alert_send('clean:' || b.id || ':' || sh || ':' || d, 'clean_late', null, u, 'إشعار رسمي: ' || lbl || ' لم تُسجَّل',
        'السيد/ مدير فرع ' || b.name || ' المحترم،' || nl || nl ||
        'انتهى موعد ' || lbl || ' الساعة ' || alert_t12(due) || ' ولم يتم تسجيلها حتى الآن.' || nl || nl ||
        'النظافة مسؤوليتكم المباشرة، وهي من أهم معايير تقييم أدائكم وإدارتكم للفرع. والتأخر في تسجيلها يُعد تقصيراً يُسجَّل عليكم ويُرفع للإدارة.' || nl || nl ||
        'نأمل المبادرة بإنجاز القائمة وتسجيلها فوراً مع الصور المطلوبة.' || nl || '— إدارة العمليات',
        './?tab=clean', 'high', true) then n := n + 1; end if;
      if late >= 120 then
        perform alert_send('clean2:' || b.id || ':' || sh || ':' || d, 'clean_late2', null, u || alert_owners(), 'إشعار تقصير رسمي: ' || lbl || ' متأخرة أكثر من ساعتين',
          'السيد/ مدير فرع ' || b.name || '،' || nl || nl ||
          'مضى أكثر من ساعتين على موعد ' || lbl || ' (' || alert_t12(due) || ') ولم تُسجَّل حتى الآن رغم التنبيه السابق.' || nl || nl ||
          'تم تسجيل ذلك تقصيراً في سجل أداء الفرع ورفعه للإدارة. نذكّر بأن الالتزام بالنظافة معيار أساسي في تقييم إدارة الفرع، واستمرار التقصير يستوجب اتخاذ الإجراء الإداري اللازم.' || nl || nl ||
          'المطلوب تسجيل القائمة فوراً.' || nl || '— نظام المتابعة الآلي', './?tab=clean', 'urgent', true);
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.clean_alerts_run() from public, anon, authenticated;

do $$
begin
  begin perform cron.unschedule('auto-clean'); exception when others then null; end;
  perform cron.schedule('auto-clean', '*/15 * * * *', 'select public.clean_alerts_run()');
end $$;

select 'تم: النظافة (قوائم الفتح ومنتصف اليوم والإغلاق + الصور + التقييم + تنبيهات التأخير)' as result;
