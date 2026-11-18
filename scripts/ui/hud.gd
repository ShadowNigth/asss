class_name Hud
extends CanvasLayer
## In-game HUD: health/armour, ammo, radar, round timer and the crosshair.
##
## Everything is drawn with `Control` nodes and `draw_*` calls so it works
## without any imported font assets (the headless build has no fontconfig).

const RADAR_SIZE := 168.0
const RADAR_RANGE := 90.0

var game: Node3D
var player: PlayerController
var match_state: MatchState

var root: Control
var crosshair: Crosshair
var radar: Radar
var health_label: Label
var ammo_label: Label
var timer_label: Label
var money_label: Label
var weapon_label: Label
var hint_label: Label
var death_label: Label
var fps_label: Label
var objective_label: Label
var _objective_bar: ProgressBar
var kill_feed: VBoxContainer
var banner_label: Label
var _banner_time := 0.0
var match_over_label: Label
var flash_overlay: ColorRect
var hit_marker_time := 0.0
var show_fps := false


func setup(game_ref: Node3D, player_ref: PlayerController, state: MatchState) -> void:
	game = game_ref
	player = player_ref
	match_state = state
	layer = 10
	_build()
	if player_ref != null:
		player_ref.objective_progress.connect(show_objective)
		player_ref.objective_cancelled.connect(hide_objective)


func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	crosshair = Crosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(crosshair)

	radar = Radar.new()
	radar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	radar.position = Vector2(18, 18)
	radar.size = Vector2(RADAR_SIZE, RADAR_SIZE)
	root.add_child(radar)

	health_label = _label(Vector2(18, -74), 26, HORIZONTAL_ALIGNMENT_LEFT)
	health_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ammo_label = _label(Vector2(-220, -74), 26, HORIZONTAL_ALIGNMENT_RIGHT)
	ammo_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	weapon_label = _label(Vector2(-220, -104), 15, HORIZONTAL_ALIGNMENT_RIGHT)
	weapon_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	timer_label = _label(Vector2(-70, 14), 22, HORIZONTAL_ALIGNMENT_CENTER)
	timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	money_label = _label(Vector2(18, 200), 18, HORIZONTAL_ALIGNMENT_LEFT)
	hint_label = _label(Vector2(-300, -160), 16, HORIZONTAL_ALIGNMENT_CENTER)
	hint_label.set_anchors_preset(Control.PRESET_CENTER)
	death_label = _label(Vector2(-400, -40), 30, HORIZONTAL_ALIGNMENT_CENTER)
	death_label.set_anchors_preset(Control.PRESET_CENTER)
	death_label.visible = false
	fps_label = _label(Vector2(-120, 12), 14, HORIZONTAL_ALIGNMENT_RIGHT)
	fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	fps_label.visible = false
	objective_label = _label(Vector2(-300, 70), 18, HORIZONTAL_ALIGNMENT_CENTER)
	objective_label.set_anchors_preset(Control.PRESET_CENTER)
	objective_label.visible = false
	_objective_bar = ProgressBar.new()
	_objective_bar.set_anchors_preset(Control.PRESET_CENTER)
	_objective_bar.position = Vector2(-110, 100)
	_objective_bar.custom_minimum_size = Vector2(220, 14)
	_objective_bar.show_percentage = false
	_objective_bar.max_value = 1.0
	_objective_bar.visible = false
	root.add_child(_objective_bar)
	kill_feed = VBoxContainer.new()
	kill_feed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	kill_feed.position = Vector2(-320, 20)
	kill_feed.custom_minimum_size = Vector2(300, 0)
	kill_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	kill_feed.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(kill_feed)
	banner_label = _label(Vector2(-400, -120), 30, HORIZONTAL_ALIGNMENT_CENTER)
	banner_label.set_anchors_preset(Control.PRESET_CENTER)
	banner_label.visible = false
	match_over_label = _label(Vector2(-420, -30), 34, HORIZONTAL_ALIGNMENT_CENTER)
	match_over_label.set_anchors_preset(Control.PRESET_CENTER)
	match_over_label.custom_minimum_size = Vector2(840, 0)
	match_over_label.visible = false
	flash_overlay = ColorRect.new()
	flash_overlay.color = Color(1.0, 1.0, 1.0, 0.0)
	flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(flash_overlay)


