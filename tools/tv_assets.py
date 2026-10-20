"""Tribes: Vengeance package lookup: finds an imported object's home package under the game folder and loads it.

  idx = PackageIndex(game_root)          idx.load('SP-RescueTextures') -> ue2_package.Package (cached)
  idx.resolve(pkg, import_ref)           -> (package name, object name, class name) of an import (negative ref)
  idx.object(pkg, ref)                   -> (home package, export) of an object reference of `pkg`
"""
import os

import ue2_package as U

EXTENSIONS = ('.tvm', '.pkg', '.u')


class PackageIndex:
    def __init__(self, game_root, cache_size=6):
        self.paths = {}
        for sub in ('Content', 'Program'):
            for dirpath, _dirs, files in os.walk(os.path.join(game_root, sub)):
                for f in files:
                    stem, ext = os.path.splitext(f)
                    if ext.lower() in EXTENSIONS:
                        self.paths.setdefault(stem.lower(), os.path.join(dirpath, f))
        self._cache, self._limit = {}, cache_size

    def load(self, name):
        key = name.lower()
        if key not in self.paths:
            return None
        if key not in self._cache:
            if len(self._cache) >= self._limit:
                self._cache.pop(next(iter(self._cache)))
            self._cache[key] = U.load(self.paths[key])
            self._cache[key].stem = key
        return self._cache[key]

    @staticmethod
    def resolve(pkg, ref):
        """(outermost package name, object name, class name) of import reference ref (< 0)."""
        imp = pkg.imports[-ref - 1]
        name, cls, outer = imp['name'], imp['class_name'], imp['package']
        while outer < 0:
            parent = pkg.imports[-outer - 1]
            if parent['class_name'] == 'Package' and parent['package'] >= 0:
                return parent['name'], name, cls
            outer = parent['package']
        return pkg.name_of_self if hasattr(pkg, 'name_of_self') else '', name, cls

    def object(self, pkg, ref, home_name=None):
        """(Package, export) a reference points at: an export of pkg itself, or an import from another package."""
        if ref > 0:
            return pkg, pkg.exports[ref - 1]
        if ref < 0:
            pname, oname, cls = self.resolve(pkg, ref)
            other = self.load(pname)
            if other is not None:
                for e in other.exports:
                    if e['name'] == oname and other.class_name(e) == cls:
                        return other, e
        return None, None
