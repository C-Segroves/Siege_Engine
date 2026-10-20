class_name TribesPresentation
extends RefCounted
## The engine calls of the Tribes / Tribes 2 training scripts that only drive the original's presentation (HUD
## icons and flashing, GUI dialogs and modes, key maps, cameras, sounds without a line of text, skins, sensor
## masks, bot chatter) or the original AI's internals: the remake accepts them and does nothing (docs/formats/
## tribes.md section 8, tribes2.md section 8). A call not listed here and not implemented is a script error.

const TRIBES_FUNCTIONS := ["client::setguimode", "control::setvisible", "player::setdamageflash",
	"player::applyimpulse", "player::trigger", "player::blowup", "player::setanimation", "player::dropitem",
	"gamebase::startfadeout", "gamebase::startfadein", "gamebase::throw", "gamebase::setrechargerate",
	"gamebase::activateshield", "client::setcontrolobject", "playvoice", "playsound", "rbplay", "rbstop",
	"player::setmountobject", "setcdtrack"]

const TRIBES2_FUNCTIONS := ["settargetskin", "settargetvoice", "settargetnevervismask", "settargetalwaysvismask",
	"settargetsensorgroup", "playtargetaudio", "serverplay2d", "serverplay3d", "commandtoclient", "commandtoserver",
	"addmessagecallback", "togglefirstperson", "togglecamera", "togglehelptext", "hidehudhack", "cursoron",
	"cursoroff", "aisystemenabled", "aimissionend", "aiinit", "aiinitobjectives", "freeclienttarget", "freetarget",
	"aiclearobjective", "aiunassignclient", "escapefromgame", "debriefcontinue", "loadmission", "messageteam",
	"servercmdcannedchat", "flashsomethings", "aiplayanimsound", "setsensorgroupcount", "clearcenterprint",
	"clearbottomprint", "centerprintall", "bottomprintall", "aichooseobjective", "setteamsensorgroup", "createtarget"]

## Methods of objects that exist only on the original's client side (GUI controls, key maps, the canvas, the
## server connection) and presentation methods of mission objects.
const TRIBES2_METHODS := ["setvisible", "setactive", "push", "pop", "bindcmd", "blockbind", "bind", "pushdialog",
	"popdialog", "cursoron", "cursoroff", "setblackout", "setwhiteout", "setactiveweapon", "add", "clear",
	"setvalue", "settext", "scrolltotop", "opencategory", "setdamageflash", "setactionthread", "playthread",
	"stopthread", "scopetoclient", "setfrozenstate", "setmovestate", "setwhiteout", "settime", "play2d", "play3d",
	"setpilotpitchrange", "aimat", "settargetobject", "setengagetarget", "clearstep", "stop", "clientdetected",
	"setinventoryhuditem", "setinventoryhudclearall", "setweightfreq", "setmonitorfreq", "setweight", "preload",
	"setskin", "setenergylevel", "setrechargerate", "setdamagestate", "playaudio", "stopaudio",
	"setselectedcategory", "setscopealways", "setcontrolobject", "registerentrytype", "resetfields",
	"settransformcompound", "clearbackpackicon"]
## Of those, the ones that answer a query: their result.
const TRIBES2_QUERY_RESULTS := {"isvisible": 1, "isawake": 0, "iscursoron": 0, "getbinding": "", "isactive": 1}
