# Renders every roster still used by compose_promo.py into media/stills/roster/ (needs GODOT set).
cd "$(dirname "$0")"
r(){ python run_still.py "$@"; }
r bd vehicles "BATTLEDROME  1995" "Arena duelists" 8
r es2 vehicles "EARTHSIEGE 2  1996" "Hercs and Cybrids of the Cybrid war" 7
r starsiege vehicles "STARSIEGE  1999" "Hercs, Cybrids, tanks and flyers" 8
r tribes vehicles "STARSIEGE: TRIBES  1998" "Scouts and armoured personnel carriers" 7
r tribes infantry "STARSIEGE: TRIBES  1998" "Light, medium and heavy armour" 7
r tribes2 vehicles "TRIBES 2  2001" "Flyers, tanks, bikes and wheeled transports" 7
r tribes2 infantry "TRIBES 2  2001" "Light, medium and heavy armour" 7
r tribes_aa vehicles "TRIBES: AERIAL ASSAULT  2002" "Vehicles" 7
r tribes_aa infantry "TRIBES: AERIAL ASSAULT  2002" "Light, medium and heavy armour" 7
r tribes_v infantry "TRIBES: VENGEANCE  2004" "Armour" 7
r mix vehicles "EVERY GAME, ONE ROSTER" "Hercs, Cybrids, flyers, bikes and soldiers from all eight games" 9 everything_mix
