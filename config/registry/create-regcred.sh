#!/usr/bin/env bash
# =============================================================================
#  create-regcred.sh — สร้าง imagePullSecret ให้ cluster ดึง image จาก private registry
# =============================================================================
#  ทำไมเป็นสคริปต์ ไม่ใช่ไฟล์ YAML ใน config/ เหมือนตัวอื่น:
#  Secret ตัวนี้มีรหัสจริงอยู่ข้างใน จึงห้ามอยู่ใน git (บทที่ 10 หัวข้อ 6)
#  แต่ "วิธีสร้าง" ต้องอยู่ในrepo ไม่งั้นวันที่ต้องทำ namespace ใหม่หรือ cluster ใหม่
#  จะไม่มีใครรู้ว่าต้องสร้างอะไรบ้าง — สคริปต์นี้คือส่วนที่เก็บได้
#
#  ใช้ (👑 บน master01 หรือเครื่องที่มี kubeconfig):
#    export PULL_USER='ชื่อ account ที่ pull ได้อย่างเดียว'
#    read -rsp 'registry password: ' PULL_PASS && export PULL_PASS && echo
#    bash config/registry/create-regcred.sh
#
#  ระบุ namespace เองได้:
#    NAMESPACES='myhr-prod myhr-uat myhr-sit' bash config/registry/create-regcred.sh
#
#  🔴 รหัสไม่ถูกส่งผ่าน argument ของ kubectl เลย
#     ท่ามาตรฐาน (ใส่รหัสเป็น flag ให้ kubectl create secret docker-registry)
#     ทำให้รหัสโผล่ใน `ps aux` ของทั้งเครื่องระหว่างที่คำสั่งทำงาน และค้างใน history
#     สคริปต์นี้ประกอบ .dockerconfigjson เองในไฟล์ชั่วคราวสิทธิ์ 600 แล้วลบทิ้งเสมอ
# =============================================================================
set -uo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-registry.myhr.co.th}"
NAMESPACES="${NAMESPACES:-myhr-prod myhr-uat}"
SECRET_NAME="${SECRET_NAME:-regcred}"
PULL_USER="${PULL_USER:-}"
PULL_PASS="${PULL_PASS:-}"
FAIL=0

red()  { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=1; }
grn()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*"; }
info() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

# ไฟล์ชั่วคราวต้องถูกลบแม้สคริปต์ตายกลางทาง ไม่งั้นรหัสค้างอยู่บนดิสก์
TMPCFG=""
cleanup() { [ -n "$TMPCFG" ] && rm -f "$TMPCFG"; }
trap cleanup EXIT INT TERM

# =============================================================================
info "0. ของที่ต้องมีก่อน"
# =============================================================================
for BIN in kubectl curl base64; do
  command -v "$BIN" >/dev/null 2>&1 || { red "ไม่มีคำสั่ง $BIN"; exit 1; }
done
grn "kubectl · curl · base64 ครบ"

if [ -z "$PULL_USER" ] || [ -z "$PULL_PASS" ]; then
  red "ยังไม่ได้ตั้ง PULL_USER / PULL_PASS"
  cat <<'HINT'

  ตั้งค่าก่อนแล้วรันใหม่ — อย่าพิมพ์รหัสต่อท้ายคำสั่งตรง ๆ มันจะค้างใน history:

    export PULL_USER='ชื่อ account ที่ pull ได้อย่างเดียว'
    read -rsp 'registry password: ' PULL_PASS && export PULL_PASS && echo

HINT
  exit 1
fi
grn "มี credential ครบ (ไม่แสดงค่า)"

# =============================================================================
info "1. registry ตอบอะไร ก่อนจะไปยุ่งกับ Kubernetes"
# =============================================================================
# แยกให้ขาดก่อนว่าเป็นปัญหา TLS/เครือข่าย หรือเป็นปัญหา credential จริง ๆ
# ถ้าไม่แยก จะไปสร้าง secret ซ้ำ ๆ แก้ปัญหาที่ไม่ได้อยู่ตรงนั้น
PROBE_ERR=$(curl -sS -o /dev/null -w '%{http_code}' "https://${REGISTRY_HOST}/v2/" 2>&1)
PROBE_CODE="${PROBE_ERR##*$'\n'}"

case "$PROBE_CODE" in
  401|200)
    grn "https://${REGISTRY_HOST}/v2/ ตอบ HTTP ${PROBE_CODE} — TLS ผ่าน เครือข่ายถึง"
    ;;
  *)
    red "ต่อ registry ไม่ได้: ${PROBE_ERR}"
    cat <<HINT

  แปลผล:
    certificate has expired / SSL certificate problem → cert ของ registry มีปัญหา
        openssl s_client -connect ${REGISTRY_HOST}:443 -servername ${REGISTRY_HOST} \
          </dev/null 2>/dev/null | openssl x509 -noout -dates
    unknown authority   → CA ไม่ได้ลงบน node (บทที่ 02 หัวข้อ 4)
    could not resolve   → DNS หรือ /etc/hosts (บทที่ 01)
    connection refused / timeout → เครือข่ายไปไม่ถึงเครื่อง registry

  ทั้งหมดนี้ไม่ใช่เรื่องของ Secret — สร้าง secret กี่รอบก็ไม่หาย
