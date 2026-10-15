"""Tribes: Vengeance (2004, PC, Unreal Engine 2.5) - recognised only; importing is not supported yet
(see docs/formats/tribes_vengeance.md).

The user's copy is a zip holding an Inno Setup installer: setup.exe + setup-1.bin + setup-2.bin (disk slices,
magic "idska32"). identify_zip() in siege_import.py asks this module about the zip's member names.
"""

GAME = {
    'game': 'tribes_vengeance', 'pack': 'tribes_vengeance', 'name': 'Tribes: Vengeance', 'discs': 1, 'supported': False,
    'pack_json': {'name': 'Tribes: Vengeance', 'engine': 'unreal_2_5'},
}
ZIP_MEMBERS = ('setup.exe', 'setup-1.bin')


def identify(_disc):
    return 0     # no disc form is known; the zip is recognised by identify_zip()


def identify_zip(names):
    lower = {n.lower() for n in names}
    return 1 if all(m in lower for m in ZIP_MEMBERS) else 0


def steps(_ctx):
    return []
