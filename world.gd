class_name RegolithWorld
extends Node2D
## 世界：周期地形生成 + X 轴环绕 + 可破坏 + 环绕渲染
##
## ══════════════════════════════════════════════════════════════
##  这个文件是整个项目的地基。它落地了三个架构决定：
##
##  ① 周期地形 —— 用「圆采样」噪声生成，X 方向天然首尾闭合。
##     不需要事后缝合，因为噪声在 x=0 和 x=WORLD_W 处取值本来就相同。
##
##  ② 坐标环绕 —— 所有查询都过 wrap_x()，左右走永远走不到尽头。
##
##  ③ 环绕渲染 —— 画在「展开坐标」，查在「环绕坐标」。
##     接缝因此自动正确，一行特殊分支都不需要。
## ══════════════════════════════════════════════════════════════

# ───────────────────────── 世界尺寸 ─────────────────────────
const WORLD_W := 512                      # 横向格数（= 绕星球一圈）
const WORLD_H := 192                      # 纵向格数（地表 → 地核）
const TILE := 16                          # 每格边长（像素）
const WORLD_PX_W := WORLD_W * TILE
const WORLD_PX_H := WORLD_H * TILE
const SURFACE_BASE := 44                  # 平均地表，亦作为球体重力的基准半径

## 圆采样半径。噪声在这个圆上取值，绕一圈天然闭合 —— 这就是「周期」的来源。
const CIRCLE_R := 64.0

# ───────────────────────── 地核与球心 ─────────────────────────
# 世界的纵坐标就是「离球心的距离」：y=0 是地表，y 越大越接近球心。
const CORE_ROCK_TOP := WORLD_H - 54       # 地核岩层顶部（可挖，很深很暗）
const CORE_CAVITY_TOP := WORLD_H - 42     # 扩大的地心空腔，球心前留出 32 格空间
const CORE_CENTER_Y := WORLD_H - 10       # ★ 球心线：越过它就算穿过了星球中心
const CORE_TRANSITION_TILES := 16        # 球心前的低重力视角渐变带
const CORE_CHAMBER_HEIGHT := 5           # 目的地穹顶洞室高度（格）
const CORE_CHAMBER_HALF_WIDTH := 4       # 洞室底部半宽（共 9 格）
const CORE_SUBSTRATE_TOP := CORE_CENTER_Y + 2  # 穿越通道下方接回实体岩层
const BELOW_CORE_ROWS := 64             # 球心下方完整存储、渲染的方块范围
const STORAGE_H := CORE_CENTER_Y + BELOW_CORE_ROWS
const STORAGE_PX_H := STORAGE_H * TILE

# ───────────────────────── 方块类型 ─────────────────────────
enum Tile { AIR, REGOLITH, ROCK, DEEP, ICE, ORE_IRON, ORE_SILICON, CORE, BEDROCK }

const COLORS := {
	Tile.REGOLITH:    Color("a34a28"),   # 火星红壤
	Tile.ROCK:        Color("6b3b2a"),   # 玄武岩
	Tile.DEEP:        Color("3d2320"),   # 深层岩
	Tile.ICE:         Color("8fd4e8"),   # 水冰
	Tile.ORE_IRON:    Color("c98b5e"),   # 铁矿脉
	Tile.ORE_SILICON: Color("d8d2c4"),   # 硅矿脉
	Tile.CORE:        Color("7a1f4a"),   # 地核岩（可挖穿）
	Tile.BEDROCK:     Color("000000"),   # 世界之外的不可穿越边界
}

const SOLID := {
	Tile.REGOLITH: true, Tile.ROCK: true, Tile.DEEP: true, Tile.ICE: true,
	Tile.ORE_IRON: true, Tile.ORE_SILICON: true, Tile.CORE: true, Tile.BEDROCK: true,
}

## 挖矿产出：方块 → [资源名, 数量]
const YIELD := {
	Tile.REGOLITH:    ["铁氧化物", 1],
	Tile.ROCK:        ["硅酸盐", 1],
	Tile.DEEP:        ["硅酸盐", 1],
	Tile.ICE:         ["水冰", 2],
	Tile.ORE_IRON:    ["铁氧化物", 4],
	Tile.ORE_SILICON: ["硅酸盐", 4],
	Tile.CORE:        ["地核样本", 1],   # 来自球心的东西
}

## 玩家可以放置的方块
const PLACEABLE := [Tile.REGOLITH, Tile.ROCK, Tile.ICE]