HINT
    exit 1
    ;;
esac

# =============================================================================
info "2. credential ใช้ได้จริงไหม"
# =============================================================================
# ถามตัว registry ตรง ๆ ก่อนสร้าง secret — ถ้ารหัสผิดจะได้รู้ตรงนี้
# ไม่ใช่ไปรู้ตอน pod ขึ้นเป็น ImagePullBackOff แล้วไล่หาว่าใครผิด
AUTH_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -u "${PULL_USER}:${PULL_PASS}" \
              "https://${REGISTRY_HOST}/v2/" 2>/dev/null)
case "$AUTH_CODE" in
  200) grn "credential ผ่าน (HTTP 200)" ;;
  401) red "รหัสผิดหรือ account ถูกปิด (HTTP 401) — หยุดตรงนี้ ยังไม่ต้องแตะ Kubernetes"; exit 1 ;;
  403) warn "HTTP 403 — ล็อกอินผ่านแต่ account นี้อาจไม่มีสิทธิ์อ่าน repository ที่ต้องใช้" ;;
  *)   red "ไม่คาดคิด: HTTP ${AUTH_CODE}"; exit 1 ;;
esac

# =============================================================================
info "3. สร้าง / อัปเดต Secret"
# =============================================================================
# ประกอบ .dockerconfigjson เองเพื่อไม่ให้รหัสไปโผล่ใน argument ของ kubectl
umask 077
TMPCFG=$(mktemp)
AUTH_B64=$(printf '%s:%s' "${PULL_USER}" "${PULL_PASS}" | base64 | tr -d '\n')
printf '{"auths":{"%s":{"auth":"%s"}}}' "${REGISTRY_HOST}" "${AUTH_B64}" > "$TMPCFG"

for NS in $NAMESPACES; do
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    red "${NS}: ไม่มี namespace นี้ — ข้าม (namespace เป็นของกลาง สร้างจาก config/security/namespaces.yaml)"
    continue
  fi

  # --dry-run + apply แทน create เปล่า ๆ เพื่อให้รันซ้ำได้และใช้ตอนหมุนรหัสได้ด้วย
  if kubectl create secret generic "$SECRET_NAME" \
        --namespace "$NS" \
        --type=kubernetes.io/dockerconfigjson \
        --from-file=".dockerconfigjson=${TMPCFG}" \
        --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null 2>&1; then
    grn "${NS}: ${SECRET_NAME} พร้อมใช้"
  else
    red "${NS}: สร้าง secret ไม่สำเร็จ"
  fi
done

# =============================================================================
info "4. อ่านกลับมาตรวจว่า host ตรงกับที่ image ใช้"
# =============================================================================
# ตรวจ host ที่อยู่ในตัว secret จริง ไม่ใช่ตรวจว่า "มีไฟล์ secret อยู่"
# --docker-server ที่พิมพ์เกินมาเป็น https:// หรือมี path ต่อท้าย จะได้ 401 เหมือนไม่มี secret เลย
for NS in $NAMESPACES; do
  kubectl get namespace "$NS" >/dev/null 2>&1 || continue
  GOT=$(kubectl -n "$NS" get secret "$SECRET_NAME" \
          -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d 2>/dev/null)
  case "$GOT" in
    *"\"${REGISTRY_HOST}\""*) grn "${NS}: host ใน secret = ${REGISTRY_HOST}" ;;
    "")  red "${NS}: อ่าน secret กลับมาไม่ได้" ;;
    *)   red "${NS}: host ใน secret ไม่ตรงกับ ${REGISTRY_HOST}" ;;
  esac
done

# =============================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  grn "เสร็จแล้ว"
  cat <<HINT

  เหลืออีก 2 อย่างที่สคริปต์นี้ทำแทนไม่ได้:

  1. Deployment ต้องอ้างถึง secret นี้เอง — แม่แบบมีให้แล้ว:
         imagePullSecrets:
           - name: ${SECRET_NAME}

  2. pod ที่ค้าง ImagePullBackOff อยู่จะ retry เองแต่ backoff ถอยไปถึง 5 นาที
     ถ้าอยากให้ลองใหม่เดี๋ยวนี้:
         kubectl -n myhr-prod rollout restart deploy/ชื่อ-service
HINT
else
  red "มีข้อที่ไม่ผ่าน — แก้ก่อนไป deploy ต่อ"
fi
exit "$FAIL"
