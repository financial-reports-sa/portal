# -*- coding: utf-8 -*-
"""مزامنة أرقام التقارير مع بوابة التقارير (myreportshub.report).

الاستخدام:
    set PORTAL_USER=sync
    set PORTAL_PASS=********
    python portal_sync.py payload.json

payload.json بنفس شكل ملف الاستيراد:
    {"daily_sales":[{"branch_id","day","amount"}],
     "channel_sales":[{"branch_id","month","data"}],
     "income_statements":[{"branch_id","month","is_estimate","meta","groups"}],
     "chicken_prices":[{"day","item","unit","price"}],
     "carcass_prices":[{"day","item","price"}]}
مكتبات بايثون القياسية فقط. لا يطبع كلمة المرور أبداً.
"""
import json, os, sys, urllib.request, urllib.error

URL = os.environ.get("PORTAL_URL", "https://olsqykputyhigalzmlbs.supabase.co")
KEY = "sb_publishable_KLB7HL6IGxhNj_8PSebE6w_F_CpCM8r"
DOMAIN = "myreportshub.report"
TABLES = [("daily_sales", "branch_id,day"), ("channel_sales", "branch_id,month"),
          ("income_statements", "branch_id,month"), ("chicken_prices", "day,item"),
          ("carcass_prices", "day,item")]


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
    if len(sys.argv) < 2:
        raise SystemExit("usage: python portal_sync.py payload.json")
    user, pw = os.environ.get("PORTAL_USER", "sync"), os.environ.get("PORTAL_PASS")
    if not pw:
        raise SystemExit("ERROR: PORTAL_PASS غير موجود")
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
    email = user if "@" in user else user + "@" + DOMAIN
    tok = req("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": pw})["access_token"]
    out = []
    for table, conflict in TABLES:
        rows = payload.get(table) or []
        for i in range(0, len(rows), 200):
            req("POST", "/rest/v1/%s?on_conflict=%s" % (table, conflict), rows[i:i + 200], tok,
                "resolution=merge-duplicates,return=minimal")
        if rows:
            out.append("%s: %d" % (table, len(rows)))
    print("OK " + (" · ".join(out) if out else "لا يوجد بيانات"))


if __name__ == "__main__":
    main()
