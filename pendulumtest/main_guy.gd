extends CharacterBody2D

# Player movement variables
@export var speed = 200.0
@export var jump_velocity = -400.0
@export var gravity = 980
@export var friction = 0.65  # Ground friction (lower = more slippery)
@export var bounce_factor = 0.05  # How bouncy collisions are (0-1)

# Crosshair variables
@export var crosshair_radius = 100.0
@export var crosshair_rotation_speed = 3.0
var crosshair_angle = 0.0
var crosshair_active = false
var crosshair

# Grappling hook variables
@export var grapple_range = 500.0  # Maximum distance the grapple can reach
@export_flags_2d_physics var grapple_collision_mask = 1  # Physics layers to interact with
@export var rope_pull_speed = 200.0  # Speed to pull up/down the rope
@export var swing_force = 100.0  # Force applied when swinging
@export var swing_damping = 0.999  # Damping for swing momentum
@export var release_boost = 2  # Momentum boost when releasing grapple

# Enhanced ninja rope variables
@export var rope_mid_air_reshoot_enabled = true  # Allow shooting rope again in mid-air
@export var rope_segment_check_distance = 5.0  # Distance between segment checks
@export var rope_max_segments = 8  # Maximum number of rope segments for corners
@export var rope_corner_detection_angle = 0.7  # Angle threshold for corner detection (in radians)
@export var wall_bounce_threshold = 300.0  # Speed threshold for bouncing off walls
@export var rope_bounce_factor = 0.75  # Bounce factor when colliding while on rope (0-1)
@export var min_rope_length = 20.0  # Minimum rope length to prevent extreme behavior
@export var corner_detection_interval = 0.1  # Time interval between corner detection checks (seconds)

# Rope state variables
var grapple_hit = false
var grapple_hit_position = Vector2.ZERO
var grapple_rope_length = 0.0
var grapple_debug_draw = true
var pre_release_velocity = Vector2.ZERO
var just_released_grapple = false
var release_timer = 0.0
var rope_cooldown_timer = 0.0
var rope_cooldown_duration = 0.1  # Time before allowing another rope shot
var rope_segments = []  # Points where rope bends around corners
var rope_was_attached = false  # Track if rope was previously attached
var last_corner_check_time = 0.0  # Timer for corner detection

# Node references
@onready var sprite = $AnimatedSprite2D
@onready var rope_line = $RopeLine if has_node("RopeLine") else _create_rope_line()

# Signals I'm not really using these anywhere, so I could potentially just remove...
signal rope_attached
signal rope_detached

func _ready():
	# Create the crosshair as a child node (THIS COULD ALL BE DONE IN PRELOAD IF YOU PREFER!)
	crosshair = Sprite2D.new()
	crosshair.texture = preload("res://Resources/crosshair_outline_small.png")
	crosshair.visible = false
	add_child(crosshair)

func _create_rope_line():
	# Create a Line2D node for rope visualization if it doesn't exist
	var line = Line2D.new()
	line.name = "RopeLine"
	line.width = 2.0
	line.default_color = Color(0.8, 0.7, 0.2, 1.0)  # Rope-like color
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.antialiased = true
	line.visible = false
	add_child(line)
	return line

func _physics_process(delta):
	# Handle cooldown timer
	if rope_cooldown_timer > 0:
		rope_cooldown_timer -= delta
	
	# Handle post-release momentum state
	if just_released_grapple:
		release_timer += delta
		if release_timer > 0.2:  # Short grace period
			just_released_grapple = false
			release_timer = 0.0
	
	# Apply the appropriate physics depending on state
	if grapple_hit:
		handle_grapple_physics(delta)
		rope_was_attached = true
	else:
		handle_normal_physics(delta)
		
		# Check if we just detached
		if rope_was_attached:
			rope_was_attached = false
			emit_signal("rope_detached")
	
	# Update animations
	update_animations()
	
	# Update rope visuals
	update_rope_visual()
	
	# Draw debug line for grappling hook
	queue_redraw()

