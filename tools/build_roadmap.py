#!/usr/bin/env python3
"""Render roadmap.json + git history into the interactive Pages landing.

The metaphor is the game's own: white light split into a spectrum, one hue per
work track (hues live in roadmap.json). The landing (docs/index.html) is a
spacious, explorable TIME map: every git commit is a dot placed at its REAL
commit time on its track's lane (assigned by files touched), and the curated
phases from roadmap.json sit on top as labelled steps. History on the left, the
"now" frontier and planned steps to the right.

Layout + interaction (pan, zoom-to-cursor that stretches the time axis so dense
bursts pull apart, click-through to the commit on GitHub) live in the page's JS;
Python just bakes the data. Data is curated (roadmap.json) + git log; the HTML is
generated -- never hand-edit. Run: python3 tools/build_roadmap.py -> docs/index.html
"""

import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "roadmap.json")
OUT_HTML = os.path.join(ROOT, "docs", "index.html")
REPO = "https://github.com/temikgo/prism"


def track_of_path(p):
    if p.endswith("bot.cpp") or p.endswith("bot.hpp"):
        return "bot"
    if "balance" in p or "selfplay" in p:
        return "bot"  # self-play / balance harness is bot-vs-bot machinery
    if p.startswith("server/") or "protocol" in p or p.startswith("replays/"):
        return "server"
    if p.endswith("cards.json") or p.startswith("cards/") or p in (
            "EFFECTS.md", "ART.md"):
        return "cards"
    if p.startswith("client-godot/"):
        return "client"
    if p.startswith("engine/"):
        return "engine"
    return "infra"


def is_meta(p):
    # Docs / journal / generated meta touched by many commits (BACKLOG.md is
    # often the biggest diff) -- must NOT decide a commit's track, or e.g. a bot
    # change with a long journal entry lands in Инфра instead of Бот.
    return (p.endswith(".md") or p.startswith("docs/")
            or p.startswith("roadmap.") or p == ".gitignore" or p == "LICENSE")


def track_from_subject(s):
    # Fallback for commits that change only docs/journals (no code to score):
    # route them to the track their MESSAGE is about.
    s = s.lower()

    def has(*ws):
        return any(w in s for w in ws)

    if has("self-play", "selfplay", "winrate", "noise floor", "crn", "gih",
           "per-card balance", "balance precision", "balance probe",
           "balance pass", "bot", "mcts", "greedy", "жадн", "determiniz",
           "детерминиз", "rollout", "puct", "lookahead", "тренировк"):
        return "bot"
    if has("websocket", "matchmak", "room manager", "replay", "реплей"):
        return "server"
    if has("app shell", "main menu", "vfx", "drag", "layout", "wordmark",
           "анимац", "screen", "экран"):
        return "client"
    if has("card-rework", "keyword set", "keyword catalog", "card pack",
           "archetype", "архетип", "re-cost", "nerf"):
        return "cards"
    if has("serialize", "сериализ", "clone", "combat", "движок"):
        return "engine"
    return None


def get_commits():
    """All commits (oldest first), each assigned to the track whose files it
    touched most. Returns {track_id: [{h,at,s}...]}, at_of, t_first, t_now."""
    raw = subprocess.check_output(
        ["git", "log", "--no-merges", "--reverse",
         "--pretty=format:@@@%h|%at|%s", "--numstat"],
        cwd=ROOT, text=True)
    commits = []
    cur = None
    for line in raw.splitlines():
        if line.startswith("@@@"):
            h, at, s = line[3:].split("|", 2)
            cur = {"h": h, "at": int(at), "s": s, "w": {}}
            commits.append(cur)
        elif line.strip() and cur is not None:
            parts = line.split("\t")
            if len(parts) == 3:
                a, d, path = parts
                if is_meta(path):
                    continue
                ch = (int(a) if a.isdigit() else 0) + \
                     (int(d) if d.isdigit() else 0) + 1
                t = track_of_path(path)
                cur["w"][t] = cur["w"].get(t, 0) + ch
    by_track = {}
    for c in commits:
        t = max(c["w"], key=c["w"].get) if c["w"] else \
            (track_from_subject(c["s"]) or "infra")
        by_track.setdefault(t, []).append(c)
    at_of = {c["h"]: c["at"] for c in commits}
    t_first = min(c["at"] for c in commits)
    t_now = max(c["at"] for c in commits)
    return by_track, at_of, t_first, t_now


