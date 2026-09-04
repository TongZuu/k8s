#!/usr/bin/env bash
# =============================================================================
#  import-public-cert.sh — เอา public cert ที่องค์กรมีอยู่แล้วเข้า Gateway
# =============================================================================
#  ใช้:
#      bash config/gateway/import-public-cert.sh [ตัวเลือก] <fullchain.pem> <privkey.pem> [ชื่อโฮสต์ ...]
#
#  ตัวเลือก:
#      --dry-run          ตรวจอย่างเดียว ไม่แตะ cluster (ใช้ตรวจ cert ที่เพิ่งได้มาจาก CA)
#      --secret <ชื่อ>     ชื่อ Secret ปลายทาง (ค่าเริ่มต้น myhr-public-tls)
#                         ใช้ตอนมี public cert หลายใบแยกตามชื่อ service
#
#  ตัวอย่าง:
#      bash config/gateway/import-public-cert.sh /root/certs/fullchain.pem /root/certs/privkey.pem
#      bash config/gateway/import-public-cert.sh fullchain.pem key.pem hr.myhr.co.th api.myhr.co.th
#      bash config/gateway/import-public-cert.sh --secret hr-myhr-tls hr-chain.pem hr.key hr.myhr.co.th
#
# -----------------------------------------------------------------------------
#  ทำไมต้องมีสคริปต์นี้ แทนที่จะพิมพ์ kubectl create secret tls ตรง ๆ
# -----------------------------------------------------------------------------
#  kubectl create secret tls รับไฟล์อะไรก็ได้ที่หน้าตาเป็น PEM แล้วตอบ created
#  ปัญหาทั้งสี่ข้อข้างล่างจึงผ่านด่านนั้นไปได้หมด แล้วไปโผล่ทีหลังในรูปแบบที่
#  หาสาเหตุยาก (บางเครื่องเข้าได้ บางเครื่องไม่ได้ / เข้าได้วันนี้ พังเดือนหน้า)
#
#    1. ใส่แค่ leaf ไม่ใส่ intermediate
#       เบราว์เซอร์บนเครื่องที่เคย cache intermediate ไว้จะผ่าน
#       แต่ curl / Java / มือถือเครื่องใหม่ ฟ้อง unable to get local issuer certificate
#    2. key ไม่ใช่คู่ของ cert (หยิบผิดไฟล์ตอนต่ออายุ)
#       secret สร้างได้ แต่ Envoy โหลดไม่ขึ้น listener ค้างที่ Programmed=False
#    3. key มี passphrase หรือเป็น .pfx ที่แปลงมาไม่สุด
#       เหมือนข้อ 2 คือเงียบตอนสร้าง ไปตายตอน Envoy อ่าน
#    4. cert ไม่ครอบชื่อที่จะใช้จริง (ได้ cert รายชื่อมาแต่นึกว่าเป็น wildcard)
#       เข้า hr.myhr.co.th ได้ แต่ api.myhr.co.th เตือน cert
#
#  สคริปต์นี้ตรวจทั้งสี่ข้อก่อน แล้วค่อยเขียน secret
#  ผิดข้อไหนก็หยุดพร้อมบอกว่าข้อไหน และยังไม่แตะ cluster
# =============================================================================
set -uo pipefail

# ---- แก้ตรงนี้ถ้า Gateway อยู่คนละที่ ----------------------------------------
ns=envoy-gateway-system
secret=myhr-public-tls
# -----------------------------------------------------------------------------

warn_days=30          # เตือนถ้า cert เหลืออายุน้อยกว่านี้
failed=0
dry_run=0

ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failed=1; }
warn() { echo "  เตือน  $*"; }

usage() {
    sed -n '5,20p' "$0" | sed 's/^#[[:space:]]\{0,2\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "${1:-}" in
        --dry-run) dry_run=1; shift ;;
        --secret)  secret=${2:-}; [ -n "$secret" ] || usage; shift 2 ;;
        --help|-h) usage ;;
        --*)       echo "ไม่รู้จักตัวเลือก $1"; usage ;;
        *)         break ;;
    esac
done

chain=${1:-}
key=${2:-}
[ -n "$chain" ] && [ -n "$key" ] || usage
shift 2
hosts=("$@")

