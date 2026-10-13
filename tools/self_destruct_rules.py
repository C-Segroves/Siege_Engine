"""Self-destruct ("spider") rules of the Earthsiege 1 / 2 Spider (Arachnitron), read from the simulators.

The unit's own DAT has the switch (0x4a self_destruct) and its contact radius (0x6e); everything else is code:

Earthsiege 1 (DBSIM.EXE, VA = file offset - 0x48FD)
  0x10407  the Spider's pilot class: think 0x18320, per-tick move 0x18278
  0x18320  think: every 0x2710 ms re-picks its target (0xddf4 flags 6); steers straight at it at full throttle
           (0x12038); a cycle of two states on a timer: walk rand(4000)+8000 ms (0x1849a / 0x184ab), then
           lunge rand(1500)+3000 ms (0x184dc / 0x184ed) in which it moves two extra steps per tick (0x183f7 and
           0x1843a call the move step again: three steps per tick)
  0x18278  move step: moves (0x14148 / 0x144dc), then contact (0x14174: another unit closer than both contact
           radii, or a base, 0x375c) or a unit that ran into it (flag +0xab, set by vtable slot 0x6c 0x118e4)
           detonates: 0x1f75c(damage 2000 0x182ba, radius 3000 0x182b5, centre) and 32000 (0x182e3) on each of
           its own components
  0x1f75c  every unit whose centre is within the radius: 0x13a7c(unit, attacker 0, radius, centre, damage)
  0x13a7c  each existing component (28) with chance 0x802 / 0x1000 (0x13acd) takes damage x (radius - d) / radius,
           d = distance from the centre to that component's point (vtable slot 0x5c 0x15990: its COL sphere in its
           part), straight to the component (0x13250): shields are not asked
  0x13919  killed any other way: no blast (only the death of a self-destructing unit, pilot state 0xaf514)

Earthsiege 2 (DBSIM.EXE 1.0, PE): the same pilot (think 0x41e570, move 0x41e488, the same constants at 0x41e509 /
  0x41e50e / 0x41e52e / 0x41e6e3 / 0x41e6f5 / 0x41e71d / 0x41e72f / 0x41e5df), but the blast 0x426a20 skips the
  Spider itself, reaches units whose hull (centre distance minus the unit's radius, slot 0x5c) is within the radius,
  and 0x4187d0 first lets the shield bank facing the blast absorb the damage (0x413c68), then splashes what is left
  over the components with the same chance (0x41885a) and fall-off.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fx_deaths import CodeCheck, ES1_EXE, ES2_EXE, _pe_offset  # noqa: E402

ES1_EVIDENCE = {
    0x182B5: ('68b80b0000', 'detonation: blast radius'),
    0x182BA: ('68d0070000', 'detonation: blast damage'),
    0x182E3: ('68007d0000', 'detonation: damage on each own component'),
    0x13ACD: ('3d02080000', 'blast: component hit when rand & 0xfff < this'),
    0x1849A: ('68a00f0000', 'walk time: random span'),
    0x184AB: ('6681c6401f', 'walk time: base'),
    0x184DC: ('68dc050000', 'lunge time: random span'),
    0x184ED: ('6681c6b80b', 'lunge time: base'),
    0x18395: ('c7430110270000', 'target re-picked after this many ms'),
    0x183F6: ('57e87cfeffff', 'lunge: extra move step 1'),
    0x18439: ('57e839feffff', 'lunge: extra move step 2'),
}
ES2_EVIDENCE = {
    0x41E50E: ('68b80b0000', 'detonation: blast radius'),
    0x41E509: ('68d0070000', 'detonation: blast damage'),
    0x41E52E: ('68007d0000', 'detonation: damage on each own component'),
    0x41885A: ('3d02080000', 'blast: component hit when rand & 0xfff < this'),
    0x41E6E3: ('68a00f0000', 'walk time: random span'),
    0x41E6F5: ('6605401f', 'walk time: base'),
    0x41E71D: ('68dc050000', 'lunge time: random span'),
    0x41E72F: ('6605b80b', 'lunge time: base'),
    0x41E5DF: ('c7460110270000', 'target re-picked after this many ms'),
    0x426A57: ('3bf3', 'blast: skips the unit that detonated'),
    0x426A74: ('2bc2', 'blast: reach = centre distance minus the unit radius'),
    0x418822: ('e841b4ffff', 'blast: the facing shield bank absorbs first'),
}
RANDOM_RANGE = 0x1000
LUNGE_STEPS = 3      # the engine's move step plus the think's two extra ones


def _u16(check, va):
    return check.u16(va)


def make_rules(game):
    """The rules dict for `game` ('es1' / 'es2'), or {} when its simulator is not installed."""
    if game == 'es1':
        check = CodeCheck(ES1_EXE[0], lambda va: va + ES1_EXE[1], ES1_EVIDENCE)
        at = {'radius': 0x182B6, 'damage': 0x182BB, 'self': 0x182E4, 'chance': 0x13ACE, 'walk_span': 0x1849B,
              'walk_base': 0x184AE, 'lunge_span': 0x184DD, 'lunge_base': 0x184F0, 'retarget': 0x18398}
        es2 = False
    else:
        check = CodeCheck(ES2_EXE, _pe_offset(ES2_EXE), ES2_EVIDENCE)
        at = {'radius': 0x41E50F, 'damage': 0x41E50A, 'self': 0x41E52F, 'chance': 0x41885B, 'walk_span': 0x41E6E4,
              'walk_base': 0x41E6F7, 'lunge_span': 0x41E71E, 'lunge_base': 0x41E731, 'retarget': 0x41E5E2}
        es2 = True
    if check.data is None:
        return {}
    v = {k: _u16(check, va) for k, va in at.items()}
    return {
        'blast_radius': v['radius'], 'blast_damage': v['damage'], 'self_damage': v['self'],
        'component_hit_chance': v['chance'] / RANDOM_RANGE,
        'walk_ms': [v['walk_base'], v['walk_base'] + v['walk_span']],
        'lunge_ms': [v['lunge_base'], v['lunge_base'] + v['lunge_span']],
        'lunge_steps': LUNGE_STEPS, 'retarget_ms': v['retarget'],
        'shields_absorb': es2, 'skips_self': es2, 'reach_adds_unit_radius': es2,
        'source': 'DBSIM.EXE %s (tools/self_destruct_rules.py)' % ('1.0 0x41e488 / 0x426a20' if es2 else '0x18278 / 0x1f75c'),
    }


def apply_to_units(units, game):
    """Adds the rules to every unit whose DAT sets self_destruct."""
    rules = None
    for u in units.values():
        if isinstance(u, dict) and u.get('self_destruct'):
            rules = make_rules(game) if rules is None else rules
            if rules:
                u['self_destruct_rules'] = rules


if __name__ == '__main__':
    import json
    for g in ('es1', 'es2'):
        print(g, json.dumps(make_rules(g)))
