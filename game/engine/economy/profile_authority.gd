class_name ProfileAuthority
extends RefCounted
## Who holds the operator profiles and pays credits (docs/design/lobby_loadout_economy.md C8, open question O1). The only
## implementation now is LocalProfileAuthority (each player's machine keeps his own file, the host never verifies
## ownership); a server-side store can replace it behind this interface.


func make_profile(_peer: int) -> OperatorProfile:
	push_error("ProfileAuthority.make_profile: not implemented")
	return OperatorProfile.new()


func apply_award(_peer: int, _award: Dictionary) -> void:
	push_error("ProfileAuthority.apply_award: not implemented")
