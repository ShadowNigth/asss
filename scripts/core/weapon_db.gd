extends Node
## Weapon table + recoil/accuracy data (autoload singleton `Weapons`).
##
## Static balance numbers live in `data/weapons.json`, `data/recoil.json` and
## `data/accuracy.json`; models are optional GLB viewmodels from the CS2 kit, so
## a missing file degrades to a placeholder rather than an error.

const DATA_DIR := "res://data"
const MODEL_DIR := "res://assets/cs2go/models/viewmodels"
const KNIFE_MODEL := "res://assets/cs2go/models/animations/knives/knife-ct.glb"

# CS2 viewmodel files are named after their CS2 weapon; the CS 1.5 arsenal maps
# onto them by family (a TMP shows the MP5 model, etc.).
const MODEL_ALIASES := {
	"tmphk": "mp5sd",
	"mp5": "mp5sd",
	"m4a1": "m4a4",
	"usp": "usp-s",
	"scout": "ssg08",
	"sg552": "sg556",
	"sg550": "scar20",
	"fiveseven": "fiveseven",
	"elite": "elite",
	"awp": "awp",
	"ak47": "ak-47",
	"deagle": "deagle",
	"glock": "glock",
	"p90": "p90",
	"ump45": "ump45",
	"mac10": "mac10",
	"galil": "galilar",
	"famas": "famas",
	"g3sg1": "g3sg1",
	"m3": "nova",
	"xm1014": "xm1014",
	"m249": "m249",
	"aug": "aug",
}

var weapons: Dictionary = {}
var recoil: Dictionary = {}
var accuracy: Dictionary = {}


func _ready() -> void:
	weapons = _load_json("weapons.json")
	recoil = _load_json("recoil.json")
	accuracy = _load_json("accuracy.json")
	if weapons.is_empty():
		push_error("weapon database is empty: %s/weapons.json is missing" % DATA_DIR)


func _load_json(file_name: String) -> Dictionary:
	var path := "%s/%s" % [DATA_DIR, file_name]
	if not FileAccess.file_exists(path):
		push_warning("missing data file: %s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("could not parse %s" % path)
		return {}
	return parsed


func has_weapon(id: String) -> bool:
	return weapons.has(id)


func get_weapon(id: String) -> Dictionary:
	var entry: Dictionary = weapons.get(id, {})
	if entry.is_empty():
		push_warning("unknown weapon id: %s" % id)
	return entry


func display_name(id: String) -> String:
	return str(get_weapon(id).get("name", id))


func slot_of(id: String) -> String:
	return str(get_weapon(id).get("slot", "primary"))


func price_of(id: String) -> int:
	return int(get_weapon(id).get("price", 0))


func recoil_pattern(id: String) -> Array:
	var entry: Dictionary = recoil.get(id, {})
	return entry.get("pattern", []) as Array


func recoil_recovery(id: String) -> float:
	var entry: Dictionary = recoil.get(id, {})
	return float(entry.get("recovery", 0.2))


func view_punch(id: String) -> float:
	var entry: Dictionary = recoil.get(id, {})
	return float(entry.get("view_punch", 1.0))


func model_id(id: String) -> String:
	return str(MODEL_ALIASES.get(id, id))


func viewmodel_path(id: String) -> String:
	if id == "knife":
		return KNIFE_MODEL
	var model := model_id(id)
	var path := "%s/%s.glb" % [MODEL_DIR, model]
	if not ResourceLoader.exists(path):
		# exported builds use the imported .scn; keep the same fallback chain
		path = "%s/%s.glb" % [MODEL_DIR, model.replace("-", "_")]
	if not ResourceLoader.exists(path):
		return ""
	return path


func buy_list(team: String) -> Array:
	var out: Array = []
	for id in weapons.keys():
		var entry: Dictionary = weapons[id]
		var slot := str(entry.get("slot", ""))
		if slot == "c4":
			continue
		var name := str(entry.get("name", ""))
		if team == "ct" and name in ["Glock-18", "TMP", "MAC-10", "AK-47", "Galil", "SG-552 Commando", "SG-550", "G3SG1"]:
			continue
		if team == "t" and name in ["USP45", "Five-SeveN", "MP5 Navy", "M4A1", "FAMAS", "AUG", "Steyr Scout", "XM1014"]:
			continue
		out.append(id)
	out.sort()
	return out


func accuracy_profile() -> Dictionary:
	if accuracy.is_empty():
		return {"recovery_rate": 7.0, "max_inaccuracy": 14.0}
	return accuracy
