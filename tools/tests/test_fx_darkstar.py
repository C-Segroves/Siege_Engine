"""tools/fx_darkstar.py: keyframe flag decoding, script datablocks and the textured-triangle rasteriser
(synthetic inputs only; no original data)."""
import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import fx_darkstar as X  # noqa: E402


class KeyFlagsTest(unittest.TestCase):
    def test_v7_word_uses_top_nibble(self):
        self.assertEqual(X.key_flags({'version': 7}, 0xD0000003), (0xD, 3))

    def test_v8_word_is_16_bit(self):
        self.assertEqual(X.key_flags({'version': 8}, 0x9002), (0x9, 2))


class DatablockTest(unittest.TestCase):
    def test_fields_vectors_and_indexed_fields(self):
        text = ('ExplosionData boom\n{\n   shapeName = "a.dts";\n   // hasLight = false;\n   hasLight = true;\n'
                '   colors[1] = { 1.0, 0.5, 0 };\n   lightRange = 3;\n};\n')
        block = X.parse_datablocks(text, 'x.cs')['boom']
        self.assertEqual(block['class'], 'ExplosionData')
        self.assertEqual(block['fields']['shapename'], 'a.dts')
        self.assertEqual(block['fields']['haslight'], 'true')
        self.assertEqual(block['fields']['colors'][1], [1.0, 0.5, 0.0])
        self.assertEqual(block['fields']['lightrange'], 3.0)


class RasteriserTest(unittest.TestCase):
    def test_quad_diagonal_drawn_once(self):
        canvas = (np.zeros((8, 8, 3), np.float32), np.zeros((8, 8), np.float32))
        tex = np.full((2, 2, 4), 128, np.uint8)
        quad = [(0, 0), (8, 0), (8, 8), (0, 8)]
        uv = [(0, 0), (1, 0), (1, 1), (0, 1)]
        for tri in ((0, 1, 2), (0, 2, 3)):
            X.draw_triangle(canvas, [quad[i] for i in tri], [uv[i] for i in tri], tex, True)
        self.assertTrue(np.allclose(canvas[0], (128 / 255.0) ** 2))

    def test_additive_encoding_keeps_light(self):
        rgb = np.zeros((1, 1, 3), np.float32)
        rgb[0, 0] = (0.5, 0.25, 0.0)
        px = np.asarray(X.finish_canvas((rgb, np.zeros((1, 1), np.float32)), True), np.float32)[0, 0] / 255.0
        self.assertAlmostEqual(px[0] * px[3], 0.5, places=2)
        self.assertAlmostEqual(px[1] * px[3], 0.25, places=2)


if __name__ == '__main__':
    unittest.main()
