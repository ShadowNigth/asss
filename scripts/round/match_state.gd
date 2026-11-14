class_name MatchState
extends Node
## Round / match flow: freeze time, buy time, bomb timers, economy, score.
##
## Mirrors CS 1.5: 115 s rounds, 5 s freeze, 20 s buy window, 35 s C4 fuse,
## $3250 win / $1400 loss / $800 start, first to 16 rounds.

signal phase_changed(phase: String)
signal round_started(round_number: int, freeze: float)
signal round_ended(winner: String, reason: String)
signal score_changed(t: int, ct: int)
signal money_changed(money: int)
signal bomb_planted(site: String, timer: float)
signal bomb_defused()
signal bomb_exploded()

enum Phase { FREEZE, LIVE, ENDED, MATCH_OVER }

const PHASE_NAMES := ["freeze", "live", "ended", "match_over"]

var phase: int = Phase.FREEZE
var phase_time := 0.0
var round_number := 1
var score_t := 0
var score_ct := 0
var bomb_state := "carried"  # carried | planted | defused | exploded | dropped
var bomb_timer := 0.0
var bomb_site := ""
## Where the C4 lies once planted (Godot space), and who can pick it up again.
var bomb_position := Vector3.ZERO
var bomb_carrier := ""
var round_time := Cfg.ROUND_TIME
var buy_time_left := Cfg.BUY_TIME
var loss_streak := {"t": 0, "ct": 0}
var money := {"t": Cfg.START_MONEY, "ct": Cfg.START_MONEY}
var alive := {"t": 0, "ct": 0}
var running := false


func start() -> void:
	running = true
	score_t = 0
	score_ct = 0
	round_number = 1
	_begin_freeze()


func stop() -> void:
	running = false


func _begin_freeze() -> void:
	phase = Phase.FREEZE
	phase_time = Cfg.FREEZE_TIME
	buy_time_left = Cfg.BUY_TIME
	round_time = Cfg.ROUND_TIME
	bomb_state = "carried"
	bomb_timer = 0.0
	bomb_site = ""
	bomb_position = Vector3.ZERO
	bomb_carrier = ""
	phase_changed.emit(PHASE_NAMES[phase])
	round_started.emit(round_number, phase_time)


func _begin_live() -> void:
	phase = Phase.LIVE
	phase_time = Cfg.ROUND_TIME
	phase_changed.emit(PHASE_NAMES[phase])


func _process(delta: float) -> void:
	if not running:
		return
	phase_time = maxf(0.0, phase_time - delta)
	match phase:
		Phase.FREEZE:
			if phase_time <= 0.0:
				_begin_live()
		Phase.LIVE:
			buy_time_left = maxf(0.0, buy_time_left - delta)
			round_time = maxf(0.0, round_time - delta)
			if bomb_state == "planted":
				bomb_timer = maxf(0.0, bomb_timer - delta)
				if bomb_timer <= 0.0:
					bomb_state = "exploded"
					bomb_exploded.emit()
					end_round("t", "bomb exploded")
					return
			if round_time <= 0.0 and bomb_state != "planted":
				end_round("ct", "time ran out")
		Phase.ENDED:
			if phase_time <= 0.0:
				if score_t >= Cfg.SCORE_LIMIT or score_ct >= Cfg.SCORE_LIMIT:
					_finish_match()
				else:
					round_number += 1
					_begin_freeze()


func end_round(winner: String, reason: String) -> void:
	if phase != Phase.LIVE:
		return
	phase = Phase.ENDED
	phase_time = 4.5
	var loser := "ct" if winner == "t" else "t"
	loss_streak[winner] = 0
	loss_streak[loser] = mini(int(loss_streak[loser]) + 1, 4)
	if winner == "t":
		score_t += 1
	else:
		score_ct += 1
	var reward := Cfg.ROUND_WIN_MONEY
	money[winner] = mini(int(money[winner]) + reward, Cfg.MAX_MONEY)
	var loss_reward := Cfg.ROUND_LOSS_MONEY + 500 * (int(loss_streak[loser]) - 1)
	money[loser] = mini(int(money[loser]) + maxi(Cfg.ROUND_LOSS_MONEY, loss_reward), Cfg.MAX_MONEY)
	score_changed.emit(score_t, score_ct)
	money_changed.emit(int(money["t"]))
	phase_changed.emit(PHASE_NAMES[phase])
	round_ended.emit(winner, reason)


func _finish_match() -> void:
	phase = Phase.MATCH_OVER
	phase_time = 0.0
	running = false
	phase_changed.emit(PHASE_NAMES[phase])


func plant_bomb(site: String, position: Vector3 = Vector3.ZERO) -> bool:
	if bomb_state != "carried" or phase != Phase.LIVE:
		return false
	bomb_state = "planted"
	bomb_site = site
	bomb_position = position
	bomb_carrier = ""
	bomb_timer = Cfg.BOMB_TIMER
	bomb_planted.emit(site, bomb_timer)
	return true


func defuse_bomb() -> bool:
	if bomb_state != "planted":
		return false
	bomb_state = "defused"
	bomb_defused.emit()
	end_round("ct", "bomb defused")
	return true


func can_buy() -> bool:
	return phase == Phase.FREEZE or (phase == Phase.LIVE and buy_time_left > 0.0)


func spend(team: String, amount: int) -> bool:
	if int(money.get(team, 0)) < amount:
		return false
	money[team] = int(money[team]) - amount
	money_changed.emit(int(money[team]))
	return true


func set_alive_counts(t_count: int, ct_count: int) -> void:
	alive["t"] = t_count
	alive["ct"] = ct_count
	if phase != Phase.LIVE:
		return
	# A planted C4 keeps a round alive even after the last terrorist dies, but
	# only until the fuse runs out; if it is still being carried when the last
	# T falls the bomb is lost and CT wins on elimination.
	if t_count == 0 and bomb_state != "planted":
		end_round("ct", "terrorists eliminated")
	elif ct_count == 0:
		end_round("t", "counter-terrorists eliminated")


func status_line() -> String:
	var phase_name: String = PHASE_NAMES[phase]
	if phase == Phase.FREEZE:
		return "RESTART IN %.1f" % phase_time
	if bomb_state == "planted":
		return "BOMB PLANTED — %.1fs" % bomb_timer
	return "%s  %.1f" % [phase_name.to_upper(), round_time]
