#!/usr/bin/env bash
# =============================================================================
#  verify-security.sh — ตรวจว่าบทที่ 10 ทำงานจริง ไม่ใช่แค่ apply ผ่าน
# =============================================================================
#  รัน:  bash /root/k8s/config/security/verify-security.sh
#  ที่:   👑 master01 (ต้องมี kubeconfig ของ admin และ ssh ไม่ต้องใช้)
#
#  แตะของจริงอย่างเดียว: สร้าง Secret ชั่วคราวชื่อ enc-verify-* ใน default
#  แล้วลบทิ้งเมื่อจบ — ต้องเขียนของใหม่ถึงจะรู้ว่า "ตอนนี้" เข้ารหัสอยู่จริง
#  ที่เหลืออ่านอย่างเดียวทั้งหมด รันซ้ำได้ตลอด
#
#  ทำไมต้องมีสคริปต์นี้ — ทุกด่านในบทที่ 10 ผ่านได้ทั้งที่ระบบยังไม่ปลอดภัย:
#    · apply NetworkPolicy สำเร็จ ไม่ได้แปลว่า Cilium บังคับใช้จริง
#    · เปิด encryption แค่ master01 แล้วทดสอบผ่าน VIP ก็ยังผ่าน 2 ใน 3 ครั้ง
#    · ติด label PSA แล้วแต่ไม่มีผล จะรู้ก็ตอน deploy จริงในบทที่ 11
#    · ใส่ audit flag แล้วแต่ policy ไม่ match อะไรเลย = log ไม่โต แต่ไม่มีใครบ่น
# =============================================================================
set -uo pipefail

OK=0; BAD=0; WARN=0
ok()   { printf '  [ผ่าน]   %s\n' "$*"; OK=$((OK+1)); }
bad()  { printf '  [ตก]     %s\n' "$*"; BAD=$((BAD+1)); }
warn() { printf '  [ระวัง]  %s\n' "$*"; WARN=$((WARN+1)); }
note() { printf '           %s\n' "$*"; }

# ตัด CR ก่อน source — ไฟล์ที่ scp ขึ้นมาจากเครื่อง Windows อาจเป็น CRLF
# ถ้า source ตรง ๆ จะได้ bash: $'\r': command not found แล้วตายทั้งสคริปต์เพราะ set -e
if [ -f /root/k8s/versions.env ]; then
    set -a; . <(tr -d '\r' < /root/k8s/versions.env); set +a
fi
M1=${MASTER01_IP:-192.168.50.101}
M2=${MASTER02_IP:-192.168.50.102}
M3=${MASTER03_IP:-192.168.50.103}

if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
    echo "❌ kubectl ใช้ไม่ได้ — ต้องรันบน master ที่มี kubeconfig ของ admin"
    exit 2
fi

echo "==============================================================="
echo " ตรวจบทที่ 10 — Security Baseline   $(date '+%Y-%m-%d %H:%M')"
echo "==============================================================="

# --------------------------------------------------------------- 1 encryption
echo
echo "1 · etcd encryption at rest"

api_cmds=$(kubectl -n kube-system get pods -l component=kube-apiserver \
             -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.containers[0].command}{"\n"}{end}' 2>/dev/null)
n_api=$(printf '%s\n' "$api_cmds" | grep -c .)
n_enc=$(printf '%s\n' "$api_cmds" | grep -c 'encryption-provider-config')

if [ "$n_api" -lt 3 ]; then
    bad "เห็น kube-apiserver แค่ $n_api ตัว (ต้องได้ 3) — มีเครื่อง start ไม่ขึ้น"
    note "ดู: kubectl -n kube-system get pods -l component=kube-apiserver -o wide"
fi
if [ "$n_enc" -eq "$n_api" ] && [ "$n_api" -ge 3 ]; then
    ok "apiserver ทั้ง $n_api ตัวมี --encryption-provider-config"
else
    bad "apiserver มี flag encryption แค่ $n_enc จาก $n_api ตัว"
    printf '%s\n' "$api_cmds" | grep -v 'encryption-provider-config' | cut -d'|' -f1 | sed 's/^/           ขาด: /'
fi

