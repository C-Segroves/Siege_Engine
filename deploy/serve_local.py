#!/usr/bin/env python3
"""Serves an exported Siege Engine browser build for a quick local test (not for the CT: that uses nginx).

    python deploy/serve_local.py --root build/web [--data <packs dir>] [--port 8060] [--bind 127.0.0.1]

Sends the same headers as deploy/nginx-site.conf.template: the WebAssembly MIME type, cross-origin
isolation (COOP/COEP, needed only by a threaded build) and no-cache revalidation. --data serves a
folder written by game/tools/web/pack_gamedata.gd at /data/ (default: <root>/data).
Binds to 127.0.0.1 by default: a page served from localhost counts as a secure context.
"""
import argparse
import functools
import http.server
import os
import posixpath

DATA_PREFIX = '/data/'
EXTRA_TYPES = {'.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.js': 'text/javascript'}


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, **EXTRA_TYPES}
    data_dir = None

    def translate_path(self, path):
        clean = path.split('?', 1)[0].split('#', 1)[0]
        if self.data_dir and clean.startswith(DATA_PREFIX):
            rel = posixpath.normpath(clean[len(DATA_PREFIX):]).lstrip('/')
            if rel.startswith('..'):
                return os.path.join(self.data_dir, 'not-found')
            return os.path.join(self.data_dir, *rel.split('/'))
        return super().translate_path(path)

    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--root', required=True, help='folder with index.html of the Web export')
    ap.add_argument('--data', help='folder with packs.json and the .pck packs (default: <root>/data)')
    ap.add_argument('--port', type=int, default=8060)
    ap.add_argument('--bind', default='127.0.0.1')
    a = ap.parse_args()
    Handler.data_dir = os.path.abspath(a.data) if a.data else None
    handler = functools.partial(Handler, directory=os.path.abspath(a.root))
    with http.server.ThreadingHTTPServer((a.bind, a.port), handler) as server:
        print('Serving %s on http://%s:%d/ (Ctrl+C stops)' % (a.root, a.bind, a.port), flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