def build():
    data = json.load(open(DATA, encoding="utf-8"))
    by_track, at_of, t_first, t_now = get_commits()

    tracks = []
    total = 0
    for tr in data["tracks"]:
        cms = by_track.get(tr["id"], [])
        total += len(cms)
        phases = []
        for nd in tr["nodes"]:
            at = nd.get("at")
            phases.append({
                "l": nd["label"], "s": nd.get("status", "planned"),
                "w": nd.get("weight", "minor"), "at": at,
                "t": at_of.get(at) if at else None, "note": nd.get("note"),
            })
        tracks.append({
            "name": tr["name"], "hue": tr["hue"], "count": len(cms),
            "commits": [[c["h"], c["at"], c["s"]] for c in cms],
            "phases": phases,
        })

    payload = {"repo": REPO, "tFirst": t_first, "tNow": t_now,
               "title": data["title"], "tracks": tracks}
    blob = json.dumps(payload, ensure_ascii=False).replace("<", "\\u003c")
    html = TMPL.replace("__DATA__", blob)

    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)
    open(OUT_HTML, "w", encoding="utf-8").write(html)
    open(os.path.join(os.path.dirname(OUT_HTML), ".nojekyll"), "w").write("")
    print(f"wrote {os.path.relpath(OUT_HTML, ROOT)} (+ .nojekyll, {total} commits)")


