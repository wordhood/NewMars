extends SceneTree
## 转场连续性回归；加 --capture 可在图形渲染器下输出关键帧。

var scene
var world
var player
var cam: Camera2D
var passed := 0
var failed := 0
var capture := false
var capture_dir := "/tmp/newmars-smooth-preview"

func _initialize() -> void:
	capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("_run")

func _check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("  ✅  ", label)
	else:
		failed += 1
		print("  ❌  ", label)

func _screen_point(p: Vector2) -> Vector2:
	return (p - cam.global_position).rotated(-cam.global_rotation) * cam.zoom

func _target_screen_point(target_x: int) -> Vector2:
	var data_point := Vector2((target_x + 0.5) * RegolithWorld.TILE,
		(RegolithWorld.CORE_CENTER_Y - RegolithWorld.CORE_CHAMBER_HEIGHT - 0.5) * RegolithWorld.TILE)
	if world._transition_active:
		data_point.x -= world._transition_tile_shift * RegolithWorld.TILE
		data_point.y = world.core_center_px() * 2.0 - data_point.y
	return _screen_point(world.to_global(data_point))

func _target_body_clear() -> bool:
	for x in [-player.HALF.x, player.HALF.x]:
		for y in [-player.HALF.y - 3.0, player.HALF.y]:
			var point: Vector2 = world.to_local(player.to_global(Vector2(x, y)))
			point.x += world._transition_tile_shift * RegolithWorld.TILE
			point.y = world.core_center_px() * 2.0 - point.y
			if world.is_solid(int(floor(point.x / RegolithWorld.TILE)), int(floor(point.y / RegolithWorld.TILE))):
				return false
	return true

func _capture_frame(label: String) -> void:
	if not capture:
		return
	cam.force_update_scroll()
	await process_frame
	await RenderingServer.frame_post_draw
	var frame := root.get_texture().get_image()
	var path := capture_dir.path_join(label + ".png")
	_check("关键帧已输出：" + label, frame.save_png(path) == OK)

