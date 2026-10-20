create table if not exists public.alert_log (
  key        text primary key,
  kind       text not null,
  emp_id     uuid,
  users      uuid[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists alert_log_emp_idx on public.alert_log (emp_id, created_at);
alter table public.alert_log enable row level security;
revoke all on public.alert_log from anon, authenticated;

create table if not exists public.alert_cfg (
  id    int primary key default 1 check (id = 1),
  att   boolean not null default true,
  rets  boolean not null default true,
  ops   boolean not null default true,
  since timestamptz not null default now()
);
alter table public.alert_cfg add column if not exists since timestamptz not null default now();
insert into public.alert_cfg (id) values (1) on conflict (id) do nothing;
alter table public.alert_cfg enable row level security;
revoke all on public.alert_cfg from anon, authenticated;

create or replace function public.alert_t12(p_ts timestamptz) returns text
language sql immutable as $$
  select to_char(p_ts at time zone 'Asia/Riyadh', 'FMHH12:MI') || case when extract(hour from p_ts at time zone 'Asia/Riyadh') < 12 then ' ص' else ' م' end
$$;

create or replace function public.alert_dur(p_min int, p_bn boolean default false) returns text
language sql immutable as $$
  select case when p_bn then
           case when p_min >= 60 then (p_min / 60) || ' ঘণ্টা' || case when p_min % 60 > 0 then ' ' || (p_min % 60) || ' মিনিট' else '' end else p_min || ' মিনিট' end
         else
           case when p_min >= 60 then
             case p_min / 60 when 1 then 'ساعة' when 2 then 'ساعتين' else (p_min / 60) || case when p_min / 60 <= 10 then ' ساعات' else ' ساعة' end end ||
             case when p_min % 60 > 0 then ' و' || (p_min % 60) || ' دقيقة' else '' end
           else p_min || ' دقيقة' end
         end
$$;

drop function if exists public.alert_send(text, text, uuid, uuid[], text, text, text, text, boolean);
create or replace function public.alert_send(p_key text, p_kind text, p_emp uuid, p_users uuid[], p_title text, p_body text, p_url text, p_prio text default 'high', p_ack boolean default true, p_cc uuid[] default '{}')
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare u uuid[]; c uuid[]; mid bigint; snd uuid;
begin
  u := array(select distinct x from unnest(coalesce(p_users, '{}')) x where x is not null);
  if cardinality(u) = 0 then return false; end if;
  c := array(select distinct x from unnest(coalesce(p_cc, '{}')) x where x is not null and not (x = any(u)));
  insert into alert_log (key, kind, emp_id, users) values (p_key, p_kind, p_emp, u) on conflict (key) do nothing;
  if not found then return false; end if;
  select id into snd from profiles where role = 'owner' order by created_at limit 1;
  if snd is null then select id into snd from profiles where role = 'admin' order by created_at limit 1; end if;
  insert into msgs (kind, prio, title, body, need_ack, target, sender, sender_name)
  values ('warn', p_prio, p_title, p_body, p_ack, jsonb_build_object('auto', p_kind), snd, 'نظام المتابعة الآلي')
  returning id into mid;
  insert into msg_rcpt (msg_id, user_id, name, kind)
  select mid, p.id, coalesce(nullif(p.full_name, ''), p.username), case when p.role in ('owner', 'admin') then 'admin' when p.role = 'employee' then 'emp' else 'mgr' end
  from profiles p where p.id = any(u)
  on conflict do nothing;
  insert into msg_rcpt (msg_id, user_id, name, kind)
  select mid, p.id, coalesce(nullif(p.full_name, ''), p.username), 'cc'
  from profiles p where p.id = any(c) and coalesce(p.active, true)
  on conflict do nothing;
  perform push_send(u, p_title, left(split_part(p_body, chr(10) || '—' || chr(10), 1), 240), p_url, 'auto-' || p_kind);
  return true;
exception when others then
  return false;
end $$;
revoke all on function public.alert_send(text, text, uuid, uuid[], text, text, text, text, boolean, uuid[]) from public, anon, authenticated;

create or replace function public.alert_mgrs(p_branch text, p_secs text[]) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
declare r uuid[];
begin
  if to_regclass('public.user_ro') is not null then
    execute 'select coalesce(array_agg(distinct p.id), ''{}'') from profiles p
             join user_sections us on us.user_id = p.id and us.section = any($2)
             join user_branches ub on ub.user_id = p.id and ub.branch_id = $1
             where coalesce(p.active, true) and p.role = ''user''
               and not exists (select 1 from user_ro ro where ro.user_id = p.id and ro.section = us.section)'
      into r using p_branch, p_secs;
  else
    select coalesce(array_agg(distinct p.id), '{}') into r from profiles p
      join user_sections us on us.user_id = p.id and us.section = any(p_secs)
      join user_branches ub on ub.user_id = p.id and ub.branch_id = p_branch
     where coalesce(p.active, true) and p.role = 'user';
  end if;
  return r;
end $$;
revoke all on function public.alert_mgrs(text, text[]) from public, anon, authenticated;

create or replace function public.alert_sup(p_sec text) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p.id), '{}') from profiles p join user_sections us on us.user_id = p.id and us.section = p_sec
  where coalesce(p.active, true) and p.role in ('user', 'admin')
