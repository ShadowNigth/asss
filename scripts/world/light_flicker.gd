class_name LightFlicker
extends Node
## Emulates GoldSrc light styles.
##
## Lights parsed from the BSP keep their `style` string; style "0"–"9" are the
## classic half-life sequences.  Only the cheap ones are reproduced: 0 steady,
## 10 (fluorescent), 2 (slow pulse), 12 (flicker) and 11 (impulse).  Anything
## else falls back to steady so map lighting stays readable.

const FLUORESCENT := "10"
const PULSE_SLOW := "2"
const FLICKER := "12"
const PULSE_FAST := "11"

var base_energy := 1.0
var style := "0"
var phase := 0.0
var light: Light3D


static func attach(parent: Node3D, target: Light3D, style_name: String) -> LightFlicker:
	var node := LightFlicker.new()
	node.light = target
	node.style = style_name
	node.base_energy = target.light_energy
	node.phase = randf() * TAU
	parent.add_child(node)
	return node


func _process(delta: float) -> void:
	if light == null or not light.is_inside_tree():
		return
	phase += delta
	var factor := 1.0
	match style:
		FLUORESCENT:
			factor = 1.5 if fmod(phase, 2.6) > 2.35 else 0.75
		PULSE_SLOW:
			factor = 0.75 + 0.25 * sin(phase * 1.4)
		PULSE_FAST:
			factor = 0.7 + 0.3 * sin(phase * 6.0)
		FLICKER:
			var noise := sin(phase * 17.0) * sin(phase * 5.3) + sin(phase * 2.1) * 0.5
			factor = clampf(0.55 + noise * 0.45, 0.15, 1.35)
		_:
			factor = 1.0
	light.light_energy = base_energy * factor
