class_name SiegePhase
extends RefCounted
## The phases of the Cybrid siege, as the host runs them and every peer shows them (CybridSiege state "phase").

## The hidden chain waits to be woken.
const ARMED := 0
## The chain is complete: the broadcast and the countdown to the Cybrids' arrival.
const WARNING := 1
## The waves, the closing exfils and the shrinking safe area.
const SIEGE := 2
## The final time has passed: nothing but the Cybrids survives.
const ENDED := 3