etcd_pod=$(kubectl -n kube-system get pod -l component=etcd -o name 2>/dev/null | head -1)
etcd_pod=${etcd_pod#pod/}
etcdctl_get() {
    kubectl -n kube-system exec "$etcd_pod" -- etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        get "$@" 2>/dev/null
}

TMPSEC="enc-verify-$$"
CANARY="canary-${RANDOM}${RANDOM}"
cleanup() { kubectl -n default delete secret "$TMPSEC" --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT

if kubectl -n default create secret generic "$TMPSEC" --from-literal=key="$CANARY" >/dev/null 2>&1; then
    raw=$(etcdctl_get "/registry/secrets/default/$TMPSEC" | strings)
    if printf '%s' "$raw" | grep -q "$CANARY"; then
        bad "🔴 Secret ที่เพิ่งเขียนยังเป็น plaintext ใน etcd — encryption ไม่ทำงาน"
    elif printf '%s' "$raw" | grep -q 'k8s:enc:aescbc:v1:key1'; then
        ok "Secret ที่เพิ่งเขียนถูกเข้ารหัสด้วย aescbc:key1 ใน etcd"
    else
        warn "อ่านค่าจาก etcd ไม่ได้ — ข้ามด่านนี้ (etcd pod = ${etcd_pod:-ไม่พบ})"
    fi

    # ทุก apiserver ต้องถอดรหัสได้ ไม่ใช่แค่เครื่องที่รันสคริปต์
    # ยิงตรงไม่ผ่าน VIP เพราะ VIP สุ่มเครื่อง เครื่องที่ key ผิดอาจไม่โดนเลย
    for ip in "$M1" "$M2" "$M3"; do
        got=$(kubectl --server="https://$ip:6443" --insecure-skip-tls-verify --request-timeout=10s \
                -n default get secret "$TMPSEC" -o jsonpath='{.data.key}' 2>/dev/null | base64 -d 2>/dev/null)
        if [ "$got" = "$CANARY" ]; then
            ok "apiserver $ip ถอดรหัส Secret ได้"
        else
            bad "apiserver $ip ถอดรหัสไม่ได้ — key ไม่ตรงหรือยังไม่ได้วางไฟล์"
        fi
    done
else
    warn "สร้าง Secret ชั่วคราวไม่ได้ — ข้ามด่าน encryption ทั้งหมด"
fi

# ของเก่าที่เขียนไว้ก่อนเปิด encryption ยังเป็น plaintext จนกว่าจะถูกเขียนทับ
tot=$(etcdctl_get /registry/secrets/ --prefix --keys-only | grep -c '/registry/secrets/')
enc=$(etcdctl_get /registry/secrets/ --prefix | grep -ac 'k8s:enc:aescbc:v1:key1')
if [ "${tot:-0}" -gt 0 ]; then
    if [ "${enc:-0}" -ge "$tot" ]; then
        ok "Secret ใน etcd เข้ารหัสครบ $enc/$tot รายการ"
    else
        bad "Secret ยังไม่เข้ารหัส $((tot-enc)) จาก $tot รายการ — ของเก่ายังไม่ถูกเขียนทับ"
        note "แก้: kubectl get secrets -A -o json | kubectl replace -f -"
    fi
fi

cleanup
trap - EXIT

# --------------------------------------------------------------------- 2 PSA
echo
echo "2 · Pod Security Admission"

for ns in myhr-prod myhr-uat; do
    lv=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
    case "$lv" in
        restricted) ok "namespace $ns enforce = restricted" ;;
        "")         bad "namespace $ns ไม่มี label enforce (หรือยังไม่มี namespace)" ;;
        *)          warn "namespace $ns enforce = $lv (ไม่ใช่ restricted)" ;;
    esac
done

# ทดสอบของจริง — pod ที่ผิดกฎต้องถูกปฏิเสธ
# dry-run=server ผ่าน admission ครบทุกด่านแต่ไม่ได้สร้าง pod จริง
psa_probe='{"spec":{"containers":[{"name":"psa-probe","image":"busybox","securityContext":{"privileged":true}}]}}'
psa_out=$(kubectl -n myhr-prod run psa-probe --image=busybox --restart=Never \
            --dry-run=server --overrides="$psa_probe" 2>&1)
if printf '%s' "$psa_out" | grep -q 'violates PodSecurity'; then
    ok "PSA บล็อก privileged pod ใน myhr-prod จริง"
else
    bad "PSA ไม่บล็อก privileged pod — ติด label แล้วแต่ไม่มีผล"
    note "ผลที่ได้: $(printf '%s' "$psa_out" | head -1)"
fi

# --------------------------------------------------------- 3 NetworkPolicy
echo
echo "3 · NetworkPolicy"

