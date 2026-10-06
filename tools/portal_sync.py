# -*- coding: utf-8 -*-
"""مزامنة بيانات التطبيقات مع بوابة التقارير (myreportshub.report).

كلمة المرور تُمرَّر كمتغير بيئة فقط ولا تُطبع أبداً:
    set PORTAL_PASS=********

1) مستندات التطبيقات (نفس مستندات قاعدة بيانات التطبيق بالضبط):
    python portal_sync.py payload.json
   payload.json:
    {"app_docs":[{"app":"sales","coll":"sales","id":"2026-10-06","data":{...}}, ...]}
   app: sales (sales/targets) · channels (periods) · income (stmts)
   branches تُحسب تلقائياً إذا لم تُرسل (stmts ← br ، reports ← scope ، غيرها ← لا شيء).

2) صفحة تقرير يومي (HTML كامل):
    python portal_sync.py --page prices 2026-10-06 report.html
    python portal_sync.py --page daily  2026-10-06 report.html

مكتبات بايثون القياسية فقط.
"""
import json, os, sys, urllib.request, urllib.error

URL = os.environ.get("PORTAL_URL", "https://olsqykputyhigalzmlbs.supabase.co")
KEY = "sb_publishable_KLB7HL6IGxhNj_8PSebE6w_F_CpCM8r"
DOMAIN = "myreportshub.report"
ALL_BRANCHES = ["az", "sh", "pc"]
TABLES = [("daily_sales", "branch_id,day"), ("channel_sales", "branch_id,month"),
          ("income_statements", "branch_id,month"), ("chicken_prices", "day,item"),
          ("carcass_prices", "day,item")]


def branches_for(d):
    if d.get("branches") is not None:
        return d["branches"]
    data = d.get("data") or {}
    if d["coll"] == "stmts":
        return [data["br"]] if data.get("br") else []
    if d["coll"] == "reports":
        sc = data.get("scope") or "all"
        return ALL_BRANCHES if sc == "all" else [sc]
    return []


def req(method, path, body=None, token=None, prefer=None):
    h = {"apikey": KEY, "Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    if prefer:
        h["Prefer"] = prefer
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    r = urllib.request.Request(URL + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            t = resp.read().decode("utf-8")
            return json.loads(t) if t else None
    except urllib.error.HTTPError as e:
        raise SystemExit("ERROR %s %s: %s" % (e.code, path.split("?")[0], e.read().decode("utf-8")[:300]))


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit("usage: python portal_sync.py payload.json | --page <prices|daily> <YYYY-MM-DD> <file.html>")
    user, pw = os.environ.get("PORTAL_USER", "sync"), os.environ.get("PORTAL_PASS")
    if not pw:
        raise SystemExit("ERROR: PORTAL_PASS غير موجود")
    if args[0] == "--page":
        if len(args) < 4:
            raise SystemExit("usage: --page <prices|daily> <YYYY-MM-DD> <file.html>")
        app, day, path = args[1], args[2], args[3]
        payload = {"app_docs": [{"app": app, "coll": "pages", "id": day,
                                 "data": {"date": day, "html": open(path, encoding="utf-8").read()}}]}
    else:
        payload = json.load(open(args[0], encoding="utf-8"))
    email = user if "@" in user else user + "@" + DOMAIN
    tok = req("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": pw})["access_token"]
    out = []
    docs = payload.get("app_docs") or []
    rows = [{"app": d["app"], "coll": d["coll"], "id": str(d["id"]), "data": d["data"],
             "branches": branches_for(d)} for d in docs]
    for i in range(0, len(rows), 25):
        req("POST", "/rest/v1/app_docs?on_conflict=app,coll,id", rows[i:i + 25], tok,
            "resolution=merge-duplicates,return=minimal")
    counts = {}
    for r in rows:
        k = r["app"] + "/" + r["coll"]
        counts[k] = counts.get(k, 0) + 1
    out += ["%s: %d" % kv for kv in counts.items()]
    for table, conflict in TABLES:  # الجداول القديمة (للتوافق)
        trows = payload.get(table) or []
        for i in range(0, len(trows), 200):
            req("POST", "/rest/v1/%s?on_conflict=%s" % (table, conflict), trows[i:i + 200], tok,
                "resolution=merge-duplicates,return=minimal")
        if trows:
            out.append("%s: %d" % (table, len(trows)))
    print("OK " + (" · ".join(out) if out else "لا يوجد بيانات"))


if __name__ == "__main__":
    main()
