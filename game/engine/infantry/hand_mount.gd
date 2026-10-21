class_name HandMount
extends RefCounted
## The rotation of a soldier's weapon in his hand.
##   * Tribes 1 and Tribes 2 mount a weapon with its own grip (T2 "mountpoint" node, T1 the shape origin) on the
##     player's mount node and no extra offset or rotation (every T2 ShapeBaseImageData sets offset "0 0 0", every T1
##     weapon ItemImageData mountPoint 0 without mountRotation). The mount node is authored so the weapon points
##     along the body in the root pose (Mount0 / "dummy hand"), and the aim sequences ("looks", "look") swing the
##     arm with the pitch.
##   * The Aerial Assault and Vengeance bodies have no mount data of their own: the importers add a "mount0" node on
##     the hand bone whose axes follow the limb, not the body.
## So the mount is calibrated per body shape: the correction that turns the hand node's root-pose rotation into the
## body's forward (identity for the Tribes 2 bodies, which were authored that way). While the soldier lives the
## weapon follows his aim exactly (the originals' aim sequences pitch the whole arm); dead or seated it stays in
## the hand with the correction.

const ROOT_SEQUENCE := "root"
const ROOT_PHASE := 0.0

static var _corrections := {}


## The rotation, in the hand node's frame, that points a weapon along the body's forward (-Z) when the body
## stands in its root pose.
static func make_rest_correction(body: ShapeInstance, hand_node: int) -> Basis:
	var key := "%s#%d" % [body.shape.get("id", ""), hand_node]
	if not _corrections.has(key):
		_corrections[key] = _make_calibrated(body, hand_node)
	return _corrections[key]


## The rotation, in the hand node's frame, that points a weapon along world basis `aim`.
static func make_aim_rotation(hand: Node3D, aim: Basis) -> Basis:
	return hand.global_basis.orthonormalized().inverse() * aim.orthonormalized()


static func _make_calibrated(body: ShapeInstance, hand_node: int) -> Basis:
	var scratch := ShapeInstance.new()
	scratch.build(body.shape, 0, Packs.default_palette(str(body.shape.get("pack", ""))))
	var correction := Basis.IDENTITY
	if hand_node >= 0 and hand_node < scratch.nodes.size():
		ShapeCycles.pose(scratch, ShapeCycles.find_named(scratch, [ROOT_SEQUENCE]), ROOT_PHASE, false)
		correction = make_chain_basis(scratch, scratch.nodes[hand_node]).inverse()
	scratch.free()
	return correction


## The rotation of `node` in the frame of `root` (its ancestors' rotations multiplied; works outside the scene tree).
static func make_chain_basis(root: Node3D, node: Node3D) -> Basis:
	var basis := Basis.IDENTITY
	var n := node
	while n != null and n != root:
		basis = n.basis.orthonormalized() * basis
		n = n.get_parent() as Node3D
	return basis
