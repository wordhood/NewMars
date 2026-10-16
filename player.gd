extends Node2D
## 玩家（原型阶段：一台工程车，用色块表示）
##
## 为什么自己写格子碰撞，而不是用 Godot 的物理引擎？
##   · 泰拉瑞亚式世界的碰撞本质就是「AABB vs 格子网格」，几十行就能写完
##   · 完全可控：以后加台阶、单向平台、斜坡都好办
##   · 零资源依赖，不需要配置 TileSet 的碰撞层

const HALF := Vector2(7.0, 11.0)     # 碰撞盒半宽 / 半高（像素）
const SPEED := 140.0                 # 水平最大速度
const ACCEL := 1500.0                # 加速度（有加速才有手感，不然像贴图平移）
const JUMP_V := -285.0               # 起跳初速度
const GRAVITY := 980.0
const EPS := 0.01                    # 防抖：避免恰好卡在格线上反复触发碰撞
const COYOTE := 0.10                 # 土狼时间：走出边缘后仍可起跳的宽限期
const CLIMB_SPEED := 72.0            # 履带攀岩，需同时按住跳跃和挖掘
const CLIMB_ACCEL := 1800.0

var world: RegolithWorld             # 由 main.gd 注入（不要在 _ready 里找节点，顺序不可靠）
var velocity := Vector2.ZERO
signal core_reached

var view_sign := 1.0                # 只映射屏幕左右操作，不参与重力
var on_floor := false
var facing := 1.0

## 穿越球心时，车身受到地核环境的轻微暖色反光。
var transit_glow := false

var _coyote := 0.0
var _jumping := false
var _landing_age := -1.0

# ═════════════════════ 对外接口 ═════════════════════

func surface_rest_y(tile_x: int) -> float:
	## 站在该列地表上时，玩家中心应该在哪
	if world == null:
		return 0.0
	return world.project_y(world.surface_top_px(tile_x) - HALF.y - 2.0)

func spawn_on_surface(tile_x: int) -> void:
	## 把玩家放到指定列的地表上
	if world == null:
		return
	var tx := world.wrap_x(tile_x)
	position = Vector2(
		float(tx * RegolithWorld.TILE) + RegolithWorld.TILE * 0.5,
		surface_rest_y(tx)
	)
	velocity = Vector2.ZERO
	_refresh_floor()

func tile_pos() -> Vector2i:
	return world.world_to_tile(position) if world != null else Vector2i.ZERO

func stand_at_core() -> void:
	## 履带接触球心处的岩层，身体留在目标半球内，避免悬空或嵌入方块。
	position.y = world.project_y(world.core_center_px() - HALF.y - EPS)
	velocity = Vector2.ZERO
	reset_contact()
	_refresh_floor()

func play_landing_settle() -> void:
	_landing_age = 0.0
	queue_redraw()

func _process(delta: float) -> void:
	if _landing_age >= 0.0:
		_landing_age += delta
		if _landing_age > 0.48:
			_landing_age = -1.0
		queue_redraw()

# ═════════════════════ 主循环 ═════════════════════

