-- ============================================================
--  رادار المشتريات — التقرير اليومي يتولّد تلقائياً من فواتير جروث المتزامنة
--  يشغَّل مرة واحدة في Supabase → SQL Editor → Run
--  بعدها: كل ما توصل فواتير مشتريات من السيرفر (كل 5 دقائق) تتحدّث صفحة يومها لحالها،
--  بدون أي مهمة مجدولة أو لابتوب أو موافقات.
-- ============================================================

-- ---------- أدوات تنسيق ----------
create or replace function public.gpp_e(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

create or replace function public.gpp_n(v numeric, d int default 2) returns text language sql immutable as $$
  select case when v is null then '—'
              when d = 0 then to_char(round(v), 'FM999,999,999,990')
              else to_char(round(v, d), 'FM999,999,999,990.' || repeat('0', d)) end
$$;

-- كمية بدون أصفار زائدة: 200 ، 12.5
create or replace function public.gpp_q(v numeric) returns text language sql immutable as $$
  select case when v is null then '' else regexp_replace(regexp_replace(to_char(round(v, 3), 'FM999,999,999,990.999'), '0+$', ''), '\.$', '') end
$$;

create or replace function public.gpp_day(d date, p_long boolean default true) returns text language sql immutable as $$
  select case when p_long then (array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'])[extract(dow from d)::int + 1] || ' ' else '' end
      || extract(day from d)::int || ' '
      || (array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'])[extract(month from d)::int]
      || case when p_long then ' ' || extract(year from d)::int else '' end
$$;

-- الفئات الست نفسها في التقرير الأصلي (قوائم الاستهلاك في «مجموعة اصناف ١»)
-- أولاً من مجموعة الصنف في جروث، وإذا ما كانت واضحة فمن اسم الصنف
create or replace function public.gpp_cat(n text, g text) returns text language sql immutable as $$
  select case
    when coalesce(g, '') ~ 'دجاج المطعم' then 'chicken'
    when coalesce(g, '') ~ 'لحوم المطعم' then 'meat'
    when coalesce(g, '') ~ 'المشويات' then 'grill'
    when coalesce(g, '') ~ 'الفواكه' then 'fruit'
    when coalesce(g, '') ~ 'استهلاك (ال)?(رز|ارز|أرز)' then 'rice'
    when coalesce(g, '') ~ 'الغاز|الفحم' then 'gas'
    when coalesce(g, '') ~ 'استهلاك' then null
    when coalesce(n, '') ~ 'مرق|مرقة|بهار|توابل|ماجي|شوربة|بودرة|تتبيل|صوص|خلطة' then null
    when coalesce(n, '') ~ 'مشويات|مشاوي|شاورما|شاورمه|فيلي|فيلية|تندر|كباب|كفتة|كفته|توب سايد|شيش|لية' then 'grill'
    when coalesce(n, '') ~ 'غاز|فحم|حطب' then 'gas'
    when coalesce(n, '') ~ '(^|\s)(رز|ارز|أرز)(\s|$)|بسمتي|بشاور' then 'rice'
    when coalesce(n, '') ~ 'فواكه|فاكهة|برتقال|تفاح|موز|عنب|فراولة|فراوله|مانجو|بطيخ|شمام|اناناس|أناناس|كيوي|رمان|ثلج عصيرات|كاجو|مكسرات' then 'fruit'
    when coalesce(n, '') ~ 'ذبيح|ذبائح|ذبايح|حاشي|غنم|نعيمي|نجدي|حري|سواكن|خروف|تيس|عجل|طليان' then 'meat'
    when coalesce(n, '') ~ 'دجاج|روزنا|فقيه|أمجاد|امجاد|ساديا|داري|الوطنية|اليمامة|التنمية|فروج|فراريج' then 'chicken'
  end
$$;

create table if not exists public.gpp_cats (
  k    text primary key, ord int not null, h text not null, tag text not null, kpi text not null, none text not null
);
insert into public.gpp_cats values
  ('chicken', 1, 'الدجاج',          'قائمة استهلاك دجاج المطعم 1001551', 'مبلغ الدجاج',       'ما فيه شراء دجاج في هذا اليوم'),
  ('meat',    2, 'اللحوم والذبائح', 'قائمة استهلاك لحوم المطعم 1001552', 'مبلغ اللحوم',       'ما فيه شراء لحوم أو ذبائح في هذا اليوم'),
  ('grill',   3, 'مواد المشويات',   'قائمة استهلاك مواد المشويات 1001558', 'مبلغ المشويات',   'ما فيه شراء مواد مشويات في هذا اليوم'),
  ('fruit',   4, 'الفواكه',         'قائمة استهلاك الفواكه 1001554',      'مبلغ الفواكه',      'ما فيه شراء فواكه في هذا اليوم'),
  ('rice',    5, 'الرز',            'قائمة استهلاك الرز 1001555',         'مبلغ الرز',         'ما فيه شراء رز في هذا اليوم'),
  ('gas',     6, 'الغاز والفحم',    'قائمة استهلاك الغاز والفحم 1001560', 'مبلغ الغاز والفحم', 'ما فيه شراء غاز أو فحم في هذا اليوم')
on conflict (k) do update set ord = excluded.ord, h = excluded.h, tag = excluded.tag, kpi = excluded.kpi, none = excluded.none;
alter table public.gpp_cats enable row level security;
revoke all on public.gpp_cats from anon, authenticated;

create index if not exists growth_inv_lines_pur_item_idx on public.growth_inv_lines (item, dt) where kind = 'pur';

-- كل بنود الشراء للفئات الست مع اسم الصنف ووحدته وفئته
create or replace view public.gpp_lines as
  select g.dt, g.branch, g.line_id, g.doc, g.party, g.item, coalesce(nullif(it.name, ''), g.item) n, coalesce(it.unit, '') u,
         g.qty, g.price, g.amount, gpp_cat(it.name, it.grp) cat
  from growth_inv_lines g left join growth_items it on it.item = g.item
  where g.kind = 'pur' and g.qty > 0 and g.price > 0 and gpp_cat(it.name, it.grp) is not null;
revoke all on public.gpp_lines from public, anon, authenticated;

-- ---------- صفحة يوم واحد (HTML كامل بنفس تصميم التقرير الأصلي) ----------
create or replace function public.growth_price_page_html(p_day date) returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  css text; h text; kp text; al text := ''; secs text := ''; notes text := ''; okl text;
  c record; r record; rows text; tq text; tot numeric; n_al int := 0;
  cav numeric; cq numeric; pdt date; pav numeric; biz date := (now() at time zone 'Asia/Riyadh' - interval '8 hours')::date;
begin
  if not exists (select 1 from gpp_lines where dt = p_day) then return null; end if;

  create temp table if not exists _gpp_g (cat text, item text, n text, u text, party text, price numeric, qty numeric, amount numeric, docs text,
    pp numeric, pd date, pdoc text, alt_p numeric, alt_party text, alt_d date, alt_doc text, nprice int, has_hist boolean, flag boolean, isnew boolean) on commit drop;
  truncate _gpp_g;

  -- بنود اليوم مجمّعة على الصنف + المورد + السعر، مع آخر سعر قبلها من نفس المورد، وأرخص سعر محفوظ عند مورد ثاني
  insert into _gpp_g
  with d as (select cat, item, n, u, party, round(price, 4) price, sum(qty) qty, sum(amount) amount,
                    string_agg(distinct nullif(doc, ''), ' و') docs
             from gpp_lines where dt = p_day group by cat, item, n, u, party, round(price, 4))
  select d.cat, d.item, d.n, d.u, d.party, d.price, d.qty, d.amount, d.docs,
         pv.price, pv.dt, pv.doc, al.price, al.party, al.dt, al.doc,
         (select count(distinct x.price) from d x where x.item = d.item)::int,
         exists (select 1 from gpp_lines h where h.item = d.item and h.dt < p_day), false, false
  from d
  left join lateral (select l.price, l.dt, l.doc from gpp_lines l where l.item = d.item and l.party = d.party and l.dt < p_day
                     order by l.dt desc, l.line_id desc limit 1) pv on true
  left join lateral (select x.price, x.party, x.dt, x.doc from (
                       select distinct on (l.party) l.party, l.price, l.dt, l.doc from gpp_lines l
                       where l.item = d.item and l.party <> d.party and l.dt <= p_day and l.dt > p_day - 45
                       order by l.party, l.dt desc, l.line_id desc) x
                     where x.price < d.price * 0.995 order by x.price limit 1) al on true;

  update _gpp_g set isnew = (pp is null and not has_hist),
    flag = (pp is not null and price > pp * 1.0005 and not (cat = 'fruit' and price <= pp * 1.05))
        or (pp is not null and abs(price / pp - 1) > 0.05)
        or (alt_p is not null)
        or (nprice > 1 and price > (select min(x.price) from _gpp_g x where x.item = _gpp_g.item));

  css := $css$<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>تقرير أسعار المشتريات</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;500;600;700&family=Reem+Kufi:wght@600;700&display=swap">
<style>
:root{--bg:#F3F5F4;--surface:#FFFFFF;--ink:#16231F;--muted:#5E6D68;--line:#DDE3E0;--accent:#0E6B5C;--accent-soft:#E2F0EC;
--warn:#9A5B00;--warn-bg:#FFF3DC;--bad:#A3322A;--bad-bg:#FBE7E4;--good:#1D7A43;--good-bg:#E3F4E8;--info:#2F5D8A;--info-bg:#E5EEF7;
--f-display:"Reem Kufi","IBM Plex Sans Arabic",Tahoma,sans-serif;--f-body:"IBM Plex Sans Arabic",Tahoma,"Segoe UI",sans-serif}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0F1614;--surface:#17211E;--ink:#E6EEEB;--muted:#9AABA5;--line:#2A3833;--accent:#4FC2AB;--accent-soft:#18332D;
--warn:#F2B75C;--warn-bg:#33270F;--bad:#F08A80;--bad-bg:#3A1C19;--good:#6FD39A;--good-bg:#14301F;--info:#8DB8E3;--info-bg:#172839;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0F1614;--surface:#17211E;--ink:#E6EEEB;--muted:#9AABA5;--line:#2A3833;--accent:#4FC2AB;--accent-soft:#18332D;
--warn:#F2B75C;--warn-bg:#33270F;--bad:#F08A80;--bad-bg:#3A1C19;--good:#6FD39A;--good-bg:#14301F;--info:#8DB8E3;--info-bg:#172839;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--f-body);font-size:15px;line-height:1.65;direction:rtl}
.wrap{max-width:760px;margin:0 auto;padding-inline:16px;padding-block:28px 40px;display:grid;gap:22px}
header{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-end;gap:10px;border-bottom:2px solid var(--accent);padding-bottom:14px}
h1{font-family:var(--f-display);font-size:clamp(1.5rem,4vw,2rem);margin:0;line-height:1.3;text-wrap:balance}
.date{color:var(--muted);font-weight:500}.date b{color:var(--ink)}
.live{display:inline-block;font-size:.72rem;font-weight:700;color:var(--accent);background:var(--accent-soft);border-radius:999px;padding:1px 9px;margin-inline-start:4px}
.src{font-size:.8rem;color:var(--muted)}
h2{font-family:var(--f-display);font-size:1.15rem;margin:0 0 10px;display:flex;align-items:center;gap:8px}
h2 .tag{font-family:var(--f-body);font-size:.72rem;font-weight:600;color:var(--muted);background:var(--surface);border:1px solid var(--line);border-radius:999px;padding:1px 10px}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.kpi{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:12px 14px;min-width:0}
.kpi .l{font-size:.78rem;color:var(--muted);letter-spacing:.02em}
.kpi .v{font-size:1.45rem;font-weight:700;font-variant-numeric:tabular-nums;line-height:1.3}
.kpi .s{font-size:.78rem;color:var(--muted)}
.kpi.main{background:var(--accent-soft);border-color:transparent}.kpi.main .v{color:var(--accent)}
.down{color:var(--good);font-weight:600}.up{color:var(--bad);font-weight:600}
.alerts{display:grid;gap:8px}
.al{display:grid;grid-template-columns:auto 1fr;gap:10px;align-items:start;background:var(--surface);border:1px solid var(--line);border-inline-start:4px solid var(--muted);border-radius:8px;padding:10px 12px}
.al .pill{font-size:.72rem;font-weight:700;border-radius:999px;padding:2px 9px;white-space:nowrap;margin-top:2px}
.al.bad{border-inline-start-color:var(--bad)} .al.bad .pill{background:var(--bad-bg);color:var(--bad)}
.al.warn{border-inline-start-color:var(--warn)} .al.warn .pill{background:var(--warn-bg);color:var(--warn)}
.al.info{border-inline-start-color:var(--info)} .al.info .pill{background:var(--info-bg);color:var(--info)}
.al.ok{border-inline-start-color:var(--good)} .al.ok .pill{background:var(--good-bg);color:var(--good)}
.al p{margin:0;min-width:0}.al .inv{color:var(--muted);font-size:.85rem}
.tbl{overflow-x:auto;background:var(--surface);border:1px solid var(--line);border-radius:10px}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{padding:9px 12px;text-align:right;border-bottom:1px solid var(--line);white-space:nowrap}
th{font-size:.78rem;color:var(--muted);font-weight:600;background:var(--bg)}
td.n,th.n{text-align:left}
tr.flag td{background:var(--bad-bg)}
tr.new td:first-child::after{content:"جديد";font-size:.68rem;font-weight:700;color:var(--info);background:var(--info-bg);border-radius:999px;padding:1px 7px;margin-inline-start:6px}
tfoot td{font-weight:700;border-bottom:0;background:var(--accent-soft)}
.empty{background:var(--surface);border:1px dashed var(--line);border-radius:10px;padding:14px;color:var(--muted)}
ul.prev{margin:0;padding:0;list-style:none;display:grid;gap:8px}
ul.prev li{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
ul.prev .d{font-weight:700;color:var(--accent);margin-inline-end:6px}
ul.prev li.bad{background:var(--bad-bg);border-color:var(--bad);border-inline-start:4px solid var(--bad)}
ul.prev li.bad .d,ul.prev li.bad b{color:var(--bad)}
footer{text-align:center;color:var(--muted);font-size:.82rem;border-top:1px solid var(--line);padding-top:14px}
@media (max-width:640px){.kpis{grid-template-columns:repeat(2,1fr)}
  .wrap{padding-block:18px 32px;gap:18px}
  .tbl{background:transparent;border:0;overflow:visible}
  table,tbody,tfoot,tr,td{display:block;width:100%}
  thead{display:none}
  tbody{display:grid;gap:8px}
  tbody tr{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px 12px;display:grid;grid-template-columns:1fr auto;gap:2px 12px}
  tbody tr.flag{background:var(--bad-bg);border-color:var(--bad)}
  tr.flag td{background:transparent}
  td{border:0;padding:0;white-space:normal;text-align:right}
  td.n{text-align:right}
  tbody td[data-l="الصنف"]{font-weight:700;font-size:1rem}
  tbody td[data-l="المورد"]{grid-column:1/-1;color:var(--muted);font-size:.85rem;order:2}
  tbody td[data-l="السعر"]{order:1;font-weight:700;font-size:1.05rem;color:var(--accent);text-align:left}
  tbody td[data-l="الكمية"],tbody td[data-l="الصافي"],tbody td[data-l="الفاتورة"]{order:3;font-size:.85rem}
  tbody td[data-l="الكمية"]::before{content:"الكمية: ";color:var(--muted)}
  tbody td[data-l="الصافي"]{text-align:left}
  tbody td[data-l="الصافي"]::before{content:"الصافي: ";color:var(--muted)}
  tbody td[data-l="الفاتورة"]{grid-column:1/-1}
  tbody td[data-l="الفاتورة"]::before{content:"فاتورة: ";color:var(--muted)}
  tbody tr.flag td[data-l="السعر"]{color:var(--bad)}
  tfoot{margin-top:8px}
  tfoot tr{display:flex;flex-wrap:wrap;justify-content:space-between;gap:4px 12px;background:var(--accent-soft);border-radius:10px;padding:10px 12px}
  tfoot td{width:auto;background:transparent}
  tfoot td:empty{display:none}
  .kpi .v{font-size:1.25rem}}
</style></head><body><div class="wrap">$css$;

  h := css || '<header><div><h1>تقرير أسعار المشتريات</h1><div class="date">يوم <b>' || gpp_day(p_day) || '</b>'
     || case when p_day >= biz then ' <span class="live">حتى الآن · يتحدّث مع كل فاتورة</span>' else '' end
     || ' · دجاج · لحوم · مشويات · فواكه · رز · غاز وفحم</div></div>'
     || '<div class="src">المصدر: GROWTH ERP · فواتير المشتريات · كل الفروع</div></header>';

  -- ===== البطاقات =====
  select sum(amount) / nullif(sum(qty), 0), sum(qty) into cav, cq from gpp_lines where dt = p_day and cat = 'chicken';
  select max(dt) into pdt from gpp_lines where dt < p_day and cat = 'chicken';
  if pdt is not null then select sum(amount) / nullif(sum(qty), 0) into pav from gpp_lines where dt = pdt and cat = 'chicken'; end if;
  kp := '<section class="kpis" aria-label="ملخص اليوم"><div class="kpi main"><div class="l">متوسط سعر حبة الدجاج</div><div class="v">'
     || coalesce(gpp_n(cav), '—') || '</div><div class="s">'
     || case when cav is null then 'ما فيه شراء دجاج'
             when pav is null then gpp_q(cq) || ' حبة'
             when round(cav, 2) > round(pav, 2) then '<span class="up">▲ ' || gpp_n(round(cav, 2) - round(pav, 2)) || '</span> عن ' || gpp_day(pdt, false) || ' (' || gpp_n(pav) || ')'
             when round(cav, 2) < round(pav, 2) then '<span class="down">▼ ' || gpp_n(round(pav, 2) - round(cav, 2)) || '</span> عن ' || gpp_day(pdt, false) || ' (' || gpp_n(pav) || ')'
             else 'نفس ' || gpp_day(pdt, false) || ' (' || gpp_n(pav) || ')' end
     || '</div></div>';
  for c in select * from gpp_cats order by ord loop
    select sum(amount) into tot from gpp_lines where dt = p_day and cat = c.k;
    select string_agg(gpp_q(q) || ' ' || gpp_e(u), ' + ' order by q desc) into tq
      from (select u, sum(qty) q from gpp_lines where dt = p_day and cat = c.k group by u) z;
    kp := kp || '<div class="kpi"><div class="l">' || c.kpi || '</div><div class="v">' || coalesce(gpp_n(tot), '—') || '</div><div class="s">'
       || case when tot is null then 'ما فيه شراء'
               else tq || ' · ' || (select count(distinct item) from gpp_lines where dt = p_day and cat = c.k) || ' أصناف' end || '</div></div>';
  end loop;
  kp := kp || '</section>';

  -- ===== التنبيهات =====
  -- ارتفاع / ارتفاع كبير / نزول من نفس المورد
  for r in select * from _gpp_g where pp is not null and abs(price / pp - 1) >= 0.0005
           order by (price > pp) desc, abs(price - pp) * qty desc loop
    if r.price > r.pp and r.cat = 'fruit' and r.price <= r.pp * 1.05 then continue; end if;
    n_al := n_al + 1;
    al := al || '<div class="al ' || case when r.price > r.pp * 1.05 then 'bad' when r.price > r.pp then 'warn' else 'ok' end || '"><span class="pill">'
       || case when r.price > r.pp * 1.05 then 'ارتفاع كبير' when r.price > r.pp then 'ارتفاع' else 'نزول' end || '</span><p><b>' || gpp_e(r.n) || '</b> من '
       || gpp_e(r.party) || case when r.price > r.pp then ' ارتفع' else ' نزل' end || ' من ' || gpp_n(r.pp) || ' إلى <b>' || gpp_n(r.price) || '</b>'
       || case when r.u <> '' then ' لل' || gpp_e(r.u) else '' end
       || ' (' || case when r.price > r.pp then '+' else '−' end || gpp_n(abs(r.price - r.pp)) || '، '
       || case when r.price > r.pp then '+' else '−' end || gpp_n(abs(r.price / r.pp - 1) * 100, 1) || '%). '
       || gpp_q(r.qty) || ' ' || gpp_e(r.u) || ' — حوالي ' || gpp_n(abs(r.price - r.pp) * r.qty, 0) || ' ريال '
       || case when r.price > r.pp then 'زيادة' else 'توفير' end || '.'
       || case when r.price > r.pp * 1.05 then ' تأكد من الكمية أو محتوى الفاتورة.' else '' end
       || ' <span class="inv">فاتورة ' || coalesce(gpp_e(r.docs), '—') || ' · السابق ' || coalesce(gpp_e(r.pdoc), '—') || ' (' || gpp_day(r.pd, false) || ')</span></p></div>';
  end loop;
  -- نفس الصنف بسعرين في نفس اليوم
  for r in select item, min(n) n, min(u) u, string_agg(distinct gpp_n(price), ' و' order by gpp_n(price)) ps, min(price) mn, max(price) mx,
                  string_agg(distinct docs, ' و') docs
           from _gpp_g where nprice > 1 group by item order by max(price) - min(price) desc loop
    n_al := n_al + 1;
    al := al || '<div class="al warn"><span class="pill">سعرين</span><p><b>' || gpp_e(r.n) || '</b> انشرى بأكثر من سعر في نفس اليوم: <b>' || r.ps
       || '</b> (فرق ' || gpp_n(r.mx - r.mn) || case when r.u <> '' then ' لل' || gpp_e(r.u) else '' end || ').'
       || ' <span class="inv">فواتير ' || coalesce(gpp_e(r.docs), '—') || '</span></p></div>';
  end loop;
  -- مورد أغلى من مورد ثاني لنفس الصنف
  for r in select * from _gpp_g where alt_p is not null order by (price - alt_p) * qty desc loop
    n_al := n_al + 1;
    al := al || '<div class="al warn"><span class="pill">مورد أغلى</span><p><b>' || gpp_e(r.n) || '</b> من ' || gpp_e(r.party) || ' بـ <b>' || gpp_n(r.price)
       || '</b> مقابل ' || gpp_n(r.alt_p) || ' من ' || gpp_e(r.alt_party) || ' — +' || gpp_n(r.price - r.alt_p)
       || case when r.u <> '' then ' لل' || gpp_e(r.u) else '' end || ' (+' || gpp_n((r.price / r.alt_p - 1) * 100, 1) || '%). '
       || gpp_q(r.qty) || ' ' || gpp_e(r.u) || '. <span class="inv">فاتورة ' || coalesce(gpp_e(r.docs), '—') || ' · ' || gpp_e(r.alt_party) || ' '
       || coalesce(gpp_e(r.alt_doc), '') || ' (' || gpp_day(r.alt_d, false) || ')</span></p></div>';
  end loop;
  -- صنف / مورد جديد
  for r in select * from _gpp_g where pp is null and alt_p is null order by isnew desc, amount desc loop
    n_al := n_al + 1;
    al := al || '<div class="al info"><span class="pill">' || case when r.isnew then 'صنف جديد' else 'مورد جديد' end || '</span><p><b>' || gpp_e(r.n) || '</b> من '
       || gpp_e(r.party) || ' بـ <b>' || gpp_n(r.price) || '</b>' || case when r.u <> '' then ' لل' || gpp_e(r.u) else '' end
       || ' — أول شراء ' || case when r.isnew then 'لهذا الصنف' else 'من هذا المورد' end || ' في السجل. <span class="inv">فاتورة ' || coalesce(gpp_e(r.docs), '—') || '</span></p></div>';
  end loop;
  -- الثابت
  select string_agg(gpp_e(n) || ' ' || gpp_n(price), '، ' order by amount desc) into okl
    from _gpp_g where pp is not null and abs(price / pp - 1) < 0.0005 and alt_p is null and nprice = 1;
  if okl is not null or n_al = 0 then
    al := al || '<div class="al ok"><span class="pill">ثابت</span><p>'
       || case when okl is null then 'لا تغيير في الأسعار ✅' else 'نفس السعر السابق: ' || okl || '.' end || '</p></div>';
  end if;

  -- ===== الجداول =====
  for c in select * from gpp_cats order by ord loop
    select string_agg('<tr' || case when g.flag then ' class="flag"' when g.isnew then ' class="new"' else '' end || '><td data-l="الصنف">' || gpp_e(l.n)
             || '</td><td data-l="المورد">' || gpp_e(l.party) || '</td><td class="n" data-l="الكمية">' || gpp_q(l.qty) || ' ' || gpp_e(l.u)
             || '</td><td class="n" data-l="السعر">' || gpp_n(l.price) || '</td><td class="n" data-l="الصافي">' || gpp_n(l.amount)
             || '</td><td data-l="الفاتورة">' || gpp_e(l.doc) || '</td></tr>', '' order by l.n, l.party, l.doc, l.line_id),
           sum(l.amount)
      into rows, tot
      from gpp_lines l left join _gpp_g g on g.item = l.item and g.party = l.party and g.price = round(l.price, 4)
      where l.dt = p_day and l.cat = c.k;
    secs := secs || '<section><h2>' || c.h || ' <span class="tag">' || c.tag || '</span></h2>';
    if rows is null then
      secs := secs || '<div class="empty">' || c.none || '</div></section>';
    else
      select string_agg(gpp_q(q) || ' ' || gpp_e(u), ' + ' order by q desc) into tq
        from (select u, sum(qty) q from gpp_lines where dt = p_day and cat = c.k group by u) z;
      secs := secs || '<div class="tbl"><table><thead><tr><th>الصنف</th><th>المورد</th><th class="n">الكمية</th><th class="n">السعر</th><th class="n">الصافي</th><th>الفاتورة</th></tr></thead><tbody>'
           || rows || '</tbody><tfoot><tr><td data-l="الصنف">الإجمالي</td><td data-l="المورد"></td><td class="n" data-l="الكمية">' || tq
           || '</td><td class="n" data-l="السعر">' || case when c.k = 'chicken' and cav is not null then 'متوسط ' || gpp_n(cav) else '' end
           || '</td><td class="n" data-l="الصافي">' || gpp_n(tot) || '</td><td data-l="الفاتورة"></td></tr></tfoot></table></div></section>';
    end if;
  end loop;

  -- ===== ملاحظات من الأيام السابقة: كل دفع أكثر من نفس المورد خلال 14 يوم قبل هذا اليوم =====
  select string_agg('<li class="bad"><span class="d">' || gpp_day(z.dt, false) || '</span>' || gpp_e(z.n) || ' من ' || gpp_e(z.party) || ' ارتفع من '
           || gpp_n(z.pp) || ' إلى <b>' || gpp_n(z.price) || '</b>' || case when z.u <> '' then ' لل' || gpp_e(z.u) else '' end
           || ' (+' || gpp_n((z.price / z.pp - 1) * 100, 1) || '%). ' || gpp_q(z.qty) || ' ' || gpp_e(z.u) || ' — حوالي ' || gpp_n((z.price - z.pp) * z.qty, 0)
           || ' ريال زيادة. فاتورة ' || coalesce(gpp_e(z.docs), '—') || '.</li>', '' order by z.dt desc, (z.price - z.pp) * z.qty desc)
    into notes
    from (select * from (
            select d.*, row_number() over (order by d.dt desc, (d.price - d.pp) * d.qty desc) rn from (
              select x.dt, x.item, x.n, x.u, x.party, x.cat, x.price, sum(x.qty) qty, string_agg(distinct nullif(x.doc, ''), ' و') docs,
                     (select l.price from gpp_lines l where l.item = x.item and l.party = x.party and l.dt < x.dt order by l.dt desc, l.line_id desc limit 1) pp
              from (select dt, item, n, u, party, cat, round(price, 4) price, qty, doc from gpp_lines where dt between p_day - 14 and p_day - 1) x
              group by x.dt, x.item, x.n, x.u, x.party, x.cat, x.price) d
            where d.pp is not null and d.price > d.pp * 1.0005 and not (d.cat = 'fruit' and d.price <= d.pp * 1.05)) q where rn <= 6) z;

  return h || kp || '<section><h2>تنبيهات اليوم</h2><div class="alerts">' || al || '</div></section>' || secs
      || case when notes is not null then '<section><h2>ملاحظات من الأيام السابقة</h2><ul class="prev">' || notes || '</ul></section>' else '' end
      || '<footer>إعداد أمير العريفي · يتحدّث تلقائياً من فواتير جروث مع كل مزامنة</footer></div></body></html>';
end $$;
revoke all on function public.growth_price_page_html(date) from public, anon, authenticated;

-- ---------- حفظ صفحات الأيام في رادار المشتريات ----------
-- التقارير القديمة اللي انرفعت يدوي قبل الربط تبقى كما هي (ما تنكتب فوقها)
create or replace function public.growth_price_pages_refresh(p_days date[]) returns int
language plpgsql volatile security definer set search_path = public as $$
declare d date; v text; n int := 0; old jsonb;
begin
  for d in select distinct x from unnest(coalesce(p_days, '{}'::date[])) x
           where x is not null and x > (now() at time zone 'Asia/Riyadh')::date - 40 and x <= (now() at time zone 'Asia/Riyadh')::date + 1 order by 1 loop
    select data into old from app_docs where app = 'prices' and coll = 'pages' and id = d::text;
    if old is not null and coalesce(old->>'auto', '') <> 'growth' then continue; end if;
    v := growth_price_page_html(d);
    if v is null then
      if old is not null then delete from app_docs where app = 'prices' and coll = 'pages' and id = d::text; n := n + 1; end if;   -- الفواتير انحذفت من جروث
      continue;
    end if;
    if old is not null and old->>'html' = v then continue; end if;
    insert into app_docs (app, coll, id, data, branches, updated_at)
    values ('prices', 'pages', d::text, jsonb_build_object('date', d::text, 'html', v, 'auto', 'growth'), '{}', now())
    on conflict (app, coll, id) do update set data = excluded.data, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.growth_price_pages_refresh(date[]) from public, anon, authenticated;

-- ---------- التحديث التلقائي: مع كل دفعة فواتير توصل من السيرفر ----------
create or replace function public.gpp_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare ds date[];
begin
  if tg_op = 'DELETE' then select array_agg(distinct dt) into ds from old_rows where kind = 'pur';
  else select array_agg(distinct dt) into ds from new_rows where kind = 'pur'; end if;
  if ds is not null then
    begin perform growth_price_pages_refresh(ds);
    exception when others then raise warning 'growth_price_pages_refresh: %', sqlerrm; end;   -- التقرير ما يوقف المزامنة أبداً
  end if;
  return null;
end $$;

drop trigger if exists gpp_ins on public.growth_inv_lines;
drop trigger if exists gpp_upd on public.growth_inv_lines;
drop trigger if exists gpp_del on public.growth_inv_lines;
create trigger gpp_ins after insert on public.growth_inv_lines referencing new table as new_rows for each statement execute function public.gpp_trg();
create trigger gpp_upd after update on public.growth_inv_lines referencing new table as new_rows for each statement execute function public.gpp_trg();
create trigger gpp_del after delete on public.growth_inv_lines referencing old table as old_rows for each statement execute function public.gpp_trg();

-- ---------- الإشعار: بس لأيام اليوم وأمس، وما يطلع أثناء تعبئة الأيام الفائتة ----------
create or replace function public.price_alerts_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare a text[]; o text[] := '{}'; u uuid[]; v_first text;
begin
  if new.app <> 'prices' or new.coll <> 'pages' then return new; end if;
  if coalesce(current_setting('app.gpp_quiet', true), '') = '1' then return new; end if;
  if new.data->>'auto' = 'growth' and new.id < ((now() at time zone 'Asia/Riyadh' - interval '8 hours')::date - 1)::text then return new; end if;
  if to_regprocedure('public.push_send(uuid[],text,text,text,text)') is null then return new; end if;
  a := price_alerts_of(new.data->>'html');
  if tg_op = 'UPDATE' then o := price_alerts_of(old.data->>'html'); end if;
  a := array(select x from unnest(a) x except select y from unnest(o) y);   -- الجديد فقط، عشان ما يتكرر الإشعار مع كل فاتورة
  if coalesce(array_length(a, 1), 0) = 0 then return new; end if;
  select coalesce(array_agg(distinct p.id), '{}') into u from profiles p
  where p.active and (p.role in ('owner','admin')
     or (p.role = 'user' and exists (select 1 from user_sections s where s.user_id = p.id and s.section in ('chicken', 'wh'))));
  v_first := regexp_replace(a[1], '^[^:]*:\s*', '');
  perform push_send(u, '⚠️ ارتفاع في أسعار المشتريات',
    left(v_first, 120) || case when array_length(a, 1) > 1 then ' — و' || (array_length(a, 1) - 1) || ' تنبيه ثاني' else '' end,
    './?tab=pradar', 'prices-' || new.id);
  return new;
exception when others then return new;
end $$;

-- ---------- تعبئة الأيام الفائتة (من 16 أكتوبر وكل يوم ناقص) بدون إشعارات ----------
select set_config('app.gpp_quiet', '1', false);
select growth_price_pages_refresh(array(select distinct dt from gpp_lines where dt > (now() at time zone 'Asia/Riyadh')::date - 40)) as pages_done;
select set_config('app.gpp_quiet', '', false);
select 'تم ✓ رادار المشتريات صار يتولّد من جروث مباشرة — آخر يوم: ' ||
  coalesce((select max(id) from app_docs where app = 'prices' and coll = 'pages'), '—') ||
  ' · أيام من جروث: ' || (select count(*) from app_docs where app = 'prices' and coll = 'pages' and data->>'auto' = 'growth') as result;
