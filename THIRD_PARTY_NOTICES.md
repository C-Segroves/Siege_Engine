# Third-party notices

Siege Engine's own code, tools and documentation are under the MIT license (`LICENSE`). The repository holds no
game content and no third-party code beyond what is listed here. A release bundle (`tools/package_release.ps1`)
also ships the third-party programs below, some of them under the GPL or LGPL. Their license texts are copied into
the bundle when it is built:
- `licenses/` holds Godot's license and the notices of the code built into Godot (`tools/godot_licenses.gd`), the
  full GPL-3.0 and LGPL-2.1 texts, and `SOURCE-CODE.txt`, which says where the source of the GPL / LGPL parts is.
- `siege-importer/licenses/` holds the license texts of Python, every bundled package and the bundled ffmpeg build
  (`tools/collect_licenses.py`; `licenses/ffmpeg/BUILD.txt` has the exact FFmpeg configure line).

## Shipped in the release bundle

| component | used for | license | source |
|---|---|---|---|
| Godot Engine 4.6 (export template) | the game app, `SiegeEngine.exe` | MIT, with third-party parts under their own permissive licenses (FreeType, mbedTLS, ENet, zlib and others; listed in `licenses/Godot-THIRD_PARTY.txt`) | https://github.com/godotengine/godot |
| Python 3 (embedded by PyInstaller) | runs the disc importer | PSF License Agreement, including its bundled libraries (OpenSSL, libffi, zlib, bzip2, xz and others) | https://www.python.org/downloads/source/ |
| PyInstaller bootloader | starts `siege-importer.exe` | GPL-2.0-or-later **with the bootloader exception**, which allows distributing the frozen program under any license | https://github.com/pyinstaller/pyinstaller |
| altgraph, pefile, pywin32-ctypes (only when PyInstaller bundles them) | PyInstaller runtime helpers | MIT, MIT, BSD-3-Clause | https://pypi.org/project/altgraph/, https://github.com/erocarrera/pefile, https://github.com/enthought/pywin32-ctypes |
| pycdlib | reads ISO 9660 / Joliet disc images | LGPL-2.1-only | https://github.com/clalancette/pycdlib |
| NumPy | array maths in the converters | BSD-3-Clause, with bundled parts under their own licenses (OpenBLAS: BSD-3-Clause; the GCC Fortran runtime: GPL-3.0 with the GCC Runtime Library Exception; see its `LICENSE.txt`) | https://github.com/numpy/numpy |
| Pillow | image conversion | MIT-CMU (HPND) | https://github.com/python-pillow/Pillow |
| **FFmpeg** 8.1.3 (`siege-importer/ffmpeg/ffmpeg.exe`, our own minimal static build: `tools/ffmpeg/build_ffmpeg.sh`) | converts cinematics to `.ogv` and audio to `.ogg` | **LGPL-2.1-or-later**: configured without `--enable-gpl`, `--enable-version3` and `--enable-nonfree`, with only the decoders, formats and filters the importer uses. It is a separate program that the importer runs; nothing is linked against it | https://ffmpeg.org/releases/ (archive and SHA-256 pinned in `tools/ffmpeg/sources.lock`) |
| libogg 1.3.6, libvorbis 1.3.7, libtheora 1.2.0 (linked into `ffmpeg.exe`) | Ogg container, Vorbis audio and Theora video encoding | BSD-3-Clause | https://downloads.xiph.org/releases/ |
| MinGW-w64 runtime and libgcc (linked into `ffmpeg.exe` by the cross-compiler) | C runtime start-up code | MinGW-w64: ZPL-2.1 / public domain; libgcc: GPL-3.0 with the GCC Runtime Library Exception (no source obligation) | https://www.mingw-w64.org/, https://gcc.gnu.org/ |
| **innoextract** 1.9 (developer/importer tool for Tribes: Vengeance; not bundled in the game app) | unpacks the Inno Setup installer inside `TribesVengeance.zip` (`tools/tv_unpack.py`) | **zlib license** (Copyright 2011-2020 Daniel Scharrer); its Windows build also contains liblzma (public domain), Boost (BSL-1.0) and the libstdc++ runtime (GPL-3.0 with the GCC Runtime Library Exception). A separate program the importer runs; downloaded once into `tools/innoextract/` from https://constexpr.org/innoextract/ (SHA-256 pinned in `tools/tv_unpack.py`), or taken from `SIEGE_INNOEXTRACT` / PATH. If it is ever bundled in the importer, ship `tools/innoextract/license/*` with it (add it to `tools/collect_licenses.py`) | https://constexpr.org/innoextract/ |
| inflate64 | reads the deflate64 zip members of `TribesVengeance.zip` | LGPL-2.1-or-later (frozen into the importer like pycdlib, same terms as the pycdlib row) | https://pypi.org/project/inflate64/ |
| capstone | disassembles the Aerial Assault executable's MIPS code to read its campaign mission logic (importer only, optional: without it the scripted missions fall back to "reach and destroy") | BSD-3-Clause | https://www.capstone-engine.org/ |
| **PyOPL** 2.0 (optional: Earthsiege FM music) | OPL2/OPL3 FM synthesis. Its C++ core `dbopl.cpp` is the DOSBox OPL emulator (Copyright The DOSBox Team, GPL-2.0-or-later), which PyOPL combines under GPL-3.0 | **GPL-3.0-only** | https://github.com/Malvineous/pyopl, https://pypi.org/project/PyOPL/ |

