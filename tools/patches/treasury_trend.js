  // ===== إضافات البوابة: منحنى انسيابي + اتجاه السيولة الحي =====
  const esc=t=>String(t).replace(/[&<>"]/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;"}[ch]));
  function smoothD(P){ if(P.length<2) return P.length?`M${P[0][0]},${P[0][1]}`:''; let d=`M${P[0][0]},${P[0][1]}`;
    for(let i=0;i<P.length-1;i++){ const p0=P[i-1]||P[i], p1=P[i], p2=P[i+1], p3=P[i+2]||p2, t=.18;
      d+=` C${p1[0]+(p2[0]-p0[0])*t},${p1[1]+(p2[1]-p0[1])*t} ${p2[0]-(p3[0]-p1[0])*t},${p2[1]-(p3[1]-p1[1])*t} ${p2[0]},${p2[1]}`; } return d; }
  function drawLiveTrend(){
    const box=$('#trendBody'); if(!box) return;
    if(!box.__ro&&window.ResizeObserver){ box.__ro=new ResizeObserver(()=>{ const w=box.clientWidth; if(w&&Math.abs(w-(box.__w||0))>8){ box.__w=w; drawLiveTrend(); } }); box.__ro.observe(box); }
    if(!box.clientWidth) return; const all=Object.values(st.daily||{}).filter(d=>d&&d.date&&d.total!=null).sort((a,b)=>a.date<b.date?-1:1);
    if(all.length<3){ box.innerHTML='<div class="empty">يلزم 3 أيام مسجلة على الأقل لحساب الاتجاه</div>'; $('#trTxt').textContent=''; return; }
    const day=all[all.length-1].date, from=addDays(day,-29);
    const r={daily:all,from,day,period:'30'}; const S=trendStats(r); if(S.n<3){ box.innerHTML='<div class="empty">يلزم 3 أيام مسجلة على الأقل خلال آخر 30 يوماً</div>'; return; }
    $('#trTxt').textContent='آخر 30 يوماً • '+S.n+' يوم';
    const dc=S.dir==='صاعد'?'#1FA16B':S.dir==='هابط'?'#D0453A':'#C98A0C', arrow=S.dir==='صاعد'?'▲':S.dir==='هابط'?'▼':'◆';
    const conf=S.R2>=.6?'قوي':S.R2>=.3?'متوسط':'ضعيف';
    // chart
    box.__w=box.clientWidth; const W=Math.max(300,Math.min(box.clientWidth||340,1000)), H=210, pl=14, pr=14, pt=26, pb=26, iw=W-pl-pr, ih=H-pt-pb;
    const xMax=Math.max(S.xEnd,S.last.x)||1; const X=x=>pl+iw-(x/xMax)*iw;
    const vals=S.pts.map(p=>p.y).concat([S.projLo,S.projHi,S.tr(0)]); let lo=Math.min(...vals), hi=Math.max(...vals); const pad=(hi-lo)*.08||1; lo-=pad; hi+=pad;
    const Y=v=>pt+(hi-v)/(hi-lo)*ih;
    let g=''; for(let i=0;i<=3;i++){ const y=pt+ih*i/3; g+=`<line x1="${pl}" x2="${W-pr}" y1="${y}" y2="${y}" stroke="#E6E6E0" stroke-dasharray="3 5"/>`; }
    const band=[]; for(let x=0;x<=xMax;x+=Math.max(1,Math.round(xMax/20))) band.push(x); if(band[band.length-1]!==xMax) band.push(xMax);
    const up=band.map(x=>[X(x),Y(S.tr(x)+S.s)]), dn=band.map(x=>[X(x),Y(S.tr(x)-S.s)]).reverse();
    const bandP=`<path d="M${up.map(p=>p.join(',')).join(' L')} L${dn.map(p=>p.join(',')).join(' L')} Z" fill="${dc}" fill-opacity=".08"/>`;
    const trendL=`<line x1="${X(0)}" y1="${Y(S.tr(0))}" x2="${X(S.last.x)}" y2="${Y(S.tr(S.last.x))}" stroke="${dc}" stroke-width="1.3" stroke-dasharray="5 4"/>`
      +`<line x1="${X(S.last.x)}" y1="${Y(S.tr(S.last.x))}" x2="${X(S.xEnd)}" y2="${Y(S.proj)}" stroke="${dc}" stroke-width="1.3" stroke-dasharray="2 3"/>`;
    const P=S.pts.map(p=>[X(p.x),Y(p.y)]);
    const act=`<path d="${smoothD(P)}" fill="none" stroke="#C9A227" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>`;
    const dots=S.pts.map((p,i)=>`<circle cx="${P[i][0]}" cy="${P[i][1]}" r="${i===S.pts.length-1?3.6:1.9}" fill="${i===S.pts.length-1?'#C9A227':'#fff'}" stroke="#C9A227" stroke-width="1.1"><title>${dmy(p.key)}: ${fmt(p.y)}</title></circle>`).join('');
    const pj=`<circle cx="${X(S.xEnd)}" cy="${Y(S.proj)}" r="3.2" fill="#fff" stroke="${dc}" stroke-width="1.4"/><text x="${Math.max(pl+36,X(S.xEnd)+2)}" y="${Y(S.proj)-9}" font-size="10" font-weight="700" fill="${dc}" text-anchor="middle">${fmt(S.proj)}</text>`;
    const lx=X(S.last.x); const ll=`<text x="${Math.min(W-pr-34,lx)}" y="${P[P.length-1][1]-10}" font-size="10" font-weight="700" fill="#18231C" text-anchor="middle">${fmt(S.last.y)}</text>`;
    const xl=`<text x="${X(0)}" y="${H-8}" font-size="10" fill="#6B706A" text-anchor="end">${dmy(from).slice(0,5)}</text>${(X(S.last.x)-X(S.xEnd))>70?`<text x="${lx}" y="${H-8}" font-size="10" fill="#6B706A" text-anchor="middle">${dmy(day).slice(0,5)}</text>`:""}<text x="${X(S.xEnd)}" y="${H-8}" font-size="10" fill="${dc}" text-anchor="start">${dmy(S.endKey).slice(0,5)} متوقع</text>`;
    const svg=`<svg width="100%" viewBox="0 0 ${W} ${H}" role="img" aria-label="اتجاه السيولة" style="display:block;direction:ltr">${g}${bandP}${trendL}${act}${dots}${pj}${ll}${xl}</svg>`;
    const ins=trendInsights(r,S).slice(0,4).map(it=>`<li style="margin-bottom:6px;line-height:1.6">${esc(it.t)}</li>`).join('');
    box.innerHTML=`<div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:10px"><span style="background:${dc}1A;color:${dc};font-weight:700;border-radius:99px;padding:4px 14px;font-size:15px">${arrow} ${S.dir}</span><span class="hint">قوة الاتجاه: ${conf} • آخر رصيد ${S.pos}</span></div>
      <div class="kpis" style="margin-bottom:10px">
        <div class="kpi"><div class="hint">الميل اليومي</div><div class="num" style="font-weight:700;font-size:17px;color:${dc}">${sgnF(S.b)}</div><div class="hint">≈ ${sgnF(S.b*30)} خلال 30 يوم</div></div>
        <div class="kpi"><div class="hint">المتوقع ${dmy(S.endKey).slice(0,5)}</div><div class="num" style="font-weight:700;font-size:17px">${fmt(S.proj)}</div><div class="hint">بين ${fmt(S.projLo)} و ${fmt(S.projHi)}</div></div>
      </div>${svg}
      <div class="hint" style="display:flex;gap:12px;flex-wrap:wrap;margin:6px 0 10px"><span><b style="color:#C9A227">━</b> الرصيد الفعلي</span><span><b style="color:${dc}">╌</b> خط الاتجاه والمتوقع</span><span><b style="color:${dc};opacity:.5">■</b> النطاق الطبيعي</span></div>
      ${ins?`<ul style="margin:0;padding-inline-start:18px;font-size:13px;color:var(--txt)">${ins}</ul>`:''}`;
  }
