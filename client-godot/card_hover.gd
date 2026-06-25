class_name CardHover
extends Control

# A hover target that shows the same rich card tooltip the board uses (name,
# cost, type, generated rules, flavour) via Godot's custom-tooltip hook. Used for
# the deck-builder pool tiles so a card reads exactly as it does in a match. The
# tile still needs a non-empty tooltip_text for the tooltip to trigger.

var card_id := ""


func _make_custom_tooltip(_for_text: String) -> Object:
	if card_id == "":
		return null
	return CardView.tooltip(card_id, null)
