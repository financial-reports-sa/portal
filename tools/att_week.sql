alter table public.att_shift add column if not exists wk jsonb;
alter table public.att_shift add column if not exists fri_start_t time;
alter table public.att_shift add column if not exists fri_end_t time;
alter table public.att_shift add column if not exists fri_start2_t time;
alter table public.att_shift add column if not exists fri_end2_t time;
alter table public.att_shift add column if not exists thu_start_t time;
alter table public.att_shift add column if not exists thu_end_t time;
alter table public.att_shift add column if not exists thu_start2_t time;
alter table public.att_shift add column if not exists thu_end2_t time;

create or replace function public.att_set_week(p_emp uuid, p_wk jsonb, p_off int[] default '{}', p_grace int default 10) returns void
language plpgsql security definer set search_path = public as $$
declare o att_shift; u uuid; d int; L jsonb; fd int; txt text; offs text; nm text[] := array['الأحد','الإثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
begin
  if not att_ok(p_emp) then raise exception 'ليس لديك صلاحية على هذا الموظف'; end if;
  if p_wk is null or jsonb_typeof(p_wk) <> 'object' then raise exception 'بيانات الدوام غير صحيحة'; end if;
  p_off := coalesce(p_off, '{}');
  for d in 0..6 loop
    if d = any(p_off) then continue; end if;
    L := p_wk -> d::text;
    if L is null or jsonb_typeof(L) <> 'array' or jsonb_array_length(L) not between 1 and 2 then raise exception 'حدد دوام يوم % أو خلّه إجازة', nm[d + 1]; end if;
    if (L->0->>0) is null or (L->0->>1) is null then raise exception 'حدد بداية ونهاية الشفت يوم %', nm[d + 1]; end if;
    perform (L->0->>0)::time, (L->0->>1)::time;
    if jsonb_array_length(L) = 2 then
      if (L->1->>0) is null or (L->1->>1) is null then raise exception 'حدد بداية ونهاية الشفت الثاني يوم %', nm[d + 1]; end if;
      perform (L->1->>0)::time, (L->1->>1)::time;
    end if;
    if fd is null then fd := d; end if;
  end loop;
  if fd is null then raise exception 'لازم يكون فيه يوم دوام واحد على الأقل'; end if;
  select jsonb_object_agg(key, value) into p_wk from jsonb_each(p_wk) where key ~ '^[0-6]$' and not (key::int = any(p_off));
  L := p_wk -> fd::text;
  select * into o from att_shift where emp_id = p_emp;
  insert into att_shift (emp_id, start_t, end_t, start2_t, end2_t, off_days, grace, wk, updated_by)
  values (p_emp, (L->0->>0)::time, (L->0->>1)::time, (L->1->>0)::time, (L->1->>1)::time, p_off, coalesce(p_grace, 10), p_wk, att_who())
  on conflict (emp_id) do update set start_t = excluded.start_t, end_t = excluded.end_t, start2_t = excluded.start2_t, end2_t = excluded.end2_t,
    off_days = excluded.off_days, grace = excluded.grace, wk = excluded.wk,
    fri_start_t = null, fri_end_t = null, fri_start2_t = null, fri_end2_t = null, thu_start_t = null, thu_end_t = null, thu_start2_t = null, thu_end2_t = null,
    updated_by = excluded.updated_by, updated_at = now();
  if o.emp_id is not null and o.wk is not distinct from p_wk and o.off_days = p_off and o.grace = coalesce(p_grace, 10) then return; end if;
  select user_id into u from emp_accounts where emp_id = p_emp;
  if u is null then return; end if;
  select string_agg(dn || ': ' || t, ' · ' order by md) into txt from (
    select t, string_agg(nm[x + 1], '، ' order by x) dn, min(x) md from (
      select x, (select string_agg(att_tfmt((v->>0)::time) || ' – ' || att_tfmt((v->>1)::time), ' و ' order by i) from jsonb_array_elements(p_wk -> x::text) with ordinality a(v, i)) t
      from generate_series(0, 6) x where p_wk ? x::text) q group by t) g;
  select string_agg(nm[x + 1], '، ' order by x) into offs from unnest(p_off) x where x between 0 and 6;
  perform push_send(array[u], case when o.emp_id is null then '🗓️ تم تحديد دوامك' else '🗓️ تم تعديل دوامك' end,
    'دوامك: ' || coalesce(txt, '') || case when offs is not null then ' · إجازتك: ' || offs else '' end || ' — من ' || att_who(), './?tab=me', 'shift-' || p_emp);
end $$;
revoke all on function public.att_set_week(uuid, jsonb, int[], int) from public, anon;
grant execute on function public.att_set_week(uuid, jsonb, int[], int) to authenticated;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.att_me()'::regprocedure);
  if position('''wk''' in d) = 0 and position('''grace'', s.grace,' in d) > 0 then
    d := replace(d, '''grace'', s.grace,', '''grace'', s.grace, ''wk'', s.wk,');
    execute d;
  end if;
  d := pg_get_functiondef('public.att_alerts_run()'::regprocedure);
  if position('s.wk' in d) = 0 then
    if position('e2 := s.fri_end2_t; end if;' in d) = 0 then raise exception 'att_alerts_run: لم أجد موضع التعديل'; end if;
    d := replace(d, 'e2 := s.fri_end2_t; end if;', 'e2 := s.fri_end2_t; end if;
      if s.wk is not null and s.wk ? (extract(dow from d)::int)::text then s1 := (s.wk -> (extract(dow from d)::int)::text -> 0 ->> 0)::time; e1 := (s.wk -> (extract(dow from d)::int)::text -> 0 ->> 1)::time; s2 := (s.wk -> (extract(dow from d)::int)::text -> 1 ->> 0)::time; e2 := (s.wk -> (extract(dow from d)::int)::text -> 1 ->> 1)::time; end if;');
    execute d;
  end if;
end $$;

select 'تم: الدوام اليومي (كل يوم بشفته أو إجازة)' as result;
