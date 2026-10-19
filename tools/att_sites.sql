create table if not exists public.att_site (
  id text primary key,
  name text not null,
  lat double precision not null,
  lng double precision not null,
  radius int not null default 150 check (radius between 30 and 2000),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.att_site enable row level security;
drop policy if exists ats_sel on public.att_site;
create policy ats_sel on public.att_site for select to authenticated using (true);
revoke all on public.att_site from anon;
grant select on public.att_site to authenticated;

alter table public.att_emp add column if not exists places text[] not null default '{}';
alter table public.attendance add column if not exists place text;

create or replace function public.att_places(p_emp uuid) returns table (code text, name text, lat double precision, lng double precision, radius int)
language sql stable security definer set search_path = public as $$
  with e as (select id, branch from employees where id = p_emp),
       p as (select coalesce((select places from att_emp where emp_id = p_emp), '{}') pl)
  select g.branch, coalesce(b.name, g.branch), g.lat, g.lng, g.radius
  from att_branch g left join branches b on b.id = g.branch, e, p
  where (cardinality(p.pl) = 0 and g.branch = e.branch) or g.branch = any(p.pl)
  union all
  select 'site:' || s.id, s.name, s.lat, s.lng, s.radius
  from att_site s, p
  where ('site:' || s.id) = any(p.pl)
$$;
revoke all on function public.att_places(uuid) from public, anon;

create or replace function public.att_set_site(p_id text, p_name text, p_lat double precision, p_lng double precision, p_radius int default 150) returns text
language plpgsql security definer set search_path = public as $$
declare k text := nullif(btrim(coalesce(p_id, '')), '');
begin
  if not coalesce(is_admin(), false) then raise exception 'مواقع العمل للآدمن فقط'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'اكتب اسم الموقع'; end if;
  if k is null then k := 's' || substr(md5(random()::text || clock_timestamp()::text), 1, 8); end if;
  insert into att_site (id, name, lat, lng, radius, updated_by) values (k, btrim(p_name), p_lat, p_lng, greatest(30, least(2000, coalesce(p_radius, 150))), att_who())
  on conflict (id) do update set name = excluded.name, lat = excluded.lat, lng = excluded.lng, radius = excluded.radius, updated_by = excluded.updated_by, updated_at = now();
  return k;
end $$;
grant execute on function public.att_set_site(text, text, double precision, double precision, int) to authenticated;

create or replace function public.att_del_site(p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_admin(), false) then raise exception 'مواقع العمل للآدمن فقط'; end if;
  update att_emp set places = array_remove(places, 'site:' || p_id) where ('site:' || p_id) = any(places);
  delete from att_site where id = p_id;
end $$;
grant execute on function public.att_del_site(text) to authenticated;

create or replace function public.att_set_places(p_emp uuid, p_places text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_admin(), false) then raise exception 'تحديد مكان الدوام للآدمن فقط'; end if;
  if not att_ok(p_emp) then raise exception 'ليس لديك صلاحية على هذا الموظف'; end if;
  insert into att_emp (emp_id, places, updated_by) values (p_emp, coalesce(p_places, '{}'), att_who())
  on conflict (emp_id) do update set places = excluded.places, updated_by = excluded.updated_by, updated_at = now();
end $$;
grant execute on function public.att_set_places(uuid, text[]) to authenticated;

create or replace function public.att_check(p_kind text, p_lat double precision, p_lng double precision, p_acc double precision default null, p_photo text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e employees; d int; pn text; ph text := nullif(btrim(coalesce(p_photo, '')), ''); o attendance; today date := att_bday(); rid uuid; n int;
  x att_emp; dev text := nullif(btrim(coalesce(p_device, '')), ''); bydev boolean := false; np int; ok boolean := false; best int; bname text;
begin
  select * into e from employees where id = my_emp_id();
  if e.id is null then raise exception 'حسابك غير مرتبط بموظف'; end if;
  if e.status = 'left' then raise exception 'خدمتك منتهية'; end if;
  select count(*) into np from att_places(e.id);
  if np = 0 then raise exception 'موقع الدوام غير محدد — بلّغ مدير الفرع يحدده'; end if;
  if p_lat is null or p_lng is null then raise exception 'ما قدرنا نحدد موقعك — فعّل الموقع في الجوال'; end if;
  select att_dist(p_lat, p_lng, q.lat, q.lng), q.name, att_dist(p_lat, p_lng, q.lat, q.lng) <= q.radius + least(coalesce(p_acc, 0), 100)
    into d, pn, ok
  from att_places(e.id) q
  order by (att_dist(p_lat, p_lng, q.lat, q.lng) <= q.radius + least(coalesce(p_acc, 0), 100)) desc, att_dist(p_lat, p_lng, q.lat, q.lng) - q.radius
  limit 1;
  if not ok then
    raise exception 'أنت بعيد عن مكان دوامك «%» (% متر) — سجّل وأنت في مكان الدوام', pn, d;
  end if;
  select * into x from att_emp where emp_id = e.id for update;
  if coalesce(x.no_selfie, false) then
    if dev is null or length(dev) < 16 then raise exception 'حدّث التطبيق وحاول مرة ثانية'; end if;
    if x.device is null then
      update att_emp set device = dev, device_at = now() where emp_id = e.id;
    elsif x.device <> dev then
      raise exception 'هذا مو جوالك المسجّل — التسجيل يكون من جوالك أنت. لو غيّرت جوالك كلّم مدير الفرع يعيد تسجيل الجهاز';
    end if;
    bydev := ph is null;
  elsif ph is null then raise exception 'صورة السيلفي إلزامية'; end if;
  if ph is not null and length(ph) > 900000 then raise exception 'الصورة كبيرة — صوّر مرة ثانية'; end if;
  if p_kind = 'in' then
    if exists (select 1 from attendance where emp_id = e.id and out_at is null and in_at > now() - interval '20 hours') then
      raise exception 'حضورك مسجّل — سجّل الانصراف أولاً';
    end if;
    select coalesce(max(seq), 0) into n from attendance where emp_id = e.id and day = today and in_at is not null;
    if n >= 2 then raise exception 'سجّلت شفتين اليوم'; end if;
    insert into attendance (emp_id, branch, day, seq, in_at, in_lat, in_lng, in_dist, in_photo, in_dev, place)
    values (e.id, e.branch, today, n + 1, now(), p_lat, p_lng, d, ph, bydev, pn)
    on conflict (emp_id, day, seq) do update set in_at = excluded.in_at, in_lat = excluded.in_lat, in_lng = excluded.in_lng, in_dist = excluded.in_dist, in_photo = excluded.in_photo, in_dev = excluded.in_dev, place = excluded.place
    returning id into rid;
  elsif p_kind = 'out' then
    select * into o from attendance where emp_id = e.id and out_at is null and in_at > now() - interval '20 hours' order by in_at desc limit 1;
    if o.id is null then raise exception 'ما فيه حضور مفتوح — سجّل الحضور أولاً'; end if;
    update attendance set out_at = now(), out_lat = p_lat, out_lng = p_lng, out_dist = d, out_photo = ph, out_dev = bydev where id = o.id returning id into rid;
  else raise exception 'نوع غير صحيح'; end if;
  return jsonb_build_object('id', rid, 'dist', d, 'place', pn, 'at', now());
end $$;
grant execute on function public.att_check(text, double precision, double precision, double precision, text, text) to authenticated;

create or replace function public.att_me() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e employees; g att_branch; s att_shift; o attendance; today date := att_bday(); ae att_emp; gs jsonb;
begin
  select * into e from employees where id = my_emp_id();
  if e.id is null then return null; end if;
  select * into ae from att_emp where emp_id = e.id;
  select coalesce(jsonb_agg(jsonb_build_object('code', q.code, 'name', q.name, 'lat', q.lat, 'lng', q.lng, 'radius', q.radius)), '[]') into gs from att_places(e.id) q;
  select * into s from att_shift where emp_id = e.id;
  select * into o from attendance where emp_id = e.id and out_at is null and in_at > now() - interval '20 hours' order by in_at desc limit 1;
  return jsonb_build_object('emp', e.id, 'branch', e.branch, 'today', today, 'no_selfie', coalesce(ae.no_selfie, false), 'device_set', ae.device is not null,
    'exempt', coalesce(ae.exempt, false),
    'geo', case when jsonb_array_length(gs) = 0 then null else gs->0 end,
    'geos', gs,
    'shift', case when s.emp_id is null then null else jsonb_build_object('start', s.start_t, 'end', s.end_t, 'start2', s.start2_t, 'end2', s.end2_t, 'off', s.off_days, 'grace', s.grace,
      'fri_start', s.fri_start_t, 'fri_end', s.fri_end_t, 'fri_start2', s.fri_start2_t, 'fri_end2', s.fri_end2_t, 'by', s.updated_by, 'at', s.updated_at) end,
    'open', case when o.id is null then null else to_jsonb(o) end,
    'recs', coalesce((select jsonb_agg(to_jsonb(x) order by x.seq) from attendance x where x.emp_id = e.id and x.day = today), '[]'),
    'recent', coalesce((select jsonb_agg(to_jsonb(x) order by x.day desc) from (select * from attendance where emp_id = e.id order by day desc limit 10) x), '[]'));
end $$;
grant execute on function public.att_me() to authenticated;
