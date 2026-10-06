"""يبني صفحات التطبيقات الكاملة داخل البوابة من نسخها الأصلية.
python tools/build_apps.py <مجلد المصادر>   (sales.src.html, channels.src.html, income.src.html)"""
import re, sys, pathlib
SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'apps-src')
OUT = pathlib.Path(__file__).resolve().parent.parent / 'apps'
HEAD = '''<script>window.PORTAL_APP='%s';</script>
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>
<script src="../config.js?v=7"></script>
<script src="../portal-db.js?v=7"></script>
<script src="../portal-charts.js?v=8"></script>
<style>html[data-ro] #tbEntry{display:none!important}html[data-ro] .tabs .in{grid-template-columns:1fr 1fr!important}:root{--bg:#F2F6EA!important;--panel2:#EDF2E3!important;--line:#DCE5CF!important;--line2:#CBD7BA!important;--txt:#1E3326!important;--mute:#647563!important;--dim:#869684!important}html{-webkit-text-size-adjust:100%%;text-size-adjust:100%%}header.top{position:static!important;background:none!important;padding-block:12px 4px!important}.hm{grid-template-columns:50px repeat(7,minmax(0,1fr))!important;gap:2px!important}.hm .c{font-size:9.5px!important;padding:7px 0!important;letter-spacing:-.4px;overflow:hidden;white-space:nowrap;cursor:pointer}.hm .h,.hm .r{font-size:9.5px!important}.cal{gap:3px!important}.cal .c{cursor:pointer}.cal .c .v{font-size:9px!important;letter-spacing:-.4px;white-space:nowrap}.cal .c .d{font-size:9.5px!important}</style>
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
