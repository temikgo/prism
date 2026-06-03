class_name AbilityButton
extends Button

# A round activated-ability button on a creature. Its hover tooltip is a styled
# panel built lazily by tooltip_builder, instead of Godot's plain text tooltip.

var tooltip_builder: Callable = Callable()

func _make_custom_tooltip(_for_text: String) -> Object:
	if tooltip_builder.is_valid():
		return tooltip_builder.call()
	return null