func handle_normal_physics(delta):
	# Add gravity
	if not is_on_floor():
		velocity.y += gravity * delta
	else:
		# Apply friction when on ground
		velocity.x *= friction
		
		# Reset vertical momentum when landing (unless we just released grapple)
		if !just_released_grapple:
			velocity.y = 0
	
	# Handle jump when not in aim mode
	if Input.is_action_just_pressed("Jump") and is_on_floor():
		velocity.y = jump_velocity
	
	# Get the horizontal movement direction
	var direction = Input.get_axis("move_left", "move_right")
	
	# Check if Shift is being held down
	var is_shift_held = Input.is_action_pressed("Shift")
	
	# Handle crosshair visibility and activity based on Shift key
	if is_shift_held && !crosshair_active:
		# Activate crosshair when shift is first pressed
		crosshair_active = true
		crosshair.visible = true
		
		# Set initial crosshair angle based on player direction
		if sprite.flip_h:
			crosshair_angle = 3 * PI / 4  # 135 degrees, up and left
		else:
			crosshair_angle = PI / 4  # 45 degrees, up and right
			
		update_crosshair_position()
		
	elif !is_shift_held && crosshair_active && !grapple_hit:
		# Deactivate crosshair when shift is released (only if not grappling)
		crosshair_active = false
		crosshair.visible = false
	
	# Handle movement
	if is_shift_held && crosshair_active:
		# When shift is held and aiming, slow down horizontal movement but don't stop completely
		velocity.x *= 0.95  # Gradual slowdown rather than immediate stop
		
		# Update crosshair position based on direction input
		if abs(direction) > 0.1:
			crosshair_angle += direction * crosshair_rotation_speed * delta
			update_crosshair_position()
			
		# Handle grappling hook when in crosshair mode and pressing Jump
		if Input.is_action_just_pressed("Z") and rope_cooldown_timer <= 0:
			fire_grappling_hook()
	else:
		# Normal movement when not aiming
		if !just_released_grapple:
			# Only apply direct control if not in post-release state
			velocity.x = direction * speed
		else:
			# In post-release state, just apply some influence rather than direct control
			velocity.x += direction * speed * 0.2 * delta
		
		# Update player sprite direction only when moving
		if abs(velocity.x) > 0.1:
			sprite.flip_h = velocity.x < 0
		
		# HedgeWars-style mid-air rope shooting with Jump + Shift combo
		if rope_mid_air_reshoot_enabled and !is_on_floor() and Input.is_action_just_pressed("Z") and rope_cooldown_timer <= 0:
			# Instant aim up when pressing shift in air
			crosshair_active = true
			crosshair.visible = true
			
			# If falling, aim slightly upward; if rising, aim more upward
			if velocity.y > 0:
				# Falling - aim 30° upward in direction we're facing
				crosshair_angle = PI/6 if !sprite.flip_h else 5*PI/6
			else:
				# Rising - aim 60° upward in direction we're facing
				crosshair_angle = PI/3 if !sprite.flip_h else 2*PI/3
				
			update_crosshair_position()
			
			# Auto-fire the grapple immediately when in mid-air
			fire_grappling_hook()
	
	# Move and handle collisions
	move_and_slide()
	
	# Apply wall bounce with HedgeWars physics when hitting walls at high speed
	if is_on_wall() and abs(velocity.x) > wall_bounce_threshold:
		# Get the normal of the wall we hit
		var collision_normal = get_wall_normal()
		if collision_normal:
			# Apply stronger bounce with momentum conservation like HedgeWars
			velocity = velocity.bounce(collision_normal) * 0.6
			# Add slight upward boost on strong impacts
			if velocity.y > 0:
				velocity.y *= 0.7