TMPL = r"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Prism — над чем идёт работа</title>
<meta name="description" content="Призма раскладывает свет в спектр — живое дерево разработки модульной онлайн-ККИ Prism.">
<style>
  :root{
    --bg:#0a0b11; --ink:#eef0f7; --dim:#8b90a3; --faint:#565b6e;
    --font:"Chakra Petch",ui-sans-serif,system-ui,"Segoe UI",Helvetica,Arial,sans-serif;
  }
  *{box-sizing:border-box;}
  html,body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--font);
    -webkit-font-smoothing:antialiased;}
  @font-face{font-family:"Chakra Petch";font-weight:700;font-display:swap;
    src:url("fonts/ChakraPetch-Bold.ttf") format("truetype");}
  a{color:inherit;}
  .wrap{max-width:1400px;margin:0 auto;padding:0 24px;}

  header.hero{position:relative;text-align:center;padding:88px 0 30px;}
  .bloom{position:absolute;left:50%;top:44%;width:min(920px,94vw);height:360px;
    transform:translate(-50%,-50%);pointer-events:none;z-index:0;opacity:.55;
    background:radial-gradient(ellipse at center,
      #ff5a6e24 0%,#ffd23f1a 24%,#46e07a1a 46%,#3aa0ff1e 68%,#b06bff16 85%,transparent 100%);
    filter:blur(30px);}
  .lock{position:relative;z-index:1;}
  h1{margin:0;padding-top:.1em;font-size:clamp(54px,12vw,144px);font-weight:700;
    letter-spacing:.12em;line-height:1;color:#f4f7ff;
    text-shadow:0 3px 16px #02030855,0 0 46px #6f86ff22;}
  .lore{margin:14px 0 0;color:var(--dim);font-size:clamp(10px,1.5vw,13px);
    letter-spacing:.3em;font-weight:600;}
  .tag{position:relative;z-index:1;margin:24px auto 0;max-width:640px;color:#c6c9d8;
    font-size:clamp(15px,2vw,18px);line-height:1.6;text-wrap:balance;}

  section.map{padding:22px 0 20px;}
  .maphead{display:flex;align-items:flex-end;justify-content:space-between;
    gap:20px;flex-wrap:wrap;margin:0 0 14px;}
  .maphead h2{margin:0;font-size:23px;font-weight:700;letter-spacing:1.5px;}
  .maphead p{margin:5px 0 0;color:#9aa0b4;font-size:14.5px;max-width:660px;line-height:1.5;}
  .tools{display:flex;gap:8px;align-items:center;}
  .tools button{font-family:var(--font);font-size:14px;font-weight:600;color:#c6c9d8;
    background:#12141d;border:1px solid #23262f;border-radius:9px;padding:7px 13px;
    cursor:pointer;transition:border-color .15s,color .15s;}
  .tools button:hover{border-color:#3a3e4d;color:#fff;}
  .tools button:focus-visible{outline:2px solid #5b6cff;outline-offset:2px;}

  .mapbox{position:relative;border:1px solid #14161f;border-radius:16px;
    overflow:hidden;background:radial-gradient(120% 90% at 12% 30%,#141626 0%,#0a0b10 60%);}
  svg#map{width:100%;height:auto;display:block;cursor:grab;touch-action:none;}
  svg#map.grab{cursor:grabbing;}
  .hint{color:var(--faint);font-size:12.5px;margin:11px 4px 0;}

  .node{cursor:pointer;outline:none;}
  .node:hover,.node:focus-visible{filter:brightness(1.45);}
  .cmt{cursor:pointer;}
  .cmt:hover .v{r:6.5;opacity:1;}
  .plan{cursor:default;}

  #tip{position:fixed;pointer-events:none;z-index:30;opacity:0;transform:translateY(4px);
    transition:opacity .12s,transform .12s;background:#14151e;border:1px solid #2b2d3b;
    border-radius:11px;padding:10px 13px;max-width:320px;box-shadow:0 14px 40px #000a;}
  #tip.on{opacity:1;transform:none;}
  #tip .t{font-size:13.5px;font-weight:700;letter-spacing:.2px;line-height:1.35;}
  #tip .s{font-size:11.5px;margin-top:4px;color:var(--dim);letter-spacing:.4px;
    font-variant-numeric:tabular-nums;}
  #tip .n{font-size:12px;margin-top:7px;color:#cbcedd;font-style:italic;line-height:1.4;}

  footer{border-top:1px solid #14161f;margin-top:20px;padding:24px 0 48px;
    color:var(--dim);font-size:13px;display:flex;flex-wrap:wrap;gap:16px;
    justify-content:space-between;}
  footer a{color:#aeb2c2;text-decoration:none;}
  footer a:hover{color:var(--ink);}
  @media (prefers-reduced-motion:reduce){*{transition:none!important;}}
</style>
</head>
<body>
<div class="wrap">
  <header class="hero">
    <div class="bloom"></div>
    <div class="lock">
      <h1>PRISM</h1>
      <p class="lore">·&nbsp; СВЕТ МЕГА-ПРИЗМЫ РАСКОЛОТ НА ПЯТЬ ЦВЕТОВ &nbsp;·</p>
    </div>
    <p class="tag">Модульная онлайн-ККИ 1&nbsp;на&nbsp;1. Белый луч входит в призму и
      раскладывается в спектр — каждый луч&nbsp;— свой трек разработки.</p>
  </header>

  <section class="map">
    <div class="maphead">
      <div>
        <h2>Над чем идёт работа</h2>
        <p>Каждая точка стоит на своём реальном времени коммита — всплески кучнее,
          затишья с зазором. Клик по точке&nbsp;— открыть коммит. Растяните ось,
          чтобы развести плотные периоды.</p>
      </div>
      <div class="tools">
        <button id="zin">＋ растянуть</button>
        <button id="zout">－ сжать</button>
        <button id="zrst">сброс</button>
      </div>
    </div>
    <div class="mapbox"><svg id="map" role="img" aria-label="Дерево разработки Prism"></svg></div>
    <p class="hint">Наведите&nbsp;— тема коммита и дата. Клик&nbsp;— коммит на GitHub. Тяните&nbsp;— двигать. Колесо над картой&nbsp;— растянуть ось.</p>
  </section>

  <footer>
    <span>Призма раскладывает свет&nbsp;— мы раскладываем работу по трекам.</span>
    <span><a href="https://github.com/temikgo/prism">temikgo/prism</a></span>
  </footer>
</div>

<div id="tip"><div class="t"></div><div class="s"></div><div class="n"></div></div>

<script>
"use strict";
const P=__DATA__;
const SVGNS="http://www.w3.org/2000/svg";
const REPO=P.repo, T0=P.tFirst, TN=P.tNow, SPAN=Math.max(1,TN-T0);
const STATUS_RU={done:"сделано",planned:"план",abandoned:"пробовали → откат"};
const pad=n=>String(n).padStart(2,"0");
const fmt=t=>{const d=new Date(t*1000);return pad(d.getDate())+"."+pad(d.getMonth()+1)+"."+d.getFullYear();};
function plural(n){const a=n%10,b=n%100;if(a===1&&b!==11)return"коммит";
  if(a>=2&&a<=4&&!(b>=12&&b<=14))return"коммита";return"коммитов";}

const W=1680, LANE=178, TOP=140, X0=214, RPAD=60;
const X1=W-RPAD, FUTUREW=250, NOWX=X1-FUTUREW;
const H=TOP+(P.tracks.length-1)*LANE+150;
const LPAD=16;  // the first commit must not sit glued to the lane cap
const xOfT=t=>X0+LPAD+Math.max(0,Math.min(1,(t-T0)/SPAN))*(NOWX-X0-LPAD);

const svg=document.getElementById("map");
svg.setAttribute("viewBox",`0 0 ${W} ${H}`);
svg.setAttribute("font-family","var(--font)");
function el(n,a){const e=document.createElementNS(SVGNS,n);for(const k in a)e.setAttribute(k,a[k]);return e;}
function hsl(h,s,l){return `hsl(${((h%360)+360)%360} ${s}% ${l}%)`;}

const flex=[];   // {node,kind:'cx'|'x'|'x2'|'trans',base,base2}
const labels=[]; // phase labels, clamped into the plot on every reflow
function reg(node,kind,base,base2){flex.push({node,kind,base,base2});if(base2!=null&&node.dataset)node.dataset.start=base2;}

const defs=el("defs",{});
defs.innerHTML='<filter id="glow" x="-70%" y="-70%" width="240%" height="240%">'+
 '<feGaussianBlur stdDeviation="3" result="b"/><feMerge>'+
 '<feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'+
 '<clipPath id="pc"><rect x="'+(X0-2)+'" y="0" width="'+(W-X0+2)+'" height="'+H+'"/></clipPath>';
svg.appendChild(defs);
svg.appendChild(el("rect",{x:0,y:0,width:W,height:H,fill:"transparent"}));

const plot=el("g",{"clip-path":"url(#pc)"});
svg.appendChild(plot);

// Date grid, stepped to the REAL span: a months-only grid prints a single tick on
// a six-week project. Aim for ~6-12 ticks whatever the range.
(function(){
  const days=SPAN/86400;
  const ticks=[];
  if(days<=90){                       // weeks: every Monday inside the range
    const step=days<=21?2:7;
    let d=new Date(T0*1000); d.setHours(0,0,0,0);
    if(step===7) d.setDate(d.getDate()+((8-d.getDay())%7));  // next Monday
    let guard=0;
    while(d.getTime()/1000<=TN && guard++<64){
      ticks.push(new Date(d)); d.setDate(d.getDate()+step);
    }
  }else{                              // months (quarters once it gets long)
    const step=days<=420?1:3;
    let d=new Date(T0*1000); d=new Date(d.getFullYear(),d.getMonth(),1);
    if(d.getTime()/1000<T0) d.setMonth(d.getMonth()+1);
    let guard=0;
    while(d.getTime()/1000<=TN && guard++<64){
      ticks.push(new Date(d)); d.setMonth(d.getMonth()+step);
    }
  }
  ticks.forEach(d=>{
    const bx=xOfT(d.getTime()/1000);
    if(NOWX-bx<44) return;  // the last tick would print through the "сейчас" marker
    const ln=el("line",{y1:TOP-54,y2:H-96,stroke:"#ffffff","stroke-width":1,opacity:.06,x1:bx,x2:bx});
    reg(ln,"x2",bx,bx); plot.appendChild(ln);
    const tx=el("text",{y:TOP-64,fill:"#9aa0b4","font-size":12.5,"font-weight":600,"text-anchor":"middle",x:bx});
    tx.textContent=pad(d.getDate())+"."+pad(d.getMonth()+1); reg(tx,"x",bx); plot.appendChild(tx);
  });
  const yr=el("text",{x:X0+4,y:TOP-64,fill:"#5d6172","font-size":12,"font-weight":600,"text-anchor":"start"});
  yr.textContent=new Date(T0*1000).getFullYear(); svg.appendChild(yr);
})();

const fz=el("rect",{y:TOP-54,width:X1-NOWX,height:H-96-(TOP-54),fill:"#ffffff",opacity:.022,x:NOWX});
reg(fz,"x",NOWX); plot.appendChild(fz);
const nowL=el("line",{y1:TOP-54,y2:H-96,stroke:"#cfd3e2","stroke-width":1.5,"stroke-dasharray":"2 5",opacity:.65,x1:NOWX,x2:NOWX});
reg(nowL,"x2",NOWX,NOWX);plot.appendChild(nowL);
const nowT=el("text",{y:TOP-64,fill:"#cfd3e2","font-size":12.5,"font-weight":700,"text-anchor":"middle",x:NOWX});
nowT.textContent="сейчас";reg(nowT,"x",NOWX);plot.appendChild(nowT);
const planT=el("text",{y:TOP-64,fill:"#71758b","font-size":12,"font-style":"italic","text-anchor":"middle",x:(NOWX+X1)/2});
planT.textContent="план →";reg(planT,"x",(NOWX+X1)/2);plot.appendChild(planT);

const names=[];
function tip(g,label,sub,note,href){
  g.setAttribute("data-label",label);g.setAttribute("data-sub",sub);
  if(note)g.setAttribute("data-note",note);
  if(href)g.dataset.href=href;
}

P.tracks.forEach((tr,i)=>{
  const y=TOP+i*LANE, hue=tr.hue;
  const bright=hsl(hue,74,63), dim=hsl(hue,44,46);

  const lane=el("line",{y1:y,y2:y,stroke:dim,"stroke-width":1.6,opacity:.4,x1:X0,x2:X1});
  reg(lane,"x2",X1,X0); plot.appendChild(lane);
  const cap=el("circle",{cx:X0,cy:y,r:3.2,fill:bright,filter:"url(#glow)"});
  reg(cap,"cx",X0); plot.appendChild(cap);

  // commits at their REAL times (bursts cluster, quiet periods gap)
  tr.commits.forEach(c=>{
    const h=c[0], at=c[1], subj=c[2], bx=xOfT(at);
    const g=el("g",{class:"cmt"});
    g.appendChild(el("circle",{cy:y,r:7,fill:"#000",opacity:0,cx:bx,"pointer-events":"all"}));
    g.appendChild(el("circle",{class:"v",cy:y,r:3.6,fill:bright,opacity:.5,cx:bx,"pointer-events":"none"}));
    tip(g,subj,"коммит · "+h+" · "+fmt(at),null,REPO+"/commit/"+h);
    reg(g,"trans",bx); plot.appendChild(g);
  });

  const done=tr.phases.filter(x=>x.s!=="planned");
  const plan=tr.phases.filter(x=>x.s==="planned");
  const rowsT=[],rowsB=[]; let li=0;

  function node(ph,base){
    const l=ph.l, s=ph.s, major=ph.w==="major";
    const href=ph.at?REPO+"/commit/"+ph.at:null;
    const g=el("g",{class:s==="planned"?"plan":"node",tabindex:s==="planned"?-1:0});
    const sub=(STATUS_RU[s]||s)+(ph.at?" · "+ph.at:"")+(ph.t?" · "+fmt(ph.t):"");
    tip(g,l,sub,ph.note,href);

    if(s==="abandoned"){
      const rr=7;
      g.appendChild(el("line",{x1:base-rr,y1:y-rr,x2:base+rr,y2:y+rr,stroke:bright,"stroke-width":2.6,opacity:.8,"stroke-linecap":"round"}));
      g.appendChild(el("line",{x1:base+rr,y1:y-rr,x2:base-rr,y2:y+rr,stroke:bright,"stroke-width":2.6,opacity:.8,"stroke-linecap":"round"}));
      g.appendChild(el("circle",{cx:base,cy:y,r:9,fill:"#000",opacity:0,"pointer-events":"all"}));
    }else if(s==="planned"){
      const r=major?7.5:5;
      g.appendChild(el("circle",{cy:y,r:r+3,fill:"#000",opacity:0,cx:base,"pointer-events":"all"}));
      g.appendChild(el("circle",{cy:y,r,fill:"#0a0b11",stroke:dim,"stroke-width":2,opacity:.9,cx:base}));
    }else{
      const r=major?8:5.5;
      g.appendChild(el("circle",{cy:y,r:r+3,fill:"#000",opacity:0,cx:base,"pointer-events":"all"}));
      g.appendChild(el("circle",{cy:y,r,fill:bright,filter:"url(#glow)",cx:base}));
    }

    if(major||s==="abandoned"){
      const fs=major?13.5:12;
      const fill=s==="abandoned"?"#a59aa0":(s==="planned"?"#8e92a4":(major?"#e8eaf2":"#b9bdcc"));
      const half=l.length*0.29*fs+6;
      // Rows are packed against where the label will actually LAND (clamped into
      // the plot), not against its dot -- else two early milestones, both pushed
      // right off the left edge, are packed as if they were still far apart and
      // print on top of each other.
      const cx0=Math.max(X0+8+half,Math.min(X1-8-half,base));
      const side=(li++%2===0)?-1:1; const rows=side<0?rowsT:rowsB;
      let lvl=0; while(lvl<rows.length && cx0-half<=rows[lvl]+10)lvl++;
      if(lvl===rows.length)rows.push(0); rows[lvl]=cx0+half;
      const ly=side<0?(y-24-lvl*17):(y+32+lvl*17);
      const tx=el("text",{y:ly,"text-anchor":"middle",fill,"font-size":fs,"font-weight":major?700:500,x:base,"pointer-events":"none"});
      if(s==="abandoned")tx.setAttribute("font-style","italic");
      tx.textContent=l; g.appendChild(tx);
      // A label is centred on its dot, so an early milestone (its dot sits at the
      // very start of the axis) would spill left, under the opaque track-name
      // column, and lose its first words. Keep every label inside the plot; the
      // leader line then leans over to reach the dot. Redone on every zoom/pan,
      // which is also when a label can be pushed off the edge.
      const need=lvl>0||Math.abs(ly-y)>28;
      const ln=el("line",{y1:side<0?y-9:y+9,y2:side<0?ly+5:ly-13,stroke:bright,"stroke-width":1,
        opacity:need?.22:0,x1:base,x2:base,"pointer-events":"none"});
      g.appendChild(ln);
      labels.push({tx,ln,base,half,need});
    }
    reg(g,"trans",base); plot.appendChild(g);
  }
  done.forEach(ph=>node(ph, ph.t?xOfT(ph.t):xOfT(TN)));
  plan.forEach((ph,j)=>node(ph, NOWX+(j+1)/(plan.length+1)*(X1-NOWX)));

  const nm=el("text",{x:X0-26,y:y-1,fill:bright,"font-size":18,"font-weight":700,"text-anchor":"end"});
  nm.textContent=tr.name; names.push(nm);
  const cc=el("text",{x:X0-26,y:y+17,fill:"#7e8295","font-size":11.5,"text-anchor":"end"});
  cc.textContent=tr.count+" "+plural(tr.count); names.push(cc);
});

svg.appendChild(el("rect",{x:0,y:0,width:X0-2,height:H,fill:"#0b0c13"}));
names.forEach(n=>svg.appendChild(n));

// legend
(function(){
  const ly=H-52,gh="#aeb2c2"; let gx=40;
  const t0=el("text",{x:40,y:ly-18,fill:"#878089","font-size":12,"letter-spacing":2});
  t0.textContent="ЛЕГЕНДА"; svg.appendChild(t0);
  [["done","этап сделан"],["planned","план"],["abandoned","пробовали → откат"],["cmt","коммит"]].forEach(a=>{
    const st=a[0], name=a[1];
    if(st==="done")svg.appendChild(el("circle",{cx:gx+7,cy:ly,r:6,fill:gh}));
    else if(st==="planned")svg.appendChild(el("circle",{cx:gx+7,cy:ly,r:6,fill:"#0a0b11",stroke:gh,"stroke-width":2}));
    else if(st==="cmt")svg.appendChild(el("circle",{cx:gx+7,cy:ly,r:3.4,fill:gh,opacity:.6}));
    else svg.appendChild(el("path",{d:"M"+(gx+3)+","+(ly-4)+" L"+(gx+11)+","+(ly+4)+" M"+(gx+11)+","+(ly-4)+" L"+(gx+3)+","+(ly+4),stroke:gh,"stroke-width":1.6,"stroke-linecap":"round",opacity:.75}));
    const t=el("text",{x:gx+22,y:ly+5,fill:"#aab0c0","font-size":13.5});t.textContent=name;svg.appendChild(t);
    gx+=64+name.length*8.2;
  });
})();

// ---- stretch + pan ----
let stretch=1,panX=0;
function reflow(){
  for(const f of flex){
    const nx=X0+(f.base-X0)*stretch+panX;
    if(f.kind==="cx")f.node.setAttribute("cx",nx);
    else if(f.kind==="x")f.node.setAttribute("x",nx);
    else if(f.kind==="trans")f.node.setAttribute("transform","translate("+(nx-f.base)+",0)");
    else if(f.kind==="x2"){
      const sB=f.node.dataset.start!==undefined?+f.node.dataset.start:f.base2;
      const sx=X0+(sB-X0)*stretch+panX;
      f.node.setAttribute("x1",sx);f.node.setAttribute("x2",nx);
    }
  }
  for(const L of labels){
    const nx=X0+(L.base-X0)*stretch+panX;                      // where its dot is now
    const cx=Math.max(X0+8+L.half,Math.min(X1-8-L.half,nx));   // where the text may sit
    const local=cx-nx+L.base;                                  // the group is already translated
    L.tx.setAttribute("x",local);
    L.ln.setAttribute("x2",local);
    L.ln.setAttribute("opacity",(L.need||Math.abs(cx-nx)>2)?.22:0);
  }
}
reflow();
function clampPan(){const maxOff=(X1-X0)*(stretch-1);panX=Math.max(-maxOff,Math.min(0,panX));}
function setStretch(ns,cx){ns=Math.max(1,Math.min(7,ns));const wb=(cx-X0-panX)/stretch;stretch=ns;panX=cx-X0-wb*stretch;clampPan();reflow();}
svg.addEventListener("wheel",e=>{
  e.preventDefault();
  const r=svg.getBoundingClientRect();
  const cx=Math.max(X0,Math.min(X1,(e.clientX-r.left)/r.width*W));
  setStretch(stretch*(e.deltaY>0?1.12:1/1.12),cx);   // wheel up = zoom in
},{passive:false});
let drag=false,lastX=0,moved=0;
svg.addEventListener("pointerdown",e=>{drag=true;lastX=e.clientX;moved=0;svg.setPointerCapture(e.pointerId);svg.classList.add("grab");});
svg.addEventListener("pointermove",e=>{if(!drag)return;const r=svg.getBoundingClientRect();const dx=e.clientX-lastX;moved+=Math.abs(dx);panX+=dx/r.width*W;lastX=e.clientX;clampPan();reflow();});
function endDrag(){drag=false;svg.classList.remove("grab");}
svg.addEventListener("pointerup",endDrag);svg.addEventListener("pointercancel",endDrag);
document.getElementById("zin").onclick=()=>setStretch(stretch*1.4,(X0+X1)/2);
document.getElementById("zout").onclick=()=>setStretch(stretch/1.4,(X0+X1)/2);
document.getElementById("zrst").onclick=()=>{stretch=1;panX=0;reflow();};

// ---- tooltip + click ----
const tp=document.getElementById("tip");
const tt=tp.querySelector(".t"),ts=tp.querySelector(".s"),tn=tp.querySelector(".n");
function tshow(e){const g=e.currentTarget;
  tt.textContent=g.getAttribute("data-label")||"";
  ts.textContent=g.getAttribute("data-sub")||"";
  const note=g.getAttribute("data-note");tn.textContent=note||"";tn.style.display=note?"block":"none";
  tp.classList.add("on");tmove(e);}
function tmove(e){let x=e.clientX+15,y=e.clientY+15;const w=tp.offsetWidth,h=tp.offsetHeight;
  if(x+w>innerWidth-8)x=innerWidth-w-8;if(y+h>innerHeight-8)y=e.clientY-h-15;tp.style.left=x+"px";tp.style.top=y+"px";}
function thide(){tp.classList.remove("on");}
document.querySelectorAll(".node,.cmt,.plan").forEach(g=>{
  g.addEventListener("mouseenter",tshow);g.addEventListener("mousemove",tmove);g.addEventListener("mouseleave",thide);
  g.addEventListener("focus",()=>{const r=g.getBoundingClientRect();tshow({currentTarget:g,clientX:r.left+r.width/2,clientY:r.top+r.height/2});});
  g.addEventListener("blur",thide);
  g.addEventListener("click",()=>{if(moved>6)return;const href=g.dataset.href;if(href)window.open(href,"_blank","noopener");});
  g.addEventListener("keydown",e=>{if(e.key==="Enter"){const href=g.dataset.href;if(href)window.open(href,"_blank","noopener");}});
});
</script>
</body>
</html>
"""


if __name__ == "__main__":
    build()