# ───────────────────────── 状态 ─────────────────────────
var _tiles := PackedByteArray()           # 平铺数组：index = y * WORLD_W + x
var surface_y := PackedInt32Array()       # 每列的地表高度（格）
var _n_height: FastNoiseLite
var _n_cave: FastNoiseLite
var _n_ore: FastNoiseLite
var hemisphere_sign := 1.0              # +1：地表在球心上方；-1：地表在球心下方
var _core_landing_columns := {}          # 岩室只生成一次，保留之后挖出的通道
var _transition_active := false
var _transition_progress := 0.0
var _transition_tile_shift := 0
var _ambience_time := 0.0

# ═════════════════════ 坐标环绕（架构决定 ②） ═════════════════════

func wrap_x(x: int) -> int:
	## 把任意整数 x 折进 [0, WORLD_W)。
	## 注意 ((a % b) + b) % b 这个写法：GDScript 的 % 对负数会返回负数，
	## 直接写 x % WORLD_W 会让 x = -1 变成 -1 而不是 WORLD_W - 1。
	return ((x % WORLD_W) + WORLD_W) % WORLD_W

func wrap_delta_x(dx: float) -> float:
	## 把「展开坐标的差值」折算成「环形世界里的最短差值」（单位：格）。
	## 用途：判断两个东西实际离得多远 —— 从接缝两侧「绕过去」可能更近。
	## 注意返回的是带符号的差值，判断远近要取绝对值。
	var half := float(WORLD_W) * 0.5
	while dx > half:
		dx -= float(WORLD_W)
	while dx < -half:
		dx += float(WORLD_W)
	return dx

# ═════════════════════ 数据访问 ═════════════════════

func _idx(x: int, y: int) -> int:
	## 注意：调用前 x 必须已经是环绕过的
	return y * WORLD_W + x

func get_tile(x: int, y: int) -> int:
	if y < 0:
		return Tile.AIR            # 地表以上 = 太空
	if y >= STORAGE_H:
		return Tile.BEDROCK        # 最终边界在球心下方岩层之外
	return _tiles[_idx(wrap_x(x), y)]

func set_tile(x: int, y: int, t: int) -> void:
	if y < 0 or y >= STORAGE_H:
		return
	_tiles[_idx(wrap_x(x), y)] = t

func is_solid(x: int, y: int) -> bool:
	return SOLID.get(get_tile(x, y), false)

func depth_y(physical_y: float) -> float:
	## 数据始终按「地表 → 球心」存放，物理位置在两半球分居球心两侧。
	return core_center_px() + hemisphere_sign * (physical_y - core_center_px())

func project_y(logical_y: float) -> float:
	return core_center_px() + hemisphere_sign * (logical_y - core_center_px())

func collision_is_solid(x: int, physical_y: int) -> bool:
	var logical_y := physical_y if hemisphere_sign > 0.0 else 2 * CORE_CENTER_Y - 1 - physical_y
	return is_solid(x, logical_y)

func flip_hemisphere() -> void:
	hemisphere_sign *= -1.0
	scale.y = hemisphere_sign
	position.y = core_center_px() * (1.0 - hemisphere_sign)
	queue_redraw()

func begin_core_transition(entry_x: int, target_x: int) -> void:
	prepare_core_landing(target_x)
	_transition_tile_shift = target_x - entry_x
	_transition_progress = 0.0
	_transition_active = true
	queue_redraw()

func set_core_transition_progress(progress: float) -> void:
	_transition_progress = clampf(progress, 0.0, 1.0)
	queue_redraw()

func end_core_transition() -> void:
	_transition_active = false
	_transition_progress = 0.0
	queue_redraw()

func core_transition_weights() -> Vector2:
	# 在岩层边缘的灰尘中逐渐显露另一侧，完成前已完全交接。
	return Vector2(1.0 - smoothstep(0.20, 0.82, _transition_progress),
		smoothstep(0.20, 0.75, _transition_progress))

