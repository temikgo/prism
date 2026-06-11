/* ============================================================
   PRISM — board.jsx  (state, drag-drop, turn, tweaks wiring)
   ============================================================ */
const {useState, useEffect, useRef, useCallback} = React;

const ART = {
  blue:'assets/art_blue_seer.png',
  green:'assets/art_green_beast.png',
  red:'assets/art_red_bulwark.png',
  crystal:'assets/art_crystal.png',
  rose:'assets/art_rose.png',
  phantom:'assets/art_phantom.png',
  grove:'assets/art_grove.png',
  sovereign:'assets/art_sovereign.png',
  heroIris:'assets/hero_iris.png',
  heroFoe:'assets/hero_foe.png',
};

/* ---------- initial state ---------- */
/* statuses set: freeze · blind · shield · ward · stealth · taunt(provoke) */
const FOE_BOARD0 = [
  {id:'f1', side:'foe', color:'blue', name:'Бездонный Провидец', art:ART.blue,
   cost:3, pips:['blue','blue'], atk:4, hp:6,
   desc:'В конце хода смотрит верхнюю карту колоды соперника.',
   statuses:[{icon:'freeze'},{icon:'blind'}]},
  {id:'f2', side:'foe', color:'violet', name:'Призрак Спектра', art:ART.phantom,
   cost:1, pips:['violet'], atk:2, hp:3,
   desc:'Проникает сквозь защитников, пока незрим.', statuses:[{icon:'stealth'}]},
];
const MY_BOARD0 = [
  {id:'m1', side:'me', color:'red', name:'Рассветный Оплот', art:ART.red,
   cost:2, pips:['red'], atk:2, hp:1, hurt:true, provoke:true,
   desc:'Ранен. Пока жив, соперник бьёт только по нему.', statuses:[{icon:'taunt'}]},
  {id:'m2', side:'me', color:'green', name:'Гнилостный Зверь', art:ART.green,
   cost:1, pips:['green'], atk:1, hp:2,
   desc:'При гибели отравляет соседнее вражеское существо.', statuses:[{icon:'ward'}]},
  {id:'m3', side:'me', color:'colorless', name:'Лучезарный Монолит', art:ART.crystal,
   cost:1, pips:['colorless'], atk:0, hp:4,
   desc:'Стена: не атакует, но держит линию.', statuses:[{icon:'shield'}]},
];
const HAND0 = [
  {id:'h1', side:'me', type:'creature', color:'green', name:'Древо Истока', art:ART.grove,
   cost:4, pips:['green','green'], atk:5, hp:7,
   desc:'При призыве даёт +1 временный зелёный кристалл на этот ход.'},
  {id:'h2', side:'me', type:'creature', color:'blue', name:'Глубинный Хор', art:null,
   phTag:'арт · синий', cost:3, pips:['blue'], atk:2, hp:4,
   desc:'Боевой клич: заморозить вражеское существо.'},
  {id:'h3', side:'me', type:'spell', color:'yellow', name:'Заря Кузнеца', art:null,
   phTag:'заклинание', cost:2, pips:['yellow','blue'], dmg:3,
   desc:'Нанести 3 урона вражескому существу.'},
  {id:'h4', side:'me', type:'creature', color:'violet', spectrum:true, name:'Призматический Государь',
   art:ART.sovereign, cost:5, pips:['red','yellow','green','blue','violet'], atk:7, hp:8,
   desc:'Спектральный: требует по одной мане каждого цвета.'},
];

/* bank = banked cards face-down (= mana crystals). Grows unbounded:
   several of each colour, mix of available / spent / temp(this-turn) */
const MY_BANK = [
  {color:'red'},{color:'red'},{color:'red',spent:true},
  {color:'yellow'},{color:'yellow',spent:true},
  {color:'green'},{color:'green'},{color:'green',temp:true},
  {color:'blue'},{color:'blue',spent:true},
  {color:'violet'},
  {color:'colorless'},{color:'colorless'},
];
/* huge mid/late-game bank for the limit preview */
const BIG_BANK = (()=>{
  const order=['red','yellow','green','blue','violet','colorless'];
  const arr=[];
  order.forEach((c,ci)=>{ const n = 3+(ci%3); for(let i=0;i<n;i++) arr.push({color:c, spent:i>=n-1 && ci%2===0}); });
  arr.push({color:'green', temp:true}); arr.push({color:'blue', temp:true});
  return arr; // ~20 crystals, several per colour
})();

