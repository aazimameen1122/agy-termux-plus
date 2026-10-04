#!/data/data/com.termux/files/usr/bin/bash
# setup-widget.sh — put agy on your home screen via Termux:Widget.
#
# Generates executable scripts in ~/.shortcuts (baked with this repo's path):
#   "agy models"   — list models (and log in on first run)
#   "agy update"   — update agy to the latest release
#   "agy doctor"   — health check
#   "agy proxy"    — start the shared proxy daemon
#
# Needs the Termux:Widget app from F-Droid/GitHub. Long-press the widget to
# refresh after running this. Re-run after moving the repo.
#
# Not "#!/usr/bin/env bash": Android has no /usr/bin/env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SHORTCUTS="$HOME/.shortcuts"
mkdir -p "$SHORTCUTS"

mk() { # name, command
  cat > "$SHORTCUTS/$1" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "$HERE"
exec $2
EOF
  chmod +x "$SHORTCUTS/$1"
  echo "  $1"
}

echo "writing shortcuts to $SHORTCUTS:"
mk "agy models"   "./agy-run --notify -- models"
mk "agy login"    "./agy-login"
mk "agy update"   "./agy-update"
mk "agy doctor"   "./agy-doctor"
mk "agy proxy"    "./agy-proxyctl start"
echo
echo "Add the Termux:Widget to your home screen and long-press it to refresh."
echo "Tip: edit \"agy models\" to add your usual flags (e.g. -p \"...\")."
