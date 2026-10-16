extends Node2D
## 主场景：把世界、玩家、HUD 串起来；处理挖掘/放置和球心半圈翻转
##
## 到达球心后，画面只旋转半圈；在球心换到对跖列并恢复操作。

@export var world_seed := 20260813
@export var spawn_tile_x := 256

@onready var world = $World
@onready var player = $Player
@onready var cam: Camera2D = $Player/Camera2D
@onready var info: Label = $HUD/Info

const REACH := 5.5            # 挖掘 / 放置的最大距离（格）
const COOLDOWN := 0.07        # 按住鼠标时的连续操作间隔（秒）

const FLIP_TIME := 2.10       # 在宽阔地心中缓慢完成半圈过渡
const CORE_APPROACH_TILT := PI * 0.1333333333   # 接近球心时提前转动 24°

## 将真实向心重力投影到屏幕：index 0 是 ↓，4 是 ↑。
const ARROWS := ["↓", "↘", "→", "↗", "↑", "↖", "←", "↙"]

enum Phase { PLAY, GRAVITY_FLIP }

var _stock := {}              # 资源名 → 数量
var _brush := 0               # 当前手持方块（PLACEABLE 的下标）
var _cool := 0.0
var _last_tile := Vector2i(-9999, -9999)

# ── 穿越球心的状态 ──
var _phase: int = Phase.PLAY
var _t := 0.0                 # 当前阶段已用时
var _k := 0.0                 # 当前阶段进度 0~1
var _entry_x := 0             # 进入球心时的列
var _antipode_x := 0          # 对跖点列
var _flip_from := 0.0
var _body_from := 0.0
var _entry_position := Vector2.ZERO
var _entry_sign := 1.0
var _rest_zoom := Vector2.ONE
var _entry_zoom := Vector2.ONE
var _rest_camera_rotation := 0.0
var _flip_target := PI
var _approach_amount := 0.0
var _crossings := 0

# ═════════════════════ 初始化 ═════════════════════

func _ready() -> void:
	# 顺序很重要：先生成世界，再注入玩家，最后才摆放玩家
	world.generate(world_seed)
	player.world = world
	player.spawn_on_surface(spawn_tile_x)
	player.core_reached.connect(_begin_gravity_flip)
	cam.ignore_rotation = false
	_rest_zoom = cam.zoom
	_rest_camera_rotation = cam.global_rotation
	_update_hud()

# ═════════════════════ 每帧 ═════════════════════

func _process(delta: float) -> void:
	_cool = maxf(0.0, _cool - delta)

	# 穿越演出期间接管一切：不接受输入
	match _phase:
		Phase.GRAVITY_FLIP:
			_run_gravity_flip(delta)
			return
	_update_core_approach(delta)

	# ── 调试键：一键下潜到地核（不然要手动挖一百多格）──
	if Input.is_action_just_pressed("dive_to_core"):
		player.position = Vector2(
			player.position.x,
			world.project_y(float((RegolithWorld.CORE_ROCK_TOP + 3) * RegolithWorld.TILE))
		)
		player.velocity = Vector2.ZERO

	# ── 切换手持方块 ──
	if Input.is_action_just_pressed("cycle_block"):
		_brush = (_brush + 1) % RegolithWorld.PLACEABLE.size()
		_update_hud()

	# ── 挖掘 / 放置 ──
	if _cool <= 0.0:
		var m: Vector2 = world.get_global_mouse_position()
		if Input.is_action_pressed("mine"):
			if _try_mine(m):
				_cool = COOLDOWN
		elif Input.is_action_pressed("place"):
			if _try_place(m):
				_cool = COOLDOWN

	# HUD 只在玩家跨到新格子时刷新，别每帧重排文本
	var t: Vector2i = player.tile_pos()
	if t != _last_tile:
		_last_tile = t
		_update_hud()

# ═════════════════════ [2] 引力翻转 ═════════════════════

func _update_core_approach(delta: float) -> void:
	# 扩大的地心是一个区域；接近时就开始变化，折返时也能平滑恢复。
	var distance: float = world.core_center_px() - world.depth_y(player.position.y)
	var extent := float(RegolithWorld.CORE_TRANSITION_TILES * RegolithWorld.TILE)
	var spatial := 1.0 - clampf(distance / extent, 0.0, 1.0)
	var moving_in := clampf(player.velocity.y * world.hemisphere_sign / 80.0, 0.0, 1.0)
	var target := _ease(spatial) * moving_in if not player.on_floor else 0.0
	_approach_amount = lerpf(_approach_amount, target, 1.0 - exp(-5.0 * delta))
	cam.global_rotation = _rest_camera_rotation + CORE_APPROACH_TILT * _approach_amount
	cam.zoom = _rest_zoom * (1.0 - 0.02 * _approach_amount)