/* enemy bank when NOT under floodlight — just face-down crystal backs */
const FOE_BANK = [
  {color:'red'},{color:'red',spent:true},{color:'yellow'},
  {color:'green',spent:true},{color:'blue'},{color:'blue'},
  {color:'violet'},{color:'colorless',spent:true},
];
/* enemy banked cards — revealed as compact previews while FLOODLIGHT is up */
const FOE_PREVIEW = [
  {color:'blue', art:ART.blue},{color:'violet', art:ART.phantom},{color:'green', art:ART.grove},
  {color:'red', art:ART.red},{color:'colorless', art:ART.crystal},{color:'yellow', art:null},
  {color:'blue', art:null},{color:'violet', art:ART.sovereign},
];
/* big mid/late-game enemy bank — to inspect the floodlight reveal when full */
const FOE_BANK_BIG = (()=>{
  const order=['red','yellow','green','blue','violet','colorless'];
  const arr=[];
  order.forEach((c,ci)=>{ const n=3+(ci%3); for(let i=0;i<n;i++) arr.push({color:c, spent:i>=n-1 && ci%2===1}); });
  return arr; // ~20 backs
})();
const FOE_PREVIEW_BIG = (()=>{
  const arts={red:ART.red,yellow:null,green:ART.grove,blue:ART.blue,violet:ART.phantom,colorless:ART.crystal};
  const order=['red','yellow','green','blue','violet','colorless'];
  const extra={red:ART.sovereign,violet:ART.sovereign,blue:null,green:null,colorless:null,yellow:null};
  const arr=[];
  order.forEach((c,ci)=>{ const n=3+(ci%3); for(let i=0;i<n;i++) arr.push({color:c, art:i===0?arts[c]:(i===1?extra[c]:null)}); });
  return arr;
})();

/* awaken cards live IN the bank — played straight from there.
   mode 'awaken' = play for cost («разбудить»); 'decoy' = ripened, no surcharge («без доплаты») */
const MY_AWAKENS0 = [
  {id:'aw1', name:'Алый Вестник', art:ART.red, color:'red', cost:2, atk:3, hp:2,
   available:true, mode:'awaken', statuses:[{icon:'haste'}]},
  {id:'aw2', name:'Тихий Дозор', art:ART.crystal, color:'colorless', cost:3, atk:1, hp:5,
   available:false, mode:'awaken', statuses:[{icon:'shield'}]},
  {id:'aw3', name:'Ложный Маяк', art:ART.grove, color:'green', cost:0, atk:2, hp:2,
   available:true, mode:'decoy', statuses:[]},
];
const FOE_AWAKENS = [];

/* auras — square art tiles beside the field (own / enemy) */
const MY_AURAS = [
  {color:'blue', art:ART.crystal, name:'Призма защиты', desc:'Ваши существа получают +0/+1.'},
  {color:'green', art:ART.grove, name:'Цветение', desc:'В начале хода «фотосинтез»: +1 временный кристалл.'},
];
const FOE_AURAS = [
  {color:'violet', art:ART.phantom, name:'Завеса теней', desc:'Существа соперника получают незримость на 1 ход.'},
];
/* стресс-набор: 6 аур на сторону — проверка переноса полки */
const MANY_AURAS_ME = [
  {color:'blue', art:ART.crystal, name:'Призма защиты', desc:'Ваши существа получают +0/+1.'},
  {color:'green', art:ART.grove, name:'Цветение', desc:'В начале хода «фотосинтез»: +1 временный кристалл.'},
  {color:'yellow', art:ART.red, name:'Горнило', desc:'Существа-рывки наносят +1 урон.'},
  {color:'red', art:ART.sovereign, name:'Алый ветер', desc:'Раз в ход: 1 урон случайному врагу.'},
  {color:'violet', art:ART.phantom, name:'Эхо спектра', desc:'Заклинания стоят на 1 меньше.'},
  {color:'colorless', art:ART.blue, name:'Тихий свет', desc:'Ваш герой получает +1 броню за ход.'},
];
const MANY_AURAS_FOE = [
  {color:'violet', art:ART.phantom, name:'Завеса теней', desc:'Существа соперника незримы 1 ход.'},
  {color:'red', art:ART.red, name:'Гнёт', desc:'Ваши призывы стоят на 1 больше.'},
  {color:'blue', art:ART.blue, name:'Стужа', desc:'Раз в ход морозит ваше существо.'},
];

/* ---- limit-preview state: full hand (10) + large bank (15) ---- */
const STRESS_HAND = [
  {id:'s1', side:'me', type:'creature', color:'green', name:'Древо Истока', art:ART.grove, cost:4, pips:['green','green'], atk:5, hp:7},
  {id:'s2', side:'me', type:'creature', color:'blue', name:'Глубинный Хор', art:null, phTag:'арт · синий', cost:3, pips:['blue'], atk:2, hp:4},
  {id:'s3', side:'me', type:'spell', color:'yellow', name:'Заря Кузнеца', art:null, phTag:'заклинание', cost:2, pips:['yellow','blue'], dmg:3},
  {id:'s4', side:'me', type:'creature', color:'red', name:'Алый Вестник', art:ART.red, cost:2, pips:['red'], atk:3, hp:2},
  {id:'s5', side:'me', type:'creature', color:'violet', name:'Призрак Спектра', art:ART.phantom, cost:1, pips:['violet'], atk:2, hp:3},
  {id:'s6', side:'me', type:'creature', color:'colorless', name:'Лучезарный Монолит', art:ART.crystal, cost:1, pips:['colorless'], atk:0, hp:5},
  {id:'s7', side:'me', type:'creature', color:'blue', name:'Бездонный Провидец', art:ART.blue, cost:3, pips:['blue','blue'], atk:4, hp:6},
  {id:'s8', side:'me', type:'creature', color:'green', name:'Гнилостный Зверь', art:ART.green, cost:1, pips:['green'], atk:1, hp:2},
  {id:'s9', side:'me', type:'spell', color:'red', name:'Алый Разлом', art:null, phTag:'заклинание', cost:3, pips:['red','red'], dmg:4},
  {id:'s10', side:'me', type:'creature', color:'violet', spectrum:true, name:'Призматический Государь', art:ART.sovereign, cost:5, pips:['red','yellow','green','blue','violet'], atk:7, hp:8},
];
const STRESS_BANK = BIG_BANK;

