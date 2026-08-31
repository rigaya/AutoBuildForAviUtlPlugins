#!/bin/bash
# SVT-AV1 の LLVM instrumentation profile を関数・内部カウンタ単位で集計する。
set -e

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "使い方: $0 PROFILE [BASELINE_PROFILE]" >&2
  exit 1
fi

PROFILE=$1
BASELINE_PROFILE=${2:-}

if [ ! -r "${PROFILE}" ]; then
  echo "プロファイルを読み込めません: ${PROFILE}" >&2
  exit 1
fi
if [ -n "${BASELINE_PROFILE}" ] && [ ! -r "${BASELINE_PROFILE}" ]; then
  echo "基準プロファイルを読み込めません: ${BASELINE_PROFILE}" >&2
  exit 1
fi

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

function profile_to_tsv() {
  local profile_path=$1
  local output_path=$2

  "${LLVM_PROFDATA}" show --all-functions --counts "${profile_path}" |
    awk -F'[][]' '
      /^  [^ ].*:$/ {
        name = substr($0, 3, length($0) - 3)
        next
      }
      /^    Block counts:/ {
        count = split($2, values, /, */)
        nonzero = 0
        total_count = 0
        for (i = 1; i <= count; i++) {
          if (values[i] + 0 != 0)
            nonzero++
          total_count += values[i]
        }
        executed = nonzero > 0
        printf "%s\t%d\t%d\t%d\t%.0f\n", name, executed, nonzero, count, total_count
      }
    ' > "${output_path}"
}

function show_summary() {
  local tsv_path=$1
  local label=$2
  local pattern=$3

  awk -F '\t' -v label="${label}" -v pattern="${pattern}" '
    pattern == "" || tolower($1) ~ pattern {
      functions++
      covered_functions += ($2 > 0)
      covered_counters += $3
      counters += $4
    }
    END {
      function_rate = functions ? covered_functions * 100 / functions : 0
      counter_rate = counters ? covered_counters * 100 / counters : 0
      printf "%-20s %5d / %5d (%6.2f%%)  内部 %7d / %7d (%6.2f%%)\n", \
             label, covered_functions, functions, function_rate, covered_counters, counters, counter_rate
    }
  ' "${tsv_path}"
}

function show_delta_summary() {
  local current_tsv=$1
  local baseline_tsv=$2
  local label=$3
  local pattern=$4

  awk -F '\t' -v label="${label}" -v pattern="${pattern}" '
    NR == FNR {
      baseline_executed[$1] = $2
      baseline_counters[$1] = $3
      next
    }
    pattern == "" || tolower($1) ~ pattern {
      current_executed += ($2 > 0)
      old_executed = (($1 in baseline_executed) ? baseline_executed[$1] : 0)
      old_counters = (($1 in baseline_counters) ? baseline_counters[$1] : 0)
      baseline_executed_total += (old_executed > 0)
      newly_executed += ($2 > 0 && old_executed == 0)
      lost_executed += ($2 == 0 && old_executed > 0)
      counter_delta += $3 - old_counters
    }
    END {
      printf "%-20s 関数 %+5d（新規 %4d、消失 %4d）  内部カウンタ %+7d\n", \
             label, current_executed - baseline_executed_total, newly_executed, lost_executed, counter_delta
    }
  ' "${baseline_tsv}" "${current_tsv}"
}

CURRENT_TSV=${TMP_DIR}/current.tsv
profile_to_tsv "${PROFILE}" "${CURRENT_TSV}"

