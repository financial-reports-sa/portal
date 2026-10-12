-- ============================================================
--  إشعار تغيّر أسعار المشتريات — يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  كل ما ينرفع تقرير «أسعار المشتريات» اليومي وفيه ارتفاع سعر ← إشعار للإدارة ولمن عنده قسم الأسعار
-- ============================================================
create or replace function public.price_alerts_of(p_html text) returns text[]
language sql immutable as $$
  select coalesce(array_agg(btrim(regexp_replace(regexp_replace(m[1] || ': ' || m[2], '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g'))), '{}')
  from regexp_matches(coalesce(p_html, ''), '<div class="al [^"]*"[^>]*>\s*<span class="pill">([^<]*ارتفاع[^<]*)</span>\s*<p>((?:[^<]|<[^/]|</[^p])*)</p>', 'g') as m
$$;

create or replace function public.price_alerts_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare a text[]; o text[] := '{}'; u uuid[]; v_first text;
begin
  if new.app <> 'prices' or new.coll <> 'pages' then return new; end if;
  if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is null then return new; end if;
  a := price_alerts_of(new.data->>'html');
  if tg_op = 'UPDATE' then o := price_alerts_of(old.data->>'html'); end if;
  if coalesce(array_length(a, 1), 0) = 0 or a = o then return new; end if;   -- ما فيه ارتفاع أو نفس التنبيهات
  select coalesce(array_agg(distinct p.id), '{}') into u from profiles p
  where p.active and (p.role in ('owner','admin')
     or (p.role = 'user' and exists (select 1 from user_sections s where s.user_id = p.id and s.section = 'chicken')));
  v_first := regexp_replace(a[1], '^[^:]*:\s*', '');
  perform push_send(u, '⚠️ ارتفاع في أسعار المشتريات',
    left(v_first, 120) || case when array_length(a, 1) > 1 then ' — و' || (array_length(a, 1) - 1) || ' تنبيه ثاني' else '' end,
    './?tab=chicken', 'prices-' || new.id);
  return new;
exception when others then return new;   -- الإشعار ما يوقف رفع التقرير أبداً
end $$;

drop trigger if exists price_alerts_push_trg on public.app_docs;
create trigger price_alerts_push_trg after insert or update of data on public.app_docs
  for each row execute function public.price_alerts_push();

select 'تم تفعيل إشعار ارتفاع الأسعار ✓ — تنبيهات تقرير اليوم: ' ||
  coalesce((select array_length(price_alerts_of(data->>'html'), 1)::text from app_docs where app = 'prices' and coll = 'pages' order by id desc limit 1), '0') as result;
