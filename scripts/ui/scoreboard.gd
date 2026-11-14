class_name Scoreboard
extends CanvasLayer
## Tab-held scoreboard: per-team roster, K/D, alive state, score and money.

var game: Node3D
var match_state: MatchState
var panel: PanelContainer
var grid: GridContainer
var holds := false


func setup(game_ref: Node3D, state: MatchState) -> void:
	game = game_ref
	match_state = state
	layer = 25
	_build()
	visible = false


func _build() -> void:
	panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-260, -190)
	panel.custom_minimum_size = Vector2(520, 380)
	add_child(panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.92)
	style.border_color = Color(0.4, 0.45, 0.5)
	style.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", style)
	grid = GridContainer.new()
	grid.columns = 4
	panel.add_child(grid)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("scoreboard"):
		holds = true
		visible = true
		_refresh()
	elif event.is_action_released("scoreboard"):
		holds = false
		visible = false


func _refresh() -> void:
	for child in grid.get_children():
		child.queue_free()
	_header("TEAM", "NAME", "K/D", "STATE")
	if match_state != null:
		_header_row("SCORE  T %d — CT %d" % [match_state.score_t, match_state.score_ct])
	for team in ["ct", "t"]:
		var label := Label.new()
		label.text = "— %s —" % ("COUNTER-TERRORISTS" if team == "ct" else "TERRORISTS")
		label.add_theme_font_size_override("font_size", 16)
		grid.add_child(label)
		for i in 3:
			grid.add_child(Control.new())
		if game != null and game.player != null and game.player.team == team:
			_row(team, game.player.player_name + " (you)", "%d/%d" % [0, 0], "alive" if game.player.alive else "dead")
		if game != null:
			for bot in game.bots:
				if bot.team != team:
					continue
				_row(team, bot.display_name, "%d/%d" % [int(bot.get("kills") if bot.has_meta("kills") else 0), 0],
					"alive" if bot.alive else "dead")


func _header(a: String, b: String, c: String, d: String) -> void:
	for text in [a, b, c, d]:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
		grid.add_child(label)


func _header_row(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	grid.add_child(label)
	for i in 3:
		grid.add_child(Control.new())


func _row(team: String, name: String, kd: String, state: String) -> void:
	var color := Color(0.45, 0.72, 1.0) if team == "ct" else Color(1.0, 0.78, 0.42)
	for text in ["", name, kd, state]:
		var label := Label.new()
		label.text = text
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", color)
		grid.add_child(label)
