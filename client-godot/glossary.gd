class_name Glossary

# Plain-language Russian rules text: per-keyword and per-effect descriptions for
# the card tooltip, plus the live status lines for a creature in play and the
# card's type/color line. Pure string lookups over the static card data.

# Keyword meaning, shown in the tooltip. "N" is replaced by the keyword's value.
const KW := {
	"pierce": "Пробитие: лишний урон по существу переходит вражескому герою.",
	"bypass": "Сквозь строй: может бить героя даже при наличии защитников.",
	"lingering": "Неугасимость: раны, нанесённые им, не лечатся.",
	"regen": "Регенерация N: в начале вашего хода +N HP этому существу.",
	"self_lifesteal": "Алый дар: его урон лечит его самого на столько же.",
	"cauterize": "Заживление: его боевой урон лечит вашего героя на столько же.",
	"sear": "Дожиг N: при смерти — N урона вражескому герою.",
	"spark": "Искра N: активка — плати 1 кристалл, нанесите N урона вражескому герою. Раз в ход.",
	"provoke": "Маяк: вражеские существа обязаны атаковать это.",
	"shield": "Щит: игнорирует следующий источник урона целиком.",
	"ward": "Нимб: поглощает следующий вредный эффект/заклинание, нацеленный на это существо.",
	"germinate": "Проращивание N: активка — потратьте 1 кристалл, призовите росток N/N. Раз в ход.",
	"blind": "Ослепление N: N ход(ов) не атакует и не наносит боевой урон — даже в ответ при защите.",
	"flare": "Вспышка N: при смерти ослепляет N случайных врагов на 1 ход.",
	"firststrike": "Опережение: атакуя, бьёт первым — если убивает защитника, не получает ответный урон.",
	"strobe": "Строб: может атаковать дважды за ход.",
	"photosynthesis": "Фотосинтез N: в начале вашего хода +N кристалл(ов).",
	"growth": "Рост N: в начале вашего хода +N/+N этому существу.",
	"compost": "Компост N: когда ваше существо умирает, +N/+N этому.",
	"spores": "Споры N: при смерти призывает N ростков 1/1.",
	"undergrowth": "Подлесок N: +N/+N за каждое другое ваше существо.",
	"resonance": "Резонанс N: при выходе получает +N/+N за каждый ваш кристалл.",
	"mulch": "Подкормка: в начале вашего хода одно ваше раненое существо +1 HP.",
	"freeze": "Заморозка N: N ход(ов) не может атаковать, но в защите бьёт в ответ.",
	"chill": "Стужа N: вражеские существа -N к атаке, пока аура в игре.",
	"incandescence": "Накал N: ваши существа +N к атаке, пока аура в игре.",
	"haze": "Дымка N: пока аура в игре, вражеские заклинания стоят на N дороже.",
	"birefringence": "Раздвоение: ваше нацеленное заклинание бьёт ещё и вторую случайную цель.",
	"pinpoint": "Острый фокус: урон этого заклинания нельзя поглотить Щитом или Нимбом.",
	"brittle": "Хрупкость: замороженное вражеское существо, получив любой урон, раскалывается.",
	"lens": "Линза: первое за ход заклинание усилено (+1 к его значениям).",
	"stealth": "Незримость: нельзя выбрать целью, пока это не атакует.",
	"glimmer": "Мерцание: первое существо, которое вы разыгрываете за ход, выходит Незримым.",
	"refract": "Преломление: вражеский эффект или атака по этому уходит на случайную другую цель.",
	"split": "Расщепление N: при выходе создаёт N иллюзий (1 HP).",
	"haunt": "Морок: при смерти оставляет одну иллюзорную копию (1 HP). Иллюзия уже не перерождается.",
	"awaken": "Пробуждение: эту карту-кристалл можно разбудить за её стоимость.",
	"floodlight": "Прожектор: пока в игре, вы можете подсмотреть любой вражеский кристалл в спектре — кликните по нему.",
	"delay": "Отсрочка N: эффект срабатывает в начале вашего хода через N ход(ов).",
	"decoy": "Подготовка N: пролежав N ваших ходов в спектре, разбуживается без доплаты — расходуется только её собственный кристалл.",
	"spectral_shift": "Спектральный сдвиг: раз в ход один цветной кристалл можно потратить как любой другой цвет.",
	"palette": "Смешение красок: первый раз за ход, когда вы разыгрываете карту, чья стоимость требует 2+ разных цвета, — доберите карту.",
	"facet": "Огранка: вы можете будить любую свою карту из спектра, а не только карты с Пробуждением.",
	"lighteater": "Пожиратель света: вражеское существо, нанёсшее боевой урон вашему герою, навсегда теряет 1 атаки.",
}

