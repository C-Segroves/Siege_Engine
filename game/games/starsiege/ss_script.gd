class_name SSScript
extends DarkstarScript
## Interpreter for Starsiege (Darkstar, 1999) mission scripts (.cs): the shared Darkstar script runtime
## (engine/script: DarkstarLexer, DarkstarParser, DarkstarScript) in its Darkstar dialect. Engine functions
## (order, schedule, getObjectId, say, setNavMarker, ...) are forwarded to `host.ss_builtin(name_lower, args)`
## (StarsiegeMissionRuntime -> SSEngineFunctions) and the host reports unknown ones (return null from
## ss_builtin = "not a builtin").
