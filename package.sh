#!/usr/bin/env bash
# Package a template for sale. Usage: ./package.sh <template-folder> <output-name>
# e.g. ./package.sh atlas atlas-nextjs
set -euo pipefail

SRC="${1:?usage: ./package.sh <template-folder> <output-name>}"
NAME="${2:?usage: ./package.sh <template-folder> <output-name>}"
DIST="${NAME}"

rm -rf "$DIST" "${NAME}.zip"
cp -r "$SRC" "$DIST"

# --- strip everything that must never ship ---
rm -rf "$DIST/node_modules" \
       "$DIST/.next" \
       "$DIST/.git" \
       "$DIST/_reference" \
       "$DIST/.turbo" \
       "$DIST/dist"
find "$DIST" -name ".env.local" -delete
find "$DIST" -name ".env" -delete
find "$DIST" -name ".DS_Store" -delete
find "$DIST" -name "*.log" -delete

# --- safety net: refuse to ship if a real secret slipped through ---
if grep -rIlE "(sk_live|re_[A-Za-z0-9]{20}|NEXT_PUBLIC_[A-Z_]+=.+[A-Za-z0-9])" "$DIST" 2>/dev/null; then
  echo "ABORT: possible secret found in the files above. Clean them and re-run."
  rm -rf "$DIST"
  exit 1
fi

# --- must-exist check ---
for f in README.md LICENSE.md package.json; do
  [ -f "$DIST/$f" ] || { echo "WARNING: $f is missing from the build"; }
done

# --- what the buyer will get ---
echo "Contents:"
( cd "$DIST" && find . -maxdepth 2 -not -path '*/\.*' | sort )

zip -rq "${NAME}.zip" "$DIST" -x "*.DS_Store"
rm -rf "$DIST"
echo ""
echo "Built ${NAME}.zip"