# Spell/battlecry effects, written as the plain imperative rules sentence the
# card "prints". The rules text is generated from this data (the single source
# of truth -- cards carry no hand-written rules). "N" is the effect's value; a
# few read the selector in effect_text() for natural phrasing.
const EFFECT := {
	"freeze": "Заморозьте существо на N ход(ов).",
	"blind": "Ослепите существо на N ход(ов).",
	"damage": "Нанесите N урона существу.",
	"destroy": "Уничтожьте существо.",
	"draw": "Возьмите N карт(ы).",
	"scry": "Посмотрите N верхних карт колоды; любые уберите вниз.",
	"scatter": "Верните существо в руку.",
	"mirage": "Создайте иллюзорную копию существа (1 HP).",
	"add_crystal": "Добавьте N бесцветных кристалла(ов) в свой пул навсегда.",
	"dispel": "Уничтожьте ауру.",
}


# Russian numeral agreement: pick the form for n (1 / 2-4 / 5+, with the 11-14
# exception). Returns just the noun phrase; the caller prefixes the number.
static func _pl(n: int, one: String, few: String, many: String) -> String:
	var a := n % 10
	var b := n % 100
	if a == 1 and b != 11:
		return one
	if a >= 2 and a <= 4 and not (b >= 12 and b <= 14):
		return few
	return many


# The rules templates leave count-nouns as crude fixed forms ("карт(ы)", "ход(ов)").
# Decline them against the number that was just substituted for N so the printed
# text reads grammatically. Each placeholder occurs at most once per sentence.
static func _fix_plurals(s: String, n: int) -> String:
	s = s.replace("ход(ов)", _pl(n, "ход", "хода", "ходов"))
	s = s.replace("карт(ы)", _pl(n, "карту", "карты", "карт"))
	s = s.replace("бесцветных кристалла(ов)", _pl(n, "бесцветный кристалл", "бесцветных кристалла", "бесцветных кристаллов"))
	s = s.replace("кристалл(ов)", _pl(n, "кристалл", "кристалла", "кристаллов"))
	s = s.replace("случайных врагов", _pl(n, "случайного врага", "случайных врага", "случайных врагов"))
	s = s.replace("иллюзий", _pl(n, "иллюзию", "иллюзии", "иллюзий"))
	s = s.replace("ростков", _pl(n, "росток", "ростка", "ростков"))
	s = s.replace("верхних карт колоды", _pl(n, "верхнюю карту колоды", "верхние карты колоды", "верхних карт колоды"))
	s = s.replace("ваших ходов", _pl(n, "ваш ход", "ваших хода", "ваших ходов"))
	return s


static func keyword(kw: Dictionary) -> String:
	var id := String(kw.get("id", ""))
	if not KW.has(id):
		return ""
	var s: String = KW[id]
	if kw.has("n"):
		var n := int(kw["n"])
		s = _fix_plurals(s.replace("N", str(n)), n)
	return s


# Just the keyword's short name (the part before the colon), with N filled in:
# "Маяк", "Регенерация 1". Used for the bold headline on the card.
static func keyword_name(kw: Dictionary) -> String:
	var id := String(kw.get("id", ""))
	if not KW.has(id):
		return ""
	var nm: String = String(KW[id]).split(":")[0]
	if kw.has("n"):
		nm = nm.replace("N", str(int(kw["n"])))
	return nm


