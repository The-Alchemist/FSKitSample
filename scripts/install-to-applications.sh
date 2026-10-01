#!/usr/bin/env bash
# Copy the built host app over /Applications so Launch Services (ZIP opens)
# and the installed menubar extra match the last Xcode build.
set -euo pipefail

src="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is not set}/${FULL_PRODUCT_NAME:?FULL_PRODUCT_NAME is not set}"
dest="/Applications/${FULL_PRODUCT_NAME}"

if [[ ! -d "$src" ]]; then
  echo "error: built app not found: $src" >&2
  exit 1
fi

quit_if_running() {
  local name="$1"
  if pgrep -x "$name" >/dev/null 2>&1; then
    killall "$name" 2>/dev/null || true
    local i=0
    while pgrep -x "$name" >/dev/null 2>&1 && (( i < 25 )); do
      sleep 0.1
      i=$((i + 1))
    done
    killall -9 "$name" 2>/dev/null || true
  fi
}

# The installed copy (and its FSKit extension) can keep the bundle busy.
quit_if_running FSKitExp
quit_if_running FSKitExpExtension

ditto "$src" "$dest"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$dest"
echo "Copied to $dest"
