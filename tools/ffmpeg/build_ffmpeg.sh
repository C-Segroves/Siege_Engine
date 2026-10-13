#!/usr/bin/env bash
# Builds the disc importer's ffmpeg.exe: a small, static, LGPL-2.1-or-later FFmpeg for 64-bit Windows,
# cross-compiled with MinGW-w64 on Linux (Ubuntu; WSL, Docker or GitHub Actions).
#
#   bash tools/ffmpeg/build_ffmpeg.sh [--install-deps] <out dir>
#
#   --install-deps  apt-get installs the toolchain first (needs root: Docker / CI). The packages are
#                   mingw-w64 (gcc-mingw-w64-x86-64-win32, binutils), nasm, pkg-config, make, xz-utils, curl.
#   Docker:         docker run --rm -v "$PWD:/src" -w /src ubuntu:24.04 \
#                       bash tools/ffmpeg/build_ffmpeg.sh --install-deps build/ffmpeg
#
# Inputs:  the archives pinned in tools/ffmpeg/sources.lock (downloaded to <out>/src unless already there;
#          every archive's SHA-256 is checked, a mismatch stops the build).
# Outputs: <out>/ffmpeg/ffmpeg.exe              the program bundled with siege-importer
#          <out>/ffmpeg/BUILD.txt               versions, archive hashes, toolchain and the exact configure line
#          <out>/ffmpeg/licenses/               license texts of FFmpeg, libogg, libvorbis, libtheora, MinGW-w64
#          <out>/src/*.tar.xz                   the verified source archives (they go into the release's
#                                               third-party-sources zip, tools/third_party_sources.py)
#
# Licensing: configured WITHOUT --enable-gpl, --enable-version3 and --enable-nonfree, and with
# --disable-autodetect, so nothing but the components listed below is built in. The result is LGPL-2.1-or-later
# (FFmpeg) plus BSD-3-Clause (libogg, libvorbis, libtheora); the script refuses to finish otherwise.
# Only what the importer uses is enabled (tools/video.py, export_movies.py, siege_cd.py, siege_soundtrack.py,
# render_music.py, music_situations.py):
#   in:  AVI (Earthsiege 2: Indeo 3/4, Cinepak, MS Video 1, MS RLE, Autodesk RLE; PCM), Smacker (Starsiege),
#        raw RGB frames (Earthsiege FLIC), WAV/AIFF/FLAC/MP3/Ogg/M4A/WMA audio (cue-sheet CD images and
#        the player's own soundtrack rips)
#   out: Ogg Theora + Vorbis (.ogv), Ogg Vorbis (.ogg), 16-bit WAV / raw PCM
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$HERE/sources.lock"
HOST=x86_64-w64-mingw32

