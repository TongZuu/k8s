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

# pyyaml มองข้ามคอมเมนต์ที่อยู่ก่อน "---" บรรทัดแรกให้ แต่ kubeadm ไม่ข้าม
# kubeadm หั่นไฟล์ที่บรรทัด "---" ตรง ๆ ก่อน แล้วบังคับว่าทุกชิ้นต้องมี apiVersion+kind
# ไฟล์จึง "parse ผ่าน" ในข้อ 3 ได้ แต่ kubeadm init ตายตั้งแต่ยังไม่เริ่มทำอะไร
# เช็คนี้จำลองวิธีหั่นของ kubeadm ไม่ใช่วิธีอ่านของ pyyaml
SPLIT=0
for f in config/kubeadm/*.yaml; do
    [ -f "$f" ] || continue
    # ต้องดักกรณี awk เองพัง ไม่งั้นไม่มี output = ผ่าน ซึ่งคือกับดักที่ตรวจแล้วไม่ได้ตรวจ
    if ! OUT=$(awk -f config/kubeadm-docsplit.awk "$f" 2>&1); then
        fail "$f — ตรวจไม่สำเร็จ: $OUT"
        SPLIT=1
        continue
    fi
    if [ -n "$OUT" ]; then
        while IFS= read -r line; do fail "$line"; done <<< "$OUT"
        SPLIT=1
    fi
done
[ $SPLIT -eq 0 ] && ok "kubeadm หั่น config เป็น document ได้ครบทุกชิ้น"

# token: "" ไม่ได้แปลว่า "ปล่อยว่างให้ kubeadm สุ่มเอง" — v1beta4 แปลงค่าว่างเป็น
# BootstrapTokenString ไม่ได้ แล้วตายตอน unmarshal ถ้าจะให้สุ่มต้องไม่มี field token เลย
TOKEN_BAD=0
for f in config/kubeadm/*.yaml; do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
        fail "$f:$hit  <- token ว่าง ให้ลบบรรทัด token: ทิ้งไปเลย kubeadm จะสุ่มให้เอง"
        TOKEN_BAD=1
    done < <(grep -nE "^[[:space:]-]*token:[[:space:]]*(\"\"|''|)[[:space:]]*(#.*)?$" "$f")
done
[ $TOKEN_BAD -eq 0 ] && ok "bootstrapTokens ไม่มี token ว่าง"

# audit ต้องครบชุด ไม่งั้นได้โฟลเดอร์ว่างโดยไม่มี error ให้เห็น:
#   audit-log-path อย่างเดียว = apiserver ขึ้นปกติแต่ไม่บันทึกอะไรเลย
#   ไม่ mount policy/log dir = apiserver ไม่ขึ้น หรือเขียน log ลงในคอนเทนเนอร์
AUDIT_BAD=0
K=config/kubeadm/kubeadm-config.yaml
if [ -f "$K" ] && grep -q 'audit-log-path' "$K"; then
    grep -q 'audit-policy-file' "$K"         || { fail "$K: มี audit-log-path แต่ไม่มี audit-policy-file — apiserver จะไม่บันทึกอะไรเลย"; AUDIT_BAD=1; }
    grep -q 'hostPath: "/etc/kubernetes/audit-policy.yaml"' "$K"         || { fail "$K: ไม่ได้ mount audit-policy.yaml ใน extraVolumes — apiserver อ่าน policy ไม่เจอ"; AUDIT_BAD=1; }
    grep -q 'hostPath: "/var/log/kubernetes"' "$K"         || { fail "$K: ไม่ได้ mount /var/log/kubernetes ใน extraVolumes — log จะตกอยู่ในคอนเทนเนอร์"; AUDIT_BAD=1; }
    [ -f config/kubeadm/audit-policy.yaml ]         || { fail "config/kubeadm/audit-policy.yaml หายไป — เครื่องจะ mount ไฟล์ที่ไม่มีอยู่จริง"; AUDIT_BAD=1; }
    [ $AUDIT_BAD -eq 1 ] && FAILED=1
    [ $AUDIT_BAD -eq 0 ] && ok "audit ครบชุด (policy + flag + volume ทั้งสอง)"
fi

# health check ของ haproxy ต้องมีแบบเดียว — httpchk กับ ssl-hello-chk ใช้ร่วมกันไม่ได้
# ใส่ทั้งคู่แล้ว haproxy -c ยังผ่าน แต่ check ที่ทำงานจริงไม่ใช่ตัวที่คอมเมนต์บอกไว้
H=config/haproxy/haproxy.cfg
if [ -f "$H" ]; then
    # ต้องไม่นับบรรทัดคอมเมนต์ที่พูดถึงตัวเลือกพวกนี้ ไม่งั้นคำเตือนในไฟล์จะทำให้ตัวเองไม่ผ่าน
    if grep -qE '^[[:space:]]*option[[:space:]]+httpchk' "$H" && grep -qE '^[[:space:]]*option[[:space:]]+ssl-hello-chk' "$H"; then
        fail "$H: มีทั้ง httpchk และ ssl-hello-chk — ใช้ร่วมกันไม่ได้ ต้องเลือกอย่างเดียว"
        FAILED=1
    else
        ok "haproxy มี health check แบบเดียว ไม่ชนกัน"
    fi
fi

# kubeadm token create มี default ttl 24 ชม. ซึ่งสวนทางกับ bootstrapTokens.ttl=2h ใน
# kubeadm-config.yaml · ลืมใส่ --ttl = มีบัตรผ่านเข้า cluster อายุ 24 ชม. โดยไม่ตั้งใจ
TTL_BAD=0
while IFS= read -r hit; do
    fail "$hit  <- ต้องใส่ --ttl 2h ให้ตรงกับ kubeadm-config.yaml"
    TTL_BAD=1
done < <(grep -rn "kubeadm token create" docs/*.md ansible/*.yml 2>/dev/null | grep -v -- "--ttl")
[ $TTL_BAD -eq 0 ] && ok "kubeadm token create ระบุ --ttl ครบทุกที่"

echo "4 · ตัวแปร \$UPPERCASE ที่ใช้แต่ไม่เคยประกาศ"
UNDEF=0
for f in docs/*.md config/*/*.sh config/*/*.yaml; do
    [ -f "$f" ] || continue
    # CHECKLIST.md เป็นร้อยแก้วที่พูดถึงตัวแปร ไม่ใช่คำสั่งให้ copy ไปรัน
    case "$f" in */CHECKLIST.md) continue;; esac
    used=$(grep -oE '\$\{?[A-Z][A-Z0-9_]+\}?' "$f" 2>/dev/null | tr -d '${}' | sort -u)
    for v in $used; do
        case "$v" in HOME|PATH|USER|PWD|SHELL|HOSTNAME|RANDOM|IFS|PIPESTATUS|BASH_SOURCE|FUNCNAME|SECONDS) continue;; esac
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

