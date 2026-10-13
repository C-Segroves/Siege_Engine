"""Alternate player-model skins from the original discs -> gamedata/<pack>/skins/.

Reads the disc images directly (tools/siege_iso.py, pycdlib) and writes, per pack that has skins,
  skins/skins.json      {"pack", "source", "skins": {"<pack>:<shape>": [{id, name, textures}]}}
                        textures: {<base texture "file" of the shape's texset, lowercased>:
                                   "skins/<shape>/<skin id>/<material index>.png"}   (relative to the pack)
  skins/<shape>/<skin id>/<i>.png   RGBA PNG
Skins are sorted by name; a shape's default skin is not listed.

Where the skins live:
  tribes2   Tribes2/GameData/base/*.vl2 (ZIP): textures/skins/<skin>.<armour>.png, armour = lmale, mmale, hmale,
            lfemale, mfemale, lbioderm, mbioderm, hbioderm; replaces the shape's skins\\base.<armour>.
            Display names from scripts/GameGui.cs ($Skin[n, name] / $Skin[n, code]).
  tribes    Tribes/base/*.vol: <skin>.<armour>.bmp (PBMP, 8-bit), armour = larmor, marmor, harmor, lfemale,
            mfemale; replaces base.<armour>.bmp; resolved through the base texture's palette.
            Display names from scripts/serverDefaults.cs ($Server::teamName / teamSkin).
  starsiege setup/data1.cab (InstallShield) on disc 1: skins/<HERC>_<name>.bmp (Windows 8-bit BMP whose embedded
            palette equals world palette 8, e.g. Mars_d_8). The game lists "skins\\<HERC>_*.bmp" in the vehicle
            lab and replaces the Herc texture whose name starts with "<HERC>_" (e.g. APOC_tr.BMP); listed for the
            Herc body shapes <faction>_<herc> (tr_apoc, kn_apoc, rb_oly ...), not cinematic or building shapes.
            (Extras/Skins on the disc only holds 24-bit templates of the default textures.)

Usage: python tools/export_skins.py [--pack tribes tribes2 starsiege] [--gamedata DIR] [--iso-... PATH]
"""
import argparse, io, json, os, re, shutil, sys, tempfile, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_iso  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(__file__))
ISO_NAMES = {'tribes': 'tribes.iso', 'tribes2': 'tribes_2.iso', 'starsiege': 'starseige_disc_1.iso'}
ISO_DIR_ENV = 'SIEGE_ISO_DIR'   # folder holding your disc images; or pass --iso-<pack>
T2_ARMOURS = ('lmale', 'mmale', 'hmale', 'lfemale', 'mfemale', 'lbioderm', 'mbioderm', 'hbioderm')
T1_ARMOURS = ('larmor', 'marmor', 'harmor', 'lfemale', 'mfemale')
HERC_SHAPE = re.compile(r'^(tr|kn|rb|pi|ha|cy|mg|pl|ca)_[a-z]+$')     # Herc bodies (not cinematic / buildings)


# ---------------------------------------------------------------- disc access
def disc_open(disc, rel):
    """Seekable read-only file object of a file on the disc (pycdlib PyCdlibIO)."""
    r = disc._resolve(rel)
    if not r or r[1]:
        raise siege_iso.DiscError('%s not found on %s' % (rel, os.path.basename(disc.path)))
    return disc.iso.open_file_from_iso(**{disc._kw: '/' + r[0]})


def disc_read(disc, rel):
    with disc_open(disc, rel) as f:
        return f.read()


class FileSlicer:
    """bytes-like slicing (obj[a:b]) over a seekable file, for installshield_cab.file_data."""
    def __init__(self, fp):
        self.fp = fp

    def __getitem__(self, s):
        self.fp.seek(s.start)
        return self.fp.read(s.stop - s.start)


