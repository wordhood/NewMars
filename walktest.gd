extends SceneTree
## 场景集成测试：真实半球投影、球心支撑、向心重力和主动向上开挖。

var scene
var player
var world
var cam: Camera2D
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("  ✅  ", label)
	else:
		failed += 1
		print("  ❌  ", label)

func _ticks(count: int) -> void:
	for i in count:
		await physics_frame
		await process_frame

func _wait_for_core() -> bool:
	for i in 700:
		if scene.is_crossing():
			return true
		await _ticks(1)
	return false

func _tile_center(x: int, y: int) -> Vector2:
	return world.to_global(Vector2((x + 0.5) * RegolithWorld.TILE, (y + 0.5) * RegolithWorld.TILE))

func _check_landing(label: String) -> void:
	var center: float = world.core_center_px()
	var logical_y: float = world.depth_y(player.position.y)
	_check(label + "：身体位于球心附近的目标半球内", logical_y < center and center - logical_y < 16.0)
	_check(label + "：履带接触地核地面", player.on_floor)
	_check(label + "：落脚后速度清零", player.velocity == Vector2.ZERO)
	var gravity_screen := Vector2(0.0, player.gravity_acceleration()).rotated(-cam.global_rotation)
	_check(label + "：真实向心重力在画面中朝下", gravity_screen.y > 0.0)
	var surface := Vector2(player.position.x, world.project_y(world.surface_top_px(player.tile_pos().x)))
	var surface_screen: Vector2 = (surface - player.position).rotated(-cam.global_rotation)
	_check(label + "：目标半球地表在头顶", surface_screen.y < 0.0)
	_check(label + "：机器人履带朝向脚下", absf(angle_difference(player.rotation, cam.global_rotation)) < 0.001)