if [ -f config/kubeadm/kubeadm-config.yaml ]; then
    K=config/kubeadm/kubeadm-config.yaml
    grep -q "kubernetesVersion: v${K8S_VERSION}" "$K" || { fail "$K: kubernetesVersion ไม่ใช่ v$K8S_VERSION"; FAILED=1; }
    grep -q "controlPlaneEndpoint: \"${VIP}:${VIP_PORT}\"" "$K" || { fail "$K: controlPlaneEndpoint ไม่ใช่ $VIP:$VIP_PORT"; FAILED=1; }
    grep -q "podSubnet: \"${POD_CIDR}\"" "$K" || { fail "$K: podSubnet ไม่ใช่ $POD_CIDR"; FAILED=1; }
    grep -q "serviceSubnet: \"${SVC_CIDR}\"" "$K" || { fail "$K: serviceSubnet ไม่ใช่ $SVC_CIDR"; FAILED=1; }
    grep -q "advertiseAddress: ${MASTER01_IP}" "$K" || { fail "$K: advertiseAddress ไม่ใช่ $MASTER01_IP"; FAILED=1; }
    [ "${FAILED:-0}" -eq 0 ] && ok "kubeadm-config.yaml ตรงกับ versions.env"
fi

# inventory.ini กับ versions.env เก็บ IP ของเครื่องเดียวกันคนละที่
# ถ้า drift กัน playbook จะไปคุยกับเครื่องผิดตัวโดยไม่มีอะไรเตือน
# (ansible ไม่รู้จัก versions.env ส่วนคู่มือไม่รู้จัก inventory)
INV=ansible/inventory.ini
if [ -f "$INV" ]; then
    INV_BAD=0
    # อ่านรายชื่อ role จาก versions.env ไม่ไล่พิมพ์เอง — เพิ่มเครื่องใหม่แล้วตัวตรวจต้องเห็นเอง
    # ไม่งั้นเครื่องที่เพิ่มทีหลังจะไม่มีใครตรวจ ซึ่งอันตรายกว่าไม่มีตัวตรวจเลย
    ROLES=$(grep -oE '^(MASTER|WORKER)[0-9]+_IP=' docs/versions.env | sed 's/_IP=//' | sort -u)
    for role in $ROLES; do
        eval "want=\${${role}_IP:-}"
        eval "name=\${${role}_NAME:-}"
        [ -n "$want" ] && [ -n "$name" ] || continue
        got=$(grep -E "^$name[[:space:]]+ansible_host=" "$INV" | sed 's/.*ansible_host=//' | tr -d '[:space:]')
        if [ -z "$got" ]; then
            fail "$INV: ไม่มีบรรทัดของ $name — versions.env ประกาศไว้แต่ inventory ไม่มี"
            INV_BAD=1
        elif [ "$got" != "$want" ]; then
            fail "$INV: $name=$got แต่ versions.env บอก ${role}_IP=$want"
            INV_BAD=1
        fi
    done
    [ $INV_BAD -eq 1 ] && FAILED=1
    [ $INV_BAD -eq 0 ] && ok "inventory.ini ตรงกับ versions.env ทุกเครื่อง"
