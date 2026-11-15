extends Control

## Live "player stock" ticker for the top-right corner.
##
## The player is a stock market expert, so their performance is quoted like a
## share price. The graph is event driven:
##   player takes a hit  -> one red step down
##   player deals a hit  -> one green step up
##   player dies         -> major red drop (+ red border flash)
##   an enemy dies       -> big green jump (+ green border flash)
##
## Wiring: the player is found through the `player` group and its `hurt` and
## `died` signals. Enemies are found through the `enemies` group; their
## `damaged` and `died` signals count as player damage, because enemy bolts
## cannot hit other enemies, so today only the player can hurt them. Newly
## spawned enemies are picked up once per second.

@export_group("Price")
## Price the ticker opens at.
@export var start_price: float = 100.0
## Circuit breaker floor.
@export var min_price: float = 15.0
## Circuit breaker ceiling.
@export var max_price: float = 185.0

@export_group("Steps")
## Price lost every time the player takes a hit.
@export var hit_taken_step: float = 2.0
## Price gained every time the player deals a hit.
@export var hit_dealt_step: float = 2.0
## Price lost when the player dies.
@export var death_drop: float = 25.0
## Price gained when the player kills an enemy.
@export var kill_jump: float = 25.0

@export_group("Look")
## Text shown in the panel header.
@export var panel_title: String = "YOU CORP"
## How many seconds of history the graph shows.
@export var window_seconds: float = 24.0
## How often a flat sample is recorded between events.
@export var sample_interval: float = 0.2
## How long an event flashes the panel border.
@export var flash_time: float = 0.6

const COLOR_UP := Color(0.35, 0.9, 0.5)
const COLOR_DOWN := Color(1.0, 0.32, 0.38)

var price: float = 100.0

var _points: Array[Vector2] = []
var _time: float = 0.0
var _sample_left: float = 0.0
var _enemy_scan_left: float = 0.0
var _flash_color: Color = Color(0, 0, 0, 0)
var _flash_left: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	price = start_price
	_points.append(Vector2(0.0, price))
	_hook_player.call_deferred()
	_hook_enemies()


func _process(delta: float) -> void:
	_time += delta

	# Enemies can spawn or despawn at any time; rescan cheaply.
	_enemy_scan_left -= delta
	if _enemy_scan_left <= 0.0:
		_enemy_scan_left = 1.0
		_hook_enemies()

	# Flat samples keep the line drawing through quiet stretches.
	_sample_left -= delta
	if _sample_left <= 0.0:
		_sample_left = sample_interval
		_push(price)

	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var font := ThemeDB.fallback_font

	# Panel.
	draw_rect(rect, Color(0.05, 0.06, 0.09, 0.82))
	draw_rect(rect, _border_color(), false, 1.5)

	# Header: name on the left, quoted price and change on the right.
	draw_string(font, Vector2(10, 21), panel_title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.88, 0.95, 0.9))
	var change := price - start_price
	var up := change >= 0.0
	var trend_color := COLOR_UP if up else COLOR_DOWN
	var price_text := "%.1f  %s%.1f%%" % [price, "+" if up else "-", absf(change) / start_price * 100.0]
	var price_width := font.get_string_size(price_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, Vector2(rect.size.x - price_width - 10, 21), price_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, trend_color)

	# Graph area.
	var graph := Rect2(Vector2(8, 30), rect.size - Vector2(16, 38))
	var span := maxf(max_price - min_price, 0.001)

	# Grid lines.
	for i in range(1, 4):
		var grid_price := min_price + span * float(i) / 4.0
		var grid_y := _price_to_y(grid_price, graph)
		draw_line(Vector2(graph.position.x, grid_y), Vector2(graph.position.x + graph.size.x, grid_y), Color(1, 1, 1, 0.06), 1.0)

	# Opening price baseline.
	var base_y := _price_to_y(start_price, graph)
	draw_line(Vector2(graph.position.x, base_y), Vector2(graph.position.x + graph.size.x, base_y), Color(1, 1, 1, 0.18), 1.0)

	# The price line, green while rising and red while falling.
	var start_time := _time - window_seconds
	for i in range(_points.size() - 1):
		var a := _points[i]
		var b := _points[i + 1]
		var pa := Vector2(graph.position.x + clampf(a.x - start_time, 0.0, window_seconds) / window_seconds * graph.size.x, _price_to_y(a.y, graph))
		var pb := Vector2(graph.position.x + clampf(b.x - start_time, 0.0, window_seconds) / window_seconds * graph.size.x, _price_to_y(b.y, graph))
		var col := COLOR_UP if b.y >= a.y else COLOR_DOWN
		draw_line(pa, pb, col, 2.0)

	# Live price marker.
	if not _points.is_empty():
		var last := _points[_points.size() - 1]
		var pl := Vector2(graph.position.x + clampf(last.x - start_time, 0.0, window_seconds) / window_seconds * graph.size.x, _price_to_y(last.y, graph))
		draw_circle(pl, 3.0, trend_color)


# --- Events ----------------------------------------------------------------

func _on_player_hurt(amount: float) -> void:
	if amount <= 0.0:
		return
	_step(-hit_taken_step)


func _on_player_died() -> void:
	_step(-death_drop, Color(0.95, 0.2, 0.25))


func _on_enemy_damaged(amount: float) -> void:
	if amount <= 0.0:
		return
	_step(hit_dealt_step)


func _on_enemy_killed() -> void:
	_step(kill_jump, Color(0.2, 0.9, 0.4))


# --- Internals ---------------------------------------------------------------

## Moves the price by `change`, records the step and flashes for big events.
func _step(change: float, flash: Color = Color(0, 0, 0, 0)) -> void:
	price = clampf(price + change, min_price, max_price)
	_push(price)
	if flash.a > 0.0:
		_flash_color = flash
		_flash_left = flash_time


## Records a sample; old samples outside the window are dropped.
func _push(value: float) -> void:
	_points.append(Vector2(_time, value))
	var cutoff := _time - window_seconds
	while _points.size() > 2 and _points[1].x < cutoff:
		_points.pop_front()


func _hook_player() -> void:
	var player := get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	if player.has_signal("hurt") and not player.hurt.is_connected(_on_player_hurt):
		player.hurt.connect(_on_player_hurt)
	if player.has_signal("died") and not player.died.is_connected(_on_player_died):
		player.died.connect(_on_player_died)


func _hook_enemies() -> void:
	for enemy in get_tree().get_nodes_in_group(&"enemies"):
		_hook_enemy(enemy)


func _hook_enemy(enemy: Node) -> void:
	if enemy.has_meta("stock_graph_hooked"):
		return
	enemy.set_meta("stock_graph_hooked", true)
	if enemy.has_signal("damaged") and not enemy.damaged.is_connected(_on_enemy_damaged):
		enemy.damaged.connect(_on_enemy_damaged)
	if enemy.has_signal("died") and not enemy.died.is_connected(_on_enemy_killed):
		enemy.died.connect(_on_enemy_killed)


func _price_to_y(p: float, graph: Rect2) -> float:
	var t := clampf((p - min_price) / maxf(max_price - min_price, 0.001), 0.0, 1.0)
	return graph.position.y + graph.size.y * (1.0 - t)


func _border_color() -> Color:
	if _flash_left > 0.0:
		var strength := clampf(_flash_left / maxf(flash_time, 0.001), 0.0, 1.0)
		return Color(_flash_color.r, _flash_color.g, _flash_color.b, strength * 0.9)
	return Color(1, 1, 1, 0.12)