func prepare_core_landing(tile_x: int) -> void:
	## 对面球心是一间小岩室：脚下有可挖地核，头顶是通向地表的岩层。
	## 已经布置过的列不重新填土，保留玩家挖出的通道。
	# 落脚处融入宽阔地层，远处缓慢收回原有洞顶，避免生成细长方柱。
	const SHELF_HALF_WIDTH := 96
	const SHELF_FLAT_WIDTH := 48
	for dx in range(-SHELF_HALF_WIDTH, SHELF_HALF_WIDTH + 1):
		var tx := wrap_x(tile_x + dx)
		var shoulder := 1.0 - smoothstep(float(SHELF_FLAT_WIDTH), float(SHELF_HALF_WIDTH), float(absi(dx)))
		var thickness := float(CORE_CENTER_Y + 2 - CORE_CAVITY_TOP) + sample_height_noise(tx) * 2.0
		var bottom_y := CORE_CAVITY_TOP + int(round(thickness * shoulder))
		if absi(dx) <= SHELF_FLAT_WIDTH:
			# 平缓地层与下方岩体相接，避免边缘噪声留下整排黑色空缝。
			bottom_y = maxi(bottom_y, CORE_SUBSTRATE_TOP)
		var previous_bottom := int(_core_landing_columns.get(tx, CORE_CAVITY_TOP))
		# 相邻落脚区只延伸原地层的外缘，不填回地层内已挖出的通道。
		for y in range(previous_bottom, bottom_y):
			if get_tile(tx, y) == Tile.AIR:
				set_tile(tx, y, Tile.CORE)
		_core_landing_columns[tx] = maxi(previous_bottom, bottom_y)
	# 宽阔穹顶保留转向空间；靠近两侧仍可攀岩向上开挖。
	for h in range(1, CORE_CHAMBER_HEIGHT + 1):
		var rise := (float(h) - 0.5) / float(CORE_CHAMBER_HEIGHT)
		var half_width := maxi(1, int(floor((CORE_CHAMBER_HALF_WIDTH + 0.5) * sqrt(1.0 - rise * rise))))
		for dx in range(-half_width, half_width + 1):
			var y := CORE_CENTER_Y - h
			set_tile(tile_x + dx, y, Tile.AIR)
	# 每次到达都保证落脚处存在；其余已挖岩层保持原状。
	set_tile(tile_x, CORE_CENTER_Y, Tile.CORE)
	queue_redraw()

# ═════════════════════ 周期地形生成（架构决定 ①） ═════════════════════

func _make_noise(s: int) -> void:
	# ⚠️ 频率怎么定 —— 这是「圆采样」最容易踩的坑
	#
	# 噪声是在「半径 CIRCLE_R 的圆」上采样的，圆的周长 = 2π·R ≈ 402 个单位。
	# 若 frequency = f，那么绕星球一圈大约有 402·f 个起伏。
	#   f = 0.018  →  约 7 个起伏（每约 70 格一个山丘）  ← 我们想要的
	#   f = 0.9    →  约 360 个起伏（每 1.4 格一个）    ← 退化成锯齿噪声
	# 频率给高了，相邻两列就完全不相关，地形会变成随机锯齿而不是山丘。
	_n_height = FastNoiseLite.new()
	_n_height.seed = s
	_n_height.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_height.frequency = 0.018
	_n_height.fractal_octaves = 4        # 叠几层细节。注意：每层仍在同一个圆上采样，周期依然成立
	_n_height.fractal_gain = 0.5

	# 洞穴：同样受圆周长限制，y 轴乘系数把洞穴「拉长」成管道而不是圆球
	_n_cave = FastNoiseLite.new()
	_n_cave.seed = s + 1337
	_n_cave.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_cave.frequency = 0.05
	_n_cave.fractal_octaves = 3
	_n_cave.fractal_gain = 0.5

	# 矿脉
	_n_ore = FastNoiseLite.new()
	_n_ore.seed = s + 4242
	_n_ore.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_ore.frequency = 0.09
	_n_ore.fractal_octaves = 2
	_n_ore.fractal_gain = 0.5

func sample_height_noise(x: int) -> float:
	## 地表高度噪声的采样。x 可以取任意整数（包括 WORLD_W 和负数）。
	##
	## ★ 这是整个「环形世界」的关键一行 ★
	## 把 x 映射成角度 θ，在半径为 CIRCLE_R 的圆上取点：
	##     θ = 2π · x / WORLD_W
	##     (cos θ, sin θ) 绕完一整圈天然回到起点，
	## 所以 x = 0 和 x = WORLD_W 的采样点完全重合 → 噪声值相同 → 地形无缝。
	var theta := TAU * float(x) / float(WORLD_W)
	return _n_height.get_noise_2d(cos(theta) * CIRCLE_R, sin(theta) * CIRCLE_R)

func sample_cave_noise(x: int, y: float) -> float:
	## 洞穴噪声：需要「X 方向周期、Y 方向自由」。
	## 做法是拿 3D 噪声在「圆柱面」上采样 —— 圆负责周期，高度负责变化。
	var theta := TAU * float(x) / float(WORLD_W)
	return _n_cave.get_noise_3d(cos(theta) * CIRCLE_R, sin(theta) * CIRCLE_R, y)

