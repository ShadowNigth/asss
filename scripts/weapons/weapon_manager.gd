class_name WeaponManager
extends Node
## Inventory, switching, spread/recoil accumulation and the actual shots.
##
## Spread uses the CS model: a base cone plus a per-shot kick that decays at
## `recovery_rate`, multiplied by the movement state (standing < walking <
## jumping).  Recoil follows the per-weapon pattern from `data/recoil.json`
## applied to the camera as view punch.

signal weapon_switched(id: String)
signal ammo_changed(clip: int, reserve: int)
signal fired(id: String)

const SLOT_ORDER := ["primary", "secondary", "knife", "grenade", "c4"]

var controller: PlayerController
var inventory: Dictionary = {}
var current_id := "knife"
var inaccuracy := 0.0
var recoil_accum := Vector2.ZERO
var now := 0.0
var shots_in_burst := 0
var last_shot_time := -10.0
var primary_id := ""
var secondary_id := ""

var _switch_until := 0.0
var _zoom := 0


func setup(controller_ref: PlayerController) -> void:
	controller = controller_ref
	add_weapon("knife")
	add_weapon("glock" if controller.team in ["t", "any"] else "usp")
	equip(secondary_id if not secondary_id.is_empty() else "knife")


func add_weapon(id: String, give_ammo: bool = true) -> bool:
	if not Weapons.has_weapon(id) or inventory.has(id):
		return false
	var data := Weapons.get_weapon(id)
	var state := WeaponState.new(id, data)
	if not give_ammo:
		state.clip = 0
		state.reserve = 0
	inventory[id] = state
	match str(data.get("slot", "")):
		"primary":
			primary_id = id
		"secondary":
			secondary_id = id
	return true


func has_weapon(id: String) -> bool:
	return inventory.has(id)


func current() -> WeaponState:
	return inventory.get(current_id, null) as WeaponState


func current_data() -> Dictionary:
	return Weapons.get_weapon(current_id)


func equip(id: String, switch_time: float = 0.45) -> void:
	if not inventory.has(id) or id == current_id:
		return
	current_id = id
	_switch_until = now + switch_time
	shots_in_burst = 0
	inaccuracy = 0.0
	recoil_accum = Vector2.ZERO
	_zoom = 0
	if controller != null and controller.viewmodel != null:
		controller.viewmodel.equip(id)
	ammo_changed.emit(_clip(), _reserve())
	weapon_switched.emit(id)


func _clip() -> int:
	var state := current()
	return state.clip if state != null else 0


func _reserve() -> int:
	var state := current()
	return state.reserve if state != null else 0


func tick(delta: float, fire_held: bool, fire_pressed: bool, alt_pressed: bool, reload_pressed: bool) -> void:
	now += delta
	var state := current()
	if state == null:
		return
	state.tick(now)
	if reload_pressed:
		start_reload()
	if now < _switch_until:
		return
	if alt_pressed:
		_toggle_zoom()
	if fire_held or fire_pressed:
		_try_fire()
	_decay(delta)
	_update_recoil(delta)


func _try_fire() -> void:
	var state := current()
	if state == null:
		return
	if current_id == "knife":
		_melee()
		return
	if current_id == "c4":
		return
	if str(state.data().get("slot", "")) == "grenade":
		_throw_grenade(current_id)
		return
	if not state.can_fire(now):
		return
	if state.clip <= 0:
		if state.reserve > 0:
			start_reload()
		return
	if _zoom > 0 and current_id in ["awp", "scout", "g3sg1", "sg550"]:
		_zoom = 0
		controller.fov_target = Cfg.FOV
	if not state.consume():
		return
	state.last_fire_time = now
	last_shot_time = now
	shots_in_burst += 1
	ammo_changed.emit(state.clip, state.reserve)
	var spread := _current_inaccuracy()
	var origin := controller.eye_position()
	var direction := controller.aim_direction()
	controller.combat.fire(current_id, origin, direction, spread)
	Sound.play_shot(current_id, origin, false, -3.0)
	_apply_kick()
	fired.emit(current_id)
	if controller.viewmodel != null:
		controller.viewmodel.kick(current_id)
		controller.viewmodel.muzzle_flash()


func _throw_grenade(id: String) -> void:
	## Grenades are consumed on throw and become a projectile with a fuse; the
	## HE does area damage, the flash blinds, the smoke pops a cloud.
	var state := current()
	if state == null or state.clip <= 0:
		return
	state.clip -= 1
	ammo_changed.emit(state.clip, state.reserve)
	var origin := controller.eye_position()
	var direction := controller.aim_direction()
	var grenade := Grenade.new()
	grenade.kind = id
	get_tree().current_scene.add_child(grenade)
	grenade.launch(origin, direction, 18.0, controller.player_name, controller.team)
	Sound.play_foley("grenade_throw", origin, false, -3.0)
	if state.clip <= 0:
		inventory.erase(id)
		var remaining := _owned_slots()
		if not remaining.is_empty():
			equip(str(remaining[0]))


