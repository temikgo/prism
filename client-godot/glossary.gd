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
	"provoke": "Маяк: вражеские существа обязаны атаковать это.",
	"shield": "Щит: игнорирует следующий источник урона целиком.",
	"blind": "Ослепление N: N ход(ов) не атакует и не наносит боевой урон — даже в ответ при защите.",
	"flash": "Вспышка N: ослепляет всех врагов на N ход(ов).",
	"photosynthesis": "Фотосинтез N: в начале вашего хода +N кристалл(ов).",
	"growth": "Рост N: в начале вашего хода +N/+N этому существу.",
	"compost": "Компост N: когда ваше существо умирает, +N/+N этому.",
	"spores": "Споры N: при смерти призывает N ростков 1/1.",
	"undergrowth": "Подлесок N: +N/+N за каждое другое ваше существо.",
	"resonance": "Резонанс N: +N/+N за каждый ваш кристалл.",
	"freeze": "Заморозка N: N ход(ов) не может атаковать, но в защите бьёт в ответ.",
	"chill": "Стужа N: вражеские существа -N к атаке, пока аура в игре.",
	"stealth": "Незримость: нельзя выбрать целью, пока это не атакует.",
	"split": "Расщепление N: при выходе создаёт N иллюзий (1 HP).",
	"haunt": "Морок: при смерти оставляет иллюзорную копию (1 HP).",
	"awaken": "Awaken: эту карту-кристалл можно разбудить за её стоимость.",
}

# Spell-effect meaning (the inline grammar used by spells/battlecries). "N" is
# replaced by the effect's value.
const EFFECT := {
	"freeze": "Заморозка N: цель N ход(ов) не атакует, но в защите бьёт в ответ.",
	"blind": "Ослепление N: цель N ход(ов) не атакует и не наносит боевой урон (даже в ответ).",
	"flash": "Вспышка N: ослепляет всех врагов на N ход(ов).",
	"damage": "Урон N: наносит N урона цели.",
	"damage_all": "Выметание N: наносит N урона всем существам.",
	"destroy": "Устранение: уничтожает выбранное существо.",
	"draw": "Добор N: возьмите N карт(ы).",
	"scatter": "Рассеяние: возвращает вражеское существо в руку.",
	"mirage": "Мираж: создаёт иллюзорную копию существа (1 HP).",
}


static func keyword(kw: Dictionary) -> String:
	var id := String(kw.get("id", ""))
	if not KW.has(id):
		return ""
	var s: String = KW[id]
	if kw.has("n"):
		s = s.replace("N", str(int(kw["n"])))
	return s


static func effect(e: Dictionary) -> String:
	var a := String(e.get("action", ""))
	if not EFFECT.has(a):
		return ""
	var s: String = EFFECT[a]
	if e.has("value"):
		s = s.replace("N", str(int(e["value"])))
	return s


# Active statuses on a creature in play, with how long they last.
static func status_lines(runtime) -> Array:
	var out := []
	if typeof(runtime) != TYPE_DICTIONARY:
		return out
	var fr := int(runtime.get("frozen", 0))
	if fr > 0:
		out.append("Заморожен: ещё %d ход(ов) — не атакует, но даёт сдачу в защите." % fr)
	var bl := int(runtime.get("blind", 0))
	if bl > 0:
		out.append("Ослеплён: ещё %d ход(ов) — не атакует и не наносит урон в бою (даже в ответ)." % bl)
	if bool(runtime.get("shield", false)):
		out.append("Щит: поглотит следующий источник урона целиком.")
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