func sample_ore_noise(x: int, y: float) -> float:
	var theta := TAU * float(x) / float(WORLD_W)
	return _n_ore.get_noise_3d(cos(theta) * CIRCLE_R, sin(theta) * CIRCLE_R, y)

func generate(s: int) -> void:
	_core_landing_columns.clear()
	_make_noise(s)
	_tiles.resize(WORLD_W * STORAGE_H)
	_tiles.fill(Tile.AIR)
	surface_y.resize(WORLD_W)

	const HEIGHT_AMP := 15.0      # 起伏幅度
	const SOIL_DEPTH := 5         # 表土层厚度

	for x in WORLD_W:
		var h := sample_height_noise(x) * HEIGHT_AMP
		var sy: int = SURFACE_BASE + int(round(h))
		sy = clampi(sy, 8, CORE_ROCK_TOP - 20)
		surface_y[x] = sy

		for y in STORAGE_H:
			var t: int = Tile.AIR

			if y >= CORE_SUBSTRATE_TOP:
				t = Tile.CORE                                 # 球心以下是可挖的实体岩层
			elif y >= CORE_CAVITY_TOP:
				t = Tile.AIR                                      # 地心空腔：球心就在这片空洞里
			elif y >= CORE_ROCK_TOP:
				t = Tile.CORE                                     # 地核岩（可挖穿，这是通往对跖点的唯一路）
			elif y < sy:
				t = Tile.AIR                                      # 天空
			elif y < sy + SOIL_DEPTH:
				# 高处（山峰）结冰，其余是红壤 —— 呼应「极冠」的设定
				t = Tile.ICE if sy < SURFACE_BASE - 8 and y < sy + 2 else Tile.REGOLITH
			else:
				var cave := sample_cave_noise(x, float(y) * 1.5)
				if cave > 0.35 and y > sy + 7:
					t = Tile.AIR                                  # 洞穴
				else:
					t = Tile.DEEP if y > WORLD_H * 0.62 else Tile.ROCK
					var ore := sample_ore_noise(x, float(y))
					if ore > 0.45:
						t = Tile.ORE_IRON
					elif ore < -0.50:
						t = Tile.ORE_SILICON

			_tiles[_idx(x, y)] = t

	queue_redraw()

# ═════════════════════ 球心与对跖点 ═════════════════════

func antipode_x(x: int) -> int:
	## 对跖点（地球上叫对跖点，火星上一样）：
	## 从这一列一直往下挖穿球心，会从世界的哪一列冒出来。
	##
	## 这不是 hack，是真几何：球面上相隔 180° 的两点，
	## 换成矩形坐标就是 x + 半圈。所以 WORLD_W 必须是偶数。
	return wrap_x(x + WORLD_W / 2)

func core_center_px() -> float:
	## 球心线的像素 y。玩家的中心越过这条线，就算穿过了星球中心。
	return float(CORE_CENTER_Y * TILE)

func is_past_core_center(y_px: float) -> bool:
	return y_px > core_center_px()

func is_core_tile(x: int, y: int) -> bool:
	return get_tile(x, y) == Tile.CORE

# ═════════════════════ 挖掘 / 放置 ═════════════════════

func break_tile(x: int, y: int) -> Array:
	## 挖掉一格。成功返回 [资源名, 数量]，失败返回 []。
	var t := get_tile(x, y)
	if t == Tile.AIR or t == Tile.BEDROCK:
		return []
	set_tile(x, y, Tile.AIR)
	queue_redraw()
	return YIELD.get(t, [])

func place_tile(x: int, y: int, t: int) -> bool:
	## 放一格。只能放在空气上，且不能放在地核里。
	if y < 0 or y >= STORAGE_H:
		return false
	if get_tile(x, y) != Tile.AIR:
		return false
	set_tile(x, y, t)
	queue_redraw()
	return true

func world_to_tile(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / TILE)), int(floor(depth_y(p.y) / TILE)))

# ═════════════════════ 环绕渲染（架构决定 ③） ═════════════════════

func _process(_delta: float) -> void:
	# 原型阶段：每帧重绘。可见格子大约 1000~2000 个，draw_rect 会被合批，开销可忽略。
	# 以后要优化的话，可以只在「摄像机跨越了格子边界」或「世界被改动」时才重绘。
	_ambience_time += _delta
	queue_redraw()

