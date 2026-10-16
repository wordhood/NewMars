extends SceneTree
## 架构自检 —— 不启动窗口，直接把「三条架构决定」验一遍
##
## 运行：
##   ~/Downloads/Godot.app/Contents/MacOS/Godot --headless \
##       --path ~/Workspace/NewMars --script res://selftest.gd
##
## 它验证的不是「代码能不能跑通」，而是「设计是不是真的成立」。

var _pass := 0
var _fail := 0

func _initialize() -> void:
	print("")
	print("══════════ NewMars · 架构自检 ══════════")
	_test_input_map()
	_test_wrap_x()
	_test_wrap_delta()
	_test_periodic_terrain()
	_test_seam_data_consistency()
	_test_bounds()
	_test_break_and_place()
	_test_core_and_antipode()
	_report_world_composition()
	print("─────────────────────────────────────────")
	print("  通过 %d    失败 %d" % [_pass, _fail])
	print("═════════════════════════════════════════")
	print("")
	quit(1 if _fail > 0 else 0)

# ─────────────────────────────────────────────

func _ok(title: String, detail: String = "") -> void:
	_pass += 1
	print("  ✅  %s%s" % [title, ("   [" + detail + "]") if detail != "" else ""])

func _bad(title: String, detail: String = "") -> void:
	_fail += 1
	print("  ❌  %s%s" % [title, ("   [" + detail + "]") if detail != "" else ""])

func _check(title: String, cond: bool, detail: String = "") -> void:
	if cond: _ok(title, detail)
	else: _bad(title, detail)

# ── 1. Input Map ──

func _test_input_map() -> void:
	print("\n[1] Input Map —— 按键不硬编码，以后加手柄/触屏只加映射")
	var need := ["move_left", "move_right", "jump", "mine", "place", "cycle_block"]
	var missing: Array[String] = []
	for a in need:
		if not InputMap.has_action(a):
			missing.append(a)
	_check("6 个输入动作全部注册", missing.is_empty(),
		"缺失: " + str(missing) if not missing.is_empty() else "全部就位")

# ── 2. 坐标环绕 ──

func _test_wrap_x() -> void:
	print("\n[2] wrap_x —— 左右走永远走不到尽头")
	var w := RegolithWorld.new()
	var W := RegolithWorld.WORLD_W

	_check("wrap_x(0) == 0", w.wrap_x(0) == 0, "得到 %d" % w.wrap_x(0))
	_check("wrap_x(-1) == W-1", w.wrap_x(-1) == W - 1, "得到 %d，期望 %d" % [w.wrap_x(-1), W - 1])
	_check("wrap_x(W) == 0", w.wrap_x(W) == 0, "得到 %d" % w.wrap_x(W))
	_check("wrap_x(-W-3) == W-3", w.wrap_x(-W - 3) == W - 3, "得到 %d" % w.wrap_x(-W - 3))
	_check("wrap_x(1000000) 落在 [0,W)", w.wrap_x(1000000) >= 0 and w.wrap_x(1000000) < W,
		"得到 %d" % w.wrap_x(1000000))

func _test_wrap_delta() -> void:
	print("\n[3] wrap_delta_x —— 距离要按「环形最短路径」算")
	var w := RegolithWorld.new()
	var W := RegolithWorld.WORLD_W
	# 站在 x=2，目标在 x=W-3=509。展开差是 +507，但绕过去只隔 5 格。
	# 返回的是「带符号的最短差值」：509 在 2 的左边 → 得 -5。判断远近要取绝对值。
	var d := w.wrap_delta_x(float(W - 3) - 2.0)
	_check("跨接缝取最短路径（带符号）", is_equal_approx(d, -5.0), "得到 %.1f，期望 -5.0" % d)
	_check("跨接缝取最短路径（绝对值）", is_equal_approx(absf(d), 5.0), "得到 %.1f" % absf(d))
	_check("近距离不变", is_equal_approx(w.wrap_delta_x(7.0), 7.0))
	_check("结果恒在 [-W/2, W/2]", absf(w.wrap_delta_x(123456.0)) <= float(W) * 0.5)

# ── 4. ★ 最重要的一项：周期地形真的无缝吗？ ──

