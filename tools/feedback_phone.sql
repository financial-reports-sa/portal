create or replace function public.feedback_submit(p_branch text, p_rating int, p_tags text[] default '{}',
  p_comment text default null, p_name text default null, p_phone text default null, p_visit text default null, p_lang text default 'ar')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ip text := coalesce(split_part(coalesce(current_setting('request.headers', true), '{}')::json->>'x-forwarded-for', ',', 1), 'unknown');
  v_no bigint; v_ph text := translate(coalesce(p_phone, ''), '٠١٢٣٤٥٦٧٨٩', '0123456789');
  v_cm text := nullif(left(trim(coalesce(p_comment, '')), 1500), ''); v_en boolean := coalesce(p_lang, 'ar') = 'en';
begin
  if not exists (select 1 from branches where id = p_branch) then return jsonb_build_object('ok', false, 'message', 'رابط غير صحيح'); end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then return jsonb_build_object('ok', false, 'message', 'اختر التقييم'); end if;
  v_ph := regexp_replace(v_ph, '[^0-9]', '', 'g');
  if v_ph ~ '^00966' then v_ph := substr(v_ph, 6); elsif v_ph ~ '^966' then v_ph := substr(v_ph, 4); end if;
  if v_ph ~ '^5\d{8}$' then v_ph := '0' || v_ph; end if;
  if v_ph !~ '^05\d{8}$' then v_ph := ''; end if;
  if (p_rating <= 3 or v_cm is not null) and v_ph = '' then
    return jsonb_build_object('ok', false, 'message', case when v_en then 'A valid mobile number (05xxxxxxxx) is required with any comment or complaint' else 'رقم الجوال إلزامي مع أي تعليق أو ملاحظة — اكتبه بصيغة 05xxxxxxxx' end);
  end if;
  if (select count(*) from feedback where ip = v_ip and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('ok', false, 'message', 'تم استلام تقييمك مسبقاً — شكراً لك');
  end if;
  if v_ph <> '' and (select count(*) from feedback where phone = v_ph and branch = p_branch and created_at > now() - interval '24 hours') >= 2 then
    return jsonb_build_object('ok', false, 'message', case when v_en then 'We already received your feedback today — thank you' else 'تم استلام تقييمك اليوم مسبقاً — شكراً لك' end);
  end if;
  insert into feedback (branch, rating, tags, comment, name, phone, visit, lang, ip, log)
  values (p_branch, p_rating, coalesce(p_tags[1:12], '{}'), v_cm,
          nullif(left(trim(coalesce(p_name, '')), 80), ''), nullif(v_ph, ''), left(p_visit, 20), left(p_lang, 5), v_ip,
          jsonb_build_array(jsonb_build_object('t', now(), 'a', 'new', 'by', 'العميل')))
  returning no into v_no;
  return jsonb_build_object('ok', true, 'ref', 'CF-' || lpad(v_no::text, 5, '0'));
end $$;

select 'تم: رقم الجوال إلزامي مع التعليقات والشكاوى' as result;