$$;
revoke all on function public.alert_sup(text) from public, anon, authenticated;

create or replace function public.alert_owners() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from profiles where role = 'owner' and coalesce(active, true)
$$;
revoke all on function public.alert_owners() from public, anon, authenticated;

create or replace function public.alert_ops(p_sec text) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
declare r uuid[];
begin
  if to_regclass('public.user_ro') is not null then
    execute 'select coalesce(array_agg(distinct p.id), ''{}'') from profiles p join user_sections us on us.user_id = p.id and us.section = $1
             where coalesce(p.active, true) and p.role in (''user'', ''admin'')
               and not exists (select 1 from user_ro ro where ro.user_id = p.id and ro.section = $1)' into r using p_sec;
  else
    r := alert_sup(p_sec);
  end if;
  return r;
end $$;
revoke all on function public.alert_ops(text) from public, anon, authenticated;

create or replace function public.alert_ro(p_views text[], p_sec text, p_skip uuid[]) returns uuid[]
language plpgsql stable security definer set search_path = public as $$
declare r uuid[];
begin
  select coalesce(array_agg(distinct p.id), '{}') into r from profiles p join user_sections us on us.user_id = p.id and us.section = any(p_views)
   where coalesce(p.active, true) and p.role in ('user', 'admin') and not (p.id = any(coalesce(p_skip, '{}')));
  if to_regclass('public.user_ro') is not null then
    execute 'select coalesce(array_agg(distinct x), ''{}'') from (select unnest($1) x union select p.id from profiles p join user_ro ro on ro.user_id = p.id and ro.section = $2
             where coalesce(p.active, true) and p.role in (''user'', ''admin'') and not (p.id = any(coalesce($3, ''{}'')))) t' into r using r, p_sec, p_skip;
  end if;
  return r;
end $$;
revoke all on function public.alert_ro(text[], text, uuid[]) from public, anon, authenticated;

create or replace function public.alert_names(p_users uuid[]) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(string_agg(coalesce(nullif(full_name, ''), username), '، ' order by full_name), '') from profiles where id = any(coalesce(p_users, '{}'))
$$;
revoke all on function public.alert_names(uuid[]) from public, anon, authenticated;

create or replace function public.att_alerts_run() returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  d date; e record; s att_shift; st1 timestamptz; en1 timestamptz; st2 timestamptz; en2 timestamptz; s1 time; e1 time; s2 time; e2 time;
  r1 attendance; r2 attendance; mins int; n int := 0; nm text; to_u uuid[]; dt text; bn text; sep text := chr(10) || '—' || chr(10); nl text := chr(10);
  sig text := chr(10) || '— إدارة الموارد البشرية'; mcnt record; mon text; t0 timestamptz := coalesce((select since from alert_cfg where id = 1), now());