func _test_periodic_terrain() -> void:
	print("\n[4] ★ 周期地形 —— 首尾真的接得上吗？")
	var w := RegolithWorld.new()
	w.generate(12345)
	var W := RegolithWorld.WORLD_W

	# (a) 直接验证采样点：x 和 x+W 必须落在圆上同一个点
	var a := w.sample_height_noise(0)
	var b := w.sample_height_noise(W)
	_check("采样周期：noise(0) == noise(W)", absf(a - b) < 1e-6, "%.9f vs %.9f" % [a, b])

	# (b) 接缝落差 vs 内部相邻落差 vs 随机两列落差
	var sum_neighbor := 0
	for x in range(W - 1):
		sum_neighbor += absi(w.surface_y[x + 1] - w.surface_y[x])
	var avg_neighbor := float(sum_neighbor) / float(W - 1)

	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var sum_random := 0
	for i in 800:
		var p := rng.randi_range(0, W - 1)
		var q := rng.randi_range(0, W - 1)
		sum_random += absi(w.surface_y[p] - w.surface_y[q])
	var avg_random := float(sum_random) / 800.0

	var seam := absi(w.surface_y[0] - w.surface_y[W - 1])

	print("      · 接缝落差         = %d 格" % seam)
	print("      · 相邻列平均落差   = %.2f 格" % avg_neighbor)
	print("      · 随机两列平均落差 = %.2f 格" % avg_random)

	_check("接缝落差 ≈ 相邻列落差（不是随机列）",
		float(seam) <= maxf(avg_neighbor * 3.0, 2.0),
		"seam=%d, 阈值=%.2f" % [seam, maxf(avg_neighbor * 3.0, 2.0)])

	# 对照组：如果接缝表现得像"随机两列"，就说明周期性是假的
	_check("对照组有效：随机落差确实远大于相邻落差",
		avg_random > avg_neighbor * 3.0,
		"随机 %.2f  >  相邻 %.2f × 3" % [avg_random, avg_neighbor])

func _test_seam_data_consistency() -> void:
	print("\n[5] 接缝数据一致性 —— 越界列必须等于另一端的列")
	var w := RegolithWorld.new()
	w.generate(999)
	var W := RegolithWorld.WORLD_W
	var bad := 0
	for y in RegolithWorld.STORAGE_H:
		if w.get_tile(-1, y) != w.get_tile(W - 1, y):
			bad += 1
		if w.get_tile(W, y) != w.get_tile(0, y):
			bad += 1
	_check("第 -1 列 == 第 W-1 列，第 W 列 == 第 0 列", bad == 0, "不一致 %d 处" % bad)

# ── 6. 边界 ──

func _test_bounds() -> void:
	print("\n[6] 世界边界行为")
	var w := RegolithWorld.new()
	w.generate(2024)
	_check("地表以上 = 空气", w.get_tile(10, -5) == RegolithWorld.Tile.AIR)
	_check("扩展岩层之外是不可穿越的边界",
		w.get_tile(10, RegolithWorld.STORAGE_H + 3) == RegolithWorld.Tile.BEDROCK)
	_check("最终边界不可挖", w.break_tile(10, RegolithWorld.STORAGE_H).is_empty())
	_check("原来的底边以下也有真实方块", w.get_tile(10, RegolithWorld.WORLD_H + 3) == RegolithWorld.Tile.CORE)
	_check("球心下方岩层可挖", not w.break_tile(10, RegolithWorld.WORLD_H + 3).is_empty())

	var sy: int = w.surface_at(100)
	_check("地表那一格是实心的", w.is_solid(100, sy), "x=100 地表 y=%d" % sy)
	_check("地表上方一格是空气", not w.is_solid(100, sy - 1), "x=100 y=%d" % (sy - 1))

# ── 7. 挖掘 / 放置 ──