for ns in myhr-prod myhr-uat; do
    pols=$(kubectl -n "$ns" get netpol -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    has_deny=$(printf '%s\n' "$pols" | grep -c '^default-deny-all$')
    has_dns=$(printf '%s\n' "$pols" | grep -c '^allow-dns-egress$')
    if [ "$has_deny" -ge 1 ] && [ "$has_dns" -ge 1 ]; then
        ok "$ns มี default-deny-all + allow-dns-egress ครบคู่"
    elif [ "$has_deny" -ge 1 ]; then
        bad "🔴 $ns มี default-deny-all แต่ไม่มี allow-dns-egress — pod resolve DNS ไม่ได้"
        note "แก้ทันที: kubectl apply -f /root/k8s/config/security/allow-dns.yaml"
    else
        bad "$ns ยังไม่มี default-deny-all"
    fi
done

# object อยู่ใน apiserver ไม่ได้แปลว่า Cilium รับไปบังคับใช้แล้ว
# ต้องวนทุก agent — policy ถูกโหลดเฉพาะเครื่องที่มี pod ของ namespace นั้นอยู่
# ถาม ds/cilium เฉย ๆ จะได้ agent ตัวเดียวที่ Kubernetes เลือกให้ (มักเป็นตัวบน master
# ซึ่งไม่มี pod ของ myhr-prod เลย) แล้วจะสรุปผิดว่า policy ไม่ถูกบังคับใช้
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    loaded=0
    for cp in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null); do
        n=$(kubectl -n kube-system exec "$cp" -c cilium-agent -- \
              cilium-dbg policy get 2>/dev/null | grep -c myhr-prod)
        [ "${n:-0}" -gt 0 ] && loaded=$((loaded+1))
    done
    if [ "$loaded" -gt 0 ]; then
        ok "Cilium โหลด policy ของ myhr-prod ไปบังคับใช้แล้ว ($loaded เครื่อง)"
    else
        bad "ไม่มี agent เครื่องไหนโหลด policy ของ myhr-prod เลย"
        note "ถ้ายังไม่มี pod ใน myhr-prod ก็ปกติ — ให้รันซ้ำหลัง deploy แอปในบทที่ 11"
    fi
fi
note "การทดสอบยิงจริง (curl ออกนอกไม่ได้ แต่ DNS ได้) อยู่ที่บทที่ 10 หัวข้อ 3"

# --------------------------------------------------------------------- 4 RBAC
echo
echo "4 · RBAC"

for cr in myhr:developer myhr:deployer myhr:operator; do
    if kubectl get clusterrole "$cr" >/dev/null 2>&1; then
        ok "ClusterRole $cr มีอยู่"
    else
        bad "ไม่มี ClusterRole $cr — ยังไม่ได้ apply rbac.yaml"
    fi
done

# สิทธิ์จริงต้องตรงกับที่ตั้งใจ — ทั้งข้อที่ต้องได้และข้อที่ต้องไม่ได้
# สวมรอยเป็น group เพราะ rbac.yaml ผูกกับ Group ไม่ได้ผูกกับ ServiceAccount
# subresource ต้องส่งผ่าน --subresource ห้ามเขียน pods/exec ติดกัน
# เพราะ kubectl อ่านเป็น TYPE/NAME (resource pods ชื่อ exec) แล้วถามผิดคำถาม
can() {  # can <กลุ่ม> <verb+resource> <ns args> <yes|no>
    got=$(kubectl auth can-i $2 --as=rbac-probe --as-group="$1" $3 2>/dev/null)
    if [ "$got" = "$4" ]; then
        ok "$1: $2 ${3:-(cluster)} = $got"
    else
        bad "$1: $2 ${3:-(cluster)} ได้ '$got' ต้องได้ '$4'"
    fi
}
can myhr:developers "get pods"                        "-n myhr-prod" yes
can myhr:developers "get secrets"                     "-n myhr-prod" no
can myhr:developers "create pods --subresource=exec"  "-n myhr-prod" no
can myhr:developers "get pods --subresource=log"      "-n myhr-prod" yes
can myhr:developers "get pods"                        "-n myhr-uat"  no
can myhr:operators  "get nodes"                       ""             yes
can myhr:operators  "create pods --subresource=eviction" "-n myhr-prod" yes
can myhr:operators  "delete nodes"                    ""             no

