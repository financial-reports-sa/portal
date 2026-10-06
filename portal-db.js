/* طبقة ربط التطبيقات الأصلية بقاعدة بيانات البوابة.
   تحاكي window.claude.use('db') و use('downloads') التي تستخدمها التطبيقات،
   وتطبّق صلاحيات المستخدم (الفروع، القراءة فقط) قبل تشغيل التطبيق. */
(function () {
  'use strict';
  var CFG = window.PORTAL_CONFIG || {};
  var APP = window.PORTAL_APP;
  var sb = window.supabase.createClient(CFG.url, CFG.key, { auth: { persistSession: true, autoRefreshToken: true } });
  var ctx = null;
  var listeners = [];

  function err(code, message) { var e = new Error(message || code); e.code = code; return e; }

  function snapshot(rows) {
    return { docs: rows.map(function (r) { return { id: r.id, data: function () { return r.data; } }; }), size: rows.length };
  }

  async function fetchColl(coll) {
    var r = await sb.rpc('app_list', { p_app: APP, p_coll: coll });
    if (r.error) throw err('unavailable', r.error.message);
    return r.data || [];
  }

  async function refresh(coll) {
    var ls = listeners.filter(function (l) { return !coll || l.coll === coll; });
    var colls = Array.from(new Set(ls.map(function (l) { return l.coll; })));
    for (var i = 0; i < colls.length; i++) {
      var c = colls[i];
      try {
        var rows = await fetchColl(c);
        ls.filter(function (l) { return l.coll === c; }).forEach(function (l) { try { l.cb(snapshot(rows)); } catch (e) { console.error(e); } });
      } catch (e) {
        ls.filter(function (l) { return l.coll === c; }).forEach(function (l) { if (l.err) l.err(e); });
      }
    }
  }

  function branchesFor(coll, data) {
    if (coll === 'reports') { var s = data && data.scope; return (!s || s === 'all') ? ctx.branches.slice() : [s]; }
    if (coll === 'stmts') return data && data.br ? [data.br] : [];
    return [];
  }

  async function write(coll, id, data) {
    if (!ctx.writer && coll !== 'reports') throw err('permission-denied', 'حسابك للعرض فقط');
    var row = { app: APP, coll: coll, id: id, data: data, branches: branchesFor(coll, data), updated_at: new Date().toISOString() };
    var q = ctx.writer ? sb.from('app_docs').upsert(row, { onConflict: 'app,coll,id' }) : sb.from('app_docs').insert(row);
    var r = await q;
    if (r.error) throw err('permission-denied', r.error.message);
    refresh(coll);
  }

  async function del(coll, id) {
    var r = await sb.from('app_docs').delete().eq('app', APP).eq('coll', coll).eq('id', id);
    if (r.error) throw err('permission-denied', r.error.message);
    refresh(coll);
  }

  function newId() { return (Date.now().toString(36) + Math.random().toString(36).slice(2, 10)); }

  var db = {
    collection: function (coll) {
      return {
        onSnapshot: function (cb, onErr) {
          var l = { coll: coll, cb: cb, err: onErr };
          listeners.push(l); refresh(coll);
          return function () { listeners = listeners.filter(function (x) { return x !== l; }); };
        },
        add: async function (data) { var id = newId(); await write(coll, id, data); return { id: id }; },
        doc: function (id) { return db.doc(coll + '/' + id); }
      };
    },
    doc: function (path) {
      var p = String(path).split('/'); var coll = p[0], id = p.slice(1).join('/');
      return {
        id: id,
        set: function (data) { return write(coll, id, data); },
        update: async function (patch) {
          var rows = await fetchColl(coll); var cur = (rows.find(function (r) { return r.id === id; }) || {}).data || {};
          return write(coll, id, Object.assign({}, cur, patch));
        },
        delete: function () { return del(coll, id); },
        get: async function () {
          var rows = await fetchColl(coll); var r = rows.find(function (x) { return x.id === id; });
          return { exists: !!r, id: id, data: function () { return r ? r.data : undefined; } };
        }
      };
    }
  };

  var downloads = {
    save: async function (o) {
      var data = o.data, name = o.filename || 'download';
      var blob = data instanceof Blob ? data : new Blob([data], { type: o.mimeType || 'application/octet-stream' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a'); a.href = url; a.download = name;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
      return { ok: true };
    }
  };

  window.claude = { use: async function (name) { if (name === 'db') return db; if (name === 'downloads') return downloads; return null; } };

  // تصفية قائمة الفروع داخل التطبيق حسب صلاحيات المستخدم
  window.__pf = function (BR) {
    if (!ctx || !Array.isArray(BR)) return;
    for (var i = BR.length - 1; i >= 0; i--) { if (ctx.branches.indexOf(BR[i].k) < 0) BR.splice(i, 1); }
  };

  setInterval(function () { if (document.visibilityState === 'visible') refresh(); }, 60000);
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') refresh(); });

  async function boot() {
    var s = (await sb.auth.getSession()).data.session;
    if (!s) { (window.top || window).location.href = new URL('../', location.href).href; return; }
    var res = await Promise.all([
      sb.from('profiles').select('role,active').eq('id', s.user.id).maybeSingle(),
      sb.rpc('my_branches')
    ]);
    var role = res[0].data && res[0].data.active ? res[0].data.role : null;
    ctx = { uid: s.user.id, writer: ['owner', 'admin', 'sync'].indexOf(role) >= 0, branches: res[1].data || [] };
    if (!ctx.writer) {
      document.documentElement.setAttribute('data-ro', '1');
      ['stab', 'ostab', 'istab'].forEach(function (k) { try { if (localStorage.getItem(k) === 'entry') localStorage.setItem(k, 'dash'); } catch (e) {} });
    }
    var scripts = Array.prototype.slice.call(document.querySelectorAll('script[type="text/x-app"]'));
    scripts.forEach(function (old) { var n = document.createElement('script'); n.textContent = old.textContent; old.replaceWith(n); });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
