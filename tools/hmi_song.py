"""HMI SOS sequencer behaviour for HMP songs (Earthsiege DBSIM.EXE / GO.EXE, Battledrome SIM/SHELL.EXE).

Decoded from the SOS library linked into DBSIM.EXE (VA = file offset - 0x48fd):
  0x6e874  track -> driver mapping: a track's 5 device slots (HMP 0x80) are tried in order against the loaded
           drivers; 0xA000 also matches 0xA001/0xA008, 0xA002 also matches 0xA009 (OPL3); first match wins.
           A track nothing matches is not played.
  0x715c5  every event goes to its track's driver unchanged (channel remapping is off: 0x4f3b4 calls
           0x7225a(0)), except cc7: value * song volume >> 7 * master volume >> 7 (both 0x7f by default).
  0x7f4b8  HMI controllers 108..121 (jump table 0xa79a0) are consumed by the sequencer, the rest reach the
           driver (cc102 = the FM driver's pitch-bend range).  cc109 v: copy the following cc110's loop count
           into branch point v.  cc111/112 v (loop end): unless the count runs out (255 = forever) every track
           jumps to its branch point v (the event after its cc108 / cc110 marker, offsets in the branch table
           at header 0x20), its time restarts there, and its saved program and controllers are re-sent.
           No note-off is sent at the jump.
Events are processed per timer tick (header 0x38: ticks per second) in track order, then file order.
"""
import struct

HEADER_BRANCH_TABLE = 0x20
HEADER_TRACKS = 0x30
HEADER_DEVICE_MAP = 0x80
DEVICE_SLOTS = 5
MAX_TRACKS = 32
TRACK_DATA = 0x308
TRACK_HEADER = 12
BRANCH_ENTRY = 24
BRANCH_TARGET_SKEW = 0x0c           # 0x7f7c3: entry offset + 0xc = position of the event after the marker
DEFAULT_SONG_VOLUME = 0x7f          # 0xa56dc
DEFAULT_MASTER_VOLUME = 0x7f        # 0xa56d8

CC_VOLUME = 7
CC_LOOP_SETUP = 109
CC_LOOP_START = 110
CC_LOOP_ENDS = (111, 112)
HMI_SEQUENCER_CONTROLLERS = range(108, 122)
LOOP_FOREVER = 255

# 0x6e8a4 / 0x6e90e: device ids a track slot accepts
DEVICE_ALIASES = {0xA000: (0xA000, 0xA001, 0xA008), 0xA002: (0xA002, 0xA009)}


class Event:
    __slots__ = ('tick', 'pos', 'status', 'data1', 'data2')

    def __init__(self, tick, pos, status, data1, data2):
        self.tick, self.pos, self.status, self.data1, self.data2 = tick, pos, status, data1, data2

    def is_controller(self, number):
        return self.status & 0xf0 == 0xb0 and self.data1 == number


class Track:
    def __init__(self, index, events, devices, branches):
        self.index, self.events, self.devices, self.branches = index, events, devices, branches

    def branch_target(self, branch_id):
        """Index of the first event of the loop body for `branch_id`, or None."""
        pos = self.branches.get(branch_id)
        if pos is None:
            return None
        for i, e in enumerate(self.events):
            if e.pos >= pos:
                return i
        return len(self.events)


class HmpSong:
    """Parsed HMP: header, device map, tracks with byte positions, branch table."""

    def __init__(self, path):
        d = open(path, 'rb').read()
        if not d.startswith(b'HMIMIDIP'):
            raise ValueError('not an HMP file: ' + path)
        self.path = path
        branch_ofs, = struct.unpack_from('<I', d, HEADER_BRANCH_TABLE)
        ntracks, self.division, self.ticks_per_second, self.header_seconds = struct.unpack_from('<IIII', d, HEADER_TRACKS)
        devmap = struct.unpack_from('<%dI' % (MAX_TRACKS * DEVICE_SLOTS), d, HEADER_DEVICE_MAP)
        starts, p = [], TRACK_DATA
        for _ in range(ntracks):
            starts.append(p)
            p += struct.unpack_from('<I', d, p + 4)[0]
        branches, self.restore = read_branch_table(d, branch_ofs, starts) if branch_ofs else ({}, {})
        self.tracks = []
        for t, start in enumerate(starts):
            devices = [x for x in devmap[t * DEVICE_SLOTS:(t + 1) * DEVICE_SLOTS] if x] if t < MAX_TRACKS else []
            self.tracks.append(Track(t, read_track_events(d, start), devices, branches.get(t, {})))

    def driver_for(self, track, drivers):
        for device in track.devices:
            for driver in drivers:
                if driver in DEVICE_ALIASES.get(device, (device,)):
                    return driver
        return None

    def end_tick(self):
        return max((t.events[-1].tick for t in self.tracks if t.events), default=0)


