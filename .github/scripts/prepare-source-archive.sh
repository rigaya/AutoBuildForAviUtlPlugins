#!/usr/bin/env bash
# 同一リビジョンのソースAssetを再利用し、取得できない場合だけ自前で作成する。
# 使用法:
#   prepare-source-archive.sh <project_name> <repository_url> <revision> <dest_dir>
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <project_name> <repository_url> <revision> <dest_dir>" >&2
  exit 2
fi

PROJECT_NAME="$1"
REPOSITORY_URL="$2"
REVISION="$3"
DEST_DIR="$4"

if [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: invalid project name: $PROJECT_NAME" >&2
  exit 2
fi
if [[ ! "$REVISION" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Error: revision must be a full Git SHA: $REVISION" >&2
  exit 2
fi

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
if [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  echo "Error: GH_TOKEN or GITHUB_TOKEN is required" >&2
  exit 1
fi
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"
ARCHIVE_NAME="${PROJECT_NAME}_${REVISION}_src.7z"
ARCHIVE_PATH="${DEST_DIR}/${ARCHIVE_NAME}"

archive_is_clean() {
  local archived_paths
  if ! archived_paths="$(7z l -slt "$1" | awk -F' = ' '$1 == "Path" { print $2 }')"; then
    return 1
  fi
  ! grep -Eq '(^|/)\.git(/|$)' <<< "$archived_paths"
}

# ひとつ前のリリースにある完全SHA一致のAssetだけを再利用する。
if gh release download --repo "$REPO" -p "$ARCHIVE_NAME" -D "$DEST_DIR"; then
  if archive_is_clean "$ARCHIVE_PATH"; then
    echo "同一リビジョンのソースAssetを再利用します: $ARCHIVE_NAME"
    exit 0
  fi

  echo "既存Assetが不正か.gitディレクトリを含むため作り直します: $ARCHIVE_NAME" >&2
fi
rm -f "$ARCHIVE_PATH"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
SOURCE_DIR="${TEMP_DIR}/${PROJECT_NAME}"

echo "ソースを取得してアーカイブを作成します: ${PROJECT_NAME}@${REVISION}"
git init --quiet "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$REPOSITORY_URL"
git -C "$SOURCE_DIR" fetch --quiet --depth 1 origin "$REVISION"
git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD

# サブモジュール等も含め、全階層の.gitディレクトリを除去する。
find "$SOURCE_DIR" -type d -name .git -prune -exec rm -rf {} +
if find "$SOURCE_DIR" -type d -name .git -print -quit | grep -q .; then
  echo "Error: .gitディレクトリを除去できませんでした" >&2
  exit 1
fi

(
  cd "$TEMP_DIR"
  7z a -t7z -mx=9 "$ARCHIVE_PATH" "$PROJECT_NAME"
)

if ! archive_is_clean "$ARCHIVE_PATH"; then
  echo "Error: 作成したAssetが不正か.gitディレクトリを含んでいます" >&2
  exit 1
fi

echo "ソースAssetを作成しました: $ARCHIVE_NAME"