### What the GPL and LGPL components mean for the bundle
- The **importer** (`siege-importer.exe`) contains GPL code (PyOPL inside the frozen program), so it is
  distributed under the terms of the GPL-3.0. The Siege Engine code inside it is MIT licensed, which is compatible.
  pycdlib (LGPL-2.1) is frozen into it as well.
- **ffmpeg.exe** is LGPL-2.1-or-later. It runs as a separate program (the importer starts it as a child process), so
  the LGPL's relinking terms do not reach the importer: anyone can swap in another ffmpeg build, or point the
  importer at one with the environment variable `SIEGE_FFMPEG`.
- The **PyInstaller bootloader** (the start-up code of `siege-importer.exe`) is GPL-2.0-or-later with the bootloader
  exception, which allows distributing the frozen program under any terms and without the bootloader's source.
- The **game app** (`SiegeEngine.exe`) contains no GPL or LGPL code. It runs the importer as a separate program.
- **Corresponding source:** every release has two assets, `SiegeEngine-<version>-win64.zip` and
  `third-party-sources-<version>.zip` (`tools/third_party_sources.py`). The second holds the exact FFmpeg, libogg,
  libvorbis and libtheora archives with the build script and configure line, the PyPI source distributions of
  PyOPL and pycdlib at the bundled versions, this repository at the release commit (the importer's own code and
  build scripts), and `SOURCES.md` on how to rebuild each binary. `licenses/SOURCE-CODE.txt` in the zip says where
  it is and carries a written offer to provide the source on request for at least three years (GPLv3 §6, LGPL v2.1
  §6). `.github/workflows/release.yml` builds and attaches both assets together.

## Used during development or the build only (not shipped)

| component | used for | license | source |
|---|---|---|---|
| PyInstaller (the build tool itself) | freezes the importer | GPL-2.0-or-later with the bootloader exception | https://github.com/pyinstaller/pyinstaller |
| pyinstaller-hooks-contrib | PyInstaller hooks | GPL-2.0-or-later / Apache-2.0 (per hook) | https://github.com/pyinstaller/pyinstaller-hooks-contrib |
| imageio-ffmpeg (developer checkouts only; excluded from the importer build) | finds an ffmpeg when the converters run from source | BSD-2-Clause; its bundled ffmpeg binary is a GPL build, which is why releases ship our own | https://github.com/imageio/imageio-ffmpeg |
| MinGW-w64, nasm, pkg-config (Ubuntu packages) | cross-compile `ffmpeg.exe` | GPL / BSD (tools only) | your distribution's packages |
| capstone (optional, research scripts `tools/exe.py` and others) | disassembly while reverse engineering | BSD-3-Clause | https://github.com/capstone-engine/capstone |
| nginx, OpenSSL, systemd (self-hosted browser build, `deploy/`) | serving the web export on your own server; installed by your Linux distribution | BSD-2-Clause, Apache-2.0, LGPL-2.1-or-later | your distribution's packages |

## Reference material (no code copied)

| project | how it was used | license |
|---|---|---|
| open-siege / siege-studio, Copyright (c) 2019-2024 Matthew Rindel | file-format reference for the Darkstar and 3Space structures (`tools/darkstar_vol.py`, `darkstar_dts.py`, `darkstar_gfx.py`, `darkstar_mis.py`, `dts.py`, `torque_dts.py`), which are independent Python implementations following its documented field layouts. Credited here under the MIT license's notice condition. | MIT (code); its UI themes, images and logos are CC BY-SA 4.0 and not used here. https://github.com/open-siege/siege-studio |
| ScummVM `dgds` engine | format reference for the Dynamix DGDS chunked files and the trivial run-length scheme in `tools/shell.py` (`dgds_rle`); no ScummVM code is included | GPL-2.0-or-later (not applicable: nothing copied). https://github.com/scummvm/scummvm |

## Game content
None. Metaltech: Earthsiege, Metaltech: Battledrome, Earthsiege 2, Starsiege, Starsiege: Tribes and Tribes 2 belong
to their rights holders. The engine reads them only from the player's own discs at import time. See the README's
"License and trademarks" section.
