"""Battledrome in-sim voices, decoded from SIM.EXE (docs/formats/battledrome.md section 8, audio_video.md section 3).

    python tools/bd_voices.py            # prints the decoded tables

What plays when (SIM.EXE VAs; one sim time unit = 4 ms, docs/formats/units.md section 4):
  0x78998  sound table: 43 x {u32 kind, char *path}; kind 1 effect, 0 music, 2 voice.  Voices are switched by
           Preferences VOICES (SoundManager +0x10a, checked in the player 0x2828c).
  0x13b74  Referee state machine (jump table 0x767ec).  Victory terms met (0x13fa8) -> state 1 at once:
           0x13c85 ENDRND1 (both Hercs frozen), next state after 0x200 units; 0x13cfd AREAN01, after 0x200;
           0x13d6d AREAN11 when the winner is the local player's Herc [0x954ac] (0x2508: always this
           machine's own Herc) else AREAN12, after 0x300 the sim ends (0x13dde).
  0x149b0  MessageManager::set(message): table 0x76830 (32 x 18 bytes {u32 text, s32 sound, u8 queued,
           u8 urgent, s32 repeat, s32 last}).  A message repeats only after `repeat` units; within 0x200 units
           of the previous message a non-urgent one is queued (queued = 1, drained by 0x14978) or dropped;
           the voice ducks the other sounds to half (0x2821c).  SHIELDS LOW also restarts SHIELDS DEPLETED's
           repeat timer and vice versa (0x14ab8 / 0x14ac4).
  0x8057   shield warning, every shield update of a Herc with a HUD while the match runs: shield * 256 / SG
           points (0x808c) in 1..25 -> message 1 SHIELDS DEPLETED, in 26..63 -> message 2 SHIELDS LOW.
Every constant is read from the user's SIM.EXE; the instruction bytes around it are checked first.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bd_hud  # noqa: E402

MS_PER_UNIT = 4                       # sim clock [0x954b4] (units.md section 4)
SOUND_TABLE = 0x78998
SOUND_COUNT = 43
SOUND_KINDS = {0: 'music', 1: 'effect', 2: 'voice'}
NO_SOUND = -1

# (VA of the instruction, expected opcode bytes, operand size): operand follows the opcode bytes
END_ROUND_VOICE = (0x13c85, b'\x6a', 1)          # push 0x18 (ENDRND1)
ANNOUNCE_VOICE = (0x13cfd, b'\x6a', 1)           # push 0x19 (AREAN01)
WINNER_VOICE = (0x13d6d, b'\xb9', 4)             # mov ecx, 0x1a (AREAN11: the local player won)
LOSER_VOICE = (0x13d74, b'\xb9', 4)              # mov ecx, 0x1b (AREAN12)
STATE_DELAYS = [(0x13cee, b'\xc7\x87\x01\x01\x00\x00', 4),   # after ENDRND1
                (0x13d15, b'\xc7\x87\x01\x01\x00\x00', 4),   # after AREAN01
                (0x13d91, b'\xc7\x87\x01\x01\x00\x00', 4)]   # after the winner's voice, then the sim ends
SHIELD_DEPLETED_MAX = (0x8057, b'\x83\xfe', 1)   # cmp esi, 0x19
SHIELD_LOW_MAX = (0x806e, b'\x83\xfe', 1)        # cmp esi, 0x3f
MESSAGE_SPACING = (0x14a3b, b'\x81\xf9', 4)      # cmp ecx, 0x200
SHIELD_SCALE = 256                               # 0x80ba: shl eax, 8 before the divide by SG points
SHIELDS_DEPLETED, SHIELDS_LOW = 1, 2             # message numbers pushed at 0x805c / 0x8073


def operand(img, site):
    """The immediate operand of the instruction at `site`, after checking its opcode bytes."""
    va, opcode, size = site
    p = va + bd_hud.VA_BASE
    if img.data[p:p + len(opcode)] != opcode:
        raise ValueError('SIM.EXE: unexpected code at 0x%x (not the 1994-11-18 build?)' % va)
    return int.from_bytes(img.data[p + len(opcode):p + len(opcode) + size], 'little', signed=True)


def seconds(units):
    return round(units * MS_PER_UNIT / 1000.0, 6)


def read_sounds(img):
    """Sound id -> {kind, stem} (the RAW / SFX / HMP file name, lower case, no extension)."""
    out = []
    for i in range(SOUND_COUNT):
        kind = img.u32(SOUND_TABLE + 8 * i)
        path = img.cstr(img.u32(SOUND_TABLE + 8 * i + 4))
        out.append({'kind': SOUND_KINDS.get(kind, str(kind)), 'stem': os.path.splitext(path.split('\\')[-1])[0].lower()})
    return out


def stem_of(sounds, sound_id):
    return sounds[sound_id]['stem'] if 0 <= sound_id < len(sounds) else ''


def read_messages(img, sounds):
    """MessageManager table with each message's voice resolved to a file stem ("" = text only)."""
    out = []
    for m in bd_hud.read_message_table(img):
        out.append({'text': m['text'], 'voice': stem_of(sounds, m['sound']) if m['sound'] != NO_SOUND else '',
                    'queued': bool(m['flag']), 'urgent': m['urgent'], 'repeat_s': seconds(m['repeat_ticks'])})
    return out


def read_end_of_round(img, sounds):
    delays = [seconds(operand(img, s)) for s in STATE_DELAYS]
    return {'voices': [stem_of(sounds, operand(img, END_ROUND_VOICE)), stem_of(sounds, operand(img, ANNOUNCE_VOICE))],
            'winner_voice': stem_of(sounds, operand(img, WINNER_VOICE)),
            'loser_voice': stem_of(sounds, operand(img, LOSER_VOICE)),
            'delays_s': delays}


def read_shield_warning(img):
    return {'scale': SHIELD_SCALE, 'depleted_max': operand(img, SHIELD_DEPLETED_MAX),
            'low_max': operand(img, SHIELD_LOW_MAX), 'depleted_message': SHIELDS_DEPLETED,
            'low_message': SHIELDS_LOW, 'shared_repeat_timer': True}


def make_voices(img):
    sounds = read_sounds(img)
    return {'sounds': sounds, 'messages': read_messages(img, sounds),
            'message_spacing_s': seconds(operand(img, MESSAGE_SPACING)),
            'end_of_round': read_end_of_round(img, sounds), 'shield_warning': read_shield_warning(img),
            'source': 'SIM.EXE, decoded by tools/bd_voices.py'}


def main():
    print(json.dumps(make_voices(bd_hud.load_image()), indent=1))


if __name__ == '__main__':
    main()