/* full-board preview: up to 8 creatures per side (row must absorb the overlap) */
const CREA_POOL = [
  {color:'red', art:ART.red, name:'Рассветный Оплот', atk:2, hp:3, provoke:true, statuses:[{icon:'taunt'}]},
  {color:'green', art:ART.green, name:'Гнилостный Зверь', atk:1, hp:2, statuses:[{icon:'ward'}]},
  {color:'colorless', art:ART.crystal, name:'Лучезарный Монолит', atk:0, hp:4, statuses:[{icon:'shield'}]},
  {color:'blue', art:ART.blue, name:'Бездонный Провидец', atk:4, hp:6, statuses:[{icon:'freeze'}]},
  {color:'violet', art:ART.phantom, name:'Призрак Спектра', atk:2, hp:3, statuses:[{icon:'stealth'}]},
  {color:'green', art:ART.grove, name:'Древо Истока', atk:5, hp:7, statuses:[]},
  {color:'violet', art:ART.sovereign, name:'Призматический Государь', atk:7, hp:8, spectrum:true, statuses:[]},
  {color:'red', art:ART.red, name:'Алый Вестник', atk:3, hp:2, statuses:[{icon:'haste'}]},
];
function mkFull(side){
  return CREA_POOL.map((b,i)=>({
    id:side+'F'+i, side, cost:Math.max(1,Math.min(7,b.atk||1)),
    pips:[b.color], hurt:b.hp<=2, ...b,
  }));
}
const MY_BOARD_FULL  = mkFull('me');
const FOE_BOARD_FULL = mkFull('foe').map(c=>({...c, provoke:false}));

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "direction":"glass",
  "glow":0.9,
  "blur":14,
  "motif":0.5,
  "dispersion":true,
  "floodlight":true,
  "handFull":false,
  "boardFull":false,
  "bankHuge":false,
  "foeBankHuge":false,
  "aurasMany":false
}/*EDITMODE-END*/;

function availCount(mana){ return mana.filter(m=>!m.spent).length; }
function spendMana(mana, n){
  if(availCount(mana) < n) return null;
  const next = mana.map(m=>({...m}));
  let left=n;
  // spend colored first, colorless last
  for(const m of next){ if(left<=0) break; if(m.color!=='colorless' && !m.spent){ m.spent=true; left--; } }
  for(const m of next){ if(left<=0) break; if(!m.spent){ m.spent=true; left--; } }
  return next;
}