func _begin_gravity_flip() -> void:
	if is_crossing():
		return
	_phase = Phase.GRAVITY_FLIP
	_t = 0.0
	_k = 0.0
	# 全局角度会归一化，先相对当前半球展开，避免再次穿越时多转一圈。
	_flip_from = _rest_camera_rotation + angle_difference(_rest_camera_rotation, cam.global_rotation)
	_flip_target = _rest_camera_rotation + PI
	_body_from = player.rotation
	_entry_position = player.position
	_entry_sign = world.hemisphere_sign
	_entry_zoom = cam.zoom
	_entry_x = player.tile_pos().x
	_antipode_x = world.antipode_x(_entry_x)
	# 提前准备并显示对面的岩室，避免转完后才突然生成整片地形。
	world.begin_core_transition(_entry_x, _antipode_x)

	player.set_physics_process(false)
	player.velocity = Vector2.ZERO
	player.transit_glow = true
	player.queue_redraw()
	_update_hud()

func _run_gravity_flip(delta: float) -> void:
	_t += delta
	_k = clampf(_t / FLIP_TIME, 0.0, 1.0)

	var eased := _ease(_k)
	world.set_core_transition_progress(_k)
	# 身体穿过球心后沿短路径贴合落脚面，转动稍滞后于镜头。
	var landing_x := float(_entry_x * RegolithWorld.TILE) + RegolithWorld.TILE * 0.5
	player.position.x = lerpf(_entry_position.x, landing_x, eased)
	# 先通过球心，再给旋转中的车体留出净空，最后缓缓贴地。
	var clearance: float = player.HALF.y + player.EPS + (3.0 + 8.0 * (1.0 - _k)) * pow(sin(PI * _k), 2.0)
	player.position.y = lerpf(_entry_position.y,
		world.core_center_px() + _entry_sign * clearance, _ease(clampf(_k / 0.28, 0.0, 1.0)))
	player.rotation = _body_from + PI * _ease(clampf((_k - 0.06) / 0.88, 0.0, 1.0))
	# Camera2D 是车体子节点，要设置全局角度，避免叠加车体转角。
	cam.global_rotation = lerpf(_flip_from, _flip_target, eased)
	cam.zoom = _entry_zoom.lerp(_rest_zoom, eased) * (1.0 - 0.045 * pow(sin(PI * _k), 2.0))

	player.queue_redraw()
	_update_hud()

	if _k >= 1.0:
		_finish_crossing()

func _finish_crossing() -> void:
	world.flip_hemisphere()
	world.end_core_transition()
	player.position.x = float(_antipode_x * RegolithWorld.TILE) + RegolithWorld.TILE * 0.5
	player.view_sign = world.hemisphere_sign
	player.rotation = 0.0 if world.hemisphere_sign > 0.0 else PI
	# 地核岩室支撑并停止穿越运动；接下来需主动逆重力攀岩开挖。
	player.stand_at_core()
	_rest_camera_rotation = _flip_target
	_approach_amount = 0.0
	cam.global_rotation = _rest_camera_rotation
	cam.zoom = _rest_zoom
	player.play_landing_settle()
	player.transit_glow = false
	player.set_physics_process(true)
	player.queue_redraw()
	_phase = Phase.PLAY
	_crossings += 1
	_last_tile = Vector2i(-9999, -9999)
	_update_hud()

func _ease(k: float) -> float:
	## 五次缓动：两端速度和加速度都为零，避免启停时突然一顿。
	return k * k * k * (k * (k * 6.0 - 15.0) + 10.0)

# ── 供自动化测试查询 ──

func core_crossing_count() -> int:
	return _crossings

func is_crossing() -> bool:
	return _phase != Phase.PLAY

func crossing_phase() -> int:
	return _phase

# ═════════════════════ 挖掘 / 放置 ═════════════════════

func _try_mine(world_pos: Vector2) -> bool:
	var t: Vector2i = world.world_to_tile(world_pos)
	if not _in_reach(t):
		return false
	var got: Array = world.break_tile(t.x, t.y)
	if got.is_empty():
		return false
	_stock[got[0]] = _stock.get(got[0], 0) + int(got[1])
	_update_hud()
	return true