func _run() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	player = scene.get_node("Player")
	world = scene.get_node("World")
	cam = scene.get_node("Player/Camera2D")
	print("\n══════════ NewMars · 球心开挖集成测试 ══════════")
	await _ticks(60)
	_check("出生后站在地表", player.on_floor)
	var start_x: float = player.position.x
	Input.action_press("move_right")
	await _ticks(90)
	Input.action_release("move_right")
	_check("正常向右移动", player.position.x > start_x + 100.0)
	player.spawn_on_surface(RegolithWorld.WORLD_W - 2)
	Input.action_press("move_right")
	await _ticks(80)
	Input.action_release("move_right")
	_check("向右环绕世界", player.position.x < RegolithWorld.WORLD_PX_W * 0.5)
	_check("环绕后落地", player.on_floor)
	player.spawn_on_surface(2)
	Input.action_press("move_left")
	await _ticks(60)
	Input.action_release("move_left")
	_check("向左环绕世界", player.position.x > RegolithWorld.WORLD_PX_W * 0.5)
	_check("向左环绕后落地", player.on_floor)

	player.set_physics_process(false)
	var center: float = world.core_center_px()
	player.position = Vector2(200 * RegolithWorld.TILE + 8.0, center)
	player.velocity = Vector2.ZERO
	_check("球心净重力为零", is_zero_approx(player.gravity_acceleration()))
	player.position.y = center - 40.0
	var near_g: float = player.gravity_acceleration()
	player.position.y = center - 80.0
	_check("靠近球心重力变弱", is_equal_approx(player.gravity_acceleration(), near_g * 2.0))
	player.reset_contact()
	player.set_physics_process(true)
	_check("从入口自然坠落触发穿越", await _wait_for_core())
	if not scene.is_crossing():
		_finish()
		return
	_check("演出暂停在球心", not player.is_physics_processing() and is_equal_approx(player.position.y, center))
	scene._run_gravity_flip(scene.FLIP_TIME * 0.5)
	_check("半圈翻转有中间动画", cam.global_rotation > 0.1 and cam.global_rotation < PI - 0.1)
	scene._run_gravity_flip(scene.FLIP_TIME)
	scene.set_process(false)
	_check("画面停在 180 度", absf(angle_difference(cam.global_rotation, PI)) < 0.001)
	_check("物理已恢复", not scene.is_crossing() and player.is_physics_processing())
	_check("切换到对跖列", player.tile_pos().x == world.antipode_x(200))
	_check("另一半球地形实际位于球心另一侧", world.hemisphere_sign == -1.0 and player.position.y > center)
	_check("球心外的重力指回球心", player.gravity_acceleration() < 0.0)
	_check("HUD 重力箭头朝下", scene._gravity_arrow() == "↓")
	_check_landing("首次到达")
	var resting_y: float = player.position.y
	await _ticks(120)
	_check("不操作时站稳，不会自由漂浮", player.on_floor and absf(player.position.y - resting_y) < 0.1)
	_check("不操作时不会自动升向地表", absf(player.position.y - resting_y) < 0.1)
	_check("落脚处不会连续翻转", scene.core_crossing_count() == 1 and not scene.is_crossing())

	var tx: int = player.tile_pos().x
	var roof_y := RegolithWorld.CORE_CENTER_Y - RegolithWorld.CORE_CHAMBER_HEIGHT - 1
	var roof_point := _tile_center(tx, roof_y)
	_check("渲染坐标可反查到同一岩层格", world.world_to_tile(roof_point) == Vector2i(tx, roof_y))
	var roof_screen: Vector2 = (roof_point - player.position).rotated(-cam.global_rotation)
	_check("可挖岩层就在机器人头顶", roof_screen.y < 0.0 and roof_screen.length() < scene.REACH * RegolithWorld.TILE)
	_check("头顶是目标半球的地核岩", world.get_tile(tx, roof_y) == RegolithWorld.Tile.CORE)
	_check("翻转后的挖掘距离正确", scene._in_reach(Vector2i(tx, roof_y)))
	_check("翻转后能挖掉头顶岩层", scene._try_mine(roof_point))
	_check("挖掘确实修改了目标半球的数据", world.get_tile(tx, roof_y) == RegolithWorld.Tile.AIR)
	_check("获得地核资源", int(scene._stock.get("地核样本", 0)) == 1)
	# 原先的黑色区域现在也要参与真实的坐标、碰撞和方块编辑。
	var lower_y := RegolithWorld.CORE_SUBSTRATE_TOP + 1
	var lower_point := _tile_center(tx, lower_y)
	var lower_screen: Vector2 = (lower_point - player.position).rotated(-cam.global_rotation)
	_check("球心下方确实生成方块", world.get_tile(tx, lower_y) == RegolithWorld.Tile.CORE)
	_check("下方方块出现在画面脚下", lower_screen.y > 0.0)
	_check("下方方块参与碰撞", world.collision_is_solid(tx, int(floor(lower_point.y / RegolithWorld.TILE))))
	_check("下方方块可挖掘", scene._try_mine(lower_point) and world.get_tile(tx, lower_y) == RegolithWorld.Tile.AIR)
	_check("下方方块可重新放置", scene._try_place(lower_point))
	_check("同一位置也能正确放置", scene._try_place(roof_point))
	_check("放置物体参与实际碰撞", world.collision_is_solid(tx, int(floor(roof_point.y / RegolithWorld.TILE))))
	scene._try_mine(roof_point)
	player.set_physics_process(false)
	player.position = Vector2((world.antipode_x(tx) + 0.5) * RegolithWorld.TILE, world.project_y(center - 80.0))
	player.reset_contact()
	_check("空旷空腔没有可攀附岩壁", not player.has_wall_grip())
	Input.action_press("jump")
	Input.action_press("mine")
	player._physics_process(1.0 / 60.0)
	_check("没有岩壁时操作不会凭空飞升", player.velocity.y < 0.0)
	Input.action_release("jump")
	Input.action_release("mine")
	player.position.x = (tx + 0.5) * RegolithWorld.TILE
	player.stand_at_core()
	player.set_physics_process(true)
	await _ticks(1)
	# 放宽的洞室需要先走到侧壁，不能在中央的空中攀升。
	Input.action_press("move_right")
	await _ticks(32)
	Input.action_release("move_right")
	await _ticks(4)
	var climb_tx: int = player.tile_pos().x
	_check("走到洞室侧壁后可以攀附", player.has_wall_grip())
	Input.action_press("jump")
	Input.action_press("mine")
	var climbing_start: float = world.depth_y(player.position.y)
	for i in 90:
		# 挖掉即将碰到的头顶岩层，模拟准星持续指向上方。
		var head_depth: float = world.depth_y(player.position.y) - player.HALF.y
		var next_y := int(floor(head_depth / RegolithWorld.TILE)) - 1
		scene._try_mine(_tile_center(climb_tx, next_y))
		await _ticks(1)
	Input.action_release("mine")
	Input.action_release("jump")
	var climbed: float = climbing_start - world.depth_y(player.position.y)
	_check("玩家主动攀附并向上开挖", climbed > 65.0)
	_check("向上开挖是在克服向心重力", player.gravity_acceleration() < 0.0)
	await _ticks(30)
	_check("松开攀附后受到重力减速", player.velocity.y < player.CLIMB_SPEED)
	await _ticks(300)
	_check("松开后落回球心支撑处", player.on_floor and absf(player.position.y - resting_y) < 0.2)
	_check("头顶挖出的通道仍然存在", world.get_tile(tx, roof_y) == RegolithWorld.Tile.AIR)

	# 横向挖开岩壁，验证翻转后的左右键仍按屏幕方向工作。
	player.position.x = (tx + 0.5) * RegolithWorld.TILE
	player.stand_at_core()
	for dx in range(-2, 3):
		for y in range(RegolithWorld.CORE_CENTER_Y - 2, RegolithWorld.CORE_CENTER_Y):
			world.break_tile(tx + dx, y)
	var old_x: float = player.position.x
	Input.action_press("move_right")
	await _ticks(10)
	Input.action_release("move_right")
	_check("翻转后右键方向仍向画面右侧", player.position.x < old_x - 5.0)
	# 目的地地表也应能正常站立、跳跃和落地，验证整套投影。
	player.spawn_on_surface(tx)
	await _ticks(60)
	_check("另一半球地表可正常站立", player.on_floor)
	var surface_y: float = player.position.y
	Input.action_press("jump")
	await _ticks(8)
	Input.action_release("jump")
	var jump_screen := Vector2(0.0, player.position.y - surface_y).rotated(-cam.global_rotation)
	_check("另一半球跳跃仍朝屏幕上方", jump_screen.y < -10.0)
	await _ticks(100)
	_check("跳跃后受向心重力落回地表", player.on_floor and absf(player.position.y - surface_y) < 0.2)

	# 回到落脚位，挖开脚下可再次穿过球心，下一侧仍能落脚开挖。
	player.position.x = (tx + 0.5) * RegolithWorld.TILE
	player.velocity = Vector2.ZERO
	player.stand_at_core()
	_check("脚下地核可挖", scene._try_mine(_tile_center(tx, RegolithWorld.CORE_CENTER_Y)))
	_check("挖开脚下后可返回另一半球", await _wait_for_core())
	scene._run_gravity_flip(scene.FLIP_TIME)
	_check("第二次穿越计数正确", scene.core_crossing_count() == 2)
	_check("第二次恢复原半球投影", world.hemisphere_sign == 1.0)
	_check("第二次再旋转半圈", absf(angle_difference(cam.global_rotation, TAU)) < 0.001)
	_check_landing("再次到达")
	_check("穿越结束光晕关闭", not player.transit_glow)
	# 再次生成落脚处不能把之前挖出的向上通道填回。
	world.prepare_core_landing(tx)
	_check("重新到达不会填回已挖通道", world.get_tile(tx, roof_y) == RegolithWorld.Tile.AIR)
	_finish()

func _finish() -> void:
	for action in ["move_left", "move_right", "jump", "mine"]:
		Input.action_release(action)
	print("\n通过 %d    失败 %d\n" % [passed, failed])
	quit(1 if failed > 0 else 0)
