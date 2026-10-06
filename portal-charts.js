/* حركة الرسوم البيانية + لمس أي عنصر في الرسم يفتح تفاصيله كاملة.
   يعمل داخل تطبيقات البوابة وصفحات التقارير اليومية. */
(function () {
  'use strict';
  var APP = window.PORTAL_APP || 'page';
  var RM = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var MONTHS = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  var DAYS = ['الأحد', 'الإثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];
  var VAT = 0.15;
  function fmt(n, d) { if (n == null || isNaN(n)) return '—'; d = d || 0; return Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }); }
  function pct(x, d) { return x == null || !isFinite(x) ? '—' : (x * 100).toFixed(d == null ? 1 : d) + '%'; }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function iso(d) { return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
  function dt(s) { var p = s.split('-').map(Number); return new Date(p[0], p[1] - 1, p[2] || 1); }
  function sum(a) { return a.reduce(function (t, v) { return t + (+v || 0); }, 0); }
  function delta(a, b) { if (!b || a == null) return ''; var d = a / b - 1; return '<span class="pc-' + (d >= 0 ? 'up' : 'dn') + '">' + (d >= 0 ? '▲ ' : '▼ ') + pct(Math.abs(d)) + '</span>'; }
  function norm(c) { if (!c) return ''; c = String(c).trim().toLowerCase(); if (c[0] === '#') { if (c.length === 4) c = '#' + c[1] + c[1] + c[2] + c[2] + c[3] + c[3]; return c.slice(0, 7); }
    var m = c.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/); if (m) return '#' + [m[1], m[2], m[3]].map(function (x) { return (+x).toString(16).padStart(2, '0'); }).join(''); return c; }

  // ---------- styles ----------
  var css = document.createElement('style');
  css.textContent = [
    '.pc-sheet-bg{position:fixed;inset:0;z-index:60;background:transparent}',
    '.pc-sheet{position:fixed;z-index:61;background:#16233A;color:#fff;width:min(300px,calc(100vw - 24px));max-height:70vh;overflow:auto;border-radius:12px;padding:11px 13px;box-shadow:0 10px 30px rgba(15,25,40,.35);direction:rtl;font-family:"IBM Plex Sans Arabic",Tahoma,sans-serif;font-size:12.5px;line-height:1.6;animation:pcpop .16s ease-out}',
    '.pc-sheet h4{margin:0;font-size:14px;font-weight:700;font-family:"Readex Pro","IBM Plex Sans Arabic",Tahoma,sans-serif}',
    '.pc-sheet .pc-sub{color:#AEB9CC;font-size:11.5px;margin:0 0 6px}',
    '.pc-big{font-size:19px;font-weight:700;font-variant-numeric:tabular-nums;font-family:"Readex Pro",Tahoma,sans-serif;margin:2px 0}',
    '.pc-big small{color:#AEB9CC!important}',
    '.pc-sheet table{width:100%;border-collapse:collapse;font-size:12px;margin-top:6px}',
    '.pc-sheet td,.pc-sheet th{padding:4px 2px;border-bottom:1px solid rgba(255,255,255,.12);text-align:start;color:#fff}',
    '.pc-sheet th{font-size:10.5px;color:#AEB9CC!important;font-weight:600}',
    '.pc-sheet td.n,.pc-sheet th.n{text-align:end;font-variant-numeric:tabular-nums;white-space:nowrap}',
    '.pc-sheet td[style*="6B7A90"]{color:#AEB9CC!important}',
    '.pc-sheet tr.t td{font-weight:700;border-top:1px solid rgba(255,255,255,.5);border-bottom:0}',
    '.pc-sw{display:inline-block;width:8px;height:8px;border-radius:2px;margin-inline-end:5px;vertical-align:middle}',
    '.pc-up{color:#5FD39A;font-weight:600}.pc-dn{color:#FF8A7E;font-weight:600}',
    '.pc-kv{display:grid;grid-template-columns:1fr 1fr;gap:5px;margin-top:6px}',
    '.pc-kv div{background:rgba(255,255,255,.08);border-radius:8px;padding:5px 8px}.pc-kv span{display:block;font-size:10.5px;color:#AEB9CC}.pc-kv b{font-variant-numeric:tabular-nums;font-size:12.5px}',
    '.pc-close{display:none}',
    '.pc-hit{cursor:pointer}',
    'svg.pc-focus .pc-dim{opacity:.35;transition:opacity .2s}',
    '@keyframes pcpop{from{opacity:0;transform:translateY(4px) scale(.97)}}'
  ].join('\n');
  (document.head || document.documentElement).appendChild(css);

  // ---------- sheet ----------
  var lastFocus = null;
  function closeSheet() { var b = document.querySelector('.pc-sheet-bg'); if (b) b.remove(); if (lastFocus) { lastFocus.classList.remove('pc-focus'); lastFocus.querySelectorAll('.pc-dim').forEach(function (e) { e.classList.remove('pc-dim'); }); lastFocus = null; } }
  var tapX = innerWidth / 2, tapY = innerHeight / 2;
  document.addEventListener('pointerdown', function (e) { tapX = e.clientX; tapY = e.clientY; }, true);
  function sheet(title, sub, body) {
    closeSheet();
    var bg = document.createElement('div'); bg.className = 'pc-sheet-bg';
    var tip = document.createElement('div'); tip.className = 'pc-sheet'; tip.setAttribute('role', 'dialog'); tip.setAttribute('aria-label', title);
    tip.innerHTML = '<h4>' + esc(title) + '</h4>' + (sub ? '<div class="pc-sub">' + sub + '</div>' : '') + body;
    bg.appendChild(tip); document.body.appendChild(bg);
    var w = tip.offsetWidth, h = tip.offsetHeight, x = tapX - w / 2, y = tapY - h - 14;
    if (y < 8) y = tapY + 16; if (y + h > innerHeight - 8) y = Math.max(8, innerHeight - h - 8);
    x = Math.max(12, Math.min(innerWidth - w - 12, x));
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
    bg.addEventListener('click', function (e) { if (!tip.contains(e.target)) closeSheet(); });
  }
  window.addEventListener('scroll', function () { closeSheet(); }, { passive: true });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeSheet(); });

  // ---------- helpers on SVG ----------
  function isChart(svg) {
    if (!svg || svg.closest('button,.tab,nav')) return false;
    var vb = svg.getAttribute('viewBox') || ''; if (/^0 0 2[04] 2[04]$/.test(vb.trim())) return false;
    var r = svg.getBoundingClientRect(); return r.width > 60 && r.height > 50;
  }
  function center(el) { var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, r: r }; }
  function texts(svg) { return Array.prototype.map.call(svg.querySelectorAll('text'), function (t) { var c = center(t); return { el: t, s: (t.textContent || '').trim(), x: c.x, y: c.y, r: c.r }; }).filter(function (t) { return t.s; }); }
  function axisLabel(svg, c) {
    var sr = svg.getBoundingClientRect(), T = texts(svg).filter(function (t) { return t.y > sr.top + sr.height * 0.78; });
    var best = null, bd = 1e9; T.forEach(function (t) { var d = Math.abs(t.x - c.x); if (d < bd) { bd = d; best = t; } });
    return best && bd < Math.max(30, c.r.width) ? best.s : '';
  }
  function valueLabel(svg, c, axis) {
    var T = texts(svg).filter(function (t) { return t.s !== axis && /[\d٠-٩]/.test(t.s) && Math.abs(t.x - c.x) < Math.max(14, c.r.width / 2 + 6) && t.y <= c.r.bottom + 4 && t.y >= c.r.top - 28; });
    T.sort(function (a, b) { return Math.abs(a.y - c.r.top) - Math.abs(b.y - c.r.top); });
    return T[0] ? T[0].s : '';
  }
  function legendName(root, color) {
    color = norm(color); if (!color) return '';
    var els = root.querySelectorAll('.sw,.dot,i[style*="background"],span[style*="background"]');
    for (var i = 0; i < els.length; i++) { var e = els[i]; if (norm(e.style.background || e.style.backgroundColor) === color) { var t = (e.parentElement && e.parentElement.textContent || '').replace(/[\d.,%٪]+\s*$/, '').trim(); if (t) return t; } }
    return '';
  }
  function cardTitle(svg) { var card = svg.closest('.card,section,article,.br,.chart'); var h = card && card.querySelector('h2,h3,h4'); return (h ? h.textContent : (svg.getAttribute('aria-label') || 'تفاصيل')).trim(); }
  function focusEl(svg, el) { lastFocus = svg; svg.classList.add('pc-focus'); svg.querySelectorAll('rect,circle,path,polyline').forEach(function (e) { if (e !== el && e.getAttribute('fill') !== 'none') e.classList.add('pc-dim'); }); }

  // ---------- app-specific details ----------
  function st() { return window.__st || {}; }
  function brs() { return (window.__BR || []).slice(); }
  function brByName(n) { return brs().find(function (b) { return n && (b.name === n || b.short === n || n.indexOf(b.short) >= 0); }); }

  function salesDay(date) {
    var S = st(), B = brs(), doc = (S.sales || {})[date];
    var dd = dt(date), title = DAYS[dd.getDay()] + ' ' + dd.getDate() + ' ' + MONTHS[dd.getMonth()] + ' ' + dd.getFullYear();
    var scope = S.scope && S.scope !== 'all' ? [S.scope] : B.map(function (b) { return b.k; });
    if (!doc) { sheet(title, 'لا توجد مبيعات مسجلة لهذا اليوم بعد', ''); return true; }
    var tot = sum(scope.map(function (k) { return doc[k]; }));
    var prev = (S.sales || {})[iso(new Date(dd.getFullYear(), dd.getMonth(), dd.getDate() - 7))], prevT = prev ? sum(scope.map(function (k) { return prev[k]; })) : null;
    var m = date.slice(0, 7), days = Object.keys(S.sales || {}).filter(function (k) { return k.slice(0, 7) === m; }).sort();
    var dayTots = days.map(function (k) { return sum(scope.map(function (b) { return S.sales[k][b]; })); }), mTot = sum(dayTots), avg = days.length ? mTot / days.length : null;
    var rank = dayTots.slice().sort(function (a, b) { return b - a; }).indexOf(tot) + 1;
    var rows = scope.map(function (k) { var b = B.find(function (x) { return x.k === k; }) || { name: k, col: '#999' }; var v = doc[k], pv = prev ? prev[k] : null;
      return '<tr><td><span class="pc-sw" style="background:' + b.col + '"></span>' + esc(b.short || b.name) + '</td><td class="n">' + fmt(v, 2) + '</td><td class="n">' + pct(tot ? (v || 0) / tot : null) + '</td><td class="n">' + delta(v, pv) + '</td></tr>'; }).join('');
    var body = '<div class="pc-big">' + fmt(tot, 2) + ' <small style="font-size:13px;color:#6B7A90">ر.س</small></div>' +
      '<div class="pc-kv"><div><span>مقابل ' + DAYS[dd.getDay()] + ' الماضي</span><b>' + (prevT != null ? fmt(prevT) + ' ' + delta(tot, prevT) : '—') + '</b></div><div><span>مقابل متوسط الشهر</span><b>' + fmt(avg) + ' ' + delta(tot, avg) + '</b></div>' +
      '<div><span>ترتيبه في الشهر</span><b>' + (rank > 0 ? rank + ' من ' + days.length : '—') + '</b></div><div><span>حصته من مبيعات الشهر</span><b>' + pct(mTot ? tot / mTot : null) + '</b></div></div>' +
      (scope.length > 1 ? '<table><thead><tr><th>الفرع</th><th class="n">المبيعات</th><th class="n">الحصة</th><th class="n">عن الأسبوع الماضي</th></tr></thead><tbody>' + rows + '<tr class="t"><td>الإجمالي</td><td class="n">' + fmt(tot, 2) + '</td><td class="n">100%</td><td class="n">' + delta(tot, prevT) + '</td></tr></tbody></table>' : '');
    sheet(title, 'المبيعات اليومية' + (scope.length === 1 ? ' · ' + esc((B.find(function (x) { return x.k === scope[0]; }) || {}).name || '') : ''), body);
    return true;
  }
  function salesWeekday(wd, only) {
    var S = st(), B = brs(), m = S.month; if (!m) return false;
    var scope = only ? [only] : S.scope && S.scope !== 'all' ? [S.scope] : B.map(function (b) { return b.k; });
    var ds = Object.keys(S.sales || {}).filter(function (k) { return k.slice(0, 7) === m && dt(k).getDay() === wd; }).sort();
    var vals = ds.map(function (k) { return sum(scope.map(function (b) { return S.sales[k][b]; })); }), avg = vals.length ? sum(vals) / vals.length : null;
    var bn = only ? ((B.find(function (x) { return x.k === only; }) || {}).short || '') : '';
    if (!ds.length) { sheet('أيام ' + DAYS[wd] + (bn ? ' · ' + bn : ''), 'لا توجد أيام ' + DAYS[wd] + ' مسجلة في ' + MONTHS[+m.slice(5) - 1] + ' بعد', ''); return true; }
    var body = '<div class="pc-big">' + fmt(avg) + ' <small style="font-size:13px;color:#6B7A90">متوسط اليوم</small></div><table><thead><tr><th>التاريخ</th><th class="n">المبيعات</th><th class="n">عن المتوسط</th></tr></thead><tbody>' +
      ds.map(function (k, i) { return '<tr><td>' + dt(k).getDate() + ' ' + MONTHS[dt(k).getMonth()] + '</td><td class="n">' + fmt(vals[i], 2) + '</td><td class="n">' + delta(vals[i], avg) + '</td></tr>'; }).join('') + '</tbody></table>';
    sheet('أيام ' + DAYS[wd] + (bn ? ' · ' + bn : '') + ' · ' + MONTHS[+m.slice(5) - 1], ds.length + ' أيام مسجلة هذا الشهر', body); return true;
  }
  function channelDetail(name) {
    var S = st(), CH = window.__CH || {}, B = brs(), doc = (S.periods || {})[S.month]; if (!doc) return false;
    var key = Object.keys(CH).find(function (k) { return CH[k].name === name; });
    if (key) {
      var rows = B.map(function (b) { var bd = doc[b.k] || {}, v = +bd[key] || 0, bt = sum(Object.keys(bd).map(function (k) { return bd[k]; })); return { b: b, v: v, sh: bt ? v / bt : null }; }).filter(function (r) { return r.v > 0; });
      var tot = sum(rows.map(function (r) { return r.v; }));
      sheet(name, 'منافذ المبيعات · ' + MONTHS[+S.month.slice(5) - 1] + ' ' + S.month.slice(0, 4),
        '<div class="pc-big">' + fmt(tot, 2) + ' <small style="font-size:13px;color:#6B7A90">قبل الضريبة</small></div><div class="pc-kv"><div><span>بعد الضريبة</span><b>' + fmt(tot * (1 + VAT), 2) + '</b></div><div><span>الفروع</span><b>' + rows.length + '</b></div></div>' +
        '<table><thead><tr><th>الفرع</th><th class="n">قبل الضريبة</th><th class="n">من مبيعات الفرع</th></tr></thead><tbody>' + rows.map(function (r) { return '<tr><td><span class="pc-sw" style="background:' + r.b.col + '"></span>' + esc(r.b.short) + '</td><td class="n">' + fmt(r.v, 2) + '</td><td class="n">' + pct(r.sh) + '</td></tr>'; }).join('') + '</tbody></table>');
      return true;
    }
    var b = brByName(name); if (!b) return false;
    var bd = doc[b.k] || {}, list = Object.keys(bd).filter(function (k) { return CH[k] && +bd[k] > 0; }).map(function (k) { return { n: CH[k].name, c: CH[k].col, v: +bd[k] }; }).sort(function (x, y) { return y.v - x.v; });
    var t = sum(list.map(function (x) { return x.v; }));
    sheet(b.name, 'توزيع المنافذ · ' + MONTHS[+S.month.slice(5) - 1], '<div class="pc-big">' + fmt(t, 2) + ' <small style="font-size:13px;color:#6B7A90">قبل الضريبة</small></div><table><thead><tr><th>المنفذ</th><th class="n">المبلغ</th><th class="n">النسبة</th></tr></thead><tbody>' +
      list.map(function (x) { return '<tr><td><span class="pc-sw" style="background:' + x.c + '"></span>' + esc(x.n) + '</td><td class="n">' + fmt(x.v, 2) + '</td><td class="n">' + pct(t ? x.v / t : null) + '</td></tr>'; }).join('') + '<tr class="t"><td>الإجمالي</td><td class="n">' + fmt(t, 2) + '</td><td class="n">100%</td></tr></tbody></table>');
    return true;
  }

  function generic(svg, el, c) {
    var axis = axisLabel(svg, c), val = valueLabel(svg, c, axis), color = el.getAttribute('fill') || el.getAttribute('stroke');
    var who = legendName(document, color);
    var tt = el.querySelector && el.querySelector('title'); var tip = tt ? tt.textContent : (el.getAttribute('aria-label') || '');
    if (!axis && !val && !who && !tip) return false;
    var rows = [];
    if (who) rows.push(['البند', esc(who)]);
    if (axis) rows.push(['الفترة', esc(axis)]);
    if (val) rows.push(['القيمة', esc(val)]);
    if (tip) rows.push(['التفاصيل', esc(tip)]);
    // كل أعمدة نفس الفترة (للرسوم المكدسة)
    var same = [];
    if (axis) svg.querySelectorAll('rect').forEach(function (r) { if (r === el) return; var rc = center(r); if (Math.abs(rc.x - c.x) < 2 && rc.r.height > 1) { var n = legendName(document, r.getAttribute('fill')); if (n) same.push(n); } });
    sheet(cardTitle(svg), esc(svg.getAttribute('aria-label') || ''), '<table><tbody>' + rows.map(function (r) { return '<tr><td style="color:#6B7A90">' + r[0] + '</td><td class="n" style="white-space:normal">' + r[1] + '</td></tr>'; }).join('') + '</tbody></table>' +
      (same.length ? '<div class="pc-sub" style="margin-top:8px">في نفس العمود أيضاً: ' + esc(same.join('، ')) + '</div>' : ''));
    return true;
  }

  function onChartTap(svg, el) {
    var c = center(el), S = st();
    if (APP === 'sales' && S.month) {
      var ax = axisLabel(svg, c);
      if (/^\d{1,2}$/.test(ax) && +ax >= 1 && +ax <= 31) return salesDay(S.month + '-' + String(+ax).padStart(2, '0'));
      var wd = DAYS.indexOf(ax); if (wd >= 0) return salesWeekday(wd);
      if (el.tagName === 'path' || el.tagName === 'circle') { var b = brs().find(function (x) { return norm(x.col) === norm(el.getAttribute('fill') || el.getAttribute('stroke')); }); if (b && S.scope === 'all') { var ks = Object.keys(S.sales || {}).filter(function (k) { return k.slice(0, 7) === S.month; }); var last = ks.sort().pop(); if (last) return salesDay(last); } }
    }
    if (APP === 'channels' && S.month) {
      var col = norm(el.getAttribute('fill') || el.getAttribute('stroke')), CH = window.__CH || {};
      var k = Object.keys(CH).find(function (x) { return norm(CH[x].col) === col; }); if (k && channelDetail(CH[k].name)) return true;
      var b2 = brs().find(function (x) { return norm(x.col) === col; }); if (b2 && channelDetail(b2.name)) return true;
    }
    return generic(svg, el, c);
  }

  document.addEventListener('click', function (e) {
    if (e.target.closest('.pc-sheet-bg')) return;
    // صفوف القوائم والأشرطة في التطبيقات
    if (APP === 'channels') {
      var row = e.target.closest('.chr,.mbar i,.dl,.legend span'); if (row && !e.target.closest('button,input,select,a')) {
        var name = row.getAttribute('title') ? row.getAttribute('title').replace(/\s[\d.]+%$/, '') : (row.querySelector('.nm') || row).textContent.replace(/[\d.,%]+\s*$/, '').trim();
        if (channelDetail(name)) return;
      }
    }
    if (APP === 'sales') { var hc = e.target.closest('.hm .c'); if (hc && st().month) { var sib = Array.prototype.slice.call(hc.parentElement.children), idx = sib.indexOf(hc), col = (idx % 8) - 1, rowEl = sib[idx - col - 1], rb = rowEl ? brByName(rowEl.textContent.trim()) : null; if (col >= 0 && salesWeekday(col, rb && rb.k)) return; } }
    if (APP === 'sales') { var cell = e.target.closest('#cal .c:not(.x):not(.h)'); if (cell && st().month) { var d = parseInt(cell.textContent, 10); if (d) { salesDay(st().month + '-' + String(d).padStart(2, '0')); return; } } }
    var el = e.target.closest('rect,circle,path,polygon,polyline'); if (!el) return;
    var svg = el.ownerSVGElement || el.closest('svg'); if (!isChart(svg)) return;
    if (el.tagName === 'rect' && (+el.getAttribute('height') || 0) < 2) return;
    if (onChartTap(svg, el)) focusEl(svg, el);
  }, true);

  // ---------- animation ----------
  var seen = new WeakSet();
  function animate(svg) {
    if (seen.has(svg)) return; seen.add(svg);
    if (RM || window.__pcQuiet || !svg.animate || APP === 'income') return;
    var i = 0;
    svg.querySelectorAll('rect').forEach(function (r) {
      var h = +r.getAttribute('height') || 0, w = +r.getAttribute('width') || 0; if (h < 2 && w < 2) return;
      r.classList.add('pc-hit'); r.style.transformBox = 'fill-box';
      var horiz = w > h * 3 && w > 40; r.style.transformOrigin = horiz ? 'right center' : 'center bottom';
      r.animate([{ transform: horiz ? 'scaleX(0)' : 'scaleY(0)' }, { transform: 'none' }], { duration: 650, delay: Math.min(i++ * 18, 500), easing: 'cubic-bezier(.2,.8,.2,1)', fill: 'backwards' });
    });
    svg.querySelectorAll('polyline,path').forEach(function (p) {
      var fill = p.getAttribute('fill');
      if (fill === 'none' && p.getTotalLength) { var L = p.getTotalLength(); if (!L) return; var dash = p.getAttribute('stroke-dasharray'); if (dash && dash !== 'none') { p.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 700, delay: 300, fill: 'backwards' }); return; }
        p.animate([{ strokeDasharray: L + ' ' + L, strokeDashoffset: L }, { strokeDasharray: L + ' ' + L, strokeDashoffset: 0 }], { duration: 1100, easing: 'ease-out', fill: 'backwards' }); }
      else if (fill && fill !== 'none') { p.classList.add('pc-hit'); p.style.transformBox = 'view-box'; p.style.transformOrigin = 'center';
        p.animate([{ opacity: 0, transform: 'scale(.85) rotate(-8deg)' }, { opacity: 1, transform: 'none' }], { duration: 700, delay: Math.min(i++ * 60, 500), easing: 'cubic-bezier(.2,.8,.2,1)', fill: 'backwards' }); }
    });
    svg.querySelectorAll('circle').forEach(function (cc) { cc.classList.add('pc-hit'); cc.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 500, delay: 400, fill: 'backwards' }); });
  }
  function scan(root) { (root.querySelectorAll ? root.querySelectorAll('svg') : []).forEach(function (s) { if (isChart(s)) animate(s); else if (!s.getBoundingClientRect().width) { /* مخفي الآن */ } }); }
  function start() {
    scan(document);
    new MutationObserver(function (ms) { ms.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType !== 1) return; if (n.tagName === 'svg') { if (isChart(n)) animate(n); } else scan(n); }); }); })
      .observe(document.body, { childList: true, subtree: true });
    // عند فتح تبويب مخفي: حرّك رسومه أول مرة يظهر
    document.addEventListener('click', function () { setTimeout(function () { scan(document); }, 60); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