func _try_place(world_pos: Vector2) -> bool:
	var t: Vector2i = world.world_to_tile(world_pos)
	if not _in_reach(t):
		return false
	if _overlaps_player(t):
		return false                                   # 别把自己封进墙里
	if not world.place_tile(t.x, t.y, RegolithWorld.PLACEABLE[_brush]):
		return false
	_update_hud()
	return true

func _in_reach(t: Vector2i) -> bool:
	var p := Vector2(player.position.x, world.depth_y(player.position.y)) / float(RegolithWorld.TILE)
	# ★ 距离要用「环绕后的最短差值」算，否则站在接缝边上会出现
	#   明明贴着却"够不着"的怪现象
	var dx: float = world.wrap_delta_x(float(t.x) + 0.5 - p.x)
	var dy: float = float(t.y) + 0.5 - p.y
	return Vector2(dx, dy).length() <= REACH

func _overlaps_player(t: Vector2i) -> bool:
	var p := Vector2(player.position.x, world.depth_y(player.position.y)) / float(RegolithWorld.TILE)
	var dx: float = world.wrap_delta_x(float(t.x) + 0.5 - p.x)
	var dy: float = float(t.y) + 0.5 - p.y
	return absf(dx) < 0.8 and absf(dy) < 1.05

# ═════════════════════ HUD ═════════════════════

func _gravity_arrow() -> String:
	if is_zero_approx(player.gravity_acceleration()):
		return "○（球心失重）"
	var angle := cam.global_rotation
	if player.gravity_acceleration() < 0.0:
		angle += PI
	return ARROWS[posmod(int(round(angle / (TAU / 8.0))), 8)]

func _update_hud() -> void:
	var t: Vector2i = player.tile_pos()
	var on_ring: int = world.wrap_x(t.x)
	var pct := float(on_ring) / float(RegolithWorld.WORLD_W) * 100.0

	var rows: Array[String] = []
	rows.append("NewMars · 技术原型  (周期地形 + 环形世界 + 挖穿球心)")
	rows.append("")

	if _phase == Phase.GRAVITY_FLIP:
		rows.append("     ★  穿 越 球 心 · 视 角 正 在 翻 转  ★")
	else:
		rows.append("     地核岩室 · 向头顶开挖通往地表" if _crossings > 0 else "     自由探索 · 向下挖掘通往地核")
	# 固定状态行的高度，结束时 HUD 不整块上跳。
	rows.append("")

	rows.append("重力方向   %s" % _gravity_arrow())
	rows.append("环上位置   %5.1f%%      格 x=%d / %d" % [pct, on_ring, RegolithWorld.WORLD_W])
	rows.append("深度       y=%d / %d   %s" % [t.y, RegolithWorld.WORLD_H, _depth_label(t.y)])
	rows.append("对跖点     x=%d   ← 穿过球心后切换到这一列的球心" % world.antipode_x(t.x))
	rows.append("已穿越      %d 次" % _crossings)
	rows.append("")
	rows.append("资源       %s" % _stock_text())
	rows.append("手持       %s   （Q 切换）" % _block_name(RegolithWorld.PLACEABLE[_brush]))
	rows.append("")
	rows.append("A / D 移动    空格 跳跃    左键 挖掘    右键 放置")
	rows.append("按住 空格 + 左键，靠岩壁向上攀附开挖；松开会受重力拉回")
	rows.append("R 直接下潜到地核（调试用 —— 不然要手动挖一百多格）")
	rows.append("")
	rows.append("★ 穿过球心后，站在另一半球的地核岩室，向头顶挖回地表。")
	info.text = "\n".join(rows)

func _depth_label(y: int) -> String:
	if y >= RegolithWorld.CORE_CENTER_Y - RegolithWorld.CORE_TRANSITION_TILES:
		return "★ 地心低重力过渡带"
	if y >= RegolithWorld.CORE_CAVITY_TOP:
		return "★ 地心空腔 —— 再往下就是球心"
	if y >= RegolithWorld.CORE_ROCK_TOP:
		return "★ 地核岩层 —— 挖穿它"
	if y >= RegolithWorld.CORE_ROCK_TOP - 24:
		return "接近地核…"
	return ""

func _stock_text() -> String:
	if _stock.is_empty():
		return "（还没挖到东西）"
	var parts: Array[String] = []
	for k in _stock:
		parts.append("%s ×%d" % [k, _stock[k]])
	return "    ".join(parts)

func _block_name(t: int) -> String:
	match t:
		RegolithWorld.Tile.REGOLITH: return "红壤"
		RegolithWorld.Tile.ROCK:     return "玄武岩"
		RegolithWorld.Tile.ICE:      return "水冰"
	return "?"