func _melee() -> void:
	if now - _switch_until < 0.35:
		return
	var origin := controller.eye_position()
	var direction := controller.aim_direction()
	controller.combat.fire("knife", origin, direction, 0.0)
	Sound.play("knife", -4.0, randf_range(0.95, 1.05))
	_switch_until = now + 0.35
	fired.emit("knife")
	if controller.viewmodel != null:
		controller.viewmodel.kick("knife")


func start_reload() -> void:
	Sound.play_reload(current_id)
	var state := current()
	if state == null:
		return
	if state.begin_reload(now):
		ammo_changed.emit(state.clip, state.reserve)
		if controller.viewmodel != null:
			controller.viewmodel.reload()


func _current_inaccuracy() -> float:
	var state := current()
	var data := Weapons.get_weapon(current_id)
	var base := float(data.get("spread", 1.0))
	var profile := Weapons.accuracy_profile()
	var movement := 0.0
	if controller.body != null:
		var speed := controller.body.velocity.length()
		if not controller.body.on_ground:
			movement = float(profile.get("jumping", {}).get("base", 6.0))
		elif speed > 0.4:
			movement = float(profile.get("moving", {}).get("base", 2.2)) * clampf(speed / (Cfg.MAXSPEED * Cfg.U2M), 0.0, 1.5)
		if controller.body.ducking:
			movement += float(profile.get("crouching", {}).get("base", -0.15))
	var crouch := 1.0
	if controller.body != null and controller.body.ducking:
		crouch = float(profile.get("crouching", {}).get("scale", 0.7))
	var max_inacc := float(profile.get("max_inaccuracy", 14.0))
	return clampf((base + inaccuracy) * crouch + movement, 0.0, max_inacc)


func _apply_kick() -> void:
	var pattern := Weapons.recoil_pattern(current_id)
	if pattern.is_empty():
		return
	var index := mini(shots_in_burst - 1, pattern.size() - 1)
	var entry: Dictionary = pattern[index]
	var recovery := Weapons.recoil_recovery(current_id)
	inaccuracy = minf(inaccuracy + float(entry.get("up", 1.0)) * 0.35, 8.0)
	recoil_accum.y += deg_to_rad(float(entry.get("up", 1.0)) * 0.22)
	recoil_accum.x += deg_to_rad(float(entry.get("side", 0.0)) * 0.16)
	if controller != null:
		controller.recoil_offset = recoil_accum
		controller.pitch = clampf(controller.pitch + recoil_accum.y * 0.35, deg_to_rad(-89), deg_to_rad(89))


func _decay(delta: float) -> void:
	var profile := Weapons.accuracy_profile()
	var recovery := float(profile.get("recovery_rate", 7.0))
	inaccuracy = maxf(0.0, inaccuracy - recovery * delta)
	var reset := Weapons.recoil_recovery(current_id)
	if now - last_shot_time > maxf(0.12, reset):
		shots_in_burst = 0


func _update_recoil(delta: float) -> void:
	recoil_accum = recoil_accum.lerp(Vector2.ZERO, clampf(delta * 6.0, 0.0, 1.0))
	if controller != null:
		controller.recoil_offset = recoil_accum


func _toggle_zoom() -> void:
	Sound.play_foley("zoom_in" if _zoom == 0 else "zoom_out", controller.eye_position(), false, -8.0)
	var data := current_data()
	var zooms: Array = data.get("zoom_fovs", []) as Array
	if zooms.is_empty():
		return
	_zoom = (_zoom + 1) % (zooms.size() + 1)
	if _zoom == 0:
		controller.fov_target = Cfg.FOV
	else:
		controller.fov_target = float(zooms[_zoom - 1])


func next_weapon(backwards: bool = false) -> void:
	var owned := _owned_slots()
	if owned.is_empty():
		return
	var index := owned.find(current_id)
	if index < 0:
		index = 0
	else:
		index = (index + (-1 if backwards else 1) + owned.size()) % owned.size()
	equip(owned[index])


func select_slot(slot_name: String) -> void:
	match slot_name:
		"primary":
			if not primary_id.is_empty():
				equip(primary_id)
		"secondary":
			if not secondary_id.is_empty():
				equip(secondary_id)
		"knife":
			equip("knife")
		"grenade":
			for id in inventory.keys():
				if str((inventory[id] as WeaponState).data().get("slot", "")) == "grenade":
					equip(id)
					return
		"c4":
			if inventory.has("c4"):
				equip("c4")


func _owned_slots() -> Array:
	var flat: Array = []
	for slot_name in SLOT_ORDER:
		for id in inventory.keys():
			var state: WeaponState = inventory[id]
			if str(state.data().get("slot", "")) == slot_name and flat.find(id) == -1:
				flat.append(id)
	return flat


func total_money_value() -> int:
	var total := 0
	for id in inventory.keys():
		total += Weapons.price_of(id)
	return total