# ---------------------------------------------------------------- helpers
def load_json(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def shape_texsets(pack_dir):
    """{shape name: [texset entries]} for every exported shape of the pack."""
    out = {}
    sdir = os.path.join(pack_dir, 'shapes')
    for fn in sorted(os.listdir(sdir)):
        if not fn.endswith('.json') or fn.startswith('_'):
            continue
        try:
            ts = load_json(os.path.join(sdir, fn)).get('texset')
            out[fn[:-5]] = load_json(os.path.join(pack_dir, 'textures', ts + '.json')) if ts else []
        except (OSError, ValueError, AttributeError):
            continue
    return out


def nice_name(s):
    words = [w for w in re.split(r'[_\s]+', s.strip('. ')) if w]
    return ' '.join(w[:1].upper() + w[1:] if w.islower() else w for w in words)


def skin_id(s):
    return re.sub(r'[^a-z0-9]+', '_', s.lower()).strip('_')


def save_png(img, pack_dir, rel):
    path = os.path.join(pack_dir, *rel.split('/'))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.convert('RGBA').save(path)
    return rel


def armour_skins(pack, pack_dir, files, base_re, load_image, names, source):
    """Tribes 1 / 2: files {lower '<skin>.<armour>': payload}; base textures matching base_re (group 1 = armour)
    are replaced by every '<skin>.<armour>' except base."""
    out = {}
    for shape, ts in shape_texsets(pack_dir).items():
        bases = {}                                   # armour -> (base file lower, material index, entry)
        for i, e in enumerate(ts):
            m = base_re.match((e.get('file') or '').lower())
            if m and m.group(1) not in bases:
                bases[m.group(1)] = (e['file'].lower(), i, e)
        lst = []
        for skin in sorted({k.split('.')[0] for k in files}):
            if skin == 'base':
                continue
            tex = {}
            for armour, (bfile, i, e) in bases.items():
                payload = files.get('%s.%s' % (skin, armour))
                if payload is None:
                    continue
                img = load_image(payload, e)
                if img is None:
                    continue
                tex[bfile] = save_png(img, pack_dir, 'skins/%s/%s/%d.png' % (shape, skin_id(skin), i))
            if tex:
                lst.append({'id': skin_id(skin), 'name': names.get(skin) or nice_name(skin), 'textures': tex})
        if lst:
            out['%s:%s' % (pack, shape)] = sorted(lst, key=lambda s: (s['name'].lower(), s['id']))
    return {'pack': pack, 'source': source, 'skins': out} if out else None


# ---------------------------------------------------------------- Tribes 2
def tribes2(iso, pack_dir):
    base = 'Tribes2/GameData/base'
    pat = re.compile(r'^textures/skins/([^/.]+)\.(%s)\.png$' % '|'.join(T2_ARMOURS), re.I)
    files, names = {}, {}
    with siege_iso.Disc(iso) as d:
        for vl2 in d.glob(base, '.vl2'):
            with disc_open(d, base + '/' + vl2) as fp, zipfile.ZipFile(fp) as z:
                for n in z.namelist():
                    m = pat.match(n.replace('\\', '/'))
                    if m:
                        files.setdefault('%s.%s' % (m.group(1).lower(), m.group(2).lower()), z.read(n))
                    elif n.lower().replace('\\', '/') == 'scripts/gamegui.cs':
                        txt = z.read(n).decode('latin1')
                        pairs = re.findall(r'\$Skin\[\s*\$SkinCount\s*,\s*name\s*\]\s*=\s*"([^"]+)";\s*'
                                           r'\$Skin\[\s*\$SkinCount\s*,\s*code\s*\]\s*=\s*"([^"]+)"', txt)
                        names.update({c.lower(): nm for nm, c in pairs})
    from PIL import Image
    return armour_skins('tribes2', pack_dir, files,
                        re.compile(r'^skins\\base\.(%s)$' % '|'.join(T2_ARMOURS)),
                        lambda data, e: Image.open(io.BytesIO(data)), names,
                        '%s: %s/*.vl2 textures/skins/<skin>.<armour>.png' % (os.path.basename(iso), base))


# ---------------------------------------------------------------- Tribes 1
def tribes(iso, pack_dir):
    import darkstar_vol as V
    import darkstar_gfx as G
    from PIL import Image
    base = 'Tribes/base'
    pat = re.compile(r'^([^\\/.]+)\.(%s)\.bmp$' % '|'.join(T1_ARMOURS), re.I)
    files, names, srcs = {}, {}, set()
    with siege_iso.Disc(iso) as d, tempfile.TemporaryDirectory() as tmp:
        for vol in d.glob(base, '.vol'):
            path = os.path.join(tmp, vol)
            with open(path, 'wb') as f:
                f.write(disc_read(d, base + '/' + vol))
            try:
                data, ents = V.read_vol(path)
            except (ValueError, AssertionError):
                continue
            for e in ents:
                n = (e['name'] or '').replace('\\', '/').split('/')[-1]
                m = pat.match(n)
                if m:
                    files.setdefault('%s.%s' % (m.group(1).lower(), m.group(2).lower()), V.file_data(data, e))
                    srcs.add(vol)
                elif n.lower() == 'serverdefaults.cs':
                    txt = V.file_data(data, e).decode('latin1')
                    tn = dict(re.findall(r'\$Server::teamName\[(\d+)\]\s*=\s*"([^"]*)"', txt))
                    for k, sk in re.findall(r'\$Server::teamSkin\[(\d+)\]\s*=\s*"([^"]*)"', txt):
                        if sk.lower() != 'base' and k in tn:
                            names[sk.lower()] = tn[k]
            os.remove(path)
    palettes = {}

    def load(data, e):
        b = G.read_pbmp(data)
        pname = e.get('palette')
        if pname not in palettes:
            palettes[pname] = load_json(os.path.join(pack_dir, 'palettes', pname + '.json'))
        img = Image.frombytes('P', (b['w'], b['h']), b['pixels'])
        img.putpalette([c for col in palettes[pname] for c in col])
        return img

    return armour_skins('tribes', pack_dir, files,
                        re.compile(r'^base\.(%s)\.bmp$' % '|'.join(T1_ARMOURS)), load, names,
                        '%s: %s/%s <skin>.<armour>.bmp (PBMP, base texture palette)'
                        % (os.path.basename(iso), base, ', '.join(sorted(srcs))))


# ---------------------------------------------------------------- Starsiege
def starsiege(iso, pack_dir):
    import installshield_cab as C
    from PIL import Image
    skins = {}                                      # herc prefix lower -> [(name part, bmp bytes)]
    with siege_iso.Disc(iso) as d, tempfile.TemporaryDirectory() as tmp:
        hdr = os.path.join(tmp, 'data1.hdr')
        with open(hdr, 'wb') as f:
            f.write(disc_read(d, 'setup/data1.hdr'))
        with disc_open(d, 'setup/data1.cab') as fp:
            cab = FileSlicer(fp)
            for e in C.read_index(hdr):
                if e['dir'].replace('/', '\\').strip('\\').lower() != 'skins' or not e['name'].lower().endswith('.bmp'):
                    continue
                stem = e['name'][:-4]
                if '_' not in stem:
                    continue
                prefix, rest = stem.split('_', 1)
                data = C.file_data(cab, e)
                if data:
                    skins.setdefault(prefix.lower(), []).append((rest, stem.lower(), data))
    out = {}
    for shape, ts in shape_texsets(pack_dir).items():
        if not HERC_SHAPE.match(shape):
            continue
        lst = []
        herc = shape.split('_', 1)[1]
        for prefix, entries in skins.items():
            if herc[:3] != prefix[:3]:              # only the Herc's own body (cy_jamm borrows BOLO_cy.BMP)
                continue
            bases = [(i, e['file']) for i, e in enumerate(ts) if (e.get('file') or '').lower().startswith(prefix + '_')]
            seen = set()
            bases = [(i, f) for i, f in bases if not (f.lower() in seen or seen.add(f.lower()))]
            if not bases:
                continue
            for rest, stem, data in entries:
                if any(os.path.splitext(f)[0].lower() == stem for _, f in bases):
                    continue                        # this shape's own default texture (e.g. pi_apoc: Apoc_pirate)
                sid = skin_id(rest)
                img = Image.open(io.BytesIO(data))
                tex = {f.lower(): save_png(img, pack_dir, 'skins/%s/%s/%d.png' % (shape, sid, i)) for i, f in bases}
                lst.append({'id': sid, 'name': nice_name(rest), 'textures': tex})
        if lst:
            out['starsiege:' + shape] = sorted(lst, key=lambda s: (s['name'].lower(), s['id']))
    if not out:
        return None
    return {'pack': 'starsiege', 'source': '%s: setup/data1.cab skins/<HERC>_<skin>.bmp (8-bit BMP, '
                                           'embedded palette = world palette 8)' % os.path.basename(iso),
            'skins': out}


# ---------------------------------------------------------------- main
EXPORTERS = {'tribes': tribes, 'tribes2': tribes2, 'starsiege': starsiege}


def run(pack, iso, gamedata):
    pack_dir = os.path.join(gamedata, pack)
    if not os.path.isdir(os.path.join(pack_dir, 'shapes')):
        print('%s: no converted pack at %s, skipped' % (pack, pack_dir))
        return None
    sdir = os.path.join(pack_dir, 'skins')
    if os.path.isdir(sdir):
        shutil.rmtree(sdir)                         # generated output only
    res = EXPORTERS[pack](iso, pack_dir)
    if res is None:
        print('%s: no alternate skins on %s, nothing written' % (pack, os.path.basename(iso)))
        if os.path.isdir(sdir):
            shutil.rmtree(sdir)
        return None
    os.makedirs(sdir, exist_ok=True)
    with open(os.path.join(sdir, 'skins.json'), 'w', encoding='utf-8') as f:
        json.dump(res, f, indent=1, ensure_ascii=False)
    for shape, lst in sorted(res['skins'].items()):
        print('%-24s %3d  %s' % (shape, len(lst), ', '.join(s['id'] for s in lst[:8]) + (' ...' if len(lst) > 8 else '')))
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--pack', nargs='+', choices=sorted(EXPORTERS), default=['tribes', 'tribes2', 'starsiege'])
    ap.add_argument('--gamedata', default=os.path.normpath(os.path.join(TOOLS, '..', 'gamedata')))
    iso_dir = os.environ.get(ISO_DIR_ENV)
    for p, name in ISO_NAMES.items():
        ap.add_argument('--iso-' + p, default=os.path.join(iso_dir, name) if iso_dir else None,
                        help='disc image (default $%s/%s)' % (ISO_DIR_ENV, name))
    a = ap.parse_args()
    for p in a.pack:
        if not getattr(a, 'iso_' + p):
            ap.error('no disc image for %s: pass --iso-%s or set %s' % (p, p, ISO_DIR_ENV))
    for p in a.pack:
        run(p, getattr(a, 'iso_' + p), a.gamedata)


if __name__ == '__main__':
    main()
