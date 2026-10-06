"""يبني صفحات التطبيقات الكاملة داخل البوابة من نسخها الأصلية.
python tools/build_apps.py <مجلد المصادر>   (sales.src.html, channels.src.html, income.src.html)"""
import re, sys, pathlib
SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'apps-src')
OUT = pathlib.Path(__file__).resolve().parent.parent / 'apps'
HEAD = '''<script>window.PORTAL_APP='%s';</script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>
<script src="../config.js?v=5"></script>
<script src="../portal-db.js?v=5"></script>
<script src="../portal-charts.js?v=5"></script>
<style>html[data-ro] #tbEntry{display:none!important}html[data-ro] .tabs .in{grid-template-columns:1fr 1fr!important}</style>
'''
for app in ('sales', 'channels', 'income'):
    h = (SRC / f'{app}.src.html').read_text(encoding='utf-8')
    n = 0
    def mark(m):
        global n; n += 1
        return '<script type="text/x-app">'
    h = re.sub(r'<script>', mark, h)
    h = h.replace('<head>', '<head>\n' + HEAD % app, 1)
    assert 'PORTAL_APP' in h, app
    i = h.index('const BR=[')
    j = h.index('];', i) + 2
    h = h[:j] + 'window.__pf&&window.__pf(BR);' + h[j:]
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