func handle_grapple_physics(delta):
	# Hide crosshair while grappling
	crosshair.visible = false
	
	# Get the last rope segment (attachment point or last corner)
	var attachment_point = get_current_attachment_point()
	
	# Vector from player to attachment point
	var to_attachment = attachment_point - global_position
	
	# Current distance to attachment point
	var current_distance = to_attachment.length()
	
	# Normalize the vector for direction
	var attachment_direction = to_attachment.normalized()
	
	# Store pre-release velocity for momentum conservation
	pre_release_velocity = velocity
	
	# Handle rope length changes with up/down keys
	if Input.is_action_pressed("move_up"):
		# Pull up on the rope (reduce length)
		grapple_rope_length = max(min_rope_length, grapple_rope_length - rope_pull_speed * delta)
	elif Input.is_action_pressed("move_down"):
		# Extend the rope (increase length)
		grapple_rope_length = min(grapple_range, grapple_rope_length + rope_pull_speed * delta)
	
	# Apply reduced gravity while swinging (HedgeWars style)
	velocity.y += gravity * delta * 0.7
	
	# Handle left/right swinging
	var swing_input = Input.get_axis("move_left", "move_right")
	if abs(swing_input) > 0.1:
		# Apply swing force perpendicular to rope
		var perpendicular = Vector2(-attachment_direction.y, attachment_direction.x)
		velocity += perpendicular * swing_input * swing_force * delta
		
		# Visual feedback - update player sprite direction when swinging
		if swing_input < 0:
			sprite.flip_h = true
		elif swing_input > 0:
			sprite.flip_h = false
	
	# Store position before movement for distance calculation
	var pre_move_pos = global_position
	
	# Apply movement
	var collision = move_and_slide()
	
	# Enhanced collision response while on rope (Worms-style bounce)
	if collision:
		for i in get_slide_collision_count():
			var collision_info = get_slide_collision(i)
			if collision_info:
				# Calculate bounce with enhanced factor for rope physics
				var normal = collision_info.get_normal()
				
				# Calculate impact velocity
				var impact_velocity = velocity.length()
				
				# Adjust bounce factor based on rope length - shorter rope = more bounce energy
				# This creates the effect of bouncing faster as you get closer to the attachment
				var length_factor = clamp(1.0 - (grapple_rope_length / grapple_range), 0.2, 0.9)
				var dynamic_bounce = rope_bounce_factor + (length_factor * 0.3)
				
				# Apply bounce with worms-style physics
				velocity = velocity.bounce(normal) * dynamic_bounce
				
				# Add slight upward boost on impacts
				if velocity.y > 0 and impact_velocity > 100:
					velocity.y *= 0.8

	# Check for rope segments/corners after significant movement
	var time_now = Time.get_ticks_msec() / 1000.0
	if time_now - last_corner_check_time > corner_detection_interval:
		check_for_rope_obstruction()
		last_corner_check_time = time_now
	
	# Get updated attachment point after potential new segments
	attachment_point = get_current_attachment_point()
	to_attachment = attachment_point - global_position
	current_distance = to_attachment.length()
	attachment_direction = to_attachment.normalized()
	
	# Post-movement rope constraint
	if current_distance > grapple_rope_length:
		# Rope constraint - move player to be within rope length
		global_position += (current_distance - grapple_rope_length) * attachment_direction
		
		# Calculate the new tangential velocity
		var velocity_on_rope = velocity.project(attachment_direction)
		var velocity_perpendicular = velocity - velocity_on_rope
		
		# Apply swing damping
		velocity = velocity_perpendicular * swing_damping

	# Cancel grapple if Jump is pressed again
	if Input.is_action_just_pressed("Jump"):
		release_grapple()
	
