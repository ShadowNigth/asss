class_name WeaponState
extends RefCounted
## Ammo + timing bookkeeping for one owned weapon.

var id := ""
var clip := 0
var reserve := 0
var last_fire_time := -100.0
var reloading := false
var reload_finish := 0.0
var shots_fired := 0
var burst_index := 0


func _init(weapon_id: String = "", data: Dictionary = {}) -> void:
	id = weapon_id
	clip = int(data.get("clip", 0))
	reserve = int(data.get("reserve", 0))


func data() -> Dictionary:
	return Weapons.get_weapon(id)


func can_fire(now: float) -> bool:
	if reloading:
		return false
	var rate := float(data().get("fire_rate", 0.1))
	return now - last_fire_time >= rate


func consume() -> bool:
	if clip <= 0:
		return false
	clip -= 1
	shots_fired += 1
	burst_index = mini(burst_index + 1, 30)
	return true


func begin_reload(now: float) -> bool:
	if reloading or clip >= int(data().get("clip", 0)) or reserve <= 0:
		return false
	reloading = true
	reload_finish = now + reload_time()
	return true


func reload_time() -> float:
	var clip_size := maxf(1.0, float(data().get("clip", 30)))
	var kind := str(data().get("slot", "primary"))
	var per_round := 0.075 if kind == "primary" else 0.09
	return clampf(clip_size * per_round, 1.2, 4.2)


func finish_reload() -> void:
	if not reloading:
		return
	reloading = false
	var clip_size := int(data().get("clip", 0))
	var missing := clip_size - clip
	var moved := mini(missing, reserve)
	clip += moved
	reserve -= moved


func tick(now: float) -> void:
	if reloading and now >= reload_finish:
		finish_reload()


func add_ammo(clip_amount: int, reserve_amount: int) -> void:
	clip = mini(clip + clip_amount, int(data().get("clip", clip)))
	reserve += reserve_amount
