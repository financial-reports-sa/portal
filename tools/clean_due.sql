create table if not exists public.clean_cfg_br (
  branch text not null,
  shift  text not null check (shift in ('open', 'mid', 'close')),
  due    time not null,
  primary key (branch, shift)
);
alter table public.clean_cfg_br enable row level security;
revoke all on public.clean_cfg_br from anon, authenticated;

insert into public.clean_cfg_br (branch, shift, due)
select b.id, x.s, x.t::time from public.branches b
join (values ('az', 'open', '11:30'), ('az', 'mid', '20:30'), ('az', 'close', '03:00'),
             ('sh', 'open', '11:30'), ('sh', 'mid', '20:30'), ('sh', 'close', '03:00'),
             ('pc', 'open', '13:00'), ('pc', 'mid', '20:00'), ('pc', 'close', '04:00')) x(br, s, t) on x.br = b.id
on conflict (branch, shift) do update set due = excluded.due;

create or replace function public.clean_due(p_branch text, p_shift text) returns time
language sql stable security definer set search_path = public as $$
  select coalesce((select due from clean_cfg_br where branch = p_branch and shift = p_shift), (select due from clean_cfg where shift = p_shift))
$$;
revoke all on function public.clean_due(text, text) from public, anon;

create or replace function public.clean_cfg_save_br(p_branch text, p_shift text, p_due time) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_admin(), false) then raise exception 'للإدارة فقط'; end if;
  if p_shift not in ('open', 'mid', 'close') then raise exception 'نوع غير صحيح'; end if;
  if coalesce(p_branch, '') = '' then
    update clean_cfg set due = p_due where shift = p_shift;
  elsif p_due is null then
    delete from clean_cfg_br where branch = p_branch and shift = p_shift;
  else
    insert into clean_cfg_br (branch, shift, due) values (p_branch, p_shift, p_due)
    on conflict (branch, shift) do update set due = excluded.due;
  end if;
end $$;
grant execute on function public.clean_cfg_save_br(text, text, time) to authenticated;

create or replace function public.clean_board(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, att_bday()); bs text[];
begin
  if not (coalesce(is_writer(), false) or coalesce(has_section('clean'), false)) then raise exception 'غير مصرح'; end if;
  bs := case when coalesce(is_writer(), false) then (select array_agg(id) from branches) else coalesce(my_branches(), '{}') end;
  return jsonb_build_object(
    'day', d, 'today', att_bday(), 'week', clean_week(d), 'admin', coalesce(is_admin(), false), 'ro', clean_ro(), 'photos', 3,
    'branches', to_jsonb(bs),
    'cfg', coalesce((select jsonb_object_agg(shift, to_char(due, 'HH24:MI')) from clean_cfg), '{}'),
    'cfgb', coalesce((select jsonb_object_agg(branch, m) from (select branch, jsonb_object_agg(shift, to_char(due, 'HH24:MI')) m from clean_cfg_br group by branch) q), '{}'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'br', branch, 's', shift, 't', title, 'p', true, 'o', sort, 'a', active) order by shift, sort, created_at)
                       from clean_items where branch is null or branch = any(bs)), '[]'),
    'checks', coalesce((select jsonb_agg(to_jsonb(c) order by c.branch, c.shift) from clean_checks c
                        where c.branch = any(bs) and ((c.shift <> 'weekly' and c.day = d) or (c.shift = 'weekly' and clean_week(c.day) = clean_week(d)))), '[]'),
    'hist', coalesce((select jsonb_agg(jsonb_build_object('b', branch, 'd', day, 's', shift, 'ok', ok, 't', total, 'r', coalesce(rating, ai_rating), 'ai', ai_rating, 'at', created_at)) from clean_checks
                      where branch = any(bs) and day > d - 31 and day <= d), '[]'));
