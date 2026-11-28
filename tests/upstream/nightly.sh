#!/bin/sh
# The newest Odin nightly for this platform, fetched into the directory given, and the path of its odin printed:
#   tests/upstream/nightly.sh <dir>
# The newest night that has this platform's: a night's may lack one, as it is built.
set -eu
dest=$1
case "$(uname -s)" in
Linux) want=linux-amd64 ;;
Darwin) want=macos-arm64 ;;
MINGW* | MSYS* | CYGWIN*) want=windows-amd64 ;;
*) echo "no nightly for $(uname -s)" >&2; exit 1 ;;
esac
python=python3
python3 -c "" 2>/dev/null || python=python # Windows may have a python3 that only offers to install one
mkdir -p "$dest"
curl -fsSLo "$dest/nightly.json" https://f001.backblazeb2.com/file/odin-binaries/nightly.json
url=$($python -c 'import json, sys
files = json.load(open(sys.argv[1]))["files"]
for day in sorted(files, reverse=True):
    for f in files[day]:
        if "-" + sys.argv[2] + "-" in f["name"]:
            print(f["url"])
            sys.exit(0)
sys.exit("no nightly for " + sys.argv[2])' "$dest/nightly.json" "$want")
echo "$url" >&2
case "$url" in
*.zip) curl -fsSLo "$dest/odin.zip" "$url" && (cd "$dest" && unzip -qo odin.zip) ;;
*) curl -fsSLo "$dest/odin.tar.gz" "$url" && (cd "$dest" && tar xzf odin.tar.gz) ;;
esac
odin=$(find "$dest" -type f \( -name odin -o -name odin.exe \) | head -n 1)
[ -n "$odin" ] || { echo "no odin in $url" >&2; exit 1; }
chmod +x "$odin"
echo "$odin"
