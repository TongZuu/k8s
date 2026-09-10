#!/usr/bin/env bash
# =============================================================================
#  issue-kubeconfig.sh — ออก client cert + kubeconfig ให้คนหนึ่งคน
# =============================================================================
#  รัน:  bash /root/k8s/config/security/issue-kubeconfig.sh <ชื่อ> [กลุ่ม]
#  ที่:   👑 master01 (ต้องมีสิทธิ์ approve CSR)
#
#  ตัวอย่าง:
#      bash issue-kubeconfig.sh teeradach --admin      # ผู้ดูแล cluster
#      bash issue-kubeconfig.sh somchai                # dev (ค่าเริ่มต้น)
#      bash issue-kubeconfig.sh somsak myhr:operators  # ops
#
#  ได้ไฟล์เดียวจบ: <ชื่อ>.kubeconfig (0600) — ไฟล์กลางถูก shred ทิ้งให้อัตโนมัติ
#  รันซ้ำได้ ของเดิมชื่อเดียวกันจะถูกออกใหม่ทับ (CSR เก่าถูกลบก่อน)
#
#  ตัวตนมาจาก client certificate:  CN = ชื่อ user · O = group ที่ rbac.yaml ผูกสิทธิ์ไว้
# =============================================================================
#  🔴 ห้ามออก cert ที่มี O=system:masters — กลุ่มนั้นข้าม RBAC ทั้งหมดและ "ถอนไม่ได้"
#     สคริปต์นี้จึงปฏิเสธให้เลย · สิทธิ์ผู้ดูแลใช้ผ่าน group myhr:admins แทน
#     ซึ่งตัดได้ทันทีด้วยการลบ ClusterRoleBinding โดยไม่ต้องรื้อ CA
# =============================================================================
set -euo pipefail

USER_NAME=${1:-}
GROUP=${2:-myhr:developers}
[ "$GROUP" = "--admin" ] && GROUP=myhr:admins

if [ -z "$USER_NAME" ]; then
    echo "ใช้: bash $0 <ชื่อ> [กลุ่ม|--admin]"
    echo "     กลุ่มที่ rbac.yaml รองรับ: myhr:developers · myhr:operators · myhr:admins"
    exit 2
fi

case "$GROUP" in
    system:masters)
        echo "❌ ไม่ออก cert ที่มี O=system:masters — ข้าม RBAC ทั้งหมดและถอนไม่ได้"
        echo "   ใช้ --admin แทน (group myhr:admins ผูก cluster-admin ผ่าน ClusterRoleBinding)"
        exit 2 ;;
esac

# ตัด CR ก่อน source — ไฟล์ที่ scp ขึ้นมาจากเครื่อง Windows อาจเป็น CRLF
# ถ้า source ตรง ๆ จะได้ bash: $'\r': command not found แล้วตายทั้งสคริปต์เพราะ set -e
if [ -f /root/k8s/versions.env ]; then
    set -a; . <(tr -d '\r' < /root/k8s/versions.env); set +a
fi
SERVER="https://${VIP:-192.168.50.100}:${VIP_PORT:-8443}"
DAYS=90
NS_DEFAULT=myhr-prod
[ "$GROUP" = "myhr:admins" ] && NS_DEFAULT=default

echo "==============================================================="
echo " ออก kubeconfig ให้ ${USER_NAME}"
echo " group   : ${GROUP}"
echo " apiserver: ${SERVER}"
echo " อายุ    : ${DAYS} วัน"
echo "==============================================================="

# ---------------------------------------------------- 0 · กลุ่มต้องมีสิทธิ์จริง
# ออก cert ให้ group ที่ไม่มี binding = ได้ไฟล์ที่ใช้ทำอะไรไม่ได้เลย
# แล้วจะไปรู้ตอนเจ้าตัวใช้งาน ซึ่งเสียเวลาไล่หาสาเหตุกันสองฝั่ง
if ! kubectl get clusterrolebindings,rolebindings -A -o json \
     | grep -q "\"name\": \"${GROUP}\""; then
    echo "❌ ไม่มี binding ไหนผูกกับ group '${GROUP}' เลย — cert ที่ออกไปจะใช้ทำอะไรไม่ได้"
    echo "   แก้: kubectl apply -f /root/k8s/config/security/rbac.yaml  แล้วรันใหม่"
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
KEY="$WORK/${USER_NAME}.key"
CSR="$WORK/${USER_NAME}.csr"
CRT="$WORK/${USER_NAME}.crt"
KCFG="./${USER_NAME}.kubeconfig"

# ------------------------------------------------------------ 1 · key + CSR
openssl genrsa -out "$KEY" 2048 2>/dev/null
openssl req -new -key "$KEY" -out "$CSR" -subj "/CN=${USER_NAME}/O=${GROUP}"
echo "  [1/5] สร้าง key + CSR แล้ว"