func _draw() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return

	var half := get_viewport_rect().size * 0.5 / cam.zoom
	var camera_center := cam.get_screen_center_position()
	var center := Vector2(camera_center.x, depth_y(camera_center.y))

	# 用「视口对角线的一半」而不是宽高的一半。
	# 平时这样会多画一点（无所谓，draw_rect 会被合批），
	# 但穿越球心时摄像机会旋转，用宽高一半会在四角露出黑边。
	var r := half.length()

	if _transition_active:
		var weights := core_transition_weights()
		_draw_region(center, r, 0, weights.x)
		# 目标半球提前投影到球心另一侧；只换绘制坐标，不挪动世界数据。
		draw_set_transform(Vector2(0.0, core_center_px() * 2.0), 0.0, Vector2(1.0, -1.0))
		_draw_region(Vector2(center.x, core_center_px() * 2.0 - center.y), r,
			_transition_tile_shift, weights.y)
		draw_set_transform(Vector2.ZERO)
	else:
		_draw_region(center, r, 0, 1.0)

func _draw_region(center: Vector2, r: float, tile_shift: int, opacity: float) -> void:
	if opacity <= 0.0:
		return
	_draw_core_ambience(center, r, tile_shift, opacity)
	var x0 := int(floor((center.x - r) / TILE)) - 1
	var x1 := int(ceil((center.x + r) / TILE)) + 1
	var y0 := maxi(0, int(floor((center.y - r) / TILE)) - 1)
	var y1 := mini(STORAGE_H - 1, int(ceil((center.y + r) / TILE)) + 1)

	for ty in range(y0, y1 + 1):
		for tx in range(x0, x1 + 1):
			# ★ 查数据用「环绕坐标」
			var sample_x := wrap_x(tx + tile_shift)
			var t: int = _tiles[_idx(sample_x, ty)]
			if t == Tile.AIR:
				continue
			# ★ 画图用「展开坐标」—— tx 可以是负数，也可以超过 WORLD_W，
			#   画面照样连续。这就是整个环形渲染的全部秘密：不需要任何接缝分支。
			var shade: Color = COLORS[t]
			shade.a = opacity
			var tile_rect := Rect2(tx * TILE, ty * TILE, TILE, TILE)
			draw_rect(tile_rect, shade)
			# 深部岩石的细裂纹给转动提供参照，避免空腔像一张纯色背景。
			if t == Tile.CORE and posmod(sample_x * 13 + ty * 7, 5) == 0:
				var crack := Vector2(tx * TILE + 3.0, ty * TILE + 5.0)
				draw_line(crack, crack + Vector2(8.0, 4.0), Color(0.20, 0.07, 0.09, opacity * 0.45))

func _draw_core_ambience(center: Vector2, r: float, tile_shift: int, opacity: float) -> void:
	# 深部尘雾和暖色反光固定在岩室中，随镜头转动产生连续的空间参照。
	var top := maxf(float(CORE_ROCK_TOP * TILE), center.y - r)
	var bottom := minf(float(STORAGE_PX_H), center.y + r)
	if bottom <= top:
		return
	for y in range(int(floor(top / 32.0)), int(ceil(bottom / 32.0))):
		var depth := clampf((y * 32.0 - CORE_ROCK_TOP * TILE) / 320.0, 0.0, 1.0)
		draw_rect(Rect2(center.x - r, y * 32.0, r * 2.0, 32.0),
			Color(0.22, 0.10, 0.075, (0.07 + depth * 0.07) * opacity))
	for gy in range(int(floor(top / 48.0)), int(ceil(bottom / 48.0))):
		for gx in range(int(floor((center.x - r) / 64.0)), int(ceil((center.x + r) / 64.0))):
			var seed_x := posmod(gx + tile_shift / 4, WORLD_W / 4)
			var seed_value := float(posmod(seed_x * 73 + gy * 37, 997))
			var dust := Vector2(gx * 64.0 + 12.0 + fmod(seed_value, 41.0),
				gy * 48.0 + 10.0 + fmod(seed_value * 3.0, 27.0))
			dust += Vector2(sin(_ambience_time * 0.22 + seed_value) * 2.0,
				cos(_ambience_time * 0.17 + seed_value) * 1.5)
			draw_circle(dust, 0.8, Color(0.60, 0.40, 0.28, opacity * 0.22))

# ═════════════════════ 便捷查询 ═════════════════════

func surface_at(x: int) -> int:
	return surface_y[wrap_x(x)]

func surface_top_px(x: int) -> float:
	## 该列地表最高处的像素 y（用来把玩家放到地面上）
	return float(surface_at(x) * TILE)
