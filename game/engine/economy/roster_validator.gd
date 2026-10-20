class_name RosterValidator
extends RefCounted
## The host's check of every roster entry at match start (docs/design/lobby_loadout_economy.md section 5.3): parts the
## mode forbids are stripped from the entry's "slot" snapshot and its legacy keys, logged as NetLog "loadout_stripped";
## the start is never blocked. Ownership is not checked here (profiles are held by their players, C8).


## Strips every roster entry of `roster` {peer: entry} to what `settings` allows. Returns [{peer, dropped: [text]}] for
## the entries that changed.
static func apply(roster: Dictionary, settings: Dictionary) -> Array:
	var ctx := LoadoutContext.make_for(settings, LoadoutContext.ROLE_BOT)
	var changed := []
	for peer in roster:
		var entry: Dictionary = roster[peer]
		if not entry.get("slot") is Dictionary:
			continue
		var slot := CharacterSlot.make_from_snapshot(entry.slot)
		if slot.make_blocks(ctx).is_empty():
			continue
		var resolved := slot.make_resolved(ctx, ctx.unlocks)
		entry.merge(resolved.slot.make_roster_fields(ctx), true)
		changed.append({"peer": peer, "dropped": resolved.dropped})
		NetLog.write("loadout_stripped", "peer %s '%s': %s" % [str(peer), str(entry.get("name", "?")), "; ".join(PackedStringArray(resolved.dropped))])
	return changed