fi

# Cilium ถือค่าเครือข่ายชุดเดียวกับ kubeadm-config แต่คนละไฟล์ ถ้า drift กันจะเจ็บกว่า
# เพราะ pod จะขึ้นมาแล้วเครือข่ายพังทั้ง cluster โดยไม่มี kube-proxy ให้ถอยกลับ
CIL=config/cilium/values.yaml
if [ -f "$CIL" ]; then
    CIL_BAD=0
    grep -qE "^kubeProxyReplacement:[[:space:]]*true[[:space:]]*$" "$CIL"         || { fail "$CIL: kubeProxyReplacement ต้องเป็น true — cluster นี้ไม่มี kube-proxy ให้ใช้"; CIL_BAD=1; }
    grep -qE "^k8sServiceHost:[[:space:]]*${VIP}[[:space:]]*$" "$CIL"         || { fail "$CIL: k8sServiceHost ต้องเป็น $VIP (VIP) ไม่ใช่ IP ของ master เครื่องใดเครื่องหนึ่ง"; CIL_BAD=1; }
    grep -qE "^k8sServicePort:[[:space:]]*${VIP_PORT}[[:space:]]*$" "$CIL"         || { fail "$CIL: k8sServicePort ต้องเป็น $VIP_PORT"; CIL_BAD=1; }
    grep -qE "^[[:space:]]*-[[:space:]]*\"${POD_CIDR}\"[[:space:]]*$" "$CIL"         || { fail "$CIL: clusterPoolIPv4PodCIDRList ไม่ใช่ $POD_CIDR — ต้องตรงกับ podSubnet ใน kubeadm-config"; CIL_BAD=1; }
    grep -qE "clusterPoolIPv4MaskSize:[[:space:]]*${POD_CIDR_MASK_SIZE}([[:space:]]|$|#)" "$CIL"         || { fail "$CIL: clusterPoolIPv4MaskSize ไม่ใช่ $POD_CIDR_MASK_SIZE — ต้องตรงกับ node-cidr-mask-size"; CIL_BAD=1; }
    [ $CIL_BAD -eq 1 ] && FAILED=1
    [ $CIL_BAD -eq 0 ] && ok "cilium values.yaml ตรงกับ versions.env"