# ------------------------------------------------- 2 · ให้ cluster เซ็นให้
kubectl delete csr "$USER_NAME" --ignore-not-found >/dev/null 2>&1
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: $(base64 -w0 < "$CSR")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((DAYS * 86400))
  usages: ["client auth"]
EOF
kubectl certificate approve "$USER_NAME" >/dev/null
echo "  [2/5] cluster เซ็น cert ให้แล้ว"

for _ in $(seq 20); do
    kubectl get csr "$USER_NAME" -o jsonpath='{.status.certificate}' > "$WORK/b64" 2>/dev/null || true
    [ -s "$WORK/b64" ] && break
    sleep 1
done
if [ ! -s "$WORK/b64" ]; then
    echo "❌ รอ cert 20 วินาทีแล้วยังไม่ออก — ดู: kubectl describe csr $USER_NAME"
    exit 1
fi
base64 -d < "$WORK/b64" > "$CRT"

# ตรวจว่าได้ CN/O ตามที่ขอจริง ไม่ใช่ signer เขียนอย่างอื่นมาให้
subj=$(openssl x509 -in "$CRT" -noout -subject)
case "$subj" in
    *"CN=${USER_NAME}"*) : ;;
    *) echo "❌ cert ที่ได้ CN ไม่ตรง: $subj"; exit 1 ;;
esac
echo "  [3/5] ตรวจ cert แล้ว: $subj"
echo "        หมดอายุ: $(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)"

# --------------------------------------------------------- 3 · ประกอบ kubeconfig
rm -f "$KCFG"
kubectl config set-cluster myhr --server="$SERVER" \
    --certificate-authority=/etc/kubernetes/pki/ca.crt \
    --embed-certs=true --kubeconfig="$KCFG" >/dev/null
kubectl config set-credentials "$USER_NAME" \
    --client-certificate="$CRT" --client-key="$KEY" \
    --embed-certs=true --kubeconfig="$KCFG" >/dev/null
kubectl config set-context "$USER_NAME" --cluster=myhr --user="$USER_NAME" \
    --namespace="$NS_DEFAULT" --kubeconfig="$KCFG" >/dev/null
kubectl config use-context "$USER_NAME" --kubeconfig="$KCFG" >/dev/null
chmod 600 "$KCFG"
echo "  [4/5] ประกอบ kubeconfig แล้ว: $KCFG"

# -------------------------------------------- 4 · ทดสอบด้วยไฟล์จริงก่อนส่งมอบ
echo "  [5/5] ทดสอบสิทธิ์ด้วยไฟล์ที่เพิ่งออก:"
check() {  # check <verb+resource> <ns args> <yes|no>
    got=$(kubectl --kubeconfig="$KCFG" auth can-i $1 $2 2>/dev/null || true)
    if [ "$got" = "$3" ]; then
        printf '        [ผ่าน]  %s %s = %s\n' "$1" "${2:-(cluster)}" "$got"
    else
        printf '        [ตก]    %s %s ได้ %s ต้องได้ %s\n' "$1" "${2:-(cluster)}" "${got:-?}" "$3"
        FAILED=1
    fi
}
FAILED=0
case "$GROUP" in
    myhr:admins)
        check "create clusterrolebindings" ""             yes
        check "get secrets"                "-A"           yes
        check "delete nodes"               ""             yes ;;
    myhr:operators)
        check "get nodes"                  ""             yes
        check "create pods --subresource=eviction" "-n myhr-prod" yes
        check "delete nodes"               ""             no
        check "get secrets"                "-A"           no ;;
    *)
        check "get pods"                   "-n myhr-prod" yes
        check "get pods --subresource=log" "-n myhr-prod" yes
        check "get secrets"                "-n myhr-prod" no
        check "create pods --subresource=exec" "-n myhr-prod" no
        check "delete nodes"               ""             no ;;
esac

echo "==============================================================="
if [ "$FAILED" -eq 0 ]; then
    echo " ✅ เสร็จ — ส่ง $KCFG ให้เจ้าตัวผ่านช่องทางที่ปลอดภัย แล้วลบสำเนาบนเครื่องนี้"
    echo "    ใช้งาน:  kubectl --kubeconfig=${USER_NAME}.kubeconfig get pods"
    echo "    ต้องออกใหม่ทุก ${DAYS} วัน — cert ถอนกลางคันไม่ได้ (Kubernetes ไม่มี CRL)"
else
    echo " ❌ สิทธิ์ที่ได้ไม่ตรงกับที่ตั้งใจ — ตรวจ rbac.yaml ก่อนส่งไฟล์ให้ใคร"
fi
echo "==============================================================="
[ "$FAILED" -eq 0 ]