func _physics_process(delta: float) -> void:
	if world == null:
		return

	# ── 水平输入：走 Input Map，不硬编码按键 ──
	var dir := Input.get_axis("move_left", "move_right") * view_sign
	velocity.x = move_toward(velocity.x, dir * SPEED, ACCEL * delta)
	if not is_zero_approx(dir):
		var nf := signf(dir) * world.hemisphere_sign
		if nf != facing:
			facing = nf
			queue_redraw()

	# ── 跳跃（带土狼时间 + 可变高度）──
	if on_floor:
		_coyote = COYOTE
	else:
		_coyote = maxf(0.0, _coyote - delta)

	if Input.is_action_just_pressed("jump") and _coyote > 0.0:
		velocity.y = JUMP_V * world.hemisphere_sign
		_coyote = 0.0
		_jumping = true
	if Input.is_action_just_released("jump") and _jumping and velocity.y * world.hemisphere_sign < 0.0:
		velocity.y *= 0.45          # 松手就减速上升 → 轻按小跳，长按大跳
		_jumping = false

	# 均匀密度球体近似：球内 g ∝ r，球心 g = 0；镜头不参与计算。
	# 半隐式改为速度 Verlet，减少无阻力振荡中的能量漂移。
	var old_gravity := gravity_acceleration()
	velocity.y += old_gravity * delta * 0.5
	if Input.is_action_pressed("jump") and Input.is_action_pressed("mine") and has_wall_grip():
		# 攀附岩壁提供反作用力；离开岩壁或松开操作后恢复自由落体。
		velocity.y = move_toward(velocity.y, -world.hemisphere_sign * CLIMB_SPEED, CLIMB_ACCEL * delta)
		_jumping = false
	_move_x(velocity.x * delta)
	var hit_y := _move_y(velocity.y * delta)
	if not hit_y:
		velocity.y += gravity_acceleration() * delta * 0.5
	_wrap_x()
	if world.depth_y(position.y) >= world.core_center_px() and velocity.y * world.hemisphere_sign > 0.0:
		core_reached.emit()

func has_wall_grip() -> bool:
	for side in [-1.0, 1.0]:
		for offset_y in [-HALF.y + 1.0, 0.0, HALF.y - 1.0]:
			var sample := position + Vector2(side * (HALF.x + RegolithWorld.TILE + 2.0), offset_y)
			var t := world.world_to_tile(sample)
			if world.is_solid(t.x, t.y):
				return true
	return false

func gravity_acceleration() -> float:
	if world == null:
		return 0.0
	# 以平均地表为基准半径；洞穴、矿物不单独计算质量分布。
	var radius := float((RegolithWorld.CORE_CENTER_Y - RegolithWorld.SURFACE_BASE) * RegolithWorld.TILE)
	var distance := world.core_center_px() - position.y
	if absf(distance) <= radius:
		return GRAVITY * distance / radius
	return signf(distance) * GRAVITY * pow(radius / absf(distance), 2.0)

func reset_contact() -> void:
	on_floor = false
	_coyote = 0.0
	_jumping = false

# ═════════════════════ 碰撞 ═════════════════════

func _aabb() -> Rect2:
	return Rect2(position - HALF, HALF * 2.0)

func _move_x(dx: float) -> void:
	if is_zero_approx(dx):
		return
	position.x += dx

	var r := _aabb()
	var ty0 := int(floor(r.position.y / RegolithWorld.TILE))
	var ty1 := int(floor((r.end.y - EPS) / RegolithWorld.TILE))

	if dx > 0.0:
		var tx := int(floor((r.end.x - EPS) / RegolithWorld.TILE))
		for ty in range(ty0, ty1 + 1):
			if world.collision_is_solid(tx, ty):
				position.x = float(tx * RegolithWorld.TILE) - HALF.x - EPS
				velocity.x = 0.0
				return
	else:
		var tx := int(floor(r.position.x / RegolithWorld.TILE))
		for ty in range(ty0, ty1 + 1):
			if world.collision_is_solid(tx, ty):
				position.x = float((tx + 1) * RegolithWorld.TILE) + HALF.x + EPS
				velocity.x = 0.0
				return

func _move_y(dy: float) -> bool:
	# 深井自由落体不再限制终端速度；分段碰撞避免高速跳过一整格。
	if dy * world.hemisphere_sign > 0.0:
		var to_core := (world.core_center_px() - position.y) * world.hemisphere_sign
		dy = minf(absf(dy), maxf(0.0, to_core)) * world.hemisphere_sign
	var steps := maxi(1, int(ceil(absf(dy) / (RegolithWorld.TILE * 0.5))))
	for i in steps:
		if _step_y(dy / float(steps)):
			return true
	return false