begin
  if not coalesce((select att from alert_cfg where id = 1), true) then return 0; end if;
  for d in select x::date from generate_series(att_bday() - 1, att_bday(), interval '1 day') x loop
    for e in
      select em.id, em.name, em.branch, a.user_id
      from employees em
      join emp_accounts a on a.emp_id = em.id
      join profiles p on p.id = a.user_id and coalesce(p.active, true)
      where em.status = 'active'
        and not coalesce((select exempt from att_emp x where x.emp_id = em.id), false)
        and not exists (select 1 from leaves l where l.emp_id = em.id and l.status = 'approved' and d between l.d_from and l.d_to)
        and exists (select 1 from att_places(em.id))
        and coalesce((select count_from from att_cfg c where c.branch = em.branch), (select min(day) from attendance t where t.branch = em.branch)) <= d
    loop
      select * into s from att_shift where emp_id = e.id;
      if s.emp_id is null or s.start_t is null or s.end_t is null then continue; end if;
      if extract(dow from d)::int = any(coalesce(s.off_days, '{}')) then continue; end if;
      s1 := s.start_t; e1 := s.end_t; s2 := s.start2_t; e2 := s.end2_t;
      if extract(dow from d) = 5 and s.fri_start_t is not null then s1 := s.fri_start_t; e1 := s.fri_end_t; s2 := s.fri_start2_t; e2 := s.fri_end2_t; end if;
      st1 := ((d + s1) + case when s1 < time '05:00' then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh';
      en1 := ((d + e1) at time zone 'Asia/Riyadh'); while en1 <= st1 loop en1 := en1 + interval '1 day'; end loop;
      st2 := null; en2 := null;
      if s2 is not null and e2 is not null then
        st2 := ((d + s2) + case when s2 < time '05:00' then interval '1 day' else interval '0' end) at time zone 'Asia/Riyadh';
        en2 := ((d + e2) at time zone 'Asia/Riyadh'); while en2 <= st2 loop en2 := en2 + interval '1 day'; end loop;
      end if;
      select * into r1 from attendance where emp_id = e.id and day = d and coalesce(seq, 1) = 1;
      select * into r2 from attendance where emp_id = e.id and day = d and seq = 2;
      nm := e.name; dt := to_char(d, 'YYYY-MM-DD');
      to_u := array[e.user_id] || alert_mgrs(e.branch, array['att', 'hr']);

      if r1.id is null and r2.id is null and now() > st1 + interval '60 minutes' and st1 + interval '60 minutes' > t0 then
        if alert_send('att:abs:' || e.id || ':' || dt, 'att_abs', e.id, to_u, 'تنبيه رسمي: غياب عن الدوام',
          'السيد/ ' || nm || '،' || nl || 'لم يُسجَّل حضورك يوم ' || dt || ' في دوامك المحدد (' || alert_t12(st1) || ' – ' || alert_t12(en1) || ')، ويُعتبر ذلك غياباً بدون عذر.' || nl ||
          'يُحتسب الغياب بخصم أجر يوم كامل. إذا كان لديك عذر مقبول، قدّمه لمديرك المباشر خلال 24 ساعة، وإلا يُعتمد الغياب.' || sig || sep ||
          'সতর্কবার্তা: অনুপস্থিতি' || nl || dt || ' তারিখে আপনার ডিউটিতে (' || to_char(st1 at time zone 'Asia/Riyadh', 'HH24:MI') || ' – ' || to_char(en1 at time zone 'Asia/Riyadh', 'HH24:MI') || ') কোনো উপস্থিতি রেকর্ড হয়নি। এটি বিনা কারণে অনুপস্থিতি হিসেবে গণ্য হবে এবং এক দিনের বেতন কাটা হবে। গ্রহণযোগ্য কারণ থাকলে ২৪ ঘণ্টার মধ্যে আপনার ম্যানেজারকে জানান।',
          './?tab=me') then n := n + 1; end if;
      end if;

      if r1.id is not null and r1.in_at is not null and not coalesce(r1.manual, false) then
        mins := floor(extract(epoch from (r1.in_at - st1)) / 60)::int - coalesce(s.grace, 10);
        if mins > 0 and r1.in_at > t0 then
          mins := mins + coalesce(s.grace, 10);
          if alert_send('att:late:' || e.id || ':' || dt || ':1', 'att_late', e.id, to_u, 'تنبيه رسمي: تأخير عن الدوام',
            'السيد/ ' || nm || '،' || nl || 'سُجّل حضورك يوم ' || dt || ' الساعة ' || alert_t12(r1.in_at) || '، بينما يبدأ دوامك الساعة ' || alert_t12(st1) || '، بتأخير قدره ' || alert_dur(mins) || '.' || nl ||
            'يُعدّ الالتزام بمواعيد الدوام واجباً وظيفياً، وسيتم احتساب الخصم وفق لائحة الحضور والانصراف. نأمل عدم تكرار ذلك.' || sig || sep ||
            'সতর্কবার্তা: দেরিতে উপস্থিতি' || nl || 'আপনি ' || dt || ' তারিখে ' || to_char(r1.in_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ উপস্থিতি দিয়েছেন, অথচ আপনার ডিউটি শুরু ' || to_char(st1 at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ। দেরি: ' || alert_dur(mins, true) || '। সময়মতো উপস্থিত হওয়া বাধ্যতামূলক; নিয়ম অনুযায়ী বেতন কাটা হবে। আর পুনরাবৃত্তি করবেন না।',
            './?tab=me') then n := n + 1; end if;
        end if;
        if r1.out_at is not null then
          mins := floor(extract(epoch from (en1 - r1.out_at)) / 60)::int;
          if mins >= 5 and r1.out_at > t0 then
            if alert_send('att:early:' || e.id || ':' || dt || ':1', 'att_early', e.id, to_u, 'تنبيه رسمي: انصراف قبل نهاية الدوام',
              'السيد/ ' || nm || '،' || nl || 'سُجّل انصرافك يوم ' || dt || ' الساعة ' || alert_t12(r1.out_at) || '، قبل نهاية دوامك الساعة ' || alert_t12(en1) || ' بـ ' || alert_dur(mins) || '، دون إذن مسبق.' || nl ||
              'الانصراف قبل نهاية الدوام مخالفة، وسيتم احتساب الخصم وفق اللائحة.' || sig || sep ||
              'সতর্কবার্তা: আগে চলে যাওয়া' || nl || dt || ' তারিখে আপনি ' || to_char(r1.out_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ বের হয়েছেন, অথচ ডিউটি শেষ ' || to_char(en1 at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ (' || alert_dur(mins, true) || ' আগে), অনুমতি ছাড়া। নিয়ম অনুযায়ী বেতন কাটা হবে।',
              './?tab=me') then n := n + 1; end if;
          end if;
        elsif now() > en1 + interval '2 hours' and en1 + interval '2 hours' > t0 then
          if alert_send('att:noout:' || e.id || ':' || dt || ':1', 'att_noout', e.id, to_u, 'تنبيه رسمي: عدم تسجيل الانصراف',
            'السيد/ ' || nm || '،' || nl || 'سجّلت حضورك يوم ' || dt || ' الساعة ' || alert_t12(r1.in_at) || '، ولم تسجّل انصرافك حتى الآن.' || nl ||
            'تسجيل الانصراف إلزامي. سجّله فوراً أو راجع مديرك المباشر لتصحيحه، وإلا يُعتبر الشفت ناقصاً ويُحتسب عليك.' || sig || sep ||
            'সতর্কবার্তা: প্রস্থান রেকর্ড নেই' || nl || dt || ' তারিখে আপনি ' || to_char(r1.in_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ উপস্থিতি দিয়েছেন কিন্তু এখনো প্রস্থান রেকর্ড করেননি। প্রস্থান রেকর্ড করা বাধ্যতামূলক। এখনই রেকর্ড করুন বা সংশোধনের জন্য ম্যানেজারের সাথে যোগাযোগ করুন, নইলে শিফট অসম্পূর্ণ ধরা হবে।',
            './?tab=me') then n := n + 1; end if;
        end if;
      end if;

      if st2 is not null then
        if r1.id is not null and r2.id is null and now() > st2 + interval '60 minutes' and st2 + interval '60 minutes' > t0 then
          if alert_send('att:sh2:' || e.id || ':' || dt, 'att_sh2', e.id, to_u, 'تنبيه رسمي: عدم حضور الشفت الثاني',
            'السيد/ ' || nm || '،' || nl || 'حضرت الشفت الأول يوم ' || dt || '، ولم يُسجَّل حضورك في الشفت الثاني (' || alert_t12(st2) || ' – ' || alert_t12(en2) || ').' || nl ||
            'سيُحتسب الشفت الناقص بالخصم وفق اللائحة، ما لم يُقدَّم عذر مقبول لمديرك المباشر.' || sig || sep ||
            'সতর্কবার্তা: দ্বিতীয় শিফটে অনুপস্থিতি' || nl || dt || ' তারিখে আপনি প্রথম শিফটে উপস্থিত ছিলেন, কিন্তু দ্বিতীয় শিফটে (' || to_char(st2 at time zone 'Asia/Riyadh', 'HH24:MI') || ' – ' || to_char(en2 at time zone 'Asia/Riyadh', 'HH24:MI') || ') উপস্থিতি রেকর্ড হয়নি। গ্রহণযোগ্য কারণ না দিলে নিয়ম অনুযায়ী বেতন কাটা হবে।',
            './?tab=me') then n := n + 1; end if;
        end if;
        if r2.id is not null and r2.in_at is not null and not coalesce(r2.manual, false) then
          mins := floor(extract(epoch from (r2.in_at - st2)) / 60)::int - coalesce(s.grace, 10);
          if mins > 0 and r2.in_at > t0 then
            mins := mins + coalesce(s.grace, 10);
            if alert_send('att:late:' || e.id || ':' || dt || ':2', 'att_late', e.id, to_u, 'تنبيه رسمي: تأخير عن الدوام (الشفت الثاني)',
              'السيد/ ' || nm || '،' || nl || 'سُجّل حضورك يوم ' || dt || ' للشفت الثاني الساعة ' || alert_t12(r2.in_at) || '، بينما يبدأ الشفت الساعة ' || alert_t12(st2) || '، بتأخير قدره ' || alert_dur(mins) || '.' || nl ||
              'يُعدّ الالتزام بمواعيد الدوام واجباً وظيفياً، وسيتم احتساب الخصم وفق لائحة الحضور والانصراف. نأمل عدم تكرار ذلك.' || sig || sep ||
              'সতর্কবার্তা: দেরিতে উপস্থিতি (দ্বিতীয় শিফট)' || nl || 'আপনি ' || dt || ' তারিখে ' || to_char(r2.in_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ উপস্থিতি দিয়েছেন, অথচ শিফট শুরু ' || to_char(st2 at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ। দেরি: ' || alert_dur(mins, true) || '। নিয়ম অনুযায়ী বেতন কাটা হবে। আর পুনরাবৃত্তি করবেন না।',
              './?tab=me') then n := n + 1; end if;
          end if;
          if r2.out_at is not null then
            mins := floor(extract(epoch from (en2 - r2.out_at)) / 60)::int;
            if mins >= 5 and r2.out_at > t0 then
              if alert_send('att:early:' || e.id || ':' || dt || ':2', 'att_early', e.id, to_u, 'تنبيه رسمي: انصراف قبل نهاية الدوام (الشفت الثاني)',
                'السيد/ ' || nm || '،' || nl || 'سُجّل انصرافك يوم ' || dt || ' الساعة ' || alert_t12(r2.out_at) || '، قبل نهاية الشفت الثاني الساعة ' || alert_t12(en2) || ' بـ ' || alert_dur(mins) || '، دون إذن مسبق.' || nl ||
                'الانصراف قبل نهاية الدوام مخالفة، وسيتم احتساب الخصم وفق اللائحة.' || sig || sep ||
                'সতর্কবার্তা: আগে চলে যাওয়া (দ্বিতীয় শিফট)' || nl || dt || ' তারিখে আপনি ' || to_char(r2.out_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ বের হয়েছেন, অথচ শিফট শেষ ' || to_char(en2 at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ (' || alert_dur(mins, true) || ' আগে), অনুমতি ছাড়া। নিয়ম অনুযায়ী বেতন কাটা হবে।',
                './?tab=me') then n := n + 1; end if;
            end if;
          elsif now() > en2 + interval '2 hours' and en2 + interval '2 hours' > t0 then
            if alert_send('att:noout:' || e.id || ':' || dt || ':2', 'att_noout', e.id, to_u, 'تنبيه رسمي: عدم تسجيل الانصراف (الشفت الثاني)',
              'السيد/ ' || nm || '،' || nl || 'سجّلت حضورك يوم ' || dt || ' للشفت الثاني الساعة ' || alert_t12(r2.in_at) || '، ولم تسجّل انصرافك حتى الآن.' || nl ||
              'تسجيل الانصراف إلزامي. سجّله فوراً أو راجع مديرك المباشر لتصحيحه، وإلا يُعتبر الشفت ناقصاً ويُحتسب عليك.' || sig || sep ||
              'সতর্কবার্তা: প্রস্থান রেকর্ড নেই (দ্বিতীয় শিফট)' || nl || dt || ' তারিখে আপনি ' || to_char(r2.in_at at time zone 'Asia/Riyadh', 'HH24:MI') || '-এ উপস্থিতি দিয়েছেন কিন্তু এখনো প্রস্থান রেকর্ড করেননি। এখনই রেকর্ড করুন বা ম্যানেজারের সাথে যোগাযোগ করুন, নইলে শিফট অসম্পূর্ণ ধরা হবে।',
              './?tab=me') then n := n + 1; end if;
          end if;
        end if;
      end if;

      mon := to_char(d, 'YYYY-MM');
      select count(*) filter (where kind = 'att_late') l, count(*) filter (where kind = 'att_abs') a, count(*) filter (where kind = 'att_early') x, count(*) filter (where kind = 'att_sh2') h
        into mcnt from alert_log where emp_id = e.id and kind in ('att_late', 'att_abs', 'att_early', 'att_sh2') and to_char(created_at at time zone 'Asia/Riyadh', 'YYYY-MM') = mon;
      if mcnt.l + mcnt.a + mcnt.x + mcnt.h >= 3 then
        if alert_send('att:warn:' || e.id || ':' || mon, 'att_warn', e.id, to_u || alert_owners(), 'إنذار كتابي',
          'السيد/ ' || nm || '،' || nl || 'تكررت مخالفاتك لمواعيد الدوام خلال شهر ' || mon || ': ' || mcnt.l || ' تأخير، و' || mcnt.a || ' غياب، و' || mcnt.x || ' خروج مبكر' || case when mcnt.h > 0 then '، و' || mcnt.h || ' شفت ناقص' else '' end || '.' || nl ||
          'يُعد هذا إنذاراً رسمياً. استمرار المخالفة يعرّضك لإجراءات نظامية أشد وفق لائحة العمل.' || sig || sep ||
          'লিখিত সতর্কবার্তা' || nl || mon || ' মাসে আপনার উপস্থিতির নিয়ম বারবার লঙ্ঘন হয়েছে: দেরি ' || mcnt.l || ', অনুপস্থিতি ' || mcnt.a || ', আগে চলে যাওয়া ' || mcnt.x || case when mcnt.h > 0 then ', অসম্পূর্ণ শিফট ' || mcnt.h else '' end || '। এটি আনুষ্ঠানিক সতর্কবার্তা। লঙ্ঘন চালিয়ে গেলে আরও কঠোর ব্যবস্থা নেওয়া হবে।',
          './?tab=me', 'urgent') then n := n + 1; end if;
      end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.att_alerts_run() from public, anon, authenticated;

create or replace function public.ret_alerts_run() returns int
language plpgsql volatile security definer set search_path = public as $$
declare b record; u record; n int := 0; lst text; age int; slot text; to_u uuid[]; nl text := chr(10);
begin
  if not coalesce((select rets from alert_cfg where id = 1), true) then return 0; end if;
  slot := floor(extract(epoch from now()) / 10800)::bigint::text;
  for b in
    select r.branch, count(*) c, min(r.created_at) oldest, sum(r.amount) amt
    from cashier_returns r where r.status = 'pending' and r.created_at < now() - interval '60 minutes'
    group by r.branch
  loop
    age := floor(extract(epoch from (now() - b.oldest)) / 60)::int;
    select string_agg('• فاتورة ' || x.inv_no || ' — ' || to_char(x.amount, 'FM999G990D00') || ' ر.س — ' || coalesce(nullif(x.cashier, ''), 'كاشير') || ' (منذ ' || alert_dur(floor(extract(epoch from (now() - x.created_at)) / 60)::int) || ')', nl order by x.created_at)
      into lst from (select * from cashier_returns where branch = b.branch and status = 'pending' order by created_at limit 10) x;
    to_u := alert_mgrs(b.branch, array['rets']);
    if cardinality(to_u) = 0 then to_u := alert_owners(); end if;
    if age >= 720 then to_u := to_u || alert_owners(); end if;
    for u in select p.id, coalesce(nullif(p.full_name, ''), p.username) nm from profiles p where p.id = any(to_u) loop
      if alert_send('ret:' || b.branch || ':' || u.id || ':' || slot, 'ret_pending', null, array[u.id],
        'تذكير: مرتجعات بانتظار موافقتك',
        'السيد/ ' || u.nm || '،' || nl || 'يوجد ' || b.c || ' مرتجع في فرع ' || coalesce((select name from branches where id = b.branch), b.branch) || ' بانتظار الموافقة، بإجمالي ' || to_char(b.amt, 'FM999G990D00') || ' ر.س، أقدمها منذ ' || alert_dur(age) || ':' || nl || lst || nl ||
        'المطلوب مراجعتها والبت فيها الآن من شاشة «مرتجعات الكاشيرات».' || case when age >= 720 then nl || 'تجاوز التأخير 12 ساعة وتم إبلاغ الإدارة.' else '' end || nl || '— نظام المتابعة الآلي',
        './?tab=rets', case when age >= 720 then 'urgent' else 'high' end, false) then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.ret_alerts_run() from public, anon, authenticated;

create or replace function public.ops_alerts_run() returns int
language plpgsql volatile security definer set search_path = public as $$
declare u record; n int := 0; lst text; cnt int; dk text := to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD'); nl text := chr(10);
  rep text := ''; to_u uuid[]; cc_u uuid[]; nms text; mc int := 0; pc int := 0; bc int := 0;
begin
  if not coalesce((select ops from alert_cfg where id = 1), true) then return 0; end if;

  select count(*), string_agg('• #' || m.no || ' ' || m.title || ' — ' || coalesce((select name from branches where id = m.branch), m.branch) || ' — ' ||
           case m.status when 'new' then 'لم يُسند لفني' when 'assigned' then 'مُسند ولم يبدأ' when 'progress' then 'قيد التنفيذ ولم يُنجز' when 'hold' then 'متوقف' else m.status end ||
           ' منذ ' || greatest(1, floor(extract(epoch from (now() - m.created_at)) / 86400))::int || ' يوم' || case when m.due_date < current_date then ' (تجاوز الموعد ' || m.due_date || ')' else '' end, nl order by m.created_at)
    into mc, lst
  from maint_requests m
  where (m.status = 'new' and m.created_at < now() - interval '24 hours')
     or (m.status in ('assigned', 'progress', 'hold') and (m.due_date < (now() at time zone 'Asia/Riyadh')::date or coalesce(m.started_at, m.assigned_at, m.created_at) < now() - interval '3 days'));
  if mc > 0 then
    to_u := alert_ops('maint_sup'); cc_u := alert_ro(array['maint_view'], 'maint_sup', to_u); nms := alert_names(to_u);
    if cardinality(to_u) > 0 and alert_send('ops:maint:' || dk, 'maint_late', null, to_u, 'إشعار تقصير: طلبات صيانة متأخرة',
        case when cardinality(to_u) > 1 then 'السادة/ ' else 'السيد/ ' end || nms || '،' || nl || 'لوحظ وجود ' || mc || ' طلب صيانة متأخر لم يتم إتمامه حتى تاريخه:' || nl || lst || nl ||
        'يُعد التأخر في إتمام الطلبات تقصيراً في أداء المهام الموكلة إليك، وسيُرفع تقرير بذلك للإدارة. المطلوب إتمام الطلبات أو تحديث حالتها مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
        './?tab=maint', 'urgent', true, cc_u) then n := n + 1; end if;
    rep := rep || '🔧 الصيانة: ' || mc || ' طلب متأخر — وُجّه إلى: ' || coalesce(nullif(nms, ''), 'لا يوجد مسؤول صيانة محدد بصلاحية عمليات') || nl || lst || nl || nl;
  end if;

  select count(*), string_agg('• #' || r.no || ' ' || r.title || ' — ' || coalesce((select name from branches where id = r.branch), r.branch) || ' — ' ||
           case r.status when 'new' then 'لم يبدأ التنفيذ' when 'progress' then 'قيد التنفيذ ولم يُشترَ' else r.status end ||
           ' منذ ' || greatest(1, floor(extract(epoch from (now() - r.created_at)) / 86400))::int || ' يوم' || case when r.priority = 'urgent' then ' ⚠️ عاجل' else '' end ||
           case when r.need_by < (now() at time zone 'Asia/Riyadh')::date then ' (مطلوب قبل ' || r.need_by || ')' else '' end, nl order by r.created_at)
    into pc, lst
  from purch_requests r
  where (r.status = 'new' and r.created_at < now() - case when r.priority = 'urgent' then interval '4 hours' else interval '24 hours' end)
     or (r.status = 'progress' and (r.need_by < (now() at time zone 'Asia/Riyadh')::date or coalesce(r.started_at, r.created_at) < now() - interval '3 days'));
  if pc > 0 then
    to_u := alert_ops('purch_sup'); cc_u := alert_ro(array['purch_view'], 'purch_sup', to_u); nms := alert_names(to_u);
    if cardinality(to_u) > 0 and alert_send('ops:purch:' || dk, 'purch_late', null, to_u, 'إشعار تقصير: طلبات شراء متأخرة',
        case when cardinality(to_u) > 1 then 'السادة/ ' else 'السيد/ ' end || nms || '،' || nl || 'لوحظ وجود ' || pc || ' طلب شراء متأخر لم يتم إتمامه حتى تاريخه:' || nl || lst || nl ||
        'يُعد التأخر في إتمام الطلبات تقصيراً في أداء المهام الموكلة إليك، وسيُرفع تقرير بذلك للإدارة. المطلوب إتمام الطلبات أو تحديث حالتها مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
        './?tab=purch', 'urgent', true, cc_u) then n := n + 1; end if;
    rep := rep || '🛒 المشتريات: ' || pc || ' طلب متأخر — وُجّه إلى: ' || coalesce(nullif(nms, ''), 'لا يوجد مسؤول مشتريات محدد بصلاحية عمليات') || nl || lst || nl || nl;
  end if;

  for u in
    select p.id, coalesce(nullif(p.full_name, ''), p.username) nm, count(*) c,
           string_agg('• ' || k || ' #' || no || ' ' || title, nl) lst
    from (
      select 'صيانة' k, m.no, m.title, m.requested_uid uid from maint_requests m where m.status = 'done' and m.done_at < now() - interval '48 hours'
      union all
      select 'شراء', r.no, r.title, r.requested_uid from purch_requests r where r.status = 'bought' and r.bought_at < now() - interval '48 hours'
    ) x join profiles p on p.id = x.uid and coalesce(p.active, true)
    group by p.id, p.full_name, p.username
  loop
    if alert_send('ops:close:' || u.id || ':' || dk, 'ops_close', null, array[u.id], 'تذكير: طلبات بانتظار تأكيد الاستلام',
      'السيد/ ' || u.nm || '،' || nl || 'يوجد ' || u.c || ' طلب منفّذ بانتظار تأكيدك للاستلام وإغلاق الطلب:' || nl || u.lst || nl ||
      'المطلوب تأكيد الاستلام أو الاعتراض مع ذكر السبب اليوم.' || nl || '— نظام المتابعة الآلي',
      './?tab=maint', 'high', false) then n := n + 1; bc := bc + u.c; end if;
  end loop;

  if rep <> '' then
    perform alert_send('ops:report:' || dk, 'ops_report', null, alert_owners(), 'تقرير يومي: الطلبات المتأخرة',
      'تقرير المتابعة الآلية ليوم ' || dk || nl || nl || rep || 'تم إرسال إشعار تقصير رسمي للمسؤول المختص، ومن لديه صلاحية القراءة يطّلع عليه فقط.' || nl || '— نظام المتابعة الآلي',
      './?tab=maint', 'high', false);
  end if;
  return n;
end $$;
revoke all on function public.ops_alerts_run() from public, anon, authenticated;

do $$
begin
  begin perform cron.unschedule('auto-att'); exception when others then null; end;
  begin perform cron.unschedule('auto-rets'); exception when others then null; end;
  begin perform cron.unschedule('auto-ops'); exception when others then null; end;
  perform cron.schedule('auto-att', '*/5 * * * *', 'select public.att_alerts_run()');
  perform cron.schedule('auto-rets', '*/15 * * * *', 'select public.ret_alerts_run()');
  perform cron.schedule('auto-ops', '45 6 * * *', 'select public.ops_alerts_run()');
end $$;

select 'تم: المتابعة الآلية (الحضور كل 5 دقائق · المرتجعات كل 3 ساعات · الصيانة والمشتريات يومياً 9:45 صباحاً)' as result;
