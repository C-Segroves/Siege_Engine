class_name MineBody
extends StaticBody3D
## The hit body of a mine that can be shot (Battledrome: "the mine also explodes when shot", SIM 0x104b8): a small
## sphere on its own physics layer, which weapon rays and projectiles hit but vehicles walk through.

## Physics layer of mine bodies (vehicles collide with layer 1 only).
const LAYER := 1 << 5
const RADIUS := 0.6

var mine: Projectile


func _init(p_mine: Projectile) -> void:
	mine = p_mine
	name = "MineBody"
	collision_layer = LAYER
	collision_mask = 0
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	col.shape = sphere
	add_child(col)


## Any hit sets the mine off.
func apply_hit(_shield: float, _armor: float, _attacker: Node = null, _pos := Vector3.ZERO) -> void:
	mine.detonate()