fi

POOL=config/cilium/lb-ippool.yaml
if [ -f "$POOL" ]; then
    grep -q "\"${LB_POOL_START}\"" "$POOL" && grep -q "\"${LB_POOL_STOP}\"" "$POOL"         && ok "lb-ippool.yaml ตรงกับ LB_POOL_START/STOP"         || { fail "$POOL: ช่วง IP ไม่ตรงกับ $LB_POOL_START-$LB_POOL_STOP ใน versions.env"; FAILED=1; }
fi

echo "6 · html/ ต้องตามหลัง docs/*.md และ ansible/README.md"
# ลืม build ใหม่หลังแก้ .md เป็นเรื่องที่พึ่งความจำแล้วพลาดง่าย ให้ตัวตรวจจำแทน
# ansible/README.md อยู่คนละโฟลเดอร์แต่ build เป็น html/ansible.html จึงต้องตรวจด้วย
STALE=0
for md in docs/*.md ansible/README.md; do
    [ -f "$md" ] || continue
    case "$md" in
        ansible/README.md) h="html/ansible.html";;
        *)                 h="html/$(basename "$md" .md).html";;
    esac
    [ -f "$h" ] || continue
    if [ "$md" -nt "$h" ]; then
        fail "$md ใหม่กว่า $h — ต้องรัน python tools/build-html.py"
        STALE=1; FAILED=1
    fi
done
[ $STALE -eq 0 ] && ok "html/ ตรงกับ docs/ และ ansible/README.md แล้ว"

echo "7 · ความลับที่ไม่ควรอยู่ในrepo"
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

echo "8 · โครงสร้าง markdown ที่ทำให้ html เพี้ยน"
MD=0
for f in docs/*.md; do
    # ``` ต้องเป็นเลขคู่ ไม่งั้นโค้ดบล็อกไม่ปิด แล้วเนื้อหาที่เหลือถูกกลืนเข้าไปทั้งดุ้น
    n=$(grep -c '^```' "$f")
    if [ $((n % 2)) -ne 0 ]; then
        fail "$f มี \`\`\` $n ตัว (ต้องเป็นเลขคู่) — โค้ดบล็อกไม่ปิด"
        MD=1
    fi
    # หลัง </figure> ต้องมีบรรทัดว่าง ไม่งั้น markdown กลืนบรรทัดถัดไปเข้าไปใน html block
    if ! awk '/^<\/figure>$/{getline nxt; if (nxt != "") bad=1} END{exit bad?1:0}' "$f"; then
        fail "$f — บรรทัดหลัง </figure> ต้องเป็นบรรทัดว่าง"
        MD=1
    fi
done
[ $MD -eq 0 ] && ok "โค้ดบล็อกปิดครบ และภาพประกอบเว้นบรรทัดถูกต้อง"

echo "9 · ด่านก่อนเริ่มงานของ Ansible ที่จะหายไปเงียบ ๆ ตอน --check"
# module shell/command ถูก skip อัตโนมัติใน check mode → ตัวแปรที่ register ไม่มีค่า
# → failed_when ไม่เคยถูกประเมิน → ด่านนั้นหายไปทั้งด่านโดยไม่มี error
# และ ansible.cfg ตั้ง display_skipped_hosts = False ไว้ จึงไม่มีบรรทัดไหนบอกด้วยซ้ำ
# ผลคือ --check เขียวหมด แล้วรันจริงตายทันที (เจอจริง 11 ก.ย. 2026 ที่ด่าน versionlock)
#
# กฎนี้จับแค่คลาสที่อันตรายจริง: ด่านที่อยู่ "ก่อน" task แรกที่แก้เครื่อง
# นั่นคือเงื่อนไขที่ playbook ไม่ได้ทำให้เอง จึงต้องเห็นตั้งแต่ dry run
#   → ต้องใส่ check_mode: false
# ด่านที่อยู่ "หลัง" task ที่แก้เครื่องแล้ว เป็นเงื่อนไขที่ playbook สร้างเอง
# (เช่นเวลา sync ที่มาหลังเปิด chronyd) ต้องปล่อยให้ skip ไม่งั้น --check จะ fail
# ทั้งที่รันจริงผ่าน — กฎนี้จึงไม่แตะพวกนั้น
#
# 🔴 ห้ามใช้ check_mode: true แทน — มันแปลว่า "รันแบบ check ตลอด แม้ตอนรันจริง"
#    ซึ่งเท่ากับปิดด่านนั้นถาวร ไม่ใช่ "ยอมให้ --check ข้าม"
if command -v python >/dev/null 2>&1 && python -c 'import yaml' 2>/dev/null; then
    PYTHONIOENCODING=utf-8 python - <<'PY'
import glob, io, sys
import yaml

RUN = ('ansible.builtin.shell', 'ansible.builtin.command', 'shell', 'command')
# module ที่เปลี่ยนสภาพเครื่อง — ตัวแรกที่เจอคือเส้นแบ่ง ก่อน/หลัง
MUTATE = (
    'copy', 'file', 'template', 'dnf', 'yum', 'package', 'systemd', 'service',
    'lineinfile', 'blockinfile', 'replace', 'sysctl', 'hostname', 'reboot',
    'firewalld', 'mount', 'user', 'group', 'unarchive', 'get_url', 'command',
    'shell', 'pip', 'modprobe',
)


def mod_names(task):
    out = []
    for k in task:
        out.append(k.split('.')[-1] if '.' in k else k)
    return out


bad = []
checked = 0

for f in sorted(glob.glob('ansible/*.yml')):
    try:
        doc = yaml.safe_load(io.open(f, encoding='utf-8').read())
    except Exception as e:
        bad.append((f, '(parse ไม่ผ่าน)', str(e).split('\n')[0]))
        continue
    for play in (doc or []):
        if not isinstance(play, dict):
            continue
        flat = []
        for sect in ('pre_tasks', 'tasks', 'post_tasks'):
            for t in (play.get(sect) or []):
                if isinstance(t, dict):
                    flat.append(t)
        # หา index ของ task แรกที่แก้เครื่อง — ข้าม task ที่อ่านอย่างเดียว
        first_mutate = len(flat)
        for i, t in enumerate(flat):
            names = mod_names(t)
            if any(m in names for m in MUTATE):
                # shell/command ที่ changed_when: false คืออ่านอย่างเดียว ไม่นับว่าแก้
                if any(m in names for m in RUN) and t.get('changed_when') is False:
                    continue
                first_mutate = i
                break
        for i, t in enumerate(flat[:first_mutate]):
            if 'failed_when' not in t:
                continue
            if not any(m in t for m in RUN):
                continue
            checked += 1
            if t.get('check_mode') is not False:
                bad.append((f, t.get('name', '(ไม่มีชื่อ)'),
                            'อยู่ก่อน task ที่แก้เครื่อง แต่ไม่ได้ใส่ check_mode: false'))

for f, name, why in bad:
    print(f"  FAIL  {f} — {name} — {why}")
if not bad:
    print(f"  ok    ด่านก่อนเริ่มงานใส่ check_mode: false ครบ ({checked} ตัว)")
sys.exit(1 if bad else 0)
PY
    [ $? -ne 0 ] && FAILED=1
else
    echo "  ข้าม  (ไม่มี python + pyyaml)"
fi

echo
if [ $FAILED -eq 0 ]; then
    echo "ผ่านหมด — commit ได้"
else
    echo "มีข้อไม่ผ่าน — แก้ก่อน commit"
fi
exit $FAILED