# The generated rules sentence for one effect (imperative). A couple of actions
# read the selector so the target reads naturally (hero vs minion, any vs enemy).
static func effect_text(e: Dictionary) -> String:
	var a := String(e.get("action", ""))
	if not EFFECT.has(a):
		return ""
	var sel := String(e.get("selector", ""))
	var s: String = EFFECT[a]
	if a == "damage":
		if sel == "enemy_hero":
			s = "Нанесите N урона вражескому герою."
		elif sel == "all_creatures":
			s = "Нанесите N урона всем существам."
		elif sel == "all_enemies":
			s = "Нанесите N урона всем врагам."
		elif sel == "chosen_enemy_minion":
			s = "Нанесите N урона вражескому существу."
	elif a == "blind":
		if sel == "all_enemies":
			s = "Ослепите всех врагов на N ход(ов)."
	elif a == "freeze":
		if sel == "all_enemies":
			s = "Заморозьте всех врагов на N ход(ов)."
	elif a == "scatter":
		if sel == "chosen_any_minion":
			s = "Верните любое существо в руку."
		elif sel == "chosen_enemy_minion":
			s = "Верните вражеское существо в руку."
	elif a == "mirage":
		if sel == "chosen_friendly_minion":
			s = "Создайте иллюзорную копию вашего существа (1 HP)."
		elif sel == "chosen_enemy_minion":
			s = "Создайте иллюзорную копию вражеского существа (1 HP)."
		elif sel == "chosen_any_minion":
			s = "Создайте иллюзорную копию любого существа (1 HP)."
	elif a == "dispel":
		# Shown as an action, never as a keyword chip: "destroy an aura / all auras".
		if sel == "chosen_enemy_aura":
			s = "Уничтожьте выбранную ауру соперника."
		else:
			var dv := int(e.get("value", 1))
			if dv <= 0:
				s = "Уничтожьте все ауры."
			elif dv == 1:
				s = "Уничтожьте ауру."
			else:
				s = "Уничтожьте N ауры."
	if e.has("value"):
		var n := int(e["value"])
		s = _fix_plurals(s.replace("N", str(n)), n)
	return s


# Active statuses on a creature in play, with how long they last.
static func status_lines(runtime) -> Array:
	var out := []
	if typeof(runtime) != TYPE_DICTIONARY:
		return out
	var fr := int(runtime.get("frozen", 0))
	if fr > 0:
		out.append("Заморожен: ещё %d %s — не атакует, но даёт сдачу в защите." % [fr, _pl(fr, "ход", "хода", "ходов")])
	var bl := int(runtime.get("blind", 0))
	if bl > 0:
		out.append("Ослеплён: ещё %d %s — не атакует и не наносит урон в бою (даже в ответ)." % [bl, _pl(bl, "ход", "хода", "ходов")])
	if bool(runtime.get("shield", false)):
		out.append("Щит: поглотит следующий источник урона целиком.")
	if bool(runtime.get("ward", false)):
		out.append("Нимб: поглотит следующий вредный эффект на этом существе.")
	if bool(runtime.get("stealth", false)):
		out.append("Незрим: нельзя выбрать целью, пока это не атакует.")
	if bool(runtime.get("sick", false)):
		out.append("Болезнь призыва: не может атаковать в этот ход.")
	return out


# "Существо - красный, синий" style type/color line.
static func type_label(d: Dictionary) -> String:
	var ru_type := {"creature": "Существо", "spell": "Заклинание", "aura": "Аура"}
	var line: String = ru_type.get(String(d.get("type", "")), String(d.get("type", "")))
	var colors: Array = d.get("color", [])
	if colors.is_empty():
		return line + " - нейтральная"
	var names := []
	for c in colors:
		names.append(Palette.ru(String(c)))
	return line + " - " + ", ".join(names)
