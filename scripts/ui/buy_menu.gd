class_name BuyMenu
extends CanvasLayer
## CS 1.5 buy menu: category tabs, prices, live affordability.
##
## Bound to `B`; only usable during freeze time or the first 20 seconds, same
## rules as retail.  Items are filtered by team via `Weapons.buy_list`.

const CATEGORIES := [
	{"label": "1  Pistols", "slot": "secondary"},
	{"label": "2  Shotguns/SMGs", "slot": "smg"},
	{"label": "3  Rifles", "slot": "rifle"},
	{"label": "4  Machine gun", "slot": "heavy"},
	{"label": "5  Equipment", "slot": "gear"},
]

const SMGS := ["mp5", "tmphk", "p90", "ump45", "mac10"]
const RIFLES := ["ak47", "m4a1", "sg552", "aug", "galil", "famas", "awp", "scout", "g3sg1", "sg550"]
const SHOTGUNS := ["m3", "xm1014"]
const HEAVY := ["m249"]
const GEAR := ["kevlar", "kevlar_helmet", "hegrenade", "flashbang", "smokegrenade", "defuser"]

const GEAR_PRICES := {
	"kevlar": 650,
	"kevlar_helmet": 1000,
	"hegrenade": 300,
	"flashbang": 200,
	"smokegrenade": 300,
	"defuser": 200,
}

var game: Node3D
var player: PlayerController
var match_state: MatchState
var panel: PanelContainer
var item_box: VBoxContainer
var category := 0
var open := false


func setup(game_ref: Node3D, player_ref: PlayerController, state: MatchState) -> void:
	game = game_ref
	player = player_ref
	match_state = state
	layer = 20
	_build()
	visible = false


func _build() -> void:
	panel = PanelContainer.new()
	panel.position = Vector2(60, 120)
	panel.custom_minimum_size = Vector2(430, 420)
	add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.10, 0.94)
	style.border_color = Color(0.42, 0.48, 0.52)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text = "BUY MENU"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	for index in CATEGORIES.size():
		var button := Button.new()
		button.text = str(CATEGORIES[index]["label"])
		button.add_theme_font_size_override("font_size", 13)
		button.pressed.connect(_select_category.bind(index))
		tabs.add_child(button)
	item_box = VBoxContainer.new()
	item_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(item_box)
	var footer := Label.new()
	footer.text = "B / Esc closes      money is deducted on buy"
	footer.add_theme_font_size_override("font_size", 12)
	column.add_child(footer)
	_refresh()


func _select_category(index: int) -> void:
	category = index
	_refresh()


func _refresh() -> void:
	for child in item_box.get_children():
		child.queue_free()
	for entry in _entries():
		var row := Button.new()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_font_size_override("font_size", 15)
		var name := str(entry["name"])
		var price := int(entry["price"])
		row.text = "%-22s $%d" % [name, price]
		row.disabled = not _can_afford(price) or _already_owned(str(entry["id"]))
		row.pressed.connect(_buy.bind(entry))
		item_box.add_child(row)


func _entries() -> Array:
	var out: Array = []
	match CATEGORIES[category]["slot"]:
		"secondary":
			for id in Weapons.buy_list(player.team):
				if str(Weapons.slot_of(id)) == "secondary":
					out.append({"id": id, "name": Weapons.display_name(id), "price": Weapons.price_of(id)})
		"smg":
			for id in SMGS:
				out.append({"id": id, "name": Weapons.display_name(id), "price": Weapons.price_of(id)})
		"rifle":
			for id in RIFLES:
				out.append({"id": id, "name": Weapons.display_name(id), "price": Weapons.price_of(id)})
		"heavy":
			for id in SHOTGUNS + HEAVY:
				out.append({"id": id, "name": Weapons.display_name(id), "price": Weapons.price_of(id)})
		"gear":
			for id in GEAR:
				out.append({"id": id, "name": id.capitalize(), "price": int(GEAR_PRICES[id])})
	return out


func _can_afford(price: int) -> bool:
	return int(match_state.money.get(player.team, 0)) >= price


func _already_owned(id: String) -> bool:
	if player.weapon_manager == null:
		return false
	if GEAR_PRICES.has(id):
		return false
	return player.weapon_manager.has_weapon(id)


func _buy(entry: Dictionary) -> void:
	var id := str(entry["id"])
	var price := int(entry["price"])
	if not _can_afford(price):
		return
	if GEAR_PRICES.has(id):
		if not match_state.spend(player.team, price):
			return
		match id:
			"kevlar":
				player.add_armor(100, false)
			"kevlar_helmet":
				player.add_armor(100, true)
			"defuser":
				player.has_defuse_kit = true
			_:
				# Grenades are not implemented yet, so do not take the money.
				match_state.money[player.team] = int(match_state.money[player.team]) + price
		_refresh()
		return
	if not match_state.spend(player.team, price):
		return
	player.weapon_manager.add_weapon(id)
	if str(Weapons.slot_of(id)) in ["primary", "secondary"]:
		player.weapon_manager.equip(id)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("buy_menu"):
		_toggle()
	elif open and event is InputEventKey and event.pressed:
		var key := (event as InputEventKey)
		if key.keycode >= KEY_1 and key.keycode <= KEY_5:
			_select_category(key.keycode - KEY_1)
		elif key.keycode == KEY_ESCAPE:
			_toggle()


func _toggle() -> void:
	if match_state == null or not match_state.can_buy():
		return
	open = not open
	visible = open
	if open:
		_refresh()
		if player != null:
			player.release_mouse()
	elif player != null:
		player.capture_mouse()
