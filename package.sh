#!/usr/bin/env bash
# Package a template for sale. Usage: ./package.sh <template-folder> <output-name>
# e.g. ./package.sh atlas atlas-nextjs-v1.0.0
#
# Uses git to decide what ships: everything EXCEPT what .gitignore excludes.
# Falls back to a manual strip if the folder isn't a git repo.
set -euo pipefail

SRC="${1:?usage: ./package.sh <template-folder> <output-name>}"
NAME="${2:?usage: ./package.sh <template-folder> <output-name>}"
DIST="${NAME}"

rm -rf "$DIST" "${NAME}.zip"
mkdir -p "$DIST"

if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Git repo detected — copying only non-ignored files."
  # tracked + untracked, minus anything .gitignore excludes
  git -C "$SRC" ls-files --cached --others --exclude-standard -z \
    | while IFS= read -r -d '' f; do
        mkdir -p "$DIST/$(dirname "$f")"
        cp "$SRC/$f" "$DIST/$f"
      done
  # .gitignore itself is tracked and useful to the buyer; git already copied it.
  # But strip .git just in case a nested one exists.
  rm -rf "$DIST/.git"
else
  echo "Not a git repo — using manual strip."
  cp -r "$SRC/." "$DIST/"
  rm -rf "$DIST/node_modules" "$DIST/.next" "$DIST/.git" \
         "$DIST/_reference" "$DIST/.turbo" "$DIST/dist"
fi

# --- belt-and-braces: these must never ship even if git tracks them ---
find "$DIST" -name ".env.local" -delete
find "$DIST" -name ".env" -delete
find "$DIST" -name ".DS_Store" -delete
find "$DIST" -name "*.log" -delete
rm -rf "$DIST/_reference"

# --- safety net: refuse to ship if a real secret slipped through ---
if grep -rIlE "(sk_live|re_[A-Za-z0-9]{20}|NEXT_PUBLIC_[A-Z_]+=.+[A-Za-z0-9])" "$DIST" 2>/dev/null; then
  echo "ABORT: possible secret found in the files above. Clean them and re-run."
  rm -rf "$DIST"
  exit 1
fi

# --- must-exist check ---
for f in README.md LICENSE.md package.json; do
  [ -f "$DIST/$f" ] || echo "WARNING: $f is missing from the build"
done

# --- what the buyer will get ---
echo ""
echo "Contents:"
( cd "$DIST" && find . -maxdepth 2 -not -path '*/\.git*' | sort )

zip -rq "${NAME}.zip" "$DIST" -x "*.DS_Store"
rm -rf "$DIST"
echo ""
echo "Built ${NAME}.zip"