func _label(offset: Vector2, size: int, alignment: int) -> Label:
	var label := Label.new()
	label.position = offset
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(0.94, 0.94, 0.9))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.horizontal_alignment = alignment
	label.custom_minimum_size = Vector2(220, 0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label)
	return label


func _process(delta: float) -> void:
	if _banner_time > 0.0:
		_banner_time -= delta
		if _banner_time <= 0.0 and banner_label != null:
			banner_label.visible = false
	if player == null or not is_instance_valid(player):
		return
	if flash_overlay != null:
		var alpha := clampf(player.blind_time / 1.6, 0.0, 1.0) * 0.95
		flash_overlay.color = Color(1.0, 1.0, 1.0, alpha)
	health_label.text = "%d HP" % player.health if player.armor <= 0 else "%d HP  %d AP" % [player.health, player.armor]
	var state := player.weapon_manager.current() if player.weapon_manager != null else null
	if state != null:
		ammo_label.text = "%d / %d" % [state.clip, state.reserve]
		weapon_label.text = Weapons.display_name(state.id).to_upper()
		crosshair.spread = player.weapon_manager.inaccuracy
	if match_state != null:
		timer_label.text = match_state.status_line()
		money_label.text = "$%d" % int(match_state.money.get(player.team, 0))
		# The bomb is the round's clock: show the planted site and start the
		# timer flashing red as the fuse runs down.
		if match_state.bomb_state == "planted":
			timer_label.text = "C4 %s  %.1fs" % [match_state.bomb_site, match_state.bomb_timer]
			var urgency := clampf(1.0 - match_state.bomb_timer / 10.0, 0.0, 1.0)
			timer_label.modulate = Color(1.0, 1.0 - urgency * 0.75, 1.0 - urgency * 0.75)
			var blink := fmod(Time.get_ticks_msec() / 1000.0, 0.5) < 0.25
			timer_label.visible = match_state.bomb_timer > 10.0 or blink
		else:
			timer_label.modulate = Color.WHITE
			timer_label.visible = true
	if Input.is_action_just_pressed("toggle_fps"):
		show_fps = not show_fps
		fps_label.visible = show_fps
	if show_fps:
		fps_label.text = "%d fps  %d draws" % [Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)]
	hint_label.text = "B — buy" if match_state != null and match_state.can_buy() else ""
	hit_marker_time = maxf(0.0, hit_marker_time - delta)
	if player.weapon_manager != null and player.weapon_manager.controller != null:
		crosshair.visible = player.weapon_manager.current_id != "knife"
	crosshair.hit_flash = hit_marker_time > 0.0
	crosshair.queue_redraw()
	radar.player = player
	radar.bots = game.bots if game != null else []
	radar.queue_redraw()


func add_kill(victim: String, killer: String, weapon: String, headshot: bool) -> void:
	## One line in the top-right kill feed, retired after a few seconds.
	if kill_feed == null:
		return
	var line := Label.new()
	line.add_theme_font_size_override("font_size", 15)
	var colour := Color(0.85, 0.88, 0.92)
	if killer != "" and player != null and killer == player.player_name:
		colour = Color(0.55, 1.0, 0.6)
	elif victim == (player.player_name if player != null else ""):
		colour = Color(1.0, 0.45, 0.4)
	line.add_theme_color_override("font_color", colour)
	line.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	line.add_theme_constant_override("shadow_offset_x", 2)
	line.add_theme_constant_override("shadow_offset_y", 2)
	var marker := " [HS]" if headshot else ""
	line.text = "%s  ▸  %s%s" % [killer if killer != "" else "world", victim, marker]
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	kill_feed.add_child(line)
	while kill_feed.get_child_count() > 5:
		kill_feed.get_child(0).queue_free()
	var timer := get_tree().create_timer(6.0)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(line):
			line.queue_free())


