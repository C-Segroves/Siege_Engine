class_name LocalProfileAuthority
extends ProfileAuthority
## The profile of the pilot on this machine, read from and saved to his own file. A peer other than the local one is
## paid over the network (EconomyNet), so only the local pilot's file is ever touched here.

var pilot := ""


func _init(pilot_name := "") -> void:
	pilot = pilot_name


func make_profile(_peer: int) -> OperatorProfile:
	return OperatorProfile.load_for(pilot)


func apply_award(peer: int, award: Dictionary) -> void:
	var p := make_profile(peer)
	p.apply_award(award)
	p.save()