func _test_break_and_place() -> void:
	print("\n[7] 挖掘与放置")
	var w := RegolithWorld.new()
	w.generate(555)
	var x := 77
	var y: int = w.surface_at(x) + 1

	var before := w.get_tile(x, y)
	var got: Array = w.break_tile(x, y)
	_check("挖掉后变成空气", w.get_tile(x, y) == RegolithWorld.Tile.AIR, "原方块 id=%d" % before)
	_check("挖矿有产出", not got.is_empty(), str(got))
	_check("挖空气无产出", w.break_tile(x, y).is_empty())

	var placed := w.place_tile(x, y, RegolithWorld.Tile.ICE)
	_check("可以放回方块", placed and w.get_tile(x, y) == RegolithWorld.Tile.ICE)
	_check("不能覆盖已有方块", not w.place_tile(x, y, RegolithWorld.Tile.ROCK))

	var W := RegolithWorld.WORLD_W
	var yy: int = w.surface_at(W - 1) + 1
	w.break_tile(-1, yy)
	_check("跨接缝挖掘：break(-1,y) 命中的是第 W-1 列",
		w.get_tile(W - 1, yy) == RegolithWorld.Tile.AIR)

# ── 9. ★ 球心与对跖点 —— 挖穿星球之后到底从哪出来？ ──

func _test_core_and_antipode() -> void:
	print("\n[9] ★ 球心与对跖点 —— 挖穿星球之后从哪出来？")
	var w := RegolithWorld.new()
	w.generate(31337)
	var W := RegolithWorld.WORLD_W

	# (a) 对跖点数学：球面上相隔 180° 的两点，在矩形坐标里差半个世界
	_check("对跖点 = x + 半个世界",
		w.antipode_x(0) == W / 2
			and w.antipode_x(100) == 100 + W / 2
			and w.antipode_x(W - 1) == W / 2 - 1,
		"antipode(0)=%d  antipode(100)=%d  antipode(%d)=%d"
			% [w.antipode_x(0), w.antipode_x(100), W - 1, w.antipode_x(W - 1)])

	_check("对跖两次回到原地（对合性）",
		w.antipode_x(w.antipode_x(77)) == 77,
		"77 → %d → %d" % [w.antipode_x(77), w.antipode_x(w.antipode_x(77))])

	# (b) 地核结构：岩层必须可挖，空腔必须是空的
	var core_rock := 0
	var cavity := 0
	for x in W:
		for y in range(RegolithWorld.CORE_ROCK_TOP, RegolithWorld.CORE_CAVITY_TOP):
			if w.get_tile(x, y) == RegolithWorld.Tile.CORE:
				core_rock += 1
		for y in range(RegolithWorld.CORE_CAVITY_TOP, RegolithWorld.CORE_SUBSTRATE_TOP):
			if w.get_tile(x, y) == RegolithWorld.Tile.AIR:
				cavity += 1

	var rock_total := W * (RegolithWorld.CORE_CAVITY_TOP - RegolithWorld.CORE_ROCK_TOP)
	var cavity_total := W * (RegolithWorld.CORE_SUBSTRATE_TOP - RegolithWorld.CORE_CAVITY_TOP)

	_check("地核岩层是可挖的 CORE，不是不可挖的 BEDROCK",
		core_rock == rock_total, "%d / %d 格" % [core_rock, rock_total])
	_check("地核岩能挖出东西",
		not w.break_tile(10, RegolithWorld.CORE_ROCK_TOP + 1).is_empty())
	_check("地心空腔是空的", cavity == cavity_total, "%d / %d 格" % [cavity, cavity_total])

	# (c) 球心线必须在空腔内部 —— 否则玩家根本掉不过去
	_check("球心线落在空腔范围内",
		RegolithWorld.CORE_CENTER_Y > RegolithWorld.CORE_CAVITY_TOP
			and RegolithWorld.CORE_CENTER_Y < RegolithWorld.CORE_SUBSTRATE_TOP,
		"空腔 %d .. %d，球心线 %d"
			% [RegolithWorld.CORE_CAVITY_TOP, RegolithWorld.CORE_SUBSTRATE_TOP - 1, RegolithWorld.CORE_CENTER_Y])

	var free_fall: int = RegolithWorld.CORE_CENTER_Y - RegolithWorld.CORE_CAVITY_TOP
	_check("球心线上方有足够坠落空间（>= 5 格）", free_fall >= 5, "%d 格" % free_fall)

	# (d) 判定函数
	_check("越过球心线才判定为「已穿越」",
		not w.is_past_core_center(w.core_center_px() - 1.0)
			and w.is_past_core_center(w.core_center_px() + 1.0),
		"球心线像素 y=%.1f" % w.core_center_px())

	# (e) 世界的虚拟底：球心线以下仍要有东西接住（以防万一没触发）
	_check("世界底部之外仍是不可穿越的边界",
		w.get_tile(10, RegolithWorld.STORAGE_H + 2) == RegolithWorld.Tile.BEDROCK)