func _run() -> void:
	if capture:
		DirAccess.make_dir_recursive_absolute(capture_dir)
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.set_process(false)
	world = scene.get_node("World")
	player = scene.get_node("Player")
	cam = scene.get_node("Player/Camera2D")
	player.set_physics_process(false)
	world.set_process(false)
	world._ambience_time = 9.5
	print("\n══════════ NewMars · 转场连续性测试 ══════════")
	var center: float = world.core_center_px()
	var extent := float(RegolithWorld.CORE_TRANSITION_TILES * RegolithWorld.TILE)
	player.position = Vector2(200 * RegolithWorld.TILE + 4.0, center - extent - 32.0)
	player.velocity = Vector2(0.0, 90.0)
	scene._update_core_approach(0.2)
	_check("过渡带外不提前旋转", absf(cam.global_rotation) < 0.001)
	player.position.y = center - extent * 0.5
	scene._update_core_approach(0.2)
	_check("接近球心时已开始渐进转向", cam.global_rotation > 0.01 and cam.global_rotation < scene.CORE_APPROACH_TILT)
	_check("提前转向不会提前触发穿越", not scene.is_crossing())
	var approach_angle: float = cam.global_rotation
	player.velocity.y = -90.0
	for i in 10:
		scene._update_core_approach(0.1)
	_check("离开过渡带会平滑恢复视角", absf(cam.global_rotation) < approach_angle * 0.05)
	player.position.y = center
	player.velocity.y = 90.0
	for i in 20:
		scene._update_core_approach(0.1)
	player.position = Vector2(200 * RegolithWorld.TILE + 4.0, world.core_center_px())
	player.velocity = Vector2(10.0, 90.0)
	scene._begin_gravity_flip()
	var target_x: int = world.antipode_x(200)
	_check("转场开始前已准备目的地岩室", world.get_tile(target_x, RegolithWorld.CORE_CENTER_Y - RegolithWorld.CORE_CHAMBER_HEIGHT - 1) == RegolithWorld.Tile.CORE)
	_check("地心洞室足够宽敞", world.get_tile(target_x + 3, RegolithWorld.CORE_CENTER_Y - 1) == RegolithWorld.Tile.AIR)
	_check("第一帧保留入口位置", is_equal_approx(player.position.x, 200 * RegolithWorld.TILE + 4.0))
	_check("初始仅显示入口半球", world.core_transition_weights().is_equal_approx(Vector2(1.0, 0.0)))
	await _capture_frame("00-entry")
	var max_camera_step := 0.0
	var max_body_step := 0.0
	var max_target_step := 0.0
	var max_robot_step := 0.0
	var previous_cam: float = cam.global_rotation
	var previous_body: float = player.global_rotation
	var previous_target := _target_screen_point(target_x)
	var previous_corner := _screen_point(player.to_global(Vector2(7.0, 11.0)))
	var previous_position: Vector2 = player.position
	var moved_before_finish := false
	var body_kept_clear := true
	for i in range(1, 121):
		scene._run_gravity_flip(scene.FLIP_TIME / 120.0)
		if world._transition_active and world.core_transition_weights().y > 0.10:
			body_kept_clear = body_kept_clear and _target_body_clear()
		var target_screen := _target_screen_point(target_x)
		var robot_corner := _screen_point(player.to_global(Vector2(7.0, 11.0)))
		max_camera_step = maxf(max_camera_step, absf(angle_difference(previous_cam, cam.global_rotation)))
		max_body_step = maxf(max_body_step, absf(angle_difference(previous_body, player.global_rotation)))
		max_target_step = maxf(max_target_step, previous_target.distance_to(target_screen))
		max_robot_step = maxf(max_robot_step, previous_corner.distance_to(robot_corner))
		if i < 100 and player.position.distance_to(previous_position) > 0.001:
			moved_before_finish = true
		previous_cam = cam.global_rotation
		previous_body = player.global_rotation
		previous_target = target_screen
		previous_corner = robot_corner
		previous_position = player.position
		if i == 30:
			_check("旋转中目的地已开始显露", world.core_transition_weights().y > 0.0)
			await _capture_frame("01-quarter")
		elif i == 60:
			_check("中段两侧岩层共同可见", world.core_transition_weights().x > 0.0 and world.core_transition_weights().y > 0.0)
			_check("中段车体已连续转向", absf(angle_difference(player.rotation, 0.0)) > 0.5)
			_check("中段镜头只有轻微拉远", cam.zoom.x > 0.94 and cam.zoom.x < 1.0)
			await _capture_frame("02-half")
		elif i == 90:
			await _capture_frame("03-three-quarter")
	# 补偿累计浮点误差，不让极小余量使状态保留在转场中。
	if scene.is_crossing():
		scene._run_gravity_flip(0.00001)
	_check("转场结束恢复控制", not scene.is_crossing() and player.is_physics_processing())
	player.set_physics_process(false)
	_check("车体不会一直冻结到最后一帧", moved_before_finish)
	_check("镜头逐帧连续，没有角度跳变", max_camera_step < 0.06)
	_check("车体逐帧连续，没有瞬间掉头", max_body_step < 0.07)
	_check("目的地岩层屏幕位置连续，包括最终换半球", max_target_step < 5.0)
	_check("机器人轮廓的屏幕位置连续", max_robot_step < 1.0)
	_check("车体转向时与可见岩层保持净空", body_kept_clear)
	_check("最终镜头保持半圈", absf(angle_difference(cam.global_rotation, PI)) < 0.001)
	_check("最终缩放精确恢复", cam.zoom.is_equal_approx(Vector2.ONE))
	_check("最终关闭预览图层，避免重复绘制", not world._transition_active)
	_check("机器人已接触落脚处", player.on_floor and player.velocity == Vector2.ZERO)
	_check("履带缓冲已触发", player._landing_age >= 0.0)
	_check("缓冲不会移动碰撞和摄像机节点", cam.position == Vector2.ZERO and player.scale == Vector2.ONE)
	await _capture_frame("04-arrival")
	# 一帧跨过整个动画及反向穿越，也必须正确清理状态。
	player.position.y = world.core_center_px()
	scene._begin_gravity_flip()
	scene._run_gravity_flip(scene.FLIP_TIME * 2.0)
	_check("低帧率时仍能完整结束", not scene.is_crossing() and not world._transition_active)
	_check("再次穿越镜头角度正确", absf(angle_difference(cam.global_rotation, TAU)) < 0.001)
	_check("再次穿越依然落脚且重力朝向球心", player.on_floor and player.gravity_acceleration() > 0.0)
	print("\n通过 %d    失败 %d\n" % [passed, failed])
	quit(1 if failed > 0 else 0)
