alter table public.clean_checks add column if not exists ai_rating smallint check (ai_rating between 1 and 5);
alter table public.clean_checks add column if not exists ai_items jsonb not null default '[]';
alter table public.clean_checks add column if not exists ai_note text not null default '';
alter table public.clean_checks add column if not exists ai_at timestamptz;
alter table public.clean_checks add column if not exists ai_err text not null default '';

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
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'br', branch, 's', shift, 't', title, 'p', true, 'o', sort, 'a', active) order by shift, sort, created_at)
                       from clean_items where branch is null or branch = any(bs)), '[]'),
    'checks', coalesce((select jsonb_agg(to_jsonb(c) order by c.branch, c.shift) from clean_checks c
                        where c.branch = any(bs) and ((c.shift <> 'weekly' and c.day = d) or (c.shift = 'weekly' and clean_week(c.day) = clean_week(d)))), '[]'),
    'hist', coalesce((select jsonb_agg(jsonb_build_object('b', branch, 'd', day, 's', shift, 'ok', ok, 't', total, 'r', coalesce(rating, ai_rating), 'ai', ai_rating, 'at', created_at)) from clean_checks
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
  if exists (select 1 from jsonb_array_elements(p_items) x where coalesce((x->>'ok')::boolean, false)
             and (jsonb_typeof(x->'phs') is distinct from 'array' or (select count(*) from jsonb_array_elements_text(x->'phs') z where btrim(z) <> '') < 3)) then
    raise exception 'كل بند تم لازم له 3 صور'; end if;
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
    by_name = excluded.by_name, updated_at = now(), rating = null, review = '', reviewed_by = '', reviewed_at = null,
    ai_rating = null, ai_items = '[]', ai_note = '', ai_at = null, ai_err = ''
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

create or replace function public.clean_ai_job(p_id uuid, p_force boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c clean_checks;
begin
  select * into c from clean_checks where id = p_id;
  if c.id is null then raise exception 'غير موجود'; end if;
  if not clean_can(c.branch, false) then raise exception 'غير مصرح'; end if;
  if c.ai_at is not null and not (p_force and coalesce(is_admin(), false)) then return jsonb_build_object('done', true); end if;
  return jsonb_build_object('id', c.id, 'branch', coalesce((select name from branches where id = c.branch), c.branch),
    'shift', case c.shift when 'open' then 'قائمة الفتح' when 'mid' then 'قائمة منتصف اليوم' when 'close' then 'قائمة الإغلاق' else 'التنظيف الأسبوعي' end,
    'items', c.items);
end $$;
grant execute on function public.clean_ai_job(uuid, boolean) to authenticated;

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
      'السيد/ مدير فرع ' || bn || '،' || chr(10) || chr(10) ||
      'حصلت ' || case c.shift when 'open' then 'قائمة نظافة الفتح' when 'mid' then 'قائمة نظافة منتصف اليوم' when 'close' then 'قائمة نظافة الإغلاق' else 'قائمة النظافة' end || ' ليوم ' || c.day ||
      ' على تقييم ' || repeat('★', r) || repeat('☆', 5 - r) || ' (' || r || ' من 5) بعد تحليل الصور وفق اشتراطات الصحة العامة للمنشآت الغذائية الصادرة عن وزارة البلديات والإسكان.' || chr(10) || chr(10) ||
      case when coalesce(p_note, '') <> '' then 'أبرز الملاحظات: ' || left(p_note, 600) || chr(10) || chr(10) else '' end ||
      'هذا التقييم يُحتسب في تقييم أداء الفرع وإدارته، ويعكس مستوى المتابعة والاهتمام. المطلوب معالجة الملاحظات فوراً ورفع المستوى في القائمة القادمة.' || chr(10) || '— نظام المتابعة الآلي',
      './?tab=clean', 'high', true, '{}');
  end if;
  if r <= 3 then
    select coalesce(array_agg(id), '{}') into o from profiles where role = 'owner' and coalesce(active, true);
    perform push_send(o, '🤖 نظافة ' || bn || ': ' || r || ' من 5', left(coalesce(nullif(p_note, ''), 'تقييم منخفض للنظافة'), 220), './?tab=clean', 'clean-ai-low-' || p_id);
  end if;
  return r;
end $$;
revoke all on function public.clean_ai_save(uuid, jsonb, text, text) from public, anon, authenticated;
grant execute on function public.clean_ai_save(uuid, jsonb, text, text) to service_role;

select 'تم: النظافة بثلاث صور إلزامية لكل بند + تقييم الذكاء الاصطناعي' as result;