# ไม่ระบุชื่อโฮสต์มา ก็ตรวจกับสองชื่อที่บทที่ 07 ตั้ง listener ไว้เป็นค่าเริ่มต้น
if [ ${#hosts[@]} -eq 0 ]; then
    hosts=("*.myhr.co.th" "myhr.co.th")
    echo "ไม่ได้ระบุชื่อโฮสต์ จะตรวจกับค่าเริ่มต้น: ${hosts[*]}"
fi

command -v openssl >/dev/null 2>&1 || { echo "ต้องมี openssl ก่อน"; exit 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

echo
echo "1 - ไฟล์ต้องอ่านได้และเป็น PEM"
for f in "$chain" "$key"; do
    [ -r "$f" ] || fail "$f  ไม่มีไฟล์นี้ หรืออ่านไม่ได้"
done
if [ $failed -ne 0 ]; then echo; echo "หยุดตั้งแต่ข้อ 1"; exit 1; fi

if grep -q "BEGIN CERTIFICATE" "$chain"; then
    ok "$chain เป็น PEM"
else
    fail "$chain ไม่มี BEGIN CERTIFICATE  ถ้าเป็น .pfx/.p12/.der ต้องแปลงเป็น PEM ก่อน (ดูบทที่ 07)"
fi

if grep -q "ENCRYPTED" "$key"; then
    fail "$key มี passphrase  Kubernetes เก็บได้ แต่ Envoy อ่านไม่ออก  ถอดด้วย: openssl pkey -in $key -out key-nopass.pem"
elif grep -q "PRIVATE KEY" "$key"; then
    ok "$key เป็น private key แบบไม่มี passphrase"
else
    fail "$key ไม่ใช่ PEM private key"
fi
if [ $failed -ne 0 ]; then echo; echo "หยุดตั้งแต่ข้อ 1"; exit 1; fi

echo
echo "2 - cert กับ key ต้องเป็นคู่กัน"
# เทียบ public key ไม่ใช่ modulus เพราะ modulus ใช้ได้เฉพาะ RSA
# ส่วน public cert สมัยนี้เป็น ECDSA กันเยอะ ถ้าเทียบด้วย modulus จะได้ค่าว่าง
# ทั้งสองฝั่งแล้วสรุปว่า "ตรงกัน" ซึ่งคือการตรวจที่ผ่านทุกครั้งโดยไม่ได้ตรวจอะไร
openssl x509 -in "$chain" -noout -pubkey > "$tmp/pub-cert.pem" 2>/dev/null
openssl pkey -in "$key" -pubout > "$tmp/pub-key.pem" 2>/dev/null
if [ -s "$tmp/pub-cert.pem" ] && [ -s "$tmp/pub-key.pem" ] && cmp -s "$tmp/pub-cert.pem" "$tmp/pub-key.pem"; then
    ok "public key ของ cert ตรงกับ private key"
else
    fail "cert กับ key ไม่ใช่คู่กัน  มักเกิดตอนต่ออายุแล้วหยิบ key เก่ามาคู่กับ cert ใหม่"
fi

echo
echo "3 - chain ต้องครบ (leaf + intermediate)"
# หั่น fullchain ออกเป็นไฟล์ละใบ เพื่อนับจำนวนและเอา intermediate ไปให้ openssl verify
awk -v dir="$tmp" '
  /BEGIN CERTIFICATE/ { n++ }
  n > 0 { print > sprintf("%s/cert-%02d.pem", dir, n) }
' "$chain"
count=$(ls "$tmp"/cert-*.pem 2>/dev/null | wc -l | tr -d ' ')

if [ "$count" -eq 0 ]; then
    fail "อ่าน certificate จาก $chain ไม่ได้เลย"
elif [ "$count" -eq 1 ]; then
    fail "มี certificate ใบเดียว คือ leaf ล้วน ยังไม่ใช่ fullchain"
    echo "        CA มักส่งมาแยกเป็นหลายไฟล์ ให้ต่อเรียงเองก่อน (leaf ขึ้นก่อนเสมอ):"
    echo "            cat cert.pem intermediate.pem > fullchain.pem"
else
    ok "มี certificate $count ใบใน chain"
    # intermediates = ทุกใบยกเว้นใบแรก (ใบแรกคือ leaf)
    rm -f "$tmp/intermediates.pem"
    for c in "$tmp"/cert-[0-9][0-9].pem; do
        case "$c" in
            */cert-01.pem) continue ;;
        esac
        cat "$c" >> "$tmp/intermediates.pem"
    done
    if openssl verify -untrusted "$tmp/intermediates.pem" "$tmp/cert-01.pem" > "$tmp/verify.out" 2>&1; then
        ok "chain ต่อกันถูก และสาวถึง root ที่เครื่องนี้เชื่อถืออยู่แล้ว"
    else
        fail "chain ตรวจไม่ผ่าน: $(tr '\n' ' ' < "$tmp/verify.out")"
        echo "        ถ้า CA เป็นของภายในองค์กร (ไม่ใช่ public CA) ทางนี้ไม่ใช่ทางของคุณ"
        echo "        ให้ใช้ internal CA ตามบทที่ 07 ภาคผนวก ข แทน"
    fi
fi

echo
echo "4 - วันหมดอายุ"
not_after=$(openssl x509 -in "$chain" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
if openssl x509 -in "$chain" -noout -checkend 0 >/dev/null 2>&1; then
    if openssl x509 -in "$chain" -noout -checkend $((warn_days * 86400)) >/dev/null 2>&1; then
        ok "ยังไม่หมดอายุ ถึง $not_after"
    else
        warn "เหลือน้อยกว่า $warn_days วัน (ถึง $not_after) ใช้ได้แต่ควรต่ออายุเลย"
    fi
else
    fail "หมดอายุไปแล้วเมื่อ $not_after"
fi

echo
echo "5 - ชื่อใน cert ต้องครอบชื่อที่จะใช้จริง"
sans=$(openssl x509 -in "$chain" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ')
if [ -z "$sans" ]; then
    fail "cert ไม่มี subjectAltName เลย  เบราว์เซอร์สมัยใหม่ไม่ดู CN แล้ว ต้องขอ cert ใหม่"
else
    echo "  ชื่อใน cert: $(echo "$sans" | tr '\n' ' ')"
    for h in "${hosts[@]}"; do
        matched=0
        for s in $sans; do
            # ตรงตัว (ครอบกรณีขอตรวจ *.myhr.co.th กับ cert wildcard ด้วย)
            if [ "$h" = "$s" ]; then matched=1; break; fi
            # wildcard ครอบ subdomain ชั้นเดียวเท่านั้น
            # *.a.com ครอบ x.a.com  แต่ไม่ครอบ a.com และไม่ครอบ x.y.a.com
            case "$s" in
                "*."*)
                    suffix=${s#\*.}
                    if [ "$h" = "$suffix" ]; then continue; fi
                    if [ "${h#*.}" = "$suffix" ]; then matched=1; break; fi
                    ;;
            esac
        done
        if [ $matched -eq 1 ]; then
            ok "$h ครอบแล้ว"
        else
            fail "$h ไม่มีใน cert  เปิดชื่อนี้จะเจอ cert warning"
        fi
    done
fi

echo
if [ $failed -ne 0 ]; then
    echo "มีข้อไม่ผ่าน ยังไม่ได้เขียนอะไรลง cluster"
    exit 1
fi

if [ $dry_run -eq 1 ]; then
    echo "ตรวจผ่านหมด (--dry-run จึงไม่ได้เขียน secret)"
    exit 0
fi

echo "6 - เขียน Secret $ns/$secret"
if ! command -v kubectl >/dev/null 2>&1; then
    echo "  FAIL  ไม่มี kubectl บนเครื่องนี้ ให้รันสคริปต์นี้บน master01"
    exit 1
fi
if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "  FAIL  ไม่มี namespace $ns  ติดตั้ง Envoy Gateway ก่อน (บทที่ 07 ขั้นที่ 2)"
    exit 1
fi

# create --dry-run=client แล้ว pipe เข้า apply
# ทำให้รันซ้ำตอนต่ออายุได้เลย ไม่ต้อง kubectl delete secret ก่อน
if kubectl create secret tls "$secret" --namespace "$ns" --cert "$chain" --key "$key" --dry-run=client -o yaml | kubectl apply -f - ; then
    echo
    echo "เรียบร้อย  ต่อที่ขั้นที่ 4 ของบทที่ 07 (apply gateway.yaml)"
    echo "ถ้า Gateway มีอยู่แล้ว Envoy Gateway จะโหลด cert ใหม่ให้เองในไม่กี่วินาที ตรวจด้วย:"
    echo "    kubectl -n $ns get gateway myhr-gateway -o yaml | grep -A3 'name: https'"
else
    echo "  FAIL  เขียน secret ไม่สำเร็จ"
    exit 1
fi
