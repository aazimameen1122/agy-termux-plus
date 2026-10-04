#!/data/data/com.termux/files/usr/bin/bash
# Patch Google's Antigravity CLI to run natively in Termux, without glibc.
#
#   ./install.sh                 fetch and patch the pinned default version
#                                (agy-update follows the latest release instead)
#   ./install.sh --version 1.2.7 pin a version
#   ./install.sh --official-musl use Google's official musl build instead of
#                                patching the glibc one (resolves the latest
#                                release unless --version is also given)
#   ./install.sh --keep-download keep the downloaded tarball
#   ./install.sh --from-binary F patch F instead of downloading (agy-update and
#                                the wrapper's self-repair use this)
#
# Nothing here redistributes Google's binary: this downloads their published
# release, applies 56 bytes of patches, and builds a small shim beside it. The
# musl loader it links against is vendored in lib/ (see lib/README.md).
#
# Not "#!/usr/bin/env bash": Android has no /usr/bin/env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIBDIR="$HERE/lib"

# Repos pushed through GitHub's web UI lose the Unix executable bit, so a
# fresh `git clone` says "Permission denied" on ./install.sh. Heal that here:
# the only command that ever needs to work is `bash install.sh`.
chmod +x "$HERE/install.sh" "$HERE/agy" "$HERE/agy-update" \
  "$HERE/agy-doctor" "$HERE/agy-run" "$HERE/agy-proxyctl" \
  "$HERE/agy-login" "$HERE/setup-widget.sh" 2>/dev/null || true

VERSION=1.2.7
VERSION_PINNED=0
KEEP=0
FROM_BINARY=""
OFFICIAL_MUSL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; VERSION="${1:?--version needs a value}"; VERSION_PINNED=1 ;;
    --official-musl) OFFICIAL_MUSL=1 ;;
    --from-binary) shift; FROM_BINARY="${1:?--from-binary needs a path}" ;;
    --keep-download) KEEP=1 ;;
    -h|--help) sed -n '4,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1m==>\033[0m warning: %s\n' "$*" >&2; }
die()  { echo "install.sh: $*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[ "$(uname -m)" = "aarch64" ] || die "this targets aarch64; found $(uname -m)"
: "${PREFIX:=/data/data/com.termux/files/usr}"
command -v tar     >/dev/null || die "tar is required"
command -v cc      >/dev/null || die "a compiler is required (pkg install clang)"
command -v python3 >/dev/null || die "python3 is required (pkg install python)"
# At least one download method: curl, wget, or python3 (urllib). The chain
# matters on phones where one of them is broken (e.g. a libcurl/TLS skew).
have_dl() { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }
have_dl || die "need curl, wget or python3 to download (pkg install curl)"

# Termux's CA bundle, honoured by the python3 fallback below.
[ -z "${SSL_CERT_FILE:-}" ] && [ -r "$PREFIX/etc/tls/cert.pem" ] && export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"

LOADER="$LIBDIR/ld-musl-aarch64.so.1"
[ -f "$LOADER" ] || die "no musl loader at $LOADER (is this a full checkout?)"
chmod +x "$LOADER"



# --- fetch -------------------------------------------------------------------
# Resolve the latest agy release tag via the GitHub API (curl, then python3).
resolve_latest() {
  local meta
  if command -v curl >/dev/null 2>&1; then
    meta="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest" 2>/dev/null)" \
      && [ -n "$meta" ] || meta=""
  fi
  if [ -z "${meta:-}" ] && command -v python3 >/dev/null 2>&1; then
    meta="$(python3 - <<'EOF' 2>/dev/null
import json, os, ssl, sys, urllib.request
ca = os.environ.get("SSL_CERT_FILE")
ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
req = urllib.request.Request("https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "agy-termux-plus"})
sys.stdout.write(urllib.request.urlopen(req, timeout=60, context=ctx).read().decode())
EOF
)"
  fi
  [ -n "${meta:-}" ] || return 1
  printf '%s' "$meta" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null
}

