#!/bin/bash
# §SPEC-022 hardening (SEE-1440 / §SPEC-016, fingerprint 89cc…→LICENSE 豁免):
# .githooks/pre-commit 尾随空白闸的 LICENSE 路径豁免此前无自动化守护——Wave A
# 验收为手工临时仓实跑。本套件钉扎：许可证类文件（LICENSE*/COPYING*/OFL*…）
# 携尾随空白必须豁免（exit 0），非豁免文件必须硬阻断（exit 1）。
# 删除豁免行的变异会让 A1/A2 翻红。Hermetic：临时 git 仓，无网络。
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/.githooks/pre-commit"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
check() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1 (exit $3)"; else fail "$1 — exit: got $3, expected $2"; fi
}

[ -f "$HOOK" ] || { echo "hook missing: $HOOK"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git init -q -b master "$TMP/r"
printf 'font license body with trailing \nsecond line \n' > "$TMP/r/LICENSE-OFL.txt"
printf 'lesser copying text \ntrailing here \n' > "$TMP/r/COPYING.LESSER"
printf 'project notes \ntrailing ws line \n' > "$TMP/r/notes.txt"

run_hook_exit() {
  (cd "$TMP/r" && bash "$HOOK" >/dev/null 2>&1)
  echo $?
}

# A1: LICENSE-OFL.txt（尾随空白）单独 staged → 豁免 → exit 0
git -C "$TMP/r" add LICENSE-OFL.txt
check "A1 license file with trailing whitespace is exempt" 0 "$(run_hook_exit)"
git -C "$TMP/r" reset -q

# A2: COPYING.LESSER（尾随空白）单独 staged → 豁免 → exit 0
git -C "$TMP/r" add COPYING.LESSER
check "A2 COPYING.LESSER with trailing whitespace is exempt" 0 "$(run_hook_exit)"
git -C "$TMP/r" reset -q

# A3: notes.txt（尾随空白）单独 staged → 非豁免 → 硬阻断 exit 1
git -C "$TMP/r" add notes.txt
check "A3 non-exempt file with trailing whitespace is blocked" 1 "$(run_hook_exit)"
git -C "$TMP/r" reset -q

# A4: 豁免文件与非豁免文件同批 staged → 仍阻断（豁免不吞并阻断）
git -C "$TMP/r" add LICENSE-OFL.txt notes.txt
check "A4 exempt + non-exempt staged together still blocked" 1 "$(run_hook_exit)"

echo ""
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"
if [ "$FAIL" -eq 0 ]; then
  echo "Overall: PASS"
  exit 0
else
  echo "Overall: FAIL ($FAIL failures)"
  exit 1
fi
