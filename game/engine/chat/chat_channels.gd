class_name ChatChannels
## The chat's channels (docs/formats/cockpit.md section 9.6): what kind of line it is, how it is labelled and
## coloured in the chat panel, and which ones a player may type into.
##   system  the game's own messages (objective, hints, kills, pickups, "Nav point reached")
##   radio   the campaigns' speakers: wingmen, commanders, bases (with the speaker's name or callsign)
##   all     what a player says to everybody
##   team    what a player says to his own team

const SYSTEM := "system"
const RADIO := "radio"
const ALL := "all"
const TEAM := "team"
## Every channel in the order of the panel's filter tabs.
const ORDER := [SYSTEM, RADIO, ALL, TEAM]
## The channels a player types into, in the order chat_channel_next cycles them.
const SPOKEN := [ALL, TEAM]
const LABELS := {SYSTEM: "System", RADIO: "Radio", ALL: "All", TEAM: "Team"}
const COLORS := {
	SYSTEM: Color(1.0, 0.82, 0.35),
	RADIO: Color(0.55, 0.9, 1.0),
	ALL: Color(0.92, 0.95, 0.92),
	TEAM: Color(0.5, 1.0, 0.55),
}
## The sender's name is drawn a little brighter than the text.
const SENDER_LIGHTEN := 0.25


static func is_known(channel: String) -> bool:
	return ORDER.has(channel)


static func color_of(channel: String) -> Color:
	return COLORS.get(channel, COLORS[SYSTEM])


static func label_of(channel: String) -> String:
	return str(LABELS.get(channel, channel.capitalize()))


## The spoken channel after `channel` (all -> team -> all).
static func make_next_spoken(channel: String) -> String:
	var i := SPOKEN.find(channel)
	return SPOKEN[(i + 1) % SPOKEN.size()]
