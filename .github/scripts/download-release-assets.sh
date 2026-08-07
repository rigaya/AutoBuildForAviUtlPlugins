#!/usr/bin/env bash
# 最近のリリースから asset を認証付きで探し、見つからなければ失敗する。
# Usage:
#   download-release-assets.sh <asset_regex> <dest_dir> [--extract-exe]
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <asset_regex> <dest_dir> [--extract-exe]" >&2
  exit 2
fi

ASSET_REGEX="$1"
DEST_DIR="$2"
EXTRACT_EXE=false
if [ "${3:-}" = "--extract-exe" ]; then
  EXTRACT_EXE=true
fi

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  echo "Error: GH_TOKEN or GITHUB_TOKEN is required" >&2
  exit 1
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

mkdir -p "$DEST_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FOUND_TAG=""
while IFS= read -r tag; do
  mapfile -t NAMES < <(
    gh release view "$tag" --repo "$REPO" --json assets \
      | jq -r --arg re "$ASSET_REGEX" '.assets[].name | select(test($re))'
  )
  if [ "${#NAMES[@]}" -eq 0 ]; then
    continue
  fi

  FOUND_TAG="$tag"
  echo "Found matching assets in $tag"
  for name in "${NAMES[@]}"; do
    echo "Downloading $name"
    gh release download "$tag" --repo "$REPO" -p "$name" -D "$TMP_DIR"

    if [ "$EXTRACT_EXE" = true ]; then
      unzip -q "$TMP_DIR/$name" -d "$TMP_DIR/extract"
      exe_name="${name%.zip}.exe"
      if [ ! -f "$TMP_DIR/extract/$exe_name" ]; then
        echo "Error: $exe_name not found in $name" >&2
        exit 1
      fi
      mv "$TMP_DIR/extract/$exe_name" "$DEST_DIR/"
      rm -rf "$TMP_DIR/extract" "$TMP_DIR/$name"
    else
      mv "$TMP_DIR/$name" "$DEST_DIR/"
    fi
  done
  break
done < <(gh release list --repo "$REPO" --limit 30 --json tagName --jq '.[].tagName')

if [ -z "$FOUND_TAG" ]; then
  echo "Error: no assets matching ${ASSET_REGEX} found in recent releases" >&2
  exit 1
fi

if [ "$EXTRACT_EXE" = true ]; then
  if [ -z "$(find "$DEST_DIR" -type f -name '*.exe' -print -quit)" ]; then
    echo "Error: downloaded assets but no .exe found in $DEST_DIR" >&2
    exit 1
  fi
else
  if [ -z "$(find "$DEST_DIR" -type f -print -quit)" ]; then
    echo "Error: downloaded assets but $DEST_DIR is empty" >&2
    exit 1
  fi
fi

echo "Downloaded files from $FOUND_TAG:"
ls -la "$DEST_DIR"