def read_branch_table(d, ofs, starts):
    """Header 0x20 -> u8 count per track, then 24-byte entries {u32 offset, u8 id, u8 program, u8, u8 n,
    u32 controller-list file offset, ...}; returns ({track: {id: file position of the loop-body event}},
    {(track, id): (program, [(controller, value), ...])})."""
    counts = d[ofs:ofs + len(starts)]
    branches, restore = {}, {}
    p = ofs + len(starts)
    for t, n in enumerate(counts):
        for _ in range(n):
            offset, bid, program, _pad, nbytes, ctl = struct.unpack_from('<IBBBBI', d, p)
            branches.setdefault(t, {})[bid] = starts[t] + offset + BRANCH_TARGET_SKEW
            pairs = [(d[ctl + i], d[ctl + i + 1]) for i in range(0, nbytes, 2)]
            restore[(t, bid)] = (program, pairs)
            p += BRANCH_ENTRY
    return branches, restore


def read_track_events(d, start):
    """Track chunk -> [Event] (meta / sysex dropped).  Delta times are HMI VLQs (7-bit groups, least
    significant first, last byte has bit 7 set); running status applies."""
    length, = struct.unpack_from('<I', d, start + 4)
    q, end = start + TRACK_HEADER, start + length
    tick, status, out = 0, 0, []
    while q < end:
        dt, q = _hmi_vlq(d, q)
        tick += dt
        pos, c = q, d[q]
        if c == 0xff:
            if d[q + 1] == 0x2f:
                out.append(Event(tick, pos, 0xff, 0x2f, 0))
                break
            q += 3 + d[q + 2]
            continue
        if c in (0xf0, 0xf7):
            n, q = _hmi_vlq(d, q + 1)
            q += n
            continue
        if c & 0x80:
            status, q = c, q + 1
        nargs = 1 if status & 0xf0 in (0xc0, 0xd0) else 2
        args = d[q:q + nargs]
        q += nargs
        out.append(Event(tick, pos, status, args[0], args[1] if nargs == 2 else 0))
    return out


def _hmi_vlq(d, p):
    v = s = 0
    while True:
        b = d[p]
        p += 1
        v |= (b & 0x7f) << s
        s += 7
        if b & 0x80:
            return v, p


class Playback:
    """Runs the SOS sequencer over a song: yields (tick, track, status, data1, data2) as sent to the drivers.

    `jumps` lists the ticks at which loop branches happened (the loop iteration boundaries)."""

    def __init__(self, song, max_jumps):
        self.song, self.max_jumps = song, max_jumps
        self.jumps = []
        self.loop_counts = {}
        self.pointer = [0] * len(song.tracks)
        self.next_tick = [t.events[0].tick if t.events else None for t in song.tracks]

    def events(self):
        while True:
            pending = [t for t in self.next_tick if t is not None]
            if not pending:
                return
            now = min(pending)
            for ti in range(len(self.song.tracks)):
                yield from self._run_track(ti, now)
                if len(self.jumps) > self.max_jumps:
                    return

    def _run_track(self, ti, now):
        track = self.song.tracks[ti]
        while self.next_tick[ti] == now:
            e = track.events[self.pointer[ti]]
            self._advance(ti, now)
            if e.status == 0xff:
                self.next_tick[ti] = None
                return
            if e.status & 0xf0 == 0xb0 and e.data1 in HMI_SEQUENCER_CONTROLLERS:
                yield from self._sequencer_controller(ti, e, now)
                continue
            yield now, ti, e.status, e.data1, e.data2

    def _advance(self, ti, now):
        events = self.song.tracks[ti].events
        cur = events[self.pointer[ti]]
        self.pointer[ti] += 1
        if self.pointer[ti] < len(events) and cur.status != 0xff:
            self.next_tick[ti] = now + events[self.pointer[ti]].tick - cur.tick
        else:
            self.next_tick[ti] = None

    def _sequencer_controller(self, ti, e, now):
        if e.data1 == CC_LOOP_SETUP:
            nxt = self.song.tracks[ti].events[self.pointer[ti]] if self.pointer[ti] < len(self.song.tracks[ti].events) else None
            if nxt is not None and nxt.is_controller(CC_LOOP_START):
                self.loop_counts[e.data2] = nxt.data2
        elif e.data1 in CC_LOOP_ENDS and self._loop_continues(e.data2):
            self.jumps.append(now)
            yield from self._branch_all(e.data2, now)

    def _loop_continues(self, branch_id):
        count = self.loop_counts.get(branch_id, LOOP_FOREVER)
        if count not in (LOOP_FOREVER, 0):
            count -= 1
            self.loop_counts[branch_id] = count
        return count != 0

    def _branch_all(self, branch_id, now):
        """0x7f6f2: tracks 1.. jump to the event after their marker; program + saved controllers re-sent."""
        for ti in range(1, len(self.song.tracks)):
            track = self.song.tracks[ti]
            target = track.branch_target(branch_id)
            if target is None or target >= len(track.events):
                continue
            body = track.events[target]
            marker_tick = track.events[target - 1].tick if target > 0 else 0
            self.pointer[ti] = target
            self.next_tick[ti] = now + body.tick - marker_tick
            channel = body.status & 0x0f
            program, pairs = self.song.restore.get((ti, branch_id), (None, []))
            if program is not None:
                yield now, ti, 0xc0 | channel, program, 0
            for number, value in pairs:
                yield now, ti, 0xb0 | channel, number, value


def scale_volume(value, song_volume=DEFAULT_SONG_VOLUME, master=DEFAULT_MASTER_VOLUME):
    """0x7163f: cc7 as the drivers receive it."""
    return (((value * song_volume) >> 7) * master) >> 7