echo "プロファイル: ${PROFILE}"
echo "実行関数カバレッジ / 内部カウンタカバレッジ"
show_summary "${CURRENT_TSV}" "全体" ""
show_summary "${CURRENT_TSV}" "AVX2" "avx2"
show_summary "${CURRENT_TSV}" "SAD・variance" "sad|variance"
show_summary "${CURRENT_TSV}" "transform・quantize" "txfm|transform|quant"
show_summary "${CURRENT_TSV}" "convolve" "convolve"
show_summary "${CURRENT_TSV}" "intra" "intra"
show_summary "${CURRENT_TSV}" "CDEF・restoration" "cdef|restoration|wiener|selfguided"
show_summary "${CURRENT_TSV}" "temporal・noise" "temporal|noise"
show_summary "${CURRENT_TSV}" "tile・entropy" "tile|entropy_coding|ec_process"
show_summary "${CURRENT_TSV}" "resize・superres" "resize|superres|upscale|down2"
show_summary "${CURRENT_TSV}" "palette・screen" "palette|intrabc"
show_summary "${CURRENT_TSV}" "rate control" "rate_control|[/;]rc_|_rc_|twopass|rate_allocation"
show_summary "${CURRENT_TSV}" "warp" "warp"

echo
echo "カテゴリ対象の未実行関数（最大80件）"
awk -F '\t' '
  $2 == 0 && tolower($1) ~ /avx2|sad|variance|txfm|transform|quant|convolve|intra|cdef|restoration|wiener|selfguided|temporal|noise|tile|entropy_coding|ec_process|resize|superres|upscale|down2|palette|intrabc|rate_control|[/;]rc_|_rc_|twopass|rate_allocation|warp/ {
    print $1
  }
' "${CURRENT_TSV}" | LC_ALL=C sort | head -80

if [ -n "${BASELINE_PROFILE}" ]; then
  BASELINE_TSV=${TMP_DIR}/baseline.tsv
  profile_to_tsv "${BASELINE_PROFILE}" "${BASELINE_TSV}"

  echo
  echo "基準からのカバレッジ差分"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "全体" ""
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "AVX2" "avx2"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "SAD・variance" "sad|variance"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "transform・quantize" "txfm|transform|quant"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "convolve" "convolve"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "intra" "intra"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "CDEF・restoration" "cdef|restoration|wiener|selfguided"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "temporal・noise" "temporal|noise"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "tile・entropy" "tile|entropy_coding|ec_process"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "resize・superres" "resize|superres|upscale|down2"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "palette・screen" "palette|intrabc"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "rate control" "rate_control|[/;]rc_|_rc_|twopass|rate_allocation"
  show_delta_summary "${CURRENT_TSV}" "${BASELINE_TSV}" "warp" "warp"

  awk -F '\t' '
    NR == FNR {
      baseline_executed[$1] = $2
      baseline_counters[$1] = $3
      next
    }
    {
      old_executed = (($1 in baseline_executed) ? baseline_executed[$1] : 0)
      old_counters = (($1 in baseline_counters) ? baseline_counters[$1] : 0)
      is_avx2 = (tolower($1) ~ /\/asm_avx2\/|_avx2($|\.)/)
      newly_executed += ($2 > 0 && old_executed == 0)
      newly_avx2 += ($2 > 0 && old_executed == 0 && is_avx2)
      new_counters += $3 - old_counters
      new_avx2_counters += is_avx2 ? $3 - old_counters : 0
    }
    END {
      printf "評価\t新規関数=%d\t新規AVX2関数=%d\t新規内部カウンタ=%d\t新規AVX2内部カウンタ=%d\n", \
             newly_executed, newly_avx2, new_counters, new_avx2_counters
    }
  ' "${BASELINE_TSV}" "${CURRENT_TSV}"

  echo
  echo "基準から新たに実行された関数"
  awk -F '\t' '
    NR == FNR { baseline[$1] = $2; next }
    $2 > 0 && (($1 in baseline) ? baseline[$1] == 0 : 1) { print $1 }
  ' "${BASELINE_TSV}" "${CURRENT_TSV}" | LC_ALL=C sort

  echo
  echo "基準では実行済み、今回は未実行の関数"
  awk -F '\t' '
    NR == FNR { current[$1] = $2; next }
    $2 > 0 && (($1 in current) ? current[$1] == 0 : 1) { print $1 }
  ' "${CURRENT_TSV}" "${BASELINE_TSV}" | LC_ALL=C sort
fi
