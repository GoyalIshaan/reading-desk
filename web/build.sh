#!/bin/bash
# Rebuilds Resources/web/renderer.js from web/renderer.js.
# Needs esbuild plus the markdown-it and highlight.js packages somewhere on NODE_PATH, e.g.
#   NODE_PATH=/path/to/node_modules ESBUILD=/path/to/esbuild ./web/build.sh
# The bundled output is committed, so ./build.sh does not need Node.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"${ESBUILD:-esbuild}" "$here/renderer.js" --bundle --minify --format=iife --target=safari16 \
    --outfile="$here/../Resources/web/renderer.js" --legal-comments=none