func _step_y(dy: float) -> bool:
	if is_zero_approx(dy):
		_refresh_floor()
		return false
	position.y += dy

	var r := _aabb()
	var tx0 := int(floor(r.position.x / RegolithWorld.TILE))
	var tx1 := int(floor((r.end.x - EPS) / RegolithWorld.TILE))

	if dy > 0.0:
		var ty := int(floor((r.end.y - EPS) / RegolithWorld.TILE))
		for tx in range(tx0, tx1 + 1):
			if world.collision_is_solid(tx, ty):
				position.y = float(ty * RegolithWorld.TILE) - HALF.y - EPS
				velocity.y = 0.0
				_refresh_floor()
				return true
	else:
		var ty := int(floor(r.position.y / RegolithWorld.TILE))
		for tx in range(tx0, tx1 + 1):
			if world.collision_is_solid(tx, ty):
				position.y = float((ty + 1) * RegolithWorld.TILE) + HALF.y + EPS
				velocity.y = 0.0
				_refresh_floor()
				return true
	_refresh_floor()
	return false

func _refresh_floor() -> void:
	on_floor = false
	var r := _aabb()
	var foot_y := r.end.y + 1.0 if world.hemisphere_sign > 0.0 else r.position.y - 1.0
	var ty := int(floor(foot_y / RegolithWorld.TILE))
	var tx0 := int(floor(r.position.x / RegolithWorld.TILE))
	var tx1 := int(floor((r.end.x - EPS) / RegolithWorld.TILE))
	for tx in range(tx0, tx1 + 1):
		if world.collision_is_solid(tx, ty):
			on_floor = true
			return

# ═════════════════════ 位置环绕 ═════════════════════

func _wrap_x() -> void:
	## ★ 整个环形世界里最美的一段 ★
	##
	## 整周期瞬移在视觉上完全无痕 —— 因为地形是周期函数，
	## x 和 x + WORLD_PX_W 处的世界逐像素一模一样。
	## 摄像机是玩家的子节点，会跟着一起跳；所以玩家什么都看不出来。
	##
	## 反过来说：以后任何「不周期」的东西（比如玩家插的旗子、建好的基地）
	## 放到接缝附近时，就必须自己处理显示，否则会看到它闪一下。
	if position.x < 0.0:
		position.x += float(RegolithWorld.WORLD_PX_W)
	elif position.x >= float(RegolithWorld.WORLD_PX_W):
		position.x -= float(RegolithWorld.WORLD_PX_W)

# ═════════════════════ 绘制 ═════════════════════

func _draw() -> void:
	if _landing_age >= 0.0:
		for i in 8:
			var direction := -1.0 if i < 4 else 1.0
			var travel := _landing_age * (8.0 + (i % 4) * 5.0)
			var dust := Vector2(direction * (HALF.x + travel),
				HALF.y - sin(_landing_age * PI / 0.48) * (2.0 + i % 3))
			draw_circle(dust, 0.7, Color(0.52, 0.32, 0.24, (1.0 - _landing_age / 0.48) * 0.4))
		# 只压缩绘制，履带接触点和摄像机都保持稳定。
		var compression := sin(PI * clampf(_landing_age / 0.28, 0.0, 1.0)) * 0.06
		draw_set_transform(Vector2(0.0, HALF.y * compression), 0.0,
			Vector2(1.0 + compression * 0.5, 1.0 - compression))
	# 车体
	var body_color := Color("c8d0d8").lerp(Color("d9baa6"), 0.18 if transit_glow else 0.0)
	draw_rect(Rect2(-HALF, HALF * 2.0), body_color)
	# 履带
	draw_rect(Rect2(-HALF.x, HALF.y - 4.0, HALF.x * 2.0, 4.0), Color("2e3439"))
	# 头灯：指示朝向
	draw_rect(Rect2(facing * 3.0 - 1.5, -HALF.y + 3.0, 3.0, 3.0), Color("ffd479"))
	# 太阳能板
	draw_rect(Rect2(-HALF.x + 2.0, -HALF.y - 3.0, HALF.x * 2.0 - 4.0, 3.0), Color("3f6ea8"))
	draw_set_transform(Vector2.ZERO)