func show_match_over(winner: String, score_t: int, score_ct: int) -> void:
	## Final screen: the result and the fact you can start again with R.
	if match_over_label == null:
		return
	var line := "TERRORISTS WIN" if winner == "t" else "COUNTER-TERRORISTS WIN"
	match_over_label.text = "%s\n%d : %d\n\npress R to play again" % [line, score_t, score_ct]
	match_over_label.visible = true


func hide_match_over() -> void:
	if match_over_label != null:
		match_over_label.visible = false
	flash_overlay = ColorRect.new()
	flash_overlay.color = Color(1.0, 1.0, 1.0, 0.0)
	flash_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(flash_overlay)


func show_banner(text: String) -> void:
	if banner_label == null:
		return
	banner_label.text = text
	banner_label.visible = true
	_banner_time = 5.0


func show_objective(progress: float, label: String) -> void:
	## Plant / defuse progress while the use key is held.
	if objective_label == null:
		return
	objective_label.visible = true
	objective_label.text = label.capitalize()
	_objective_bar.visible = progress > 0.0
	_objective_bar.value = progress


func hide_objective() -> void:
	if objective_label == null:
		return
	objective_label.visible = false
	_objective_bar.visible = false


func show_death(killer: String) -> void:
	if death_label == null:
		return
	death_label.text = "YOU DIED\nkilled by %s" % (killer if not killer.is_empty() else "the world")
	death_label.visible = true


func flash_hit() -> void:
	hit_marker_time = 0.25


## Crosshair: four ticks whose gap follows the weapon's current inaccuracy.
class Crosshair:
	extends Control
	var spread := 0.0
	var hit_flash := false

	func _draw() -> void:
		var centre := size * 0.5
		var gap := 4.0 + spread * 2.2
		var length := 7.0
		var color := Color(0.15, 1.0, 0.25, 0.9)
		if hit_flash:
			color = Color(1.0, 0.3, 0.25, 0.95)
		for dir in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
			draw_line(centre + dir * gap, centre + dir * (gap + length), color, 2.0)
		draw_circle(centre, 1.4, color)


## Radar: top-down blips scaled into the map bounds around the player.
class Radar:
	extends Control
	var player: PlayerController
	var bots: Array = []

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color(0.03, 0.05, 0.07, 0.55))
		draw_rect(rect, Color(0.35, 0.4, 0.45, 0.7), false, 1.5)
		if player == null or not is_instance_valid(player):
			return
		var centre := size * 0.5
		var half := Hud.RADAR_RANGE
		var origin := player.global_position
		var forward := -player.global_transform.basis.z
		var yaw := atan2(forward.x, forward.z)
		for entry in bots:
			if entry == null or not is_instance_valid(entry) or not entry.alive:
				continue
			var bot: BotAgent = entry
			var offset: Vector3 = bot.global_position - origin
			var local: Vector3 = offset.rotated(Vector3.UP, -yaw)
			if absf(local.x) > half or absf(local.z) > half:
				continue
			var point := centre + Vector2(local.x, local.z) / half * (size * 0.5)
			var color := Color(0.95, 0.35, 0.3) if bot.team == "t" else Color(0.35, 0.7, 1.0)
			if player.team == bot.team:
				color = Color(0.4, 1.0, 0.45)
			draw_circle(point, 3.0, color)
		var triangle := PackedVector2Array([centre + Vector2(0, -6), centre + Vector2(4, 5), centre + Vector2(-4, 5)])
		draw_colored_polygon(triangle, Color(1, 1, 1, 0.95))