if command -v jq >/dev/null 2>&1; then
    admins=$(kubectl get clusterrolebindings -o json 2>/dev/null \
      | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .subjects[]?
               | select(.kind=="User" or .kind=="Group")
               | select((.name|startswith("system:"))|not) | .kind + "/" + .name' \
      | sort -u)
    n_admin=$(printf '%s\n' "$admins" | grep -c .)
    if [ "$n_admin" -le 2 ]; then
        ok "cluster-admin ที่ไม่ใช่ system: มี $n_admin ราย"
    else
        warn "cluster-admin มี $n_admin ราย — เกินที่ตกลงไว้ (ไม่เกิน 2)"
    fi
    printf '%s\n' "$admins" | grep . | sed 's/^/           · /'
else
    warn "ไม่มี jq — ข้ามการนับ cluster-admin"
fi

# ------------------------------------------------------------ 4ก imagePullSecret
echo
echo "4ก · imagePullSecret (regcred)"

# Secret ผูกกับ namespace — ขาด namespace ไหน pod ที่นั่นจะค้าง ImagePullBackOff
# โดยที่ namespace อื่นยังใช้ได้ปกติ จึงมองไม่เห็นจนกว่าจะ deploy
#
# ไม่ใช้รายชื่อตายตัว — ถามของจริงว่า namespace ไหนมี pod ที่ดึง image จาก registry นี้
# รายชื่อตายตัวจะล้าสมัยทุกครั้งที่เพิ่ม namespace ซึ่งเป็นกับดักที่ด่านนี้มีไว้จับพอดี
reg=${REGISTRY_HOST:-registry.myhr.co.th}
ns_list=$(kubectl get pods -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | grep -F "$reg" | cut -f1 | sort -u)

if [ -z "$ns_list" ]; then
    note "ยังไม่มี pod ไหนใช้ image จาก $reg — ข้ามด่านนี้ (จะมีผลตอนบทที่ 11)"
fi

for ns in $ns_list; do
    if kubectl -n "$ns" get secret regcred >/dev/null 2>&1; then
        host=$(kubectl -n "$ns" get secret regcred \
                 -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
               | base64 -d 2>/dev/null | sed -n 's/.*"auths":{"\([^"]*\)".*/\1/p')
        ok "$ns: regcred มีอยู่ (host=${host:-อ่านไม่ออก})"
    else
        bad "$ns: มี pod ที่ดึง image จาก $reg แต่ไม่มี regcred"
        note "แก้: ดูบทที่ 10 หัวข้อ 7.2 แล้วรันบล็อกสร้าง secret โดยใส่ $ns เข้าไปด้วย"
    fi
done

# ---------------------------------------------------------------- 5 audit log
echo
echo "5 · Audit log"

n_pol=$(printf '%s\n' "$api_cmds" | grep -c 'audit-policy-file')
if [ "$n_pol" -eq "$n_api" ] && [ "$n_api" -ge 3 ]; then
    ok "apiserver ทั้ง $n_api ตัวมี --audit-policy-file"
else
    bad "apiserver มี audit-policy-file แค่ $n_pol จาก $n_api ตัว"
fi

log=/var/log/kubernetes/audit.log
if [ -s "$log" ]; then
    sz=$(du -h "$log" | cut -f1)
    age=$(( $(date +%s) - $(stat -c %Y "$log") ))
    if [ "$age" -lt 300 ]; then
        ok "audit.log เขียนล่าสุดเมื่อ ${age} วินาทีที่แล้ว (ขนาด $sz)"
    else
        bad "audit.log ไม่ถูกเขียนมา ${age} วินาทีแล้ว — policy อาจไม่ match อะไรเลย"
    fi
    if tail -5 "$log" | grep -q '"kind":"Event"'; then
        ok "audit.log มี event จริงอ่านได้"
    else
        warn "อ่าน event จาก audit.log ไม่ออก"
    fi
else
    bad "ไม่มี $log บนเครื่องนี้"
    note "audit.log เป็นไฟล์ของใครของมัน — ต้องรันสคริปต์นี้ที่ master ทีละเครื่องด้วย"
fi

# ------------------------------------------------------------------- สรุป
echo
echo "==============================================================="
printf ' ผ่าน %d · ตก %d · ระวัง %d\n' "$OK" "$BAD" "$WARN"
if [ "$BAD" -eq 0 ]; then
    echo " ✅ บทที่ 10 ใช้งานได้จริงเท่าที่ตรวจอัตโนมัติได้"
    echo "    เหลือข้อที่เครื่องตรวจแทนไม่ได้ — หมุน credential เก่า (หัวข้อ 6)"
    echo "    และ encryption key ต้องอยู่ในที่เก็บ secret ขององค์กร ไม่ใช่ใน git"
else
    echo " ❌ มี $BAD ข้อที่ยังไม่ผ่าน — แก้แล้วรันซ้ำได้เลย"
fi
echo "==============================================================="
[ "$BAD" -eq 0 ]
