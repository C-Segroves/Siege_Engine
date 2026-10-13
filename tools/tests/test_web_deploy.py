"""Server-side pieces of the browser build (docs/WEB_DEPLOY.md): the importer seeds pack.json before the converters
run (fresh imports, as on a new server), and deploy/import_discs.py finds the disc images in a folder
(synthetic files only; no original data)."""
import json
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'deploy'))
import import_discs  # noqa: E402
import siege_import  # noqa: E402


def _touch(*parts):
    os.makedirs(os.path.dirname(os.path.join(*parts)), exist_ok=True)
    open(os.path.join(*parts), 'wb').close()


class SeedPackMetaTest(unittest.TestCase):
    def _ctx(self, out, pack_json):
        game = types.SimpleNamespace(GAME={'pack_json': pack_json})
        return types.SimpleNamespace(game=game, pack_path=lambda *p: os.path.join(out, *p))

    def test_fresh_staging_pack_gets_the_game_keys(self):
        with tempfile.TemporaryDirectory() as out:
            siege_import.seed_pack_meta(self._ctx(out, {'default_palette': 'WORLD0'}))
            with open(os.path.join(out, 'pack.json')) as f:
                self.assertEqual(json.load(f), {'default_palette': 'WORLD0'})

    def test_existing_pack_json_is_kept(self):
        with tempfile.TemporaryDirectory() as out:
            with open(os.path.join(out, 'pack.json'), 'w') as f:
                json.dump({'name': 'own'}, f)
            siege_import.seed_pack_meta(self._ctx(out, {'name': 'seed'}))
            with open(os.path.join(out, 'pack.json')) as f:
                self.assertEqual(json.load(f), {'name': 'own'})


class FindDiscsTest(unittest.TestCase):
    def test_images_found_and_bin_of_a_cue_skipped(self):
        with tempfile.TemporaryDirectory() as root:
            for name in ('a.iso', 'b.cue', 'b.bin', 'c.BIN', 'notes.txt', os.path.join('a', 'Track 02.flac'),
                         os.path.join('sub', 'd.ISO')):
                _touch(root, name)
            found = [os.path.relpath(p, root) for p in import_discs.find_discs(root)]
            self.assertEqual(found, ['a.iso', 'b.cue', 'c.BIN', os.path.join('sub', 'd.ISO')])


if __name__ == '__main__':
    unittest.main()