end $$;
grant execute on function public.clean_board(date) to authenticated;

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
      select ((d + q.t) + case when q.t < time '05:00' then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh' into due from (select clean_due(b.id, sh) t) q where q.t is not null;
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
        perform alert_send('clean2:' || b.id || ':' || sh || ':' || d, 'clean_late2', null, u, 'إشعار تقصير رسمي: ' || lbl || ' متأخرة أكثر من ساعتين',
          'السيد/ مدير فرع ' || b.name || ' المحترم،' || nl || nl ||
          'مضى أكثر من ساعتين على موعد ' || lbl || ' (' || alert_t12(due) || ') ولم تُسجَّل حتى الآن رغم الإشعار السابق.' || nl || nl ||
          'تم تسجيل ذلك تقصيراً في سجل أداء الفرع ورفعه للإدارة، واستمرار التقصير يستوجب اتخاذ الإجراء الإداري اللازم.' || nl || nl ||
          'المطلوب تسجيل القائمة فوراً مع الصور المطلوبة.' || nl || '— إدارة العمليات', './?tab=clean', 'urgent', true);
        perform alert_send('cleanrep:' || b.id || ':' || sh || ':' || d, 'clean_rep', null, alert_owners(), 'تقرير رقابي: تقصير في نظافة فرع ' || b.name,
          'تقرير رقابي · النظافة' || nl || nl ||
          'الفرع: ' || b.name || nl ||
          'التاريخ: ' || to_char(d, 'YYYY-MM-DD') || nl ||
          'القائمة: ' || lbl || nl ||
          'الموعد المحدد: ' || alert_t12(due) || nl ||
          'الحالة: لم تُسجَّل، ومضى على موعدها أكثر من ساعتين' || nl ||
          'المسؤول: ' || coalesce(nullif(alert_names(u), ''), 'مدير الفرع') || nl || nl ||
          'الإجراءات المتخذة آلياً:' || nl ||
          '1. إشعار رسمي لمدير الفرع عند انتهاء الموعد (' || alert_t12(due) || ').' || nl ||
          '2. إشعار تقصير رسمي بعد مرور ساعتين دون تسجيل.' || nl || nl ||
          'وحتى وقت إصدار هذا التقرير (' || alert_t12(now()) || ') لم يتم تسجيل القائمة.' || nl || '— نظام المتابعة الآلي', './?tab=clean', 'high', false);
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.clean_alerts_run() from public, anon, authenticated;

create or replace function public.clean_ai_save(p_id uuid, p_items jsonb, p_note text, p_err text default '') returns int
language plpgsql volatile security definer set search_path = public as $$
declare c clean_checks; r int; o uuid[]; bn text;
begin
  select * into c from clean_checks where id = p_id;
  if c.id is null then return null; end if;
  if coalesce(p_err, '') <> '' then
    update clean_checks set ai_err = left(p_err, 300) where id = p_id;
    return null;
  end if;
  select round(avg(case when coalesce((it->>'ok')::boolean, false)
                        then greatest(1, least(5, coalesce((select (a->>'score')::numeric from jsonb_array_elements(p_items) a where (a->>'i')::int = (q.n - 1)::int limit 1), 3)))
                        else 1 end))::int
    into r
  from jsonb_array_elements(c.items) with ordinality q(it, n);
  r := greatest(1, least(5, coalesce(r, 1)));
  update clean_checks set ai_rating = r, ai_items = coalesce(p_items, '[]'), ai_note = left(coalesce(p_note, ''), 1500), ai_at = now(), ai_err = '' where id = p_id;
  bn := coalesce((select name from branches where id = c.branch), c.branch);
  if c.by_uid is not null then
    perform push_send(array[c.by_uid], '🤖 تقييم النظافة: ' || repeat('★', r) || repeat('☆', 5 - r), left(coalesce(nullif(p_note, ''), 'تم تحليل صور القائمة'), 200), './?tab=clean', 'clean-ai-' || p_id);
  end if;
  if r <= 3 and to_regprocedure('public.alert_send(text,text,uuid,uuid[],text,text,text,text,boolean,uuid[])') is not null then
    perform alert_send('cleanlow:' || p_id, 'clean_low', null, alert_mgrs(c.branch, array['clean']), 'إشعار رسمي: تقييم نظافة منخفض (' || r || ' من 5)',
      'السيد/ مدير فرع ' || bn || ' المحترم،' || chr(10) || chr(10) ||
      'حصلت ' || case c.shift when 'open' then 'قائمة نظافة الفتح' when 'mid' then 'قائمة نظافة منتصف اليوم' when 'close' then 'قائمة نظافة الإغلاق' else 'قائمة النظافة' end || ' ليوم ' || c.day ||
      ' على تقييم ' || repeat('★', r) || repeat('☆', 5 - r) || ' (' || r || ' من 5) بعد تحليل الصور وفق اشتراطات الصحة العامة للمنشآت الغذائية الصادرة عن وزارة البلديات والإسكان.' || chr(10) || chr(10) ||
      case when coalesce(p_note, '') <> '' then 'أبرز الملاحظات: ' || left(p_note, 600) || chr(10) || chr(10) else '' end ||
      'هذا التقييم يُحتسب في تقييم أداء الفرع وإدارته، ويعكس مستوى المتابعة والاهتمام. المطلوب معالجة الملاحظات فوراً ورفع المستوى في القائمة القادمة.' || chr(10) || '— إدارة العمليات',
      './?tab=clean', 'high', true, '{}');
  end if;
  if r <= 3 and to_regprocedure('public.alert_send(text,text,uuid,uuid[],text,text,text,text,boolean,uuid[])') is not null then
    perform alert_send('cleanlowrep:' || p_id, 'clean_rep', null, alert_owners(), 'تقرير رقابي: تقييم نظافة منخفض في فرع ' || bn || ' (' || r || ' من 5)',
      'تقرير رقابي · تقييم النظافة' || chr(10) || chr(10) ||
      'الفرع: ' || bn || chr(10) ||
      'التاريخ: ' || to_char(c.day, 'YYYY-MM-DD') || chr(10) ||
      'القائمة: ' || case c.shift when 'open' then 'قائمة نظافة الفتح' when 'mid' then 'قائمة نظافة منتصف اليوم' when 'close' then 'قائمة نظافة الإغلاق' else 'قائمة النظافة' end || chr(10) ||
      'التقييم: ' || repeat('★', r) || repeat('☆', 5 - r) || ' (' || r || ' من 5)' || chr(10) ||
      'البنود المنفذة: ' || c.ok || ' من ' || c.total || chr(10) ||
      'سجّلها: ' || coalesce(nullif(c.by_name, ''), '—') || chr(10) ||
      'المسؤول: ' || coalesce(nullif(alert_names(alert_mgrs(c.branch, array['clean'])), ''), 'مدير الفرع') || chr(10) || chr(10) ||
      case when coalesce(p_note, '') <> '' then 'ملاحظات التحليل: ' || left(p_note, 800) || chr(10) || chr(10) else '' end ||
      'تم التقييم آلياً بتحليل صور البنود وفق اشتراطات الصحة العامة للمنشآت الغذائية، وأُرسل إشعار رسمي لمدير الفرع بمعالجة الملاحظات.' || chr(10) || '— نظام المتابعة الآلي',
      './?tab=clean', 'high', false, '{}');
  end if;
  return r;
end $$;
revoke all on function public.clean_ai_save(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.clean_ai_save(uuid, jsonb, text, text) to service_role;

select 'تم: مواعيد النظافة لكل فرع' as result, (select string_agg(coalesce(b.name, b.id) || ': ' || to_char(public.clean_due(b.id, 'open'), 'HH24:MI') || ' / ' || to_char(public.clean_due(b.id, 'mid'), 'HH24:MI') || ' / ' || to_char(public.clean_due(b.id, 'close'), 'HH24:MI'), ' · ') from public.branches b) as dues;