# PT_INTERP of a binary; empty for static binaries.
interp_of() {
  python3 - "$1" <<'EOF' 2>/dev/null
import struct, sys
p = sys.argv[1]
with open(p, "rb") as f:
    d = f.read(64)
    if d[:4] != b"\x7fELF": sys.exit(1)
    phoff, = struct.unpack("<Q", d[32:40])
    phentsize, phnum = struct.unpack("<HH", d[54:58])
    f.seek(phoff)
    ph = f.read(phentsize * phnum)
    for i in range(phnum):
        e = ph[i*phentsize:(i+1)*phentsize]
        ptype, = struct.unpack("<I", e[:4])
        if ptype == 3:  # PT_INTERP
            off, = struct.unpack("<Q", e[16:24]); sz, = struct.unpack("<Q", e[32:40])
            f.seek(off); sys.stdout.write(f.read(sz).split(b"\0")[0].decode()); break
EOF
}

ASSET="agy_cli_linux_arm64.tar.gz"
if [ "$OFFICIAL_MUSL" = 1 ]; then
  # Google's own musl build (static since it appeared): no loader or shim
  # needed, but it carries the same three bugs, so patch.py still applies.
  ASSET="agy_cli_linux_arm64_musl.tar.gz"
  if [ "$VERSION_PINNED" = 0 ]; then
    say "resolving the latest release (official musl builds are new)"
    VERSION="$(resolve_latest)" || die "could not resolve the latest release"
    say "latest release is $VERSION"
  fi
fi
URL="https://github.com/google-antigravity/antigravity-cli/releases/download/$VERSION/$ASSET"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Download with a fallback chain: curl, then wget, then python3's urllib.
# Any one of them being broken (a skewed libcurl, a missing wget) no longer
# kills the install — the next method is tried.
download() { # url dest
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ] && return 0
    warn "curl failed, trying the next downloader"
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url" 2>/dev/null && [ -s "$dest" ] && return 0
    warn "wget failed, trying the next downloader"
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$dest" <<'EOF' 2>/dev/null && [ -s "$dest" ] && return 0
import os, ssl, sys, urllib.request
url, dest = sys.argv[1], sys.argv[2]
ca = os.environ.get("SSL_CERT_FILE")
ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
req = urllib.request.Request(url, headers={"User-Agent": "agy-termux-plus"})
with urllib.request.urlopen(req, timeout=300, context=ctx) as r, open(dest, "wb") as f:
    while True:
        b = r.read(1 << 20)
        if not b: break
        f.write(b)
EOF
  fi
  return 1
}

if [ -n "$FROM_BINARY" ]; then
  if [ ! -f "$FROM_BINARY" ]; then die "no such file: $FROM_BINARY"; fi
  say "using the binary given with --from-binary"
  cp "$FROM_BINARY" "$tmp/antigravity"
elif [ -f "$HERE/$ASSET" ]; then
  say "using the tarball already here"
  cp "$HERE/$ASSET" "$tmp/$ASSET"
else
  say "fetching Antigravity CLI $VERSION — about 58MB"
  download "$URL" "$tmp/$ASSET" \
    || { if [ "$OFFICIAL_MUSL" = 1 ]; then
           die "could not download $URL (tried curl, wget, python3) — the official musl asset only exists for recent releases; try without --version to take the latest"
         else
           die "could not download $URL (tried curl, wget, python3)"
         fi; }
  [ "$KEEP" = 1 ] && cp "$tmp/$ASSET" "$HERE/$ASSET"
fi

if [ -z "$FROM_BINARY" ]; then
  tar xzf "$tmp/$ASSET" -C "$tmp" || die "could not extract $ASSET"
fi
[ -f "$tmp/antigravity" ] || die "no 'antigravity' binary to patch"

# --- patch -------------------------------------------------------------------
# Three fixes -- the google_find_phdr load bias, the glibc TCB read, and the
# seccomp-blocked faccessat2 -- 14 instructions (56 bytes) in place, file size
# unchanged. Seven are in agy itself, seven in the two helper ELFs it embeds.
# See FINDINGS.md, and antigravity-cli#1075 upstream.
#
# TCMalloc's 48-bit VA assumption is not patched: on 1.2.x the allocator is
# never reached (FINDINGS.md), and the verify step below is the safety net if a
# future release changes that.
say "applying the binary patches"
# Build into a temp file and rename at the end: overwriting agy.bin in place
# fails with ETXTBSY if a copy is still running.
NEW="$HERE/.agy.bin.new.$$"
trap 'rm -rf "$tmp" "$NEW"' EXIT
cp "$tmp/antigravity" "$NEW"
chmod +x "$NEW"

