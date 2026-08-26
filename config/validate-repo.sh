#!/usr/bin/env bash
# =============================================================================
#  validate-repo.sh — ตรวจไฟล์ในrepo ก่อน commit / ก่อน scp ขึ้นเครื่อง
# =============================================================================
#  มีไว้เพราะบั๊กชุดแรกที่เจอทั้งหมด (รหัสผ่านหลุด, source ไม่ผ่าน, ตัวแปรว่าง)
#  เกิดจากไฟล์ที่ "เขียนแล้วไม่เคยรัน" — สคริปต์นี้คือการรันแทน
#
#  ใช้:  bash config/validate-repo.sh
#  คืนค่า 0 = ผ่านหมด · 1 = มีอย่างน้อยหนึ่งข้อไม่ผ่าน
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILED=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }

echo "1 · syntax ของ shell script"
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null && ok "$f" || fail "$f — syntax error"
done < <(find config docs -name '*.sh' -not -name 'validate-repo.sh')

echo "2 · versions.env ต้อง source ได้"
if bash -c 'set -a; source docs/versions.env; set +a' 2>/dev/null; then
    ok "source docs/versions.env"
else
    fail "source docs/versions.env — มักเป็นค่าที่มี < > * ? แล้วไม่ได้ใส่ quote"
fi

echo "3 · YAML ต้อง parse ผ่าน"
if command -v python >/dev/null 2>&1 && python -c 'import yaml' 2>/dev/null; then
    PYTHONIOENCODING=utf-8 python - <<'PY'
import glob, io, sys
import yaml
bad = []
for f in sorted(glob.glob('config/*/*.yaml')):
    try:
        list(yaml.safe_load_all(io.open(f, encoding='utf-8').read()))
    except Exception as e:
        bad.append((f, str(e).split('\n')[0]))
for f, e in bad:
    print(f"  FAIL  {f} — {e}")
print(f"  ok    parse ผ่าน {len(glob.glob('config/*/*.yaml')) - len(bad)} ไฟล์")
sys.exit(1 if bad else 0)
PY
    [ $? -ne 0 ] && FAILED=1
else
    echo "  ข้าม  (ไม่มี python + pyyaml)"
fi

echo "4 · ตัวแปร \$UPPERCASE ที่ใช้แต่ไม่เคยประกาศ"
UNDEF=0
for f in docs/*.md config/*/*.sh config/*/*.yaml; do
    [ -f "$f" ] || continue
    # CHECKLIST.md เป็นร้อยแก้วที่พูดถึงตัวแปร ไม่ใช่คำสั่งให้ copy ไปรัน
    case "$f" in */CHECKLIST.md) continue;; esac
    used=$(grep -oE '\$\{?[A-Z][A-Z0-9_]+\}?' "$f" 2>/dev/null | tr -d '${}' | sort -u)
    for v in $used; do
        case "$v" in HOME|PATH|USER|PWD|SHELL|HOSTNAME|RANDOM|IFS) continue;; esac
        grep -qE "(^|[^A-Z_])$v=|read [^;]*\b$v\b|for $v in|export $v|declare $v" "$f" && continue
        grep -qE "^$v=" docs/versions.env && continue
        fail "$f — \$$v ไม่ได้ประกาศที่ไหนเลย (copy ไปวางแล้วจะได้ค่าว่าง)"
        UNDEF=1
    done
done
[ $UNDEF -eq 0 ] && ok "ทุกตัวแปรมีที่มา"

echo "5 · IP ต้องตรงกับ versions.env"
# ค่าเครือข่ายที่เขียนตรง ๆ ในไฟล์อื่นคือจุดที่ drift ได้เงียบ ๆ
# ตัวที่เจ็บที่สุดคือ NetworkPolicy เพราะปฏิเสธโดยไม่เขียน log อะไรเลย
set -a; . ./docs/versions.env >/dev/null 2>&1; set +a
DRIFT=0
if [ -n "${REGISTRY_IP:-}" ]; then
    HITS=$(grep -rniE "192[.]168[.][0-9]+[.][0-9]+" config/ docs/ ansible/ 2>/dev/null | grep -i registry | grep -v "$REGISTRY_IP" | grep -v "^docs/versions.env" | grep -v "^config/validate-repo.sh")
    if [ -n "$HITS" ]; then
        # ต้องมี newline ท้าย ไม่งั้น read อ่านบรรทัดสุดท้ายไม่จบแล้ว loop ไม่ทำงาน
        printf '%s\n' "$HITS" | while IFS= read -r h; do
            fail "$h  <- ไม่ตรงกับ REGISTRY_IP=$REGISTRY_IP"
        done
        DRIFT=1; FAILED=1
    fi
fi
[ $DRIFT -eq 0 ] && ok "IP ของ registry ตรงกันทุกไฟล์ ($REGISTRY_IP)"

echo "6 · ความลับที่ไม่ควรอยู่ในrepo"
LEAK=0
# placeholder ต้องยังเป็น placeholder — ไม่ใช่ค่าจริง
for pat in 'auth_pass' 'adminPassword' 'docker-password'; do
    while IFS= read -r hit; do
        echo "$hit" | grep -qE '<[A-Z_]+>' && continue
        fail "อาจเป็นค่าจริง: $hit"
        LEAK=1
    done < <(grep -rn "$pat" config/ 2>/dev/null | grep -v '^config/validate-repo.sh')
done
[ $LEAK -eq 0 ] && ok "placeholder ยังเป็น placeholder ครบ"

echo
if [ $FAILED -eq 0 ]; then
    echo "ผ่านหมด — commit ได้"
else
    echo "มีข้อไม่ผ่าน — แก้ก่อน commit"
fi
exit $FAILED