# ── 8. 世界成分报告（调参用）──

func _report_world_composition() -> void:
	print("\n[8] 世界成分报告 —— 用来看地形调参是否合理")
	var w := RegolithWorld.new()
	w.generate(20260813)
	var W := RegolithWorld.WORLD_W
	var H := RegolithWorld.STORAGE_H

	var counts := {}
	for y in H:
		for x in W:
			var t: int = w.get_tile(x, y)
			counts[t] = counts.get(t, 0) + 1

	var total := W * H
	var names := {
		RegolithWorld.Tile.AIR: "空气",
		RegolithWorld.Tile.REGOLITH: "红壤",
		RegolithWorld.Tile.ROCK: "玄武岩",
		RegolithWorld.Tile.DEEP: "深层岩",
		RegolithWorld.Tile.ICE: "水冰",
		RegolithWorld.Tile.ORE_IRON: "铁矿",
		RegolithWorld.Tile.ORE_SILICON: "硅矿",
		RegolithWorld.Tile.CORE: "地核岩",
		RegolithWorld.Tile.BEDROCK: "边界基岩",
	}
	for k in [RegolithWorld.Tile.AIR, RegolithWorld.Tile.REGOLITH, RegolithWorld.Tile.ROCK,
			RegolithWorld.Tile.DEEP, RegolithWorld.Tile.ICE, RegolithWorld.Tile.ORE_IRON,
			RegolithWorld.Tile.ORE_SILICON, RegolithWorld.Tile.CORE, RegolithWorld.Tile.BEDROCK]:
		var c: int = counts.get(k, 0)
		print("      %-10s %6d   %5.1f%%" % [names[k], c, float(c) / float(total) * 100.0])

	# 地下空洞（真正的洞穴，不含天空）
	var cave_tiles := 0
	var underground := 0
	for x in W:
		var sy: int = w.surface_y[x]
		for y in range(sy, H):
			underground += 1
			if w.get_tile(x, y) == RegolithWorld.Tile.AIR:
				cave_tiles += 1
	print("      地下空洞占比   %.2f%%" % (float(cave_tiles) / float(underground) * 100.0))

	# 地表起伏：相邻列平均落差应该很小（说明是平缓山丘，不是锯齿）
	var sum_jump := 0
	var max_jump := 0
	for x in range(W - 1):
		var j := absi(w.surface_y[x + 1] - w.surface_y[x])
		sum_jump += j
		max_jump = maxi(max_jump, j)
	var avg_jump := float(sum_jump) / float(W - 1)

	var lo := 9999
	var hi := -9999
	for x in W:
		lo = mini(lo, w.surface_y[x])
		hi = maxi(hi, w.surface_y[x])

	print("      地表相邻落差   平均 %.2f 格，最大 %d 格" % [avg_jump, max_jump])
	print("      地表高度范围   y = %d ~ %d（跨度 %d 格 = %d 像素）"
		% [lo, hi, hi - lo, (hi - lo) * RegolithWorld.TILE])

	_check("地形是平缓山丘而非锯齿（相邻列平均落差 < 1.5 格）", avg_jump < 1.5,
		"平均 %.2f 格" % avg_jump)
	_check("地形有足够起伏（高度跨度 > 15 格）", hi - lo > 15, "跨度 %d 格" % (hi - lo))
	_check("地下有洞穴", cave_tiles > 1000, "%d 格" % cave_tiles)
	_check("两种矿脉都生成了",
		counts.get(RegolithWorld.Tile.ORE_IRON, 0) > 200
			and counts.get(RegolithWorld.Tile.ORE_SILICON, 0) > 200,
		"铁 %d，硅 %d" % [counts.get(RegolithWorld.Tile.ORE_IRON, 0),
			counts.get(RegolithWorld.Tile.ORE_SILICON, 0)])