func check_for_rope_obstruction():
	# Skip if no grapple
	if !grapple_hit:
		return
	
	# Get space state for raycasting
	var space_state = get_world_2d().direct_space_state
	
	# Case 1: No segments yet - check direct line from player to grapple point
	if rope_segments.size() <= 1:
		# First, make sure the original grapple point is in the segments array
		if rope_segments.size() == 0:
			rope_segments.append(grapple_hit_position)
		
		# Setup raycast parameters from player to attachment point
		var query = PhysicsRayQueryParameters2D.create(
			global_position, 
			grapple_hit_position,
			grapple_collision_mask
		)
		query.exclude = [self]
		query.collide_with_areas = false  # Only collide with bodies
		
		# Check for obstacles
		var result = space_state.intersect_ray(query)
		
		if result and result.position.distance_to(grapple_hit_position) > 5.0:
			# Found an obstruction that's not too close to the grapple point
			if rope_segments.size() < rope_max_segments:
				# Add this as a new segment
				# Make sure we don't already have this point
				var too_close = false
				for segment in rope_segments:
					if result.position.distance_to(segment) < 10.0:
						too_close = true
						break
				
				if not too_close:
					rope_segments.insert(0, result.position)
	else:
		# We have segments - check from player to the nearest segment
		var nearest_segment = rope_segments[0]
		
		var query = PhysicsRayQueryParameters2D.create(
			global_position, 
			nearest_segment,
			grapple_collision_mask
		)
		query.exclude = [self]
		query.collide_with_areas = false
		
		var result = space_state.intersect_ray(query)
		
		if result and result.position.distance_to(nearest_segment) > 5.0:
			# Found a new corner that's not too close to existing segment
			if rope_segments.size() < rope_max_segments:
				# Make sure we don't already have this point
				var too_close = false
				for segment in rope_segments:
					if result.position.distance_to(segment) < 10.0:
						too_close = true
						break
				
				if not too_close:
					rope_segments.insert(0, result.position)
		else:
			# No obstruction to nearest segment, see if we can remove segments
			if rope_segments.size() >= 2:
				# Try to check if we can reach the segment after the nearest one
				if rope_segments.size() > 1:
					var next_segment = rope_segments[1]
					
					query = PhysicsRayQueryParameters2D.create(
						global_position, 
						next_segment,
						grapple_collision_mask
					)
					query.exclude = [self]
					query.collide_with_areas = false
					
					result = space_state.intersect_ray(query)
					
					if !result:
						# We can reach the next segment directly, so remove the nearest one
						rope_segments.remove_at(0)
	
	# Ensure rope segments are in order from player to grapple point
	# This is important for proper rope rendering and physics
	if rope_segments.size() > 1:
		# Last segment should always be the grapple point
		if rope_segments[rope_segments.size() - 1] != grapple_hit_position:
			# Remove any segments after the grapple point
			while rope_segments.size() > 0 and rope_segments[rope_segments.size() - 1] != grapple_hit_position:
				rope_segments.pop_back()
			
			# If we somehow lost the grapple point, add it back
			if rope_segments.size() == 0 or rope_segments[rope_segments.size() - 1] != grapple_hit_position:
				rope_segments.append(grapple_hit_position)

func get_current_attachment_point():
	# Return the appropriate attachment point based on rope segments
	if rope_segments.size() == 0:
		return grapple_hit_position
	elif rope_segments.size() == 1:
		# If only one segment, it's the grapple hit position
		return rope_segments[0]
	else:
		# Return the nearest segment as the current attachment point
		return rope_segments[0] # I'm pretty sure this is incorrect lol -- shouldn't it be [1] or w/e?

func release_grapple():
	# Store velocity for conservation of momentum
	var release_velocity = velocity
	
	# Calculate release speed - higher speed means bigger boost
	var release_speed = release_velocity.length()
	
	# Add a boost in the direction of travel (HedgeWars-style momentum conservation)
	var speed_boost = release_velocity.normalized() * release_speed * release_boost
	
	# Add a slight upward boost for better jumps
	speed_boost.y -= abs(speed_boost.x) * 0.5
	
	# Apply the final velocity with HedgeWars-style momentum preservation
	velocity = release_velocity + speed_boost
	
	# Mark as having just released for physics handling
	just_released_grapple = true
	release_timer = 0.0
	
	# Add cooldown before next rope shot
	rope_cooldown_timer = rope_cooldown_duration
	
	# Clear grapple state
	grapple_hit = false
	grapple_hit_position = Vector2.ZERO
	rope_segments.clear()
	
	# Hide rope line
	rope_line.visible = false
	
	# Signal that rope was detached
	emit_signal("rope_detached")