python3 "$HERE/patch.py" "$NEW" || die "patching failed"

# --- musl linkage ------------------------------------------------------------
# Google's official musl build is static: no interpreter, no DT_NEEDED, no
# shim — patch.py above already fixed its three bugs, so there is nothing
# left to link. The glibc build needs the vendored loader and the shim.
if [ -z "$(interp_of "$NEW")" ]; then
  say "static binary: no loader or shim needed"
else
  say "repointing the interpreter at musl"
  command -v patchelf >/dev/null || pkg install -y patchelf >/dev/null 2>&1 \
    || die "patchelf is required (pkg install patchelf)"

  patchelf --set-interpreter "$LOADER" "$NEW"
  for n in libresolv.so.2 libpthread.so.0 libm.so.6 libdl.so.2 librt.so.1; do
    patchelf --remove-needed "$n" "$NEW" 2>/dev/null || true
  done
  patchelf --replace-needed libc.so.6 libc.musl-aarch64.so.1 "$NEW"
  # The shim lives in lib/ next to the binary; $ORIGIN makes the binary find it
  # on its own, so nothing needs LD_LIBRARY_PATH to run agy.bin.
  patchelf --set-rpath '$ORIGIN/lib' "$NEW"

  # --- shim --------------------------------------------------------------------
  # Ten glibc-only symbols musl does not provide. Built against the musl loader,
  # not bionic: a normal build links to bionic and dies on __register_atfork.
  say "building the compatibility shim"
  mkdir -p "$LIBDIR"
  cc -shared -fPIC -O2 -nostdlib -o "$LIBDIR/libagyshim.so" "$HERE/shim.c" "$LOADER" \
    || die "could not build the shim"
  patchelf --add-needed libagyshim.so "$NEW"
fi

# --- verify ------------------------------------------------------------------
# Run the patched binary before it replaces agy.bin, so a build that cannot
# start is never installed. The wrapper's self-repair drives straight through
# here too.
#
# $NEW is run directly rather than through the agy wrapper: the wrapper would
# test whatever agy.bin is right now, which is the binary being replaced. No
# LD_LIBRARY_PATH: the rpath set above has to be enough, and this proves it.
say "checking that the patched binary runs"
v="$(env -u LD_PRELOAD "$NEW" --version 2>&1 || true)"
case "$v" in
  *[0-9].[0-9]*) ;;
  *) die "the patched binary did not report a version (said: ${v:-nothing})

  agy.bin was left exactly as it was; nothing has been replaced.

  Please open an issue with the output above and your Android version:
    https://github.com/Aarstad/agy-termux-musl/issues
  If you have a binary that is known to run here, install that one instead
  with: ./install.sh --from-binary <path>" ;;
esac

# --- install -----------------------------------------------------------------
mv -f "$NEW" "$HERE/agy.bin" || die "could not install agy.bin (is a copy running?)"
say "installed: agy $v"

# --- proxy -------------------------------------------------------------------
# musl resolves through /etc/resolv.conf, which Android does not have, so DNS
# inside the process hangs. This proxy runs on the bionic side, where it works.
if [ -f "$HERE/termux-http-proxy.c" ]; then
  say "building the proxy"
  cc -O2 -o "$HERE/termux-http-proxy" "$HERE/termux-http-proxy.c" || die "could not build the proxy"
  rm -f "$HERE/dns-proxy" # Its name before the rename
fi

rm -rf "$tmp"; trap - EXIT

echo
echo "  run it with:   $HERE/agy"
echo "  on your PATH:  ln -sf $HERE/agy ~/.local/bin/agy"
echo "  log in:        agy       (then follow the browser prompts)"
echo
echo "  extra tools in this fork:"
echo "    ./agy-doctor       health check (patches, proxy, DNS, TLS, git, termux-api)"
echo "    ./agy-run          wake-lock, session logs, notify/copy/Telegram on finish"
echo "    ./agy-proxyctl     shared proxy daemon: start|stop|status|log"
echo "    ./setup-widget.sh  home-screen shortcuts via Termux:Widget"

if [ -x "$HERE/agy-doctor" ]; then
  echo
  say "running a quick health check"
  "$HERE/agy-doctor" --quick || true
fi
