#!/bin/bash
# 候補プロファイルを基準へ一時的にマージし、純増カバレッジを評価する。
set -e

if [ $# -lt 2 ]; then
  echo "使い方: $0 BASELINE_PROFILE CANDIDATE_PROFILE..." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
BASELINE_PROFILE=$1
shift

if [ ! -r "${BASELINE_PROFILE}" ]; then
  echo "基準プロファイルを読み込めません: ${BASELINE_PROFILE}" >&2
  exit 1
fi
for candidate_profile in "$@"; do
  if [ ! -r "${candidate_profile}" ]; then
    echo "候補プロファイルを読み込めません: ${candidate_profile}" >&2
    exit 1
  fi
done

if [ -z "${LLVM_PROFDATA:-}" ]; then
  CLANG_VERSION=$(clang -dumpversion 2>/dev/null | cut -d. -f1)
  LLVM_PROFDATA=$(command -v llvm-profdata || command -v llvm-profdata-${CLANG_VERSION} || true)
fi
if [ -z "${LLVM_PROFDATA}" ]; then
  echo "llvm-profdata が見つかりません。LLVM_PROFDATA でパスを指定してください。" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT
MERGED_PROFILE=${TMP_DIR}/merged.profdata

"${LLVM_PROFDATA}" merge -output="${MERGED_PROFILE}" "${BASELINE_PROFILE}" "$@"
LLVM_PROFDATA="${LLVM_PROFDATA}" \
  bash "${SCRIPT_DIR}/analyze_svtav1_profdata.sh" "${MERGED_PROFILE}" "${BASELINE_PROFILE}"