func update_animations():
	if grapple_hit:
		sprite.play("swing")  # You'll need to create this animation
	else:
		if is_on_floor():
			if abs(velocity.x) > 0.1:
				sprite.play("run")
			else:
				sprite.play("idle")
		else:
			if velocity.y < 0:
				sprite.play("jump")
			else:
				sprite.play("fall")

func has_animation(anim_name):
	# Helper function to check if animation exists
	return sprite.sprite_frames != null and sprite.sprite_frames.has_animation(anim_name)

func update_crosshair_position():
	# Calculate the new position
	var crosshair_position = Vector2(
		cos(crosshair_angle) * crosshair_radius,
		sin(crosshair_angle) * crosshair_radius
	)
	
	# Update the crosshair position (relative to the player)
	crosshair.position = crosshair_position

func update_rope_visual():
	# Update rope line visuals if grapple is active
	if grapple_hit:
		rope_line.visible = true
		rope_line.clear_points()
		
		# Add player position as first point (in local coordinates)
		rope_line.add_point(Vector2.ZERO)
		
		# Add all rope segments in order from player to grapple point
		if rope_segments.size() > 0:
			# We're using a reverse order now, so iterate from first segment (closest to player)
			# to the last segment (grapple point)
			for segment in rope_segments:
				rope_line.add_point(to_local(segment))
		else:
			# Direct line to grapple point if no segments
			rope_line.add_point(to_local(grapple_hit_position))
	else:
		rope_line.visible = false

func fire_grappling_hook():
	# Calculate direction and target position from crosshair angle
	var direction = Vector2(cos(crosshair_angle), sin(crosshair_angle))
	var target_position = global_position + direction * grapple_range
	
	# Create space state for raycast
	var space_state = get_world_2d().direct_space_state
	
	# Set up raycast parameters
	var query = PhysicsRayQueryParameters2D.create(
		global_position,
		target_position,
		grapple_collision_mask
	)
	
	# Ignore the player's own collision
	query.exclude = [self]
	query.collide_with_areas = false  # Only collide with solid objects
	
	# Perform the raycast
	var result = space_state.intersect_ray(query)
	
	# Check if raycast hit something
	if result:
		grapple_hit = true
		grapple_hit_position = result.position
		grapple_rope_length = global_position.distance_to(grapple_hit_position)
		
		# Ensure minimum rope length to prevent physics glitches
		grapple_rope_length = max(grapple_rope_length, min_rope_length)
		
		# Hide crosshair when grapple is attached
		crosshair.visible = false
		
		# Clear existing segments and start with the hit point
		rope_segments.clear()
		rope_segments.append(grapple_hit_position)
		
		# Reset corner detection timer
		last_corner_check_time = Time.get_ticks_msec() / 1000.0
		
		# Update rope visuals
		update_rope_visual()
		
		# Emit signal
		emit_signal("rope_attached")
		
		print("Grapple hit at: ", result.position)
		print("Initial rope length: ", grapple_rope_length)
	else:
		grapple_hit = false
		grapple_hit_position = Vector2.ZERO
		# Play miss sound
		#play_sound("rope_release", -5)
		print("Grapple missed")

func _draw():
	# Draw debug line for grappling hook
	if grapple_debug_draw and grapple_hit:
		# Draw main grapple point
		var local_hit_pos = to_local(grapple_hit_position)
		draw_circle(local_hit_pos, 5.0, Color.YELLOW)
		
		# Draw rope segments
		if rope_segments.size() > 0:
			# Draw from player to first segment
			var prev_point = Vector2.ZERO
			
			# Draw all segments
			for segment in rope_segments:
				var local_segment = to_local(segment)
				draw_line(prev_point, local_segment, Color.RED, 2.0)
				draw_circle(local_segment, 3.0, Color.ORANGE)
				prev_point = local_segment
		else:
			# Draw direct line if no segments
			draw_line(Vector2.ZERO, local_hit_pos, Color.RED, 2.0)
