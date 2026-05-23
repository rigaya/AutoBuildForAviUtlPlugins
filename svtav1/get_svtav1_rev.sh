#!/bin/bash
# 最新の vX.Y.Z 形式タグを基準に、HEAD までのコミット数からリビジョン文字列を生成する。
# 例: v4.1.0 + 151 commits -> 4.1.0-151
# 例: v4.1.0 (HEAD がタグ上)   -> 4.1.0

GIT_DIR="${1:-build_svtav1/src/SVT-AV1}"

if [ ! -d "$GIT_DIR/.git" ]; then
    echo "Error: git directory not found: $GIT_DIR" >&2
    exit 1
fi

LATEST_TAG=$(
    git -C "$GIT_DIR" tag -l |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        sort -V |
        tail -n1
)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: no semver tag (vX.Y.Z) found in $GIT_DIR" >&2
    exit 1
fi

COMMIT_COUNT=$(git -C "$GIT_DIR" rev-list --count "${LATEST_TAG}..HEAD")
VERSION_BASE=${LATEST_TAG#v}

if [ "$COMMIT_COUNT" -eq 0 ]; then
    echo "${VERSION_BASE}"
else
    echo "${VERSION_BASE}-${COMMIT_COUNT}"
fi
