"""Read-only access to a disc image (ISO 9660, Joliet names preferred) for the importer.

    d = Disc('earth_siege.iso')
    d.exists('VOL/SIMVOL0.VOL')            # case-insensitive, no ';1' versions needed
    d.ls('')                                # {lower name: (real name, is_dir, size)}
    d.extract('INSTALL', 'work/bd/original/INSTALL')     # file or whole directory tree
    d.label                                 # volume identifier

Only directory records that are asked for are read, so identification is fast even on 600 MB discs.

Besides .iso files, BIN/CUE images (.cue, or a .bin next to its .cue) are read through their data track
(tools/siege_cd.py); d.audio lists the disc's CD-audio tracks (BIN/CUE audio tracks, or the ripped tracks in
the folder named like the .iso).
"""
import os

import pycdlib

import siege_cd


class DiscError(Exception):
    pass


class Disc:
    def __init__(self, path):
        self.path = path
        if not os.path.isfile(path):
            raise DiscError('File not found: %s' % path)
        self.iso = pycdlib.PyCdlib()
        self._image = None
        self.audio = []                    # siege_cd.AudioTrack list (CD-audio tracks, if any)
        self.audio_source = ''             # 'cue' (BIN/CUE image) or the folder of ripped tracks
        ext = os.path.splitext(path)[1].lower()
        try:
            if ext in ('.cue', '.bin') or siege_cd.is_raw_image(path):
                try:
                    self._image = siege_cd.open_image(path)
                except (siege_cd.CueError, ValueError, OSError) as e:
                    raise DiscError(str(e))
                if self._image.data is None:
                    raise DiscError('%s has no data track (audio CD only)' % os.path.basename(path))
                self.iso.open_fp(self._image.data)
                self.audio = self._image.audio
                self.audio_source = 'cue' if self.audio else ''
            else:
                self.iso.open(path)
                self.audio = siege_cd.sibling_audio(path)
                self.audio_source = siege_cd.audio_folder(path) or ''
        except DiscError:
            self.close()
            raise
        except Exception as e:  # pycdlib raises PyCdlibInvalidISO / InvalidInput / OSError
            self.close()
            raise DiscError('%s is not a readable ISO 9660 disc image (%s)' % (os.path.basename(path), e))
        self.joliet = self.iso.has_joliet()
        self._kw = 'joliet_path' if self.joliet else 'iso_path'
        self._dirs = {}
        try:
            self.label = self.iso.pvd.volume_identifier.decode('latin1').strip(' \0')
        except Exception:
            self.label = ''

    def mastered(self):
        """The volume creation date ('1994-10-25'), '' when the disc does not record one."""
        try:
            d = self.iso.pvd.volume_creation_date
            return '%04d-%02d-%02d' % (d.year, d.month, d.dayofmonth) if d.year else ''
        except Exception:
            return ''

    def close(self):
        try:
            self.iso.close()
        except Exception:
            pass
        if self._image is not None:
            try:
                self._image.close()
            except Exception:
                pass
            self._image = None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    # ------------------------------------------------------------------ directory lookup
    def _decode(self, ident):
        n = ident.decode('utf-16-be') if self.joliet else ident.decode('latin1')
        return n

    @staticmethod
    def _clean(n):
        n = n.split(';')[0]
        if n.endswith('.') and n not in ('.', '..'):
            n = n[:-1]
        return n

    def _list_real(self, real_dir):
        """real_dir: '/'-joined real identifiers ('' = root). -> {lower clean name: (real, is_dir, size)}"""
        if real_dir in self._dirs:
            return self._dirs[real_dir]
        out = {}
        for c in self.iso.list_children(**{self._kw: '/' + real_dir}):
            ident = c.file_identifier()
            if ident in (b'\x00', b'\x01'):
                continue
            real = self._decode(ident)
            if real in ('.', '..'):
                continue
            out[self._clean(real).lower()] = (real, c.is_dir(), c.get_data_length())
        self._dirs[real_dir] = out
        return out

    def _resolve(self, rel):
        """Case-insensitive path -> (real path, is_dir, size) or None."""
        parts = [p for p in rel.replace('\\', '/').split('/') if p]
        real, is_dir, size = '', True, 0
        for p in parts:
            if not is_dir:
                return None
            try:
                ent = self._list_real(real).get(p.lower())
            except Exception:
                return None
            if ent is None:
                return None
            real = (real + '/' + ent[0]).strip('/')
            is_dir, size = ent[1], ent[2]
        return real, is_dir, size

    def exists(self, rel):
        return self._resolve(rel) is not None

    def is_dir(self, rel):
        r = self._resolve(rel)
        return bool(r and r[1])

    def ls(self, rel=''):
        r = self._resolve(rel)
        if not r or not r[1]:
            return {}
        return self._list_real(r[0])

    def glob(self, rel_dir, suffix):
        """Names (clean, original case) in rel_dir ending with suffix (case-insensitive)."""
        return sorted(self._clean(v[0]) for k, v in self.ls(rel_dir).items() if not v[1] and k.endswith(suffix.lower()))

    # ------------------------------------------------------------------ extraction
    def size(self, rel):
        """Total bytes of a file or directory tree."""
        r = self._resolve(rel)
        if not r:
            return 0
        if not r[1]:
            return r[2]
        return sum(self.size((rel.rstrip('/') + '/' + self._clean(v[0])).lstrip('/')) if v[1] else v[2]
                   for v in self._list_real(r[0]).values())

    def extract(self, rel, dst, progress=None):
        """Copy a file or directory tree to dst. Returns the number of files written."""
        r = self._resolve(rel)
        if r is None:
            raise DiscError('%s not found on %s' % (rel, os.path.basename(self.path)))
        return self._extract_real(r[0], r[1], dst, progress)

    def _extract_real(self, real, is_dir, dst, progress):
        if not is_dir:
            os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
            with open(dst, 'wb') as fp:
                self.iso.get_file_from_iso_fp(fp, **{self._kw: '/' + real})
            if progress:
                progress(os.path.getsize(dst))
            return 1
        os.makedirs(dst, exist_ok=True)
        n = 0
        for _low, (name, sub_dir, _size) in sorted(self._list_real(real).items()):
            n += self._extract_real((real + '/' + name).strip('/'), sub_dir, os.path.join(dst, self._clean(name)), progress)
        return n
