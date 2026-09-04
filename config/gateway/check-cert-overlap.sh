#!/usr/bin/env bash
# =============================================================================
#  check-cert-overlap.sh — ตรวจว่า cert สองใบใน listener เดียวชื่อไม่ทับกัน
# =============================================================================
#  ใช้:
#      bash config/gateway/check-cert-overlap.sh
#      bash config/gateway/check-cert-overlap.sh <secret-1> <secret-2> [secret-3 ...]
#
#  ค่าเริ่มต้นคือ myhr-public-tls กับ myhr-internal-tls (บทที่ 07 ภาคผนวก ข)
#
# -----------------------------------------------------------------------------
#  ทำไมต้องตรวจ
# -----------------------------------------------------------------------------
#  พอใส่ cert หลายใบใน listener เดียว Envoy เลือกใบที่จะเสิร์ฟจาก SNI ของ request
#  ถ้ามีสองใบที่ครอบชื่อเดียวกัน ทั้งคู่ก็ "ตรง" ทั้งคู่ Envoy จะเลือกใบไหนก็ได้
#
#  อาการที่ออกมาคือผู้ใช้บางคนบางเวลาเจอ cert warning แล้วกด refresh ก็หาย
#  ไม่ผูกกับเครื่อง ไม่ผูกกับเวลา ไม่มี error ใน log ของใครเลย
#  เป็นอาการที่หาสาเหตุยากที่สุดแบบหนึ่ง และมองจากสถานะ Gateway ไม่เห็น
#  เพราะทุก listener ยัง Programmed=True อยู่ครบ — ตรงตามที่ config บอกทุกอย่าง
#
#  สคริปต์นี้จึงเป็นตัวเดียวที่จับได้ ให้รันหลัง patch cert เข้า listener
#  และรันซ้ำทุกครั้งที่ต่ออายุหรือเพิ่มชื่อเข้าไปในใบใดใบหนึ่ง
# =============================================================================
set -uo pipefail

ns=envoy-gateway-system

if [ $# -gt 0 ]; then
    secrets=("$@")
else
    secrets=(myhr-public-tls myhr-internal-tls)
fi

command -v kubectl >/dev/null 2>&1 || { echo "ต้องมี kubectl  ให้รันบน master01"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ต้องมี openssl ก่อน"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# ---- ดึงรายชื่อ SAN ของแต่ละ secret ------------------------------------------
present=()
for s in "${secrets[@]}"; do
    if ! kubectl -n "$ns" get secret "$s" >/dev/null 2>&1; then
        echo "ข้าม  $s — ไม่มี secret นี้ใน $ns"
        continue
    fi
    kubectl -n "$ns" get secret "$s" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d \
      | openssl x509 -noout -ext subjectAltName 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ' | grep . > "$tmp/$s.san"
    if [ ! -s "$tmp/$s.san" ]; then
        echo "ข้าม  $s — อ่าน subjectAltName ไม่ได้"
        rm -f "$tmp/$s.san"
        continue
    fi
    present+=("$s")
    echo "$s: $(tr '\n' ' ' < "$tmp/$s.san")"
done

echo
if [ ${#present[@]} -lt 2 ]; then
    echo "มี cert ที่อ่านได้ ${#present[@]} ใบ — ทับกันไม่ได้อยู่แล้ว ผ่าน"
    exit 0
fi

# ---- ชื่อ a ถูกครอบด้วยชื่อ b ไหม ---------------------------------------------
#  wildcard ครอบ subdomain ชั้นเดียวเท่านั้น
#  *.a.com ครอบ x.a.com  แต่ไม่ครอบ a.com และไม่ครอบ x.y.a.com
covers() {
    local pattern=$1 name=$2 suffix
    [ "$pattern" = "$name" ] && return 0
    case "$pattern" in
        "*."*)
            suffix=${pattern#\*.}
            [ "$name" = "$suffix" ] && return 1
            [ "${name#*.}" = "$suffix" ] && return 0
            ;;
    esac
    return 1
}

overlap=0
i=0
for a in "${present[@]}"; do
    i=$((i + 1))
    j=0
    for b in "${present[@]}"; do
        j=$((j + 1))
        [ $j -le $i ] && continue          # ตรวจแต่ละคู่ครั้งเดียว
        while IFS= read -r na; do
            while IFS= read -r nb; do
                if covers "$na" "$nb" || covers "$nb" "$na"; then
                    echo "  ทับกัน  $a:[$na]  <->  $b:[$nb]"
                    overlap=1
                fi
            done < "$tmp/$b.san"
        done < "$tmp/$a.san"
    done
done

echo
if [ $overlap -eq 0 ]; then
    echo "ผ่าน — ไม่มีชื่อไหนอยู่ในสองใบพร้อมกัน"
    exit 0
fi

cat <<'MSG'
ไม่ผ่าน — มีชื่อที่ cert สองใบครอบพร้อมกัน

Envoy จะเลือกใบไหนเสิร์ฟก็ได้ตอน SNI ตรงทั้งคู่ ต้องแก้ให้เหลือใบเดียวต่อชื่อ
เลือกทางใดทางหนึ่ง:

  · ถอดชื่อที่ซ้ำออกจาก dnsNames ของ config/cert-manager/internal-cert.yaml
    แล้ว kubectl apply ใหม่ (cert-manager จะออกใบใหม่ให้เอง)

  · หรือย้ายชื่อฝั่งภายในไปอยู่คนละชั้น เช่น grafana.ops.myhr.co.th
    แล้วแก้ HTTPRoute ของ service นั้นให้ใช้ชื่อใหม่ด้วย

แก้แล้วรันสคริปต์นี้ซ้ำ
MSG
exit 1
