"""يبني صفحات التطبيقات الكاملة داخل البوابة من نسخها الأصلية.
python tools/build_apps.py <مجلد المصادر>   (sales.src.html, channels.src.html, income.src.html)"""
import re, sys, pathlib
SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'apps-src')
OUT = pathlib.Path(__file__).resolve().parent.parent / 'apps'
HEAD = '''<script>window.PORTAL_APP='%s';</script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>
<script src="../config.js?v=7"></script>
<script src="../portal-db.js?v=7"></script>
<script src="../portal-charts.js?v=9"></script>
<style>@media (max-width:760px){body{zoom:.86}}html[data-ro] #tbEntry{display:none!important}html[data-ro] .tabs .in{grid-template-columns:1fr 1fr!important}:root{--bg:#F5F5F1!important;--panel2:#EFEFEA!important;--line:#E6E6E0!important;--line2:#D7D8D0!important;--txt:#18231C!important;--mute:#6B706A!important;--dim:#8E928C!important}html{-webkit-text-size-adjust:100%%;text-size-adjust:100%%}header.top{position:static!important;background:none!important;padding-block:12px 4px!important}.hm{grid-template-columns:50px repeat(7,minmax(0,1fr))!important;gap:2px!important}.hm .c{font-size:9.5px!important;padding:7px 0!important;letter-spacing:-.4px;overflow:hidden;white-space:nowrap;cursor:pointer}.hm .h,.hm .r{font-size:9.5px!important}.cal{gap:3px!important}.cal .c{cursor:pointer}.cal .c .v{font-size:9px!important;letter-spacing:-.4px;white-space:nowrap}.cal .c .d{font-size:9.5px!important}</style>
'''
TREASURY_COLORS = {  # الخزينة تصميمها غامق — نحوّلها لنفس ألوان البوابة الفاتحة
    '#08111F': '#F5F5F1', '#0F1D33': '#FFFFFF', '#142744': '#EFEFEA', '#22395C': '#E6E6E0', '#2C4870': '#D7D8D0',
    '#EAF0F8': '#18231C', '#8FA5C0': '#6B706A', '#5E7597': '#8E928C', '#EBCF7A': '#9A7B12', '#3FB98A': '#1FA16B',
    '#E0654A': '#D0453A', '#E0A72E': '#C98A0C', '#1B3358': '#F0F0EB', '#1B3152': '#F0F0EB', '#17304F': '#F0F0EB',
    '#3E5577': '#C9CBC3', '#AFC0D6': '#4F554F', '#8FB4E3': '#3C6FB0', '#F4A493': '#C24A33', '#6FC3DF': '#2A8BA8',
    '#7FD8B2': '#1F8F63', '#F2CE85': '#A9790F', 'rgba(8,17,31,.94)': 'rgba(255,255,255,.95)'}
for app in ('sales', 'channels', 'income', 'treasury'):
    h = (SRC / f'{app}.src.html').read_text(encoding='utf-8')
    n = 0
    def mark(m):
        global n; n += 1
        return '<script type="text/x-app">'
    h = re.sub(r'<script>', mark, h)
    h = h.replace('<head>', '<head>\n' + HEAD % app, 1)
    assert 'PORTAL_APP' in h, app
    if 'const BR=[' in h:
        i = h.index('const BR=[')
        j = h.index('];', i) + 2
        h = h[:j] + 'window.__pf&&window.__pf(BR);' + h[j:]
    if app == 'treasury':
        for a, b in TREASURY_COLORS.items():
            h = re.sub(re.escape(a), b, h, flags=re.I)
        h = h.replace("const lblK = v => { const a=Math.abs(v); return (a>=1e6?(v/1e6).toFixed(2)+'M':(v/1e3).toFixed(1)+'K'); };",
                      "const lblK = v => Math.round(v).toLocaleString('en-US');")
        h = h.replace('font-size="10.5" font-weight="600" fill="#FFFFFF">${lblK(r.total)}', 'font-size="10" font-weight="600" fill="#18231C">${lblK(r.total)}')
        patch = (pathlib.Path(__file__).resolve().parent / 'patches' / 'treasury_trend.js').read_text(encoding='utf-8')
        def rep1(h, old, new):
            assert old in h, old[:60]
            return h.replace(old, new, 1)
        h = rep1(h, '  function renderDaily(){', patch + '\n  function renderDaily(){')
        h = rep1(h, 'drawLine(rows,n); drawBars(rows,n);', 'drawLine(rows,n); drawBars(rows,n); drawLiveTrend();')
        h = rep1(h, '<div class="card" id="barCard">', '<div class="card" id="trendCard"><h3>اتجاه السيولة <small id="trTxt"></small></h3><div id="trendBody"></div></div>\n    <div class="card" id="barCard">')
        h = rep1(h, "const U=50, pl=26, pr=26, pt=34, pb=30;", "const U=56, pl=44, pr=44, pt=34, pb=30;")
        h = rep1(h, 'stroke="#D4AF37" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round"/>`', 'stroke="#C9A227" stroke-width="1.7" stroke-linejoin="round" stroke-linecap="round"/>`')
        h = rep1(h, 'r="${r===last?4.6:3}"', 'r="${r===last?3.8:2.2}"')
        h = rep1(h, "line+=`<polyline points=\"${pts.join(' ')}\" fill=\"none\"", "const PP=s.map(r=>[X(r.day),Y(r.total)]); line+=`<path d=\"${smoothD(PP)}\" fill=\"none\"")
        h = rep1(h, "if(s.length>1) area+=`<polygon points=\"${X(s[0].day)},${pt+ih} ${pts.join(' ')} ${X(s[s.length-1].day)},${pt+ih}\" fill=\"url(#ga)\"/>`;",
                 "if(s.length>1) area+=`<path d=\"M${X(s[0].day)},${pt+ih} L${smoothD(PP).slice(1)} L${X(s[s.length-1].day)},${pt+ih} Z\" fill=\"url(#ga)\"/>`;")
        h = h.replace('color-scheme: dark', 'color-scheme: light').replace("localStorage.getItem('tab')", "localStorage.getItem('ttab')").replace("localStorage.setItem('tab'", "localStorage.setItem('ttab'")
    # كشف حالة التطبيق لطبقة تفاصيل الرسوم
    h = h.replace('const st={', 'const st=window.__st={', 1)
    h = h.replace('window.__pf&&window.__pf(BR);', 'window.__pf&&window.__pf(BR);window.__BR=BR;', 1)
    if app == 'channels':
        i = h.index('const CH={'); j = h.index('};', i) + 2
        h = h[:j] + 'window.__CH=CH;' + h[j:]
    # التطبيق الأصلي يفترض 3 فروع في نص الترتيب — يتجاوزه لمن عنده فروع أقل
    h = h.replace("if(a.scope==='all'&&a.parts){", "if(a.scope==='all'&&a.parts&&a.parts.length>=3){")
    (OUT / f'{app}.html').write_text(h, encoding='utf-8')
    print(app, 'inline scripts:', n, 'size:', len(h))