/* ============================================================ */
function Board(){
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [turn, setTurn] = useState('me');
  const [turnCount, setTurnCount] = useState(5);
  const [foeBoard, setFoeBoard] = useState(FOE_BOARD0);
  const [myBoard, setMyBoard] = useState(MY_BOARD0);
  const [hand, setHand] = useState(HAND0);
  const [mana, setMana] = useState(MY_BANK);
  const [myAwakens, setMyAwakens] = useState(MY_AWAKENS0);
  const [dragId, setDragId] = useState(null);
  const [summonId, setSummonId] = useState(null);
  const [foeHp, setFoeHp] = useState(24);   // hero hp takes attack damage
  const [attacking, setAttacking] = useState(false);
  const [toast, setToast] = useState(null);
  const [tipInfo, setTipInfo] = useState(null); // hover card description
  const [picker, setPicker] = useState(null);   // multicolor → choose mana colour
  const tipKeyRef = useRef(null);               // last hovered element (dedupe)

  const dragRef = useRef(null);       // active drag session
  const ghostRef = useRef(null);
  const boardElRef = useRef(null);
  const atkRef = useRef(null);        // active attack session
  const arrowRef = useRef(null);      // svg overlay
  const arrowPathRef = useRef(null);
  const arrowHeadRef = useRef(null);
  const arrowOriginRef = useRef(null);

  const myField = useRef(null);

  const showToast = useCallback((msg, warn)=>{
    setToast({msg, warn});
    clearTimeout(showToast._t);
    showToast._t = setTimeout(()=>setToast(null), 1700);
  },[]);

  /* ---- apply tweaks to stage ---- */
  useEffect(()=>{
    const stage = document.getElementById('stage');
    if(!stage) return;
    stage.setAttribute('data-dir', t.direction);
    stage.style.setProperty('--glow', t.glow);
    stage.style.setProperty('--glass-blur', t.blur+'px');
    stage.style.setProperty('--motif', t.dispersion ? t.motif : 0);
  },[t]);

  /* ---- hover description: delegated over the whole board (attach once) ---- */
  useEffect(()=>{
    const root = boardElRef.current; if(!root) return;
    const onMove = (e)=>{
      const el = e.target.closest('[data-tip]');
      if(!el){
        if(tipKeyRef.current!==null){ tipKeyRef.current=null; setTipInfo(null); }
        return;
      }
      if(el===tipKeyRef.current) return;   // same card → tip already shown
      const r = el.getBoundingClientRect();
      let data; try{ data = JSON.parse(el.getAttribute('data-tip')); }catch(_){ return; }
      tipKeyRef.current = el;
      setTipInfo({data, rect:{left:r.left, right:r.right, top:r.top, bottom:r.bottom, cx:(r.left+r.right)/2}});
    };
    const onLeave = ()=>{ tipKeyRef.current=null; setTipInfo(null); };
    root.addEventListener('pointermove', onMove);
    root.addEventListener('pointerleave', onLeave);
    return ()=>{ root.removeEventListener('pointermove', onMove); root.removeEventListener('pointerleave', onLeave); };
  },[]);
  /* hide tip while dragging a card */
  useEffect(()=>{ if(dragId){ tipKeyRef.current=null; setTipInfo(null); } },[dragId]);

  useEffect(()=>{ setHand(t.handFull ? STRESS_HAND : HAND0); },[t.handFull]);
  useEffect(()=>{ setMana(t.bankHuge ? BIG_BANK : MY_BANK); },[t.bankHuge]);
  useEffect(()=>{
    setFoeBoard(t.boardFull ? FOE_BOARD_FULL : FOE_BOARD0);
    setMyBoard(t.boardFull ? MY_BOARD_FULL : MY_BOARD0);
  },[t.boardFull]);

  /* test hooks: toggle preview states without the panel */
  useEffect(()=>{
    window.__tw = (k,v)=>setTweak(k, v);
  },[setTweak]);

  const draggingCard = dragId ? hand.find(c=>c.id===dragId) : null;
  const spellMode = !!(draggingCard && draggingCard.type==='spell');

  /* ---- drag session ---- */
  const onCardPointerDown = useCallback((card)=>(e)=>{
    if(turn!=='me') return;
    if(e.button!==0) return;
    const startX=e.clientX, startY=e.clientY; let moved=false;
    const ghost = ghostRef.current;
    // paint ghost
    const rim = PALETTE[card.color];
    ghost.style.setProperty('--rim', rim);
    ghost.style.border = '1.5px solid '+rim;
    ghost.style.boxShadow = '0 0 34px '+rim+'aa';
    if(card.art){
      ghost.style.backgroundImage = `linear-gradient(180deg,rgba(4,4,10,.2),rgba(4,4,10,.55)),url(${card.art})`;
      ghost.style.backgroundSize='cover'; ghost.style.backgroundPosition='center';
    } else {
      ghost.style.backgroundImage =
        `radial-gradient(120% 80% at 50% 18%, ${rim}, transparent 60%),
         radial-gradient(140% 100% at 50% 120%, ${rim}88, #0a0a13 70%)`;
    }
    ghost.style.left = e.clientX+'px';
    ghost.style.top  = e.clientY+'px';
    ghost.style.display='block';

    dragRef.current = {card};
    setDragId(card.id);

    const move = (ev)=>{
      if(!moved && Math.hypot(ev.clientX-startX, ev.clientY-startY) < 6) return;
      moved=true;
      ghost.style.left = ev.clientX+'px';
      ghost.style.top  = ev.clientY+'px';
      // legal-zone feedback for creatures
      const el = document.elementFromPoint(ev.clientX, ev.clientY);
      const overField = el && el.closest && el.closest('.me-field');
      if(card.type!=='spell'){
        const f = myField.current;
        if(f) f.classList.toggle('drop-legal', !!overField);
      }
    };
    const up = (ev)=>{
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      ghost.style.display='none';
      if(myField.current) myField.current.classList.remove('drop-legal');
      dragRef.current=null;
      setDragId(null);
      if(!moved) return; // a plain click — leave for dblclick handler
      const el = document.elementFromPoint(ev.clientX, ev.clientY);
      resolveDrop(card, el);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  },[turn, hand, mana]);

  const resolveDrop = useCallback((card, el)=>{
    if(!el || !el.closest){ return; }
    if(card.type==='spell'){
      const tgt = el.closest('.card[data-side="foe"]');
      if(!tgt){ showToast('Нужна цель — существо соперника', true); return; }
      const id = tgt.getAttribute('data-id');
      const spent = spendMana(mana, card.cost);
      if(!spent){ showToast('Недостаточно маны', true); return; }
      setMana(spent);
      setFoeBoard(prev=>prev.map(c=>{
        if(c.id!==id) return c;
        const hp=c.hp-card.dmg;
        return {...c, hp, hurt:true};
      }).filter(c=>c.hp>0));
      setHand(prev=>prev.filter(c=>c.id!==card.id));
      showToast(<span><b>{card.name}</b> — {card.dmg} урона</span>);
    } else {
      const overField = el.closest('.me-field');
      if(!overField){ return; } // dropped outside → return to hand
      const spent = spendMana(mana, card.cost);
      if(!spent){ showToast('Недостаточно маны', true); return; }
      setMana(spent);
      const creature = {...card};
      setMyBoard(prev=>[...prev, creature]);
      setHand(prev=>prev.filter(c=>c.id!==card.id));
      setSummonId(card.id);
      setTimeout(()=>setSummonId(null), 600);
      showToast(<span><b>{card.name}</b> вступает в строй</span>);
    }
  },[mana]);

  /* ---- double-click hand card → convert to mana ---- */
  /* ---- convert hand card → mana (banked crystal of a chosen colour) ---- */
  const bankAs = useCallback((card, color)=>{
    setMana(prev=>[...prev, {color}]);            // any card = +1 crystal (unbounded mana)
    setHand(prev=>prev.filter(c=>c.id!==card.id));
    setPicker(null);
    showToast(<span><b>{card.name}</b> → +1 мана ({COLOR_RU[color]})</span>);
  },[showToast]);

  const onHandDblClick = useCallback((card)=>(e)=>{
    e.preventDefault();
    const colors = [...new Set(card.pips && card.pips.length ? card.pips : [card.color])];
    if(colors.length<=1){ bankAs(card, colors[0]||card.color); return; }
    // multicolour → let the player choose which mana to bank it as
    const el = e.currentTarget.closest('.card') || e.currentTarget;
    const r = el.getBoundingClientRect();
    tipKeyRef.current=null; setTipInfo(null);
    setPicker({card, colors, rect:{cx:(r.left+r.right)/2, top:r.top, bottom:r.bottom}});
  },[bankAs]);

  /* ---- awaken: play a card straight from the bank, no extra mana ---- */
  const onAwaken = useCallback((id)=>{
    setMyAwakens(prev=>{
      const a = prev.find(x=>x.id===id);
      if(!a || !a.available) return prev;
      const creature = {id:'aw-'+id, side:'me', color:a.color, name:a.name, art:a.art,
        cost:a.cost, pips:[a.color], atk:a.atk, hp:a.hp, statuses:a.statuses||[]};
      setMyBoard(b=>[...b, creature]);
      setSummonId(creature.id); setTimeout(()=>setSummonId(null),600);
      showToast(<span><b>{a.name}</b> пробуждён · {a.mode==='decoy'?'без доплаты':'разбужен'}</span>);
      return prev.filter(x=>x.id!==id);
    });
  },[showToast]);

  /* ---- attack: drag a beam-arrow from my creature to a legal target ---- */
  const hasStatus = (c, icon)=> (c.statuses||[]).some(s=>s.icon===icon);

  const legalTargets = useCallback(()=>{
    // stealth creatures can't be targeted; taunters force themselves as the only targets
    const visible = foeBoard.filter(c=>!hasStatus(c,'stealth'));
    const taunters = visible.filter(c=>c.provoke || hasStatus(c,'taunt'));
    if(taunters.length) return {ids:new Set(taunters.map(c=>c.id)), hero:false};
    return {ids:new Set(visible.map(c=>c.id)), hero:true};
  },[foeBoard]);

  const paintArrow = (x0,y0,x1,y1,valid)=>{
    const dx=x1-x0, dy=y1-y0; const dist=Math.hypot(dx,dy);
    const mx=(x0+x1)/2, my=(y0+y1)/2 - Math.min(120, dist*0.18); // gentle bow
    const path=arrowPathRef.current, head=arrowHeadRef.current, orig=arrowOriginRef.current;
    if(path) path.setAttribute('d', `M ${x0} ${y0} Q ${mx} ${my} ${x1} ${y1}`);
    if(orig){ orig.setAttribute('cx', x0); orig.setAttribute('cy', y0); }
    if(head){
      const ang=Math.atan2(y1-my, x1-mx); const s=17;
      const a1=ang+Math.PI*0.82, a2=ang-Math.PI*0.82;
      const p1=`${x1+Math.cos(a1)*s},${y1+Math.sin(a1)*s}`;
      const p2=`${x1+Math.cos(a2)*s},${y1+Math.sin(a2)*s}`;
      head.setAttribute('points', `${x1},${y1} ${p1} ${p2}`);
    }
    const svg=arrowRef.current;
    if(svg) svg.setAttribute('data-valid', valid?'1':'0');
  };

  const onAttackStart = useCallback((creature)=>(e)=>{
    if(turn!=='me') return;
    if(e.button!==0) return;
    if((creature.atk||0)<=0){ showToast(<span><b>{creature.name}</b> не может атаковать</span>, true); return; }
    if(hasStatus(creature,'freeze')){ showToast(<span><b>{creature.name}</b> заморожен</span>, true); return; }
    e.preventDefault(); e.stopPropagation();
    const cardEl = e.currentTarget.closest('.card');
    const r = cardEl.getBoundingClientRect();
    const x0=(r.left+r.right)/2, y0=(r.top+r.bottom)/2;
    const startX=e.clientX, startY=e.clientY; let moved=false;
    const legal = legalTargets();

    // mark legal targets in the DOM
    foeBoard.forEach(c=>{
      if(legal.ids.has(c.id)){
        const el=document.querySelector(`.foe-field .card[data-id="${c.id}"]`);
        if(el) el.classList.add('atk-legal');
      }
    });
    const heroEl=document.querySelector('.medallion.foe');
    if(legal.hero && heroEl) heroEl.classList.add('atk-legal');

    const svg=arrowRef.current; if(svg) svg.style.display='block';
    setAttacking(true);
    atkRef.current={creature, x0, y0};
    tipKeyRef.current=null; setTipInfo(null);

    let hotEl=null;
    const move=(ev)=>{
      if(!moved && Math.hypot(ev.clientX-startX, ev.clientY-startY)<6) return;
      moved=true;
      const el=document.elementFromPoint(ev.clientX, ev.clientY);
      const tgt=el && el.closest && el.closest('.atk-legal');
      if(tgt!==hotEl){ if(hotEl) hotEl.classList.remove('atk-hot'); if(tgt) tgt.classList.add('atk-hot'); hotEl=tgt; }
      paintArrow(x0,y0, ev.clientX, ev.clientY, !!tgt);
    };
    const up=(ev)=>{
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      if(svg) svg.style.display='none';
      setAttacking(false);
      const target=hotEl;   // capture before clearing highlight classes
      document.querySelectorAll('.atk-legal').forEach(n=>n.classList.remove('atk-legal'));
      document.querySelectorAll('.atk-hot').forEach(n=>n.classList.remove('atk-hot'));
      atkRef.current=null;
      if(!moved || !target) return;
      if(target.classList.contains('medallion')) resolveAttack(creature, null, 'hero');
      else resolveAttack(creature, target.getAttribute('data-id'), null);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  },[turn, foeBoard, legalTargets, showToast]);

  const flashClash = (ids)=>{
    ids.forEach(id=>{
      const el=document.querySelector(`.card[data-id="${id}"]`);
      if(el){ el.classList.add('clash'); setTimeout(()=>el.classList.remove('clash'),460); }
    });
  };

  const resolveAttack = useCallback((attacker, targetId, heroFlag)=>{
    if(heroFlag==='hero'){
      const dmg=attacker.atk||0;
      flashClash([attacker.id]);
      const heroEl=document.querySelector('.medallion.foe');
      if(heroEl){ heroEl.classList.add('hero-hit'); setTimeout(()=>heroEl.classList.remove('hero-hit'),460); }
      setFoeHp(hp=>Math.max(0, hp-dmg));
      showToast(<span><b>{attacker.name}</b> бьёт героя — {dmg} урона</span>);
      return;
    }
    const target=foeBoard.find(c=>c.id===targetId); if(!target) return;
    flashClash([attacker.id, target.id]);
    const aDmg=attacker.atk||0, tDmg=target.atk||0;
    // target takes my attack
    setFoeBoard(prev=>prev.map(c=> c.id===targetId ? {...c, hp:c.hp-aDmg, hurt:true} : c).filter(c=>c.hp>0));
    // attacker takes retaliation
    setMyBoard(prev=>prev.map(c=> c.id===attacker.id ? {...c, hp:c.hp-tDmg, hurt:true} : c).filter(c=>c.hp>0));
    const tDies=target.hp-aDmg<=0, aDies=attacker.hp-tDmg<=0;
    showToast(<span><b>{attacker.name}</b> ⚔ <b>{target.name}</b>{tDies?' · цель пала':''}{aDies?' · и сам погиб':''}</span>);
  },[foeBoard]);

  /* ---- turn switch ---- */
  const switchTurn = ()=>{
    setTurn(prev=>{
      if(prev==='me'){ return 'foe'; }
      setTurnCount(c=>c+1);
      return 'me';
    });
  };

  const myRes = {
    side:'me', bank:mana, awakens:myAwakens,
    deck:18, discard:3, hand:hand.length,
  };
  const foeRes = {
    side:'foe', bank:t.foeBankHuge?FOE_BANK_BIG:FOE_BANK, awakens:FOE_AWAKENS,
    revealed:!!t.floodlight, preview:t.foeBankHuge?FOE_PREVIEW_BIG:FOE_PREVIEW,
    deck:16, discard:1, hand:5,
  };
  const FOE_HERO = {side:'foe', name:'Кейра', hp:foeHp, armor:2,
    portraitImg:ART.heroFoe,
    abilities:[
      {icon:'target', name:'Пожиратель света', desc:'Когда умирает существо, герой поглощает его свет и восстанавливает 1 здоровье.'},
      {icon:'eye', name:'Ночной взор', desc:'Раз в партию: ослепляет вражеское существо до конца хода.'},
    ]};
  const MY_HERO = {side:'me', name:'Ирида', hp:27, armor:3,
    portraitImg:ART.heroIris,
    abilities:[
      {icon:'triangle', name:'Преломление', desc:'Первое ваше заклинание за ход преломляется и задевает соседнюю цель.'},
      {icon:'haste', name:'Световой рывок', desc:'Раз в партию: одно ваше существо получает рывок и атакует сразу.'},
    ]};

  /* creature row fits up to 8 by uniformly SCALING the row (no overlap) */
  const rowScale = (n)=>{
    const AVAIL=968, cardW=148, gap=12;
    const W = n*cardW + (n-1)*gap;
    return W<=AVAIL ? 1 : Math.max(0.6, AVAIL/W);
  };
  const foeScale = rowScale(foeBoard.length);
  const myScale  = rowScale(myBoard.length);

  /* flat hand row — no fan, no rotation; horizontal overlap adapts to count */
  const N = hand.length;
  const handOv = N<=5 ? -18 : Math.max(-64, -(18 + (N-5)*8.4));
  const fan = (i)=>{
    /* rightmost card on top: z-index grows left → right */
    return { zIndex:10+i };
  };

  return (
    <React.Fragment>
      <div className="scene"></div>
      <div className="dispersion"></div>

      <div className={'board'+(attacking?' is-attacking':'')} id="board" ref={boardElRef}>
        {/* turn indicator */}
        <div className="turnbar">
          <div className={'turn-pill'+(turn==='foe'?' foe':'')}>
            <div className="turn-label">{turn==='me'?'Ваш ход':'Ход соперника'}</div>
            <div className="turn-sep"></div>
            <div className="turn-count">ход {turnCount}</div>
            <button className="turn-switch" onClick={switchTurn}>сменить</button>
          </div>
        </div>

        {/* opponent rail */}
        <div className="rail-foe-wrap">
          <div className={'rail foe'+(turn==='foe'?' is-active':'')}>
            <Medallion hero={FOE_HERO}/>
            <AuraShelf side="foe" auras={t.aurasMany?MANY_AURAS_FOE:FOE_AURAS}/>
            <div className="field foe-field">
              {foeBoard.length===0 && <div className="field-empty-hint">поле пусто</div>}
              <div className="field-inner" style={{transform:`scale(${foeScale})`}}>
                {foeBoard.map(c=>(
                  <Card key={c.id} c={c} targetMode={spellMode}
                    summoning={summonId===c.id}/>
                ))}
              </div>
            </div>
            <Resources data={foeRes}/>
          </div>
        </div>

        {/* my rail */}
        <div className="rail-me-wrap">
          <div className={'rail me'+(turn==='me'?' is-active':'')}>
            <Medallion hero={MY_HERO}/>
            <AuraShelf side="me" auras={t.aurasMany?MANY_AURAS_ME:MY_AURAS}/>
            <div className="field me-field" ref={myField}>
              {myBoard.length===0 && <div className="field-empty-hint">перетащите карту сюда</div>}
              <div className="field-inner" style={{transform:`scale(${myScale})`}}>
                {myBoard.map(c=>(
                  <Card key={c.id} c={c} summoning={summonId===c.id}
                    onPointerDown={turn==='me' ? onAttackStart(c) : undefined}/>
                ))}
              </div>
            </div>
            <Resources data={myRes} onAwaken={onAwaken}/>
          </div>
        </div>

        {/* hand */}
        <div className="hand-zone">
          <div className="hand" style={{'--ov':handOv+'px'}}>
            {hand.map((c,i)=>(
              <div key={c.id} style={fan(i)} className="hand-card-wrap"
                onDoubleClick={onHandDblClick(c)}>
                <Card c={c} dragging={dragId===c.id} summoning={summonId===c.id}
                  onPointerDown={onCardPointerDown(c)}/>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="hint">
        тащите карту на стол — <b>разыграть</b> · от своего существа к цели — <b>атака</b> · на цель — <b>заклинание</b> · двойной клик — <b>в ману</b>
      </div>

      <div className={'toast'+(toast?' show':'')+(toast&&toast.warn?' warn':'')}>
        {toast && toast.msg}
      </div>

      {ReactDOM.createPortal(
        <React.Fragment>
          <div id="drag-ghost" ref={ghostRef}></div>
          <svg id="attack-arrow" ref={arrowRef} data-valid="0" style={{display:'none'}}>
            <defs>
              <linearGradient id="atkGrad" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0" stopColor="#FAC233"/>
                <stop offset="1" stopColor="#EB5C6B"/>
              </linearGradient>
            </defs>
            <circle ref={arrowOriginRef} className="atk-origin" r="7"/>
            <path ref={arrowPathRef} className="atk-path" fill="none"/>
            <polygon ref={arrowHeadRef} className="atk-head"/>
          </svg>
          <CardTip info={tipInfo}/>
          <ColorPicker picker={picker} onPick={bankAs} onClose={()=>setPicker(null)}/>
          <PrismTweaks t={t} setTweak={setTweak}/>
        </React.Fragment>, document.body)}
    </React.Fragment>
  );
}

/* ---------- hover description popover ---------- */
const COLOR_HEX = {'красный':'#EB334C','жёлтый':'#FAC233','зелёный':'#42D170',
  'синий':'#3D94FA','фиолетовый':'#AD52F0','бесцветный':'#CCCCE0'};
function CardTip({info}){
  const ref = React.useRef(null);
  const [pos, setPos] = React.useState(null);
  React.useLayoutEffect(()=>{
    if(!info || !ref.current){ setPos(null); return; }
    const el = ref.current;
    const w = el.offsetWidth, h = el.offsetHeight;
    const r = info.rect; const gap = 12; const vw = window.innerWidth, vh = window.innerHeight;
    let left = r.cx - w/2;
    left = Math.max(10, Math.min(left, vw - w - 10));
    let top = r.top - gap - h; // above
    if(top < 10) top = Math.min(r.bottom + gap, vh - h - 10); // flip below
    setPos({left, top});
  },[info]);
  if(!info) return null;
  const d = info.data;
  const ac = COLOR_HEX[d.color] || '#9fb4e8';
  return (
    <div className="cardtip" ref={ref}
      style={{left:(pos?pos.left:-9999)+'px', top:(pos?pos.top:-9999)+'px',
        opacity: pos?1:0, '--tipac':ac}}>
      <div className="cardtip-head">
        <span className="cardtip-name">{d.title}</span>
        {(d.cost!=null) && <span className="cardtip-cost">{d.cost} <i>мана</i></span>}
      </div>
      <div className="cardtip-meta">
        <span className="cardtip-kind">{d.kind}</span>
        {d.color && <span className="cardtip-dot" style={{background:ac}}></span>}
        {d.color && <span className="cardtip-color">{d.color}</span>}
        {d.owner && <span className="cardtip-owner">· {d.owner}</span>}
      </div>
      {(typeof d.atk==='number' || typeof d.hp==='number' || typeof d.dmg==='number') &&
        <div className="cardtip-stats">
          {typeof d.atk==='number' && <span><b>{d.atk}</b> атака</span>}
          {typeof d.hp==='number'  && <span><b>{d.hp}</b> здоровье</span>}
          {typeof d.dmg==='number' && <span><b>{d.dmg}</b> урон</span>}
        </div>}
      {d.body && <div className="cardtip-body">{d.body}</div>}
      {d.statuses && d.statuses.length>0 &&
        <div className="cardtip-status">
          {d.statuses.map((s,i)=>(
            <div key={i} className="cardtip-status-row">
              <b>{s.label}.</b> {s.text}
            </div>
          ))}
        </div>}
    </div>
  );
}

/* ---------- multicolor → choose which mana to bank as ---------- */
function ColorPicker({picker, onPick, onClose}){
  const ref = React.useRef(null);
  const [pos, setPos] = React.useState(null);
  React.useLayoutEffect(()=>{
    if(!picker || !ref.current){ setPos(null); return; }
    const el = ref.current; const w=el.offsetWidth, h=el.offsetHeight;
    const r=picker.rect; const gap=14; const vw=window.innerWidth, vh=window.innerHeight;
    let left = r.cx - w/2; left = Math.max(10, Math.min(left, vw-w-10));
    let top = r.top - gap - h; if(top<10) top = Math.min(r.bottom+gap, vh-h-10);
    setPos({left, top});
  },[picker]);
  React.useEffect(()=>{
    if(!picker) return;
    const onKey=(e)=>{ if(e.key==='Escape') onClose(); };
    const onDown=(e)=>{ if(ref.current && !ref.current.contains(e.target)) onClose(); };
    window.addEventListener('keydown', onKey);
    window.addEventListener('pointerdown', onDown, true);
    return ()=>{ window.removeEventListener('keydown', onKey); window.removeEventListener('pointerdown', onDown, true); };
  },[picker, onClose]);
  if(!picker) return null;
  const {card, colors} = picker;
  return (
    <div className="manapick" ref={ref}
      style={{left:(pos?pos.left:-9999)+'px', top:(pos?pos.top:-9999)+'px', opacity:pos?1:0}}>
      <div className="manapick-title">В какую ману?</div>
      <div className="manapick-row">
        {colors.map((c,i)=>(
          <button key={i} className="manapick-opt" style={{'--cc':PALETTE[c]}}
            onClick={()=>onPick(card, c)} title={COLOR_RU[c]}>
            <Crystal color={PALETTE[c]} w={30} h={42}/>
            <span className="manapick-name">{COLOR_RU[c]}</span>
          </button>
        ))}
      </div>
      <div className="manapick-tip">{card.name} → банк</div>
    </div>
  );
}

/* ---------- Tweaks panel ---------- */
function PrismTweaks({t, setTweak}){
  return (
    <TweaksPanel>
      <TweakSection label="Визуальное направление"/>
      <TweakRadio label="Стиль" value={t.direction}
        options={[{value:'glass',label:'Стекло'},{value:'neon',label:'Неон'},{value:'prism',label:'Призма'}]}
        onChange={v=>setTweak('direction', v)}/>
      <TweakSection label="Свет и материал"/>
      <TweakSlider label="Сила свечения" value={t.glow} min={0.3} max={2} step={0.05}
        onChange={v=>setTweak('glow', v)}/>
      <TweakSlider label="Размытие стекла" value={t.blur} min={0} max={28} step={1} unit="px"
        onChange={v=>setTweak('blur', v)}/>
      <TweakSection label="Спектральный мотив"/>
      <TweakToggle label="Дисперсия по столу" value={t.dispersion}
        onChange={v=>setTweak('dispersion', v)}/>
      <TweakSlider label="Насыщенность мотива" value={t.motif} min={0} max={1} step={0.05}
        onChange={v=>setTweak('motif', v)}/>
      <TweakSection label="Состояния и лимиты"/>
      <TweakToggle label="Прожектор: раскрыть банк соперника" value={t.floodlight}
        onChange={v=>setTweak('floodlight', v)}/>
      <TweakToggle label="Полная рука (10 карт)" value={t.handFull}
        onChange={v=>setTweak('handFull', v)}/>
      <TweakToggle label="Полный стол (8 существ)" value={t.boardFull}
        onChange={v=>setTweak('boardFull', v)}/>
      <TweakToggle label="Большой банк маны — ваш (20+)" value={t.bankHuge}
        onChange={v=>setTweak('bankHuge', v)}/>
      <TweakToggle label="Большой банк маны — соперник (20+)" value={t.foeBankHuge}
        onChange={v=>setTweak('foeBankHuge', v)}/>
      <TweakToggle label="Много аур (6 на сторону)" value={t.aurasMany}
        onChange={v=>setTweak('aurasMany', v)}/>
    </TweaksPanel>
  );
}

/* ---------- scaling ---------- */
function fitStage(){
  const stage = document.getElementById('stage');
  if(!stage) return;
  const s = Math.min(window.innerWidth/1600, window.innerHeight/900);
  stage.style.transform = `scale(${s})`;
}
window.addEventListener('resize', fitStage);

ReactDOM.createRoot(document.getElementById('root')).render(<Board/>);
setTimeout(fitStage, 0);