install_deps=0
if [[ "${1:-}" == "--install-deps" ]]; then install_deps=1; shift; fi
[[ $# -eq 1 ]] || { sed -n '2,9p' "$0"; exit 2; }
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
SRC="$OUT/src" WORK="$OUT/work" PREFIX="$OUT/work/prefix" DEST="$OUT/ffmpeg"

if (( install_deps )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends gcc-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 \
        mingw-w64-x86-64-dev nasm pkg-config make xz-utils curl ca-certificates
fi
for tool in $HOST-gcc nasm pkg-config make curl sha256sum tar; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool (see --install-deps)" >&2; exit 1; }
done

# ------------------------------------------------------------------ fetch + verify the pinned archives
lock_field() {   # lock_field <name> <column 2..4>
    awk -v n="$1" -v c="$2" '$1 == n { print $c }' "$LOCK"
}
mkdir -p "$SRC" "$WORK" "$PREFIX" "$DEST/licenses"
for name in ffmpeg libogg libvorbis libtheora; do
    file="$(lock_field "$name" 2)" sum="$(lock_field "$name" 3)" url="$(lock_field "$name" 4)"
    [[ -n "$file" && -n "$sum" && -n "$url" ]] || { echo "sources.lock has no complete entry for $name" >&2; exit 1; }
    [[ -f "$SRC/$file" ]] || curl -fsSL --retry 3 -o "$SRC/$file" "$url"
    echo "$sum  $SRC/$file" | sha256sum -c --quiet - || { echo "SHA-256 mismatch: $file" >&2; exit 1; }
    rm -rf "$WORK/$name" && mkdir -p "$WORK/$name"
    tar -xJf "$SRC/$file" -C "$WORK/$name" --strip-components=1
done

JOBS="$(nproc 2>/dev/null || echo 4)"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" PKG_CONFIG_PATH=""
export CFLAGS="-O2" LDFLAGS="-static"
autotools_lib() {   # autotools_lib <dir> [extra configure args...]
    local dir="$1"; shift
    (cd "$WORK/$dir" && ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static "$@" >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)
}
echo "building libogg, libvorbis, libtheora ..."
autotools_lib libogg
autotools_lib libvorbis --disable-docs --disable-examples --disable-oggtest
# --disable-asm: libtheora 1.2.0's x86 assembly produces corrupt Theora streams in this MinGW-w64 x86_64 build
# (FFmpeg's decoder reports "error in unpack_block_qpis" on every file); the C code path encodes correctly.
autotools_lib libtheora --disable-asm --disable-doc --disable-spec --disable-examples --disable-oggtest --disable-vorbistest

# ------------------------------------------------------------------ FFmpeg
DECODERS=rawvideo,anm,flic,smacker,smackaud,msvideo1,msrle,aasc,cinepak,indeo2,indeo3,indeo4,indeo5,theora
DECODERS+=,pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_alaw,pcm_mulaw
DECODERS+=,adpcm_ima_wav,adpcm_ms,mp1float,mp2float,mp3float,flac,vorbis,opus,aac,alac,wmav1,wmav2,wmapro,wmalossless
ENCODERS=libtheora,libvorbis,pcm_s16le,pcm_u8,wrapped_avframe   # wrapped_avframe: `-f null` decode checks
DEMUXERS=avi,smacker,anm,flic,rawvideo,wav,aiff,mp3,flac,ogg,mov,asf,pcm_s16le
MUXERS=ogg,wav,pcm_s16le,null,framemd5
PARSERS=mpegaudio,flac,vorbis,opus,aac
FILTERS=scale,format,aformat,aresample,fps,tpad,trim,atrim,setpts,asetpts,null,anull,copy,acopy,pad,crop
PROTOCOLS=file,pipe

CONFIGURE=(
    --arch=x86_64 --target-os=mingw32 --cross-prefix=$HOST- --pkg-config=pkg-config --pkg-config-flags=--static
    --extra-ldflags=-static
    --enable-static --disable-shared --disable-autodetect --enable-w32threads
    --disable-everything --disable-network --disable-doc --disable-debug --disable-ffplay --disable-ffprobe
    --disable-avdevice
    --enable-libvorbis --enable-libtheora
    --enable-decoder=$DECODERS --enable-encoder=$ENCODERS --enable-demuxer=$DEMUXERS --enable-muxer=$MUXERS
    --enable-parser=$PARSERS --enable-filter=$FILTERS --enable-protocol=$PROTOCOLS
)
echo "configuring FFmpeg ..."
# the libraries are found through these variables (FFmpeg's configure reads CFLAGS / LDFLAGS from the environment)
# rather than --extra-cflags / --extra-ldflags paths, so the configuration string that ffmpeg.exe prints
# (`ffmpeg -version`) holds no machine-specific folders
export CFLAGS="-O2 -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -static"
(cd "$WORK/ffmpeg" && ./configure "${CONFIGURE[@]}" >"$WORK/ffmpeg-configure.log") || {
    tail -30 "$WORK/ffmpeg/ffbuild/config.log" >&2; exit 1; }
for flag in GPL VERSION3 NONFREE; do
    grep -q "^#define CONFIG_$flag 0" "$WORK/ffmpeg/config.h" || { echo "CONFIG_$flag is set: not an LGPL build" >&2; exit 1; }
done
echo "building FFmpeg ..."
(cd "$WORK/ffmpeg" && make -j"$JOBS" ffmpeg.exe >/dev/null)
$HOST-strip -o "$DEST/ffmpeg.exe" "$WORK/ffmpeg/ffmpeg.exe"

# ------------------------------------------------------------------ licenses + build record
cp "$WORK/ffmpeg/COPYING.LGPLv2.1" "$DEST/licenses/FFmpeg-COPYING.LGPLv2.1.txt"
cp "$WORK/ffmpeg/LICENSE.md" "$DEST/licenses/FFmpeg-LICENSE.md"
for lib in libogg libvorbis libtheora; do cp "$WORK/$lib/COPYING" "$DEST/licenses/$lib-COPYING.txt"; done
for doc in /usr/share/doc/mingw-w64-common/copyright /usr/share/doc/mingw-w64-x86-64-dev/copyright; do
    if [[ -f "$doc" ]]; then cp "$doc" "$DEST/licenses/MinGW-w64-runtime-copyright.txt"; break; fi
done
# the build folder is written as <out> so the record carries no machine-specific paths
configuration="$(sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' "$WORK/ffmpeg/config.h" | sed "s|$OUT|<out>|g")"
{
    echo "ffmpeg.exe for Siege Engine's disc importer"
    echo "Built by tools/ffmpeg/build_ffmpeg.sh on $(date -u +%Y-%m-%d)."
    echo "License: LGPL-2.1-or-later (FFmpeg, no --enable-gpl / --enable-version3 / --enable-nonfree) with the"
    echo "BSD-3-Clause libraries libogg, libvorbis and libtheora linked in statically. ffmpeg.exe is a separate"
    echo "program run by the importer; nothing links against it."
    echo
    echo "Source archives (all in third-party-sources-<version>.zip; pinned in tools/ffmpeg/sources.lock):"
    grep -v '^#' "$LOCK" | awk 'NF { printf "  %-12s %-26s sha256 %s\n", $1, $2, $3 }'
    echo
    echo "Toolchain: $($HOST-gcc --version | head -1); $($HOST-ld --version | head -1); $(nasm -v)"
    echo "Library builds: ./configure --host=$HOST --disable-shared --enable-static (+ docs/examples/tests off;"
    echo "  libtheora also --disable-asm)"
    echo
    echo "FFmpeg configure line:"
    echo "  ./configure $configuration"
    echo
    echo "ffmpeg.exe sha256: $(sha256sum "$DEST/ffmpeg.exe" | cut -d' ' -f1)"
} >"$DEST/BUILD.txt"
cat "$DEST/BUILD.txt"
