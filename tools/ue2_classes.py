"""Unreal Engine 2 class defaults (Tribes: Vengeance): the `defaultproperties` of a class merged along its inheritance chain.

A Class export holds the class's own default properties as a tagged-property stream at the end of its serial data (after
the compiled script); the reader below finds the stream by trying start offsets from the end backwards
(ue2_package.object_properties tries them from the front, which is slow for classes with long scripts). A property a class
does not name is inherited from its super class, possibly in another package (the script packages Program/Bin/*.u).

    classes = ClassIndex(game_root)
    classes.defaults('WeaponChaingun')          -> {'roundsPerSecond': 7.5, 'projectileClass': 'ProjectileChaingun', ...}
    classes.struct_array(pkg, raw)              -> [{'weaponClass': 'WeaponBlaster', 'ammo': 0}, ...] (a struct array property)
"""
import glob
import os

import ue2_package as U

PACKAGE_GLOBS = ('Content/Classes/*.pkg', 'Program/Bin/*.u')
ROOT_CLASSES = ('Actor', 'Object')         # their defaults are engine bookkeeping, not game values
MIN_STREAM_BYTES = 2                       # a property stream is at least a name index and "None"


class ClassIndex:
    def __init__(self, game_root):
        self.packages = {}
        self.by_name = {}                 # class name -> (package path, export)
        self._own = {}
        for pattern in PACKAGE_GLOBS:
            for path in sorted(glob.glob(os.path.join(game_root, pattern))):
                try:
                    pkg = U.load(path)
                except (U.PackageError, OSError):
                    continue
                self.packages[path] = pkg
                for e in pkg.exports:
                    if pkg.class_name(e) == 'Class':
                        self.by_name.setdefault(e['name'], (path, e))

    def has(self, name):
        return name in self.by_name

    def chain(self, name):
        """[class name, its super, ...] up to (not including) the root classes."""
        out = []
        while name in self.by_name and name not in ROOT_CLASSES and name not in out:
            out.append(name)
            path, e = self.by_name[name]
            name = self.packages[path].object_name(e['super']) if e['super'] else ''
        return out

    def own_properties(self, name):
        """The defaults the class itself sets."""
        if name not in self._own:
            path, e = self.by_name[name]
            self._own[name] = read_class_defaults(self.packages[path], e)
        return self._own[name]

    def defaults(self, name):
        """The class's defaults merged along its chain (a subclass overrides its supers)."""
        merged = {}
        for cls in reversed(self.chain(name)):
            merged.update(self.own_properties(cls))
        return merged

    def package_of(self, name):
        return self.packages[self.by_name[name][0]]


def read_class_defaults(pkg, export):
    """Tagged properties at the end of a Class export: the clean stream with the most properties that ends with "None"
    exactly at the end of the export (a start inside the true stream also parses, but names fewer properties)."""
    end = export['offset'] + export['size']
    best = {}
    for start in range(end - MIN_STREAM_BYTES, export['offset'] - 1, -1):
        res = U._strict_properties(pkg, pkg.data, start, end)
        if res and len(res) >= len(best):
            best = res
    return best


def struct_array(pkg, raw):
    """Elements of a struct-array property value (raw bytes): a compact-index count, then each element's tagged properties.
    Returns [{property: value}] (object references as class / object names)."""
    r = U.Reader(raw, 0)
    count = r.index()
    out = []
    for _ in range(count):
        props = U.read_properties(pkg, r)
        out.append(dict(props))
    return out
