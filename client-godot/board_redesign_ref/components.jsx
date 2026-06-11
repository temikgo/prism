/* ============================================================
   PRISM — components.jsx  (icons, badges, card, medallion, bank, auras)
   Design system preserved: dark glass, faceted gems, prism glyph, tokens.
   ============================================================ */

const PALETTE = {
  red:'#EB334C', yellow:'#FAC233', green:'#42D170',
  blue:'#3D94FA', violet:'#AD52F0', colorless:'#CCCCE0',
  me:'#579EFA', foe:'#EB5C6B', gold:'#F4C657',
};

/* ---------- thin-line icons (our set — DO NOT replace) ---------- */
const ICONS = {
  freeze:(<g><path d="M12 2v20M12 2l-3 3M12 2l3 3M12 22l-3-3M12 22l3-3M3 7l18 10M3 7l1 4M3 7l4-1M21 17l-1-4M21 17l-4 1M21 7L3 17M21 7l-4-1M21 7l-1 4M3 17l4 1M3 17l1-4"/></g>),
  eye:(<g><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z"/><circle cx="12" cy="12" r="2.6"/></g>),
  /* ослепление — глаз с перечёркиванием */
  blind:(<g><path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12Z"/><circle cx="12" cy="12" r="2.6"/><path d="M3 3 21 21"/></g>),
  /* щит */
  shield:(<g><path d="M12 3l7 2.5v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9v-5L12 3Z"/></g>),
  guard:(<g><path d="M12 3l7 2.5v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9v-5L12 3Z"/></g>),
  /* оберег (ward) — защитный руний-сигил */
  ward:(<g><circle cx="12" cy="12" r="6"/><path d="M12 1.5v4M12 18.5v4M1.5 12h4M18.5 12h4"/><path d="M12 9l3 3-3 3-3-3 3-3Z"/></g>),
  /* незримость (stealth) — полумесяц + блик */
  stealth:(<g><path d="M16.6 4.3A8 8 0 1 0 16.6 19.7 9.6 9.6 0 0 1 16.6 4.3Z"/><path d="M19.2 6.4l.5 1.6 1.6.5-1.6.5-.5 1.6-.5-1.6-1.6-.5 1.6-.5.5-1.6Z"/></g>),
  /* провокатор (taunt) — щит с восклицанием */
  taunt:(<g><path d="M12 3l7 2.5v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9v-5L12 3Z"/><path d="M12 8v4.2"/><path d="M12 15.2v.2"/></g>),
  venom:(<g><path d="M12 3c2.5 3 5 5.5 5 9a5 5 0 0 1-10 0c0-3.5 2.5-6 5-9Z"/><path d="M12 13v3"/></g>),
  haste:(<g><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z"/></g>),
  target:(<g><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3.4"/><path d="M12 1v3M12 20v3M1 12h3M20 12h3"/></g>),
  triangle:(<g><path d="M12 4 21 19H3L12 4Z"/><path d="M12 11v5M9.5 13.5h5"/></g>),
  /* прожектор (floodlight) */
  flood:(<g><path d="M8.5 3h7l2.5 6H6l2.5-6Z"/><path d="M7.6 9v2.5a4.4 4.4 0 0 0 8.8 0V9"/><path d="M12 16.4V21"/></g>),
};
function Icon({name, w=24}){
  return (
    <svg viewBox="0 0 24 24" width={w} height={w} fill="none"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
      {ICONS[name]}
    </svg>
  );
}

const COLOR_RU = {red:'красный',yellow:'жёлтый',green:'зелёный',
  blue:'синий',violet:'фиолетовый',colorless:'бесцветный'};

/* ---------- hover description (every card-like element gets one) ----------
   Encoded into a data-tip JSON attribute; Board renders a single popover. */
function tip(obj){
  return {'data-tip': JSON.stringify(obj)};
}
function statusTip(statuses){
  return (statuses||[]).map(s=>{
    const m = STATUS[s.icon] || {};
    return {label:m.label||s.icon, text:m.desc||''};
  });
}

/* status meta: which icon, which color, optional full-card fx */
const STATUS = {
  freeze:{icon:'freeze', color:'blue',     fx:'freeze', label:'Заморозка', desc:'Не может атаковать в этот ход.'},
  blind: {icon:'blind',  color:'violet',   fx:null,     label:'Ослепление', desc:'Атакует случайную цель, возможен промах.'},
  shield:{icon:'shield', color:'blue',     fx:'shield', label:'Щит', desc:'Поглощает следующий полученный урон.'},
  ward:  {icon:'ward',   color:'yellow',   fx:'ward',   label:'Оберег', desc:'Блокирует первое вражеское заклинание.'},
  stealth:{icon:'stealth',color:'colorless',fx:'stealth',label:'Незримость', desc:'Нельзя выбрать целью, пока не атакует.'},
  taunt: {icon:'taunt',  color:'red',      fx:null,     label:'Провокатор', desc:'Враг обязан атаковать это существо первым.'},
  haste: {icon:'haste',  color:'red',      fx:null,     label:'Рывок', desc:'Может атаковать сразу в ход призыва.'},
};

/* ---------- octagon stat badge (OUR faceted stat-gem — DO NOT redesign) ---------- */
function HexBadge({color}){
  const pts="30,3 70,3 97,30 97,70 70,97 30,97 3,70 3,30";
  const id='g'+color.replace('#','');
  return (
    <svg className="hex" viewBox="0 0 100 100" preserveAspectRatio="none"
      style={{position:'absolute',inset:0,width:'100%',height:'100%'}}>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#ffffff" stopOpacity="0.5"/>
          <stop offset="0.32" stopColor={color}/>
          <stop offset="1" stopColor={color}/>
        </linearGradient>
      </defs>
      <polygon points={pts} fill={'url(#'+id+')'} stroke="rgba(0,0,0,0.4)" strokeWidth="3"/>
      <polygon points={pts} fill="none" stroke="rgba(255,255,255,0.35)" strokeWidth="2"
        transform="scale(0.86)" style={{transformOrigin:'center'}}/>
    </svg>
  );
}

/* ---------- faceted mana crystal (preserved) ---------- */
function Crystal({color, spent, w=22, h=30}){
  const id='cg'+color.replace('#','');
  return (
    <div className={'crystal'+(spent?' spent':'')} style={{'--cc':color, width:w, height:h}}>
      <svg viewBox="0 0 32 44">
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#ffffff" stopOpacity="0.85"/>
            <stop offset="0.4" stopColor={color}/>
            <stop offset="1" stopColor={color} stopOpacity="0.85"/>
          </linearGradient>
        </defs>
        <path d="M16 1 L29 13 L16 43 L3 13 Z" fill={'url(#'+id+')'}
          stroke="rgba(255,255,255,0.55)" strokeWidth="0.8"/>
        <path d="M16 1 L16 43 M3 13 L29 13 M16 1 L10 13 L16 43 M16 1 L22 13"
          stroke="rgba(0,0,0,0.28)" strokeWidth="0.7" fill="none"/>
        <path d="M16 1 L10 13 L16 25 Z" fill="#ffffff" opacity="0.28"/>
      </svg>
    </div>
  );
}

/* ---------- prism glyph (motif: ray → prism → spectrum) ---------- */
function PrismGlyph(){
  return (
    <svg className="prism-glyph" width="60" height="30" viewBox="0 0 60 30" fill="none">
      <path d="M2 15 H21" stroke="#dfe6ff" strokeWidth="1.6" strokeLinecap="round"/>
      <path d="M22 5 L33 15 L22 25 Z" fill="rgba(255,255,255,0.14)"
        stroke="#eef1ff" strokeWidth="1.3" strokeLinejoin="round"/>
      <path d="M33 15 L58 8"  stroke="#EB334C" strokeWidth="1.5" strokeLinecap="round"/>
      <path d="M33 15 L58 12" stroke="#FAC233" strokeWidth="1.5" strokeLinecap="round"/>
      <path d="M33 15 L58 15" stroke="#42D170" strokeWidth="1.5" strokeLinecap="round"/>
      <path d="M33 15 L58 18" stroke="#3D94FA" strokeWidth="1.5" strokeLinecap="round"/>
      <path d="M33 15 L58 22" stroke="#AD52F0" strokeWidth="1.5" strokeLinecap="round"/>
    </svg>
  );
}

/* ---------- creature / hand card ----------
   Frame (chrome) is designed AROUND the fixed stat-gems + status icons.
   Art is full-bleed; gems sit in darkened corner nooks for legibility. */
function Card({c, onPointerDown, targetMode, dragging, summoning}){
  const rim = PALETTE[c.color];
  const targetable = targetMode && c.side==='foe';
  const statuses = c.statuses || [];
  const fxList = statuses.map(s=>STATUS[s.icon] && STATUS[s.icon].fx).filter(Boolean);
  const cls = ['card'];
  if(c.spectrum) cls.push('spectrum');
  if(c.provoke)  cls.push('provoke');
  if(targetable) cls.push('targetable','foe-target');
  if(dragging)   cls.push('dragging');
  if(summoning)  cls.push('summoning');
  fxList.forEach(fx=>cls.push('fx-'+fx));

  const kindRu = c.type==='spell' ? 'Заклинание' : 'Существо';
  const tipData = {
    title: c.name || (c.phTag||'Карта'),
    kind: kindRu,
    color: COLOR_RU[c.color],
    cost: c.cost,
    atk: typeof c.atk==='number'?c.atk:(c.type==='spell'?undefined:undefined),
    hp:  typeof c.hp==='number'?c.hp:undefined,
    dmg: c.type==='spell'?c.dmg:undefined,
    body: c.desc || (c.type==='spell'?'Одноразовый эффект.':''),
    statuses: statusTip(statuses),
    spectrum: !!c.spectrum,
  };

  return (
    <div className={cls.join(' ')} style={{'--rim':rim}} data-id={c.id} data-side={c.side}
      {...tip(tipData)} onPointerDown={onPointerDown}>
      {c.art
        ? <div className="art" style={{backgroundImage:`url(${c.art})`}}></div>
        : <div className="art placeholder" style={{'--rim':rim}}>
            {c.phTag && <div className="ph-tag">{c.phTag}</div>}
          </div>}
      <div className="art-scrim"></div>

      {/* status-driven full-card effects */}
      {fxList.includes('freeze')  && <div className="fx fx-freeze-layer"></div>}
      {fxList.includes('stealth') && <div className="fx fx-stealth-layer"></div>}
      {fxList.includes('shield')  && <div className="fx fx-shield-layer"></div>}
      {fxList.includes('ward')    && <div className="fx fx-ward-layer"></div>}

      <div className="rim"></div>
      {c.provoke && <div className="provoke-frame"><span></span><span></span><span></span><span></span></div>}

      {/* cost + colour pips */}
      <div className="cost"><b>{c.cost}</b>
        <div className="pips">{c.pips.map((p,i)=>(<span key={i} className="pip" style={{'--p':PALETTE[p]}}></span>))}</div>
      </div>

      {/* status badges (our thin-line icons) */}
      {statuses.length>0 &&
        <div className="status">
          {statuses.map((s,i)=>{
            const meta = STATUS[s.icon] || {};
            const col = PALETTE[s.color || meta.color] || '#cfe0ff';
            return (
              <div key={i} className="badge" style={{'--c':col}} title={meta.label}>
                <Icon name={s.icon} w={13}/>
              </div>
            );
          })}
        </div>}

      {c.name && <div className="card-name">{c.name}</div>}

      {/* fixed stat-gems in corner nooks */}
      {typeof c.atk==='number' &&
        <div className="stat atk"><span className="nook"></span><HexBadge color={PALETTE.yellow}/><span className="v">{c.atk}</span></div>}
      {typeof c.hp==='number' &&
        <div className={'stat hp'+(c.hurt?' hurt':'')}>
          <span className="nook"></span><HexBadge color={c.hurt?PALETTE.red:PALETTE.green}/><span className="v">{c.hp}</span>
        </div>}
      {c.type==='spell' && typeof c.dmg==='number' &&
        <div className="stat atk"><span className="nook"></span><HexBadge color={PALETTE.red}/><span className="v">{c.dmg}</span></div>}
    </div>
  );
}

/* ---------- hero medallion (real portrait) ---------- */
function Medallion({hero}){
  const side = hero.side;
  /* heroes can have several abilities — each opens its OWN description tooltip */
  const abilities = hero.abilities ||
    (hero.passive ? [{icon:hero.passive, name:hero.passiveName, desc:hero.passiveDesc}] : []);
  return (
    <div className={'medallion '+side}>
      <div className="hero-tag">{side==='foe'?'СОПЕРНИК':'ВЫ'}</div>
      <div className="portrait-wrap">
        <div className="portrait">
          {hero.portraitImg
            ? <div className="face" style={{backgroundImage:`url(${hero.portraitImg})`}}></div>
            : <div className="face" style={{background:hero.portrait}}></div>}
          <div className="portrait-sheen"></div>
        </div>
        <div className="hero-stat armor"><HexBadge color="#BCD6FF"/><span className="v">{hero.armor}</span></div>
        <div className="hero-stat hp">
          <HexBadge color={side==='me'?PALETTE.me:PALETTE.foe}/><span className="v">{hero.hp}</span>
        </div>
      </div>
      <div className="hero-name">{hero.name}</div>
      {abilities.length>0 &&
        <div className="abilities">
          {abilities.map((ab,i)=>(
            <div key={i} className="passive"
              {...tip({title:ab.name, kind:'Способность', owner: side==='me'?'Ваш герой':'Герой соперника',
                body:ab.desc||'Описание способности.'})}>
              <Icon name={ab.icon} w={16}/>
            </div>
          ))}
        </div>}
    </div>
  );
}

/* ---------- aura shelf (square art tiles · own / enemy) ----------
   Single column with capped-height scroll (like the mana bank), so it stays
   one column wide and never collides with the field — even with many auras. */
function AuraShelf({side, auras}){
  if(!auras || auras.length===0) return null;
  return (
    <div className={'aura-shelf '+side}>
      <div className="aura-tiles">
        {auras.map((a,i)=>(
          <div key={i} className="aura-tile" style={{'--ac':PALETTE[a.color]}}
            {...tip({title:a.name, kind:'Аура', color:COLOR_RU[a.color],
              body:a.desc||'Постоянный эффект, пока аура на столе.',
              owner: side==='me'?'Ваша аура':'Аура соперника'})}>
            {a.art
              ? <div className="aura-art" style={{backgroundImage:`url(${a.art})`}}></div>
              : <div className="aura-art ph"></div>}
            <div className="aura-rim"></div>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------- banked card = mana crystal (face-down) ----------
   states: available · spent (dim) · temp (this-turn bonus → green ring) */
function BankCard({color, spent, temp}){
  const cls = 'bankcard'+(spent?' spent':'')+(temp?' temp':'');
  const state = spent ? 'потрачен' : (temp ? 'временный · только этот ход' : 'доступен');
  return (
    <div className={cls} style={{'--cc':PALETTE[color]}}
      {...tip({title:'Кристалл маны', kind:'Мана', color:COLOR_RU[color],
        body:'Банкнутая карта рубашкой вниз. Состояние: '+state+'.'
          + (temp?' Дан «фотосинтезом», сгорит в конце хода.':'')})}>
      <div className="bank-back"></div>
      <Crystal color={PALETTE[color]} spent={spent} w={15} h={21}/>
      {temp && <span className="temp-ring"></span>}
    </div>
  );
}

/* mana grows unbounded → group by colour, wrap into rows, cap height + scroll */
const COLOR_ORDER = ['red','yellow','green','blue','violet','colorless'];
function BankPool({crystals}){
  const sorted = [...crystals].sort(
    (a,b)=>COLOR_ORDER.indexOf(a.color)-COLOR_ORDER.indexOf(b.color));
  return (
    <div className="bankpool">
      <div className="bank-row">
        {sorted.map((m,i)=>(<BankCard key={i} color={m.color} spent={m.spent} temp={m.temp}/>))}
      </div>
    </div>
  );
}

/* enemy bank revealed by FLOODLIGHT — compact face-up previews */
function BankPreview({card}){
  return (
    <div className="bankprev" style={{'--rim':PALETTE[card.color]}}
      {...tip({title:card.name||'Банкнутая карта', kind:'Мана соперника', color:COLOR_RU[card.color],
        body:'Видно благодаря прожектору — это банкнутая карта в мана-ряду соперника.'})}>
      {card.art
        ? <div className="bankprev-art" style={{backgroundImage:`url(${card.art})`}}></div>
        : <div className="bankprev-art ph"></div>}
      <div className="bankprev-rim"></div>
    </div>
  );
}

/* ---------- awaken card (gold mini-card, playable from the bank) ----------
   mode 'awaken' → play for cost (tag «разбудить»);
   mode 'decoy'  → ripened, play paying only its crystal (tag «без доплаты») */
function AwakenCard({data, onPlay}){
  const avail = data.available;
  const decoy = data.mode==='decoy';
  const tag = decoy ? 'без доплаты' : 'разбудить';
  const tipBody = decoy
    ? 'Decoy созрел: разыграть можно без доплаты — тратится только его кристалл маны.'
    : 'Ключевик Awaken: разыграть прямо из банка за стоимость '+(data.cost!=null?data.cost:0)+' маны.';
  return (
    <button className={'awaken'+(avail?'':' locked')+(decoy?' decoy':'')}
      onClick={avail && onPlay ? ()=>onPlay(data.id) : undefined}
      {...tip({title:data.name, kind:'Awaken · существо', color:COLOR_RU[data.color],
        cost: decoy?0:data.cost, atk:data.atk, hp:data.hp,
        body: tipBody + (avail?'':' Сейчас недостаточно маны.'),
        statuses: statusTip(data.statuses)})}>
      <div className="awaken-art" style={{backgroundImage:`url(${data.art})`}}></div>
      <div className="awaken-scrim"></div>
      <div className="awaken-rim"></div>
      {!decoy && <div className="awaken-cost" style={{'--cc':PALETTE[data.color]}}>{data.cost!=null?data.cost:0}</div>}
      <div className="awaken-stats">
        <span className="aw-atk">{data.atk}</span><span className="aw-hp">{data.hp}</span>
      </div>
      <div className="awaken-name">{data.name}</div>
      <div className="awaken-tag">{tag}</div>
    </button>
  );
}

/* ---------- resource column (bank + awaken + stacks) ---------- */
function Resources({data, onAwaken}){
  const side = data.side;
  const avail = data.bank ? data.bank.filter(c=>!c.spent).length : 0;
  return (
    <div className={'resources '+side}>
      <div className="res-block">
        {data.revealed
          ? <div className="res-label flood"><Icon name="flood" w={11}/> Мана соперника · прожектор</div>
          : <div className="res-label">Мана · банк <span className="bank-count">{avail}/{data.bank.length}</span></div>}
        {data.revealed
          ? <div className="bankpool reveal"><div className="bank-row">
              {data.preview.map((c,i)=>(<BankPreview key={i} card={c}/>))}
            </div></div>
          : <BankPool crystals={data.bank}/>}
      </div>

      {data.awakens && data.awakens.length>0 &&
        <div className="res-block">
          <div className="res-label gold">Awaken · в банке</div>
          <div className="awaken-row">
            {data.awakens.map(a=>(<AwakenCard key={a.id} data={a} onPlay={onAwaken}/>))}
          </div>
        </div>}

      <div className="stacks">
        <div className="pile"><b>{data.deck}</b><small>колода</small></div>
        <div className="pile"><b>{data.discard}</b><small>сброс</small></div>
        <div className="pile hand-pile"><b>{data.hand}</b><small>рука</small></div>
      </div>
    </div>
  );
}

Object.assign(window, {
  PALETTE, STATUS, COLOR_RU, Icon, HexBadge, Crystal, PrismGlyph,
  Card, Medallion, AuraShelf, BankCard, BankPool, BankPreview, AwakenCard, Resources,
});
