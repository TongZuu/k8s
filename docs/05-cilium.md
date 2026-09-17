# บทที่ 05 — Cilium (CNI + kube-proxy replacement + LB-IPAM)

> **รันที่: 👑 master01 เกือบทั้งบท** (Helm กระจายไปทุก node ให้เอง) · ยกเว้น 2 จุดที่บอกไว้:
> loop `ssh` ในข้อ 2 รันจาก**เครื่องคุณ** · `curl` ทดสอบ LB ในข้อ 7 ต้องยิงจาก**เครื่องในวง LAN
> ที่ไม่ใช่ node** (7.2 อธิบายว่าทำไม)
> **ลำดับ: 1 → 7 ตามลำดับ ไม่มีข้อไหนทำพร้อมกันได้** — แต่ละข้อรอผลข้อก่อนหน้า
> **เวลาที่ใช้:** ~25 นาที + connectivity test ข้อ 5 อีก 10-20 นาที
> **ต้องผ่านบทที่ 04** — `kubectl get nodes` เห็นครบ 6 เครื่องในสถานะ `NotReady` (ยังไม่มี CNI คือปกติ)

---

## Cilium ทำอะไรให้บ้าง

| หน้าที่ | แทนอะไร |
|---|---|
| **CNI** | ให้ pod มี IP และคุยข้าม node ได้ |
| **kube-proxy replacement** | ทำ Service ClusterIP/NodePort ด้วย eBPF — เราไม่ได้ติดตั้ง kube-proxy เลย |
| **LB-IPAM + L2 announcement** | จ่าย IP ให้ `type: LoadBalancer` — แทน MetalLB |
| **NetworkPolicy** | บังคับ default-deny ได้ ซึ่ง Flannel ของเดิมทำไม่ได้ |
| **Hubble** | ตอบคำถาม "pod นี้คุยกับใครบ้าง" ซึ่งจำเป็นตอน audit |

> ⚠️ **ทั้งหมดนี้อยู่ในตัวเดียว** — Cilium มีปัญหาทีเดียว pod network, Service
> และ LoadBalancer ดับพร้อมกัน และ **ไม่มี kube-proxy ให้ถอยกลับไปใช้**
> นี่คือราคาของการตัดชิ้นส่วนออก จึงต้องพิสูจน์ให้ได้ว่าทีม debug มันเป็นก่อนขึ้น production

> 🔎 **ตอนของจริงพัง** ให้เปิด [`../html/cilium-envoy-scenarios.html`](../html/cilium-envoy-scenarios.html)
> — 28 อาการของ Cilium + Envoy Gateway เรียงตามความถี่ที่เจอจริง ค้นด้วยข้อความ error ได้เลย
> และมีอีก 25 แบบแผนว่าควรออกแบบยังไงตั้งแต่แรก พร้อมภาพประกอบและขั้นตอนแบบทำตามได้
> (แบ่ง namespace/zone · กัน namespace เรียกหากัน · auth ที่ทางเข้า · เข้ารหัส pod network · เตรียม audit)

---

## 1 · ติดตั้ง Helm 4 และ Cilium CLI

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** `/root/k8s/dl/` มีอยู่แล้วจาก[บท 02](02-container-runtime.md)
· เครื่องออก `get.helm.sh` และ `github.com` ได้ (DNS ภายนอกของวงนี้หลุดเป็นช่วง ๆ — `curl` ล้มให้รันซ้ำ)

```bash
set -a && source /root/k8s/versions.env && set +a
cd /root/k8s/dl

# Helm
curl -fsSLO "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
tar -xzf "helm-v${HELM_VERSION}-linux-amd64.tar.gz"
install -m 755 linux-amd64/helm /usr/local/bin/helm
helm version --short
```
**ควรเห็น:** `v4.2.4+...`

```bash
# Cilium CLI — ใช้ตอน debug เป็นหลัก
CILIUM_CLI=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -fsSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI}/cilium-linux-amd64.tar.gz"
tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
cilium version --client
```

> Helm 4 ใช้ **Server-Side Apply** เป็นค่าเริ่มต้นและต้องการสิทธิ์ RBAC เพิ่มสำหรับ kstatus
> ถ้าเจอ error เรื่องสิทธิ์ตอน install ให้ดูตรงนี้ก่อน

---

## 2 · ตรวจ values ก่อนติดตั้ง

**ทำที่:** 👑 master01 (บล็อก `grep`) · **เครื่องคุณ** (loop `ssh` ไป worker) · **ต้องมีก่อน:**
`/root/k8s/config/cilium/` อยู่บนเครื่องจาก[บท 00](00-overview.md) · ข้อนี้อ่านอย่างเดียว ไม่แก้อะไรถ้าค่าตรง

```bash
grep -E -A1 'k8sServiceHost|k8sServicePort|clusterPoolIPv4PodCIDRList|kubeProxyReplacement|terminatePodConnections' \
  /root/k8s/config/cilium/values.yaml | grep -E 'k8sService|clusterPool|kubeProxy|terminatePod|^ +- '
```

(`-A1` เพราะ `clusterPoolIPv4PodCIDRList` เป็น list — ค่าอยู่บรรทัดถัดไป `- "10.246.0.0/16"` ไม่ใช่บรรทัดเดียวกับชื่อ)

**ต้องตรงกับ `versions.env`:**

| ค่า | ต้องเป็น |
|---|---|
| `kubeProxyReplacement` | `true` |
| `k8sServiceHost` | `192.168.50.100` (VIP) |
| `k8sServicePort` | `8443` |
| `clusterPoolIPv4PodCIDRList` | บรรทัดถัดไปเป็น `- "10.246.0.0/16"` |
| `terminatePodConnections` | `false` — kernel UEK ไม่มี `CONFIG_INET_DIAG_DESTROY` ถ้าเปิดไว้ agent log error และ `check-log-errors` ตก |

> **`k8sServiceHost` ต้องเป็น VIP ไม่ใช่ IP ของ master01**
> เพราะไม่มี kube-proxy Cilium จึงหา apiserver ผ่าน Service ClusterIP ไม่ได้
> ถ้าชี้ไปที่ master01 ตรง ๆ วันที่ master01 ตาย Cilium ทั้ง cluster จะหลุด

**ยืนยันชื่อ interface ใน L2 policy ให้ตรงกับ worker จริง:**

> ⚠️ **ต้องเทียบกับ worker ไม่ใช่เครื่องที่คุณกำลังยืนอยู่** — policy ตัด control plane
> ออกด้วย `nodeSelector` แล้ว (กัน traffic ของ application ไม่ให้เบียด apiserver/etcd)
> master จะชื่อ interface อะไรก็ไม่มีผล ถ้าเช็กบน master01 แล้วเห็นตรงกันพอดี
> จะผ่านไปทั้งที่ยังไม่ได้ตรวจสิ่งที่ต้องตรวจเลย

```bash
for ip in 104 105 106; do echo -n "worker$ip: "; ssh root@192.168.50.$ip "ip -br -4 a s | awk '/192.168.50./{print \$1}'"; done
grep -A3 'interfaces:' /root/k8s/config/cilium/l2-announcement-policy.yaml
```
**ควรเห็น:** ชื่อ interface ของ worker **ทั้ง 3 ตัว** เข้าเงื่อนไข regex ใน `interfaces:`

**ถ้ามีตัวไหนไม่เข้า** ให้แก้ `l2-announcement-policy.yaml` เป็น regex ที่ครอบคลุมทุกชื่อ:
```yaml
  interfaces:
    - ^ens[0-9]+$
```

> ชื่อ NIC ต่างกันได้รายเครื่องตามชนิด adapter ที่ VM ถูกสร้างมา
> (`ens192` มักเป็น VMXNET3 · `ens33`/`ens32` มักเป็น E1000) — เคยเจอจริงใน cluster นี้
>
> **ผลถ้าปล่อยให้ไม่ตรง:** worker ตัวนั้นจะไม่ถูกเลือกเป็นคนตอบ ARP
> · ไม่ตรงบางตัว → ยังใช้งานได้ แต่เหลือตัวสำรองน้อยลงโดยไม่มีอะไรเตือน
> · **ไม่ตรงเลยสักตัว → Service ขึ้น `EXTERNAL-IP` ปกติ `kubectl` ไม่ฟ้องอะไร
> แต่ ping จากข้างนอกไม่ติด** เป็นอาการเดียวกับตอนโดน Dynamic ARP Inspection บล็อก

---

## 3 · ติดตั้ง Cilium

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 1 (`helm version` ตอบ) · ข้อ 2 ค่าตรงครบ · `kubectl` ใช้ได้
([บท 04 ข้อ 3](04-create-cluster.md) — helm ใช้ kubeconfig เดียวกัน)

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  -f /root/k8s/config/cilium/values.yaml
```

**รอให้ขึ้นครบ:**
```bash
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m
```

**ตรวจสถานะ:**
```bash
cilium status --wait
```

**ควรเห็น:**
```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Hubble Relay:       OK
 \__/¯¯\__/    ClusterMesh:        disabled
    \__/

DaemonSet    cilium    Desired: 6, Ready: 6/6, Available: 6/6
```

**ตรวจ node กลายเป็น Ready:**
```bash
kubectl get nodes
```
**ควรเห็น:** ทั้ง 6 เครื่องเป็น **`Ready`** แล้ว

---

## 4 · ยืนยันว่า kube-proxy replacement ทำงานจริง

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 3 จบและ `cilium status --wait` ผ่าน (agent Running ครบ 6 —
ถามก่อนขึ้นครบจะได้ผลไม่ครบ 6 บรรทัด)

```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  n=$(kubectl -n kube-system get "$p" -o jsonpath='{.spec.nodeName}')
  echo "$n  $(kubectl -n kube-system exec "$p" -c cilium-agent -- \
      cilium-dbg status 2>/dev/null | grep -i KubeProxyReplacement | tr -s ' ')"
done
```
**ควรเห็น:** ครบ 6 บรรทัด บรรทัดละเครื่อง และเป็น `KubeProxyReplacement: True` ทุกบรรทัด
(ในวงเล็บต่อท้ายคือ interface กับ IP ของเครื่องนั้น จึงไม่เหมือนกันแต่ละบรรทัด)

> 🔴 **ต้องวนทุก agent เพราะค่านี้เป็นค่าต่อ node** — `exec ds/cilium` ได้ agent
> ตัวเดียวที่ Kubernetes เลือกให้ ถ้าเครื่องที่มันเลือกปกติ จะเห็น `True` แล้วผ่านไป
> ทั้งที่อีกเครื่องยังเป็น `False` · เครื่องนั้นจะไม่มีอะไรทำ Service เลย
> แล้วอาการจะออกมาเป็น "บาง request ใช้ได้ บางอันไม่ได้" ซึ่งไล่ยากที่สุด

ถ้ามีบรรทัดไหนเป็น `False` หรือ `Disabled` **ให้หยุด** — เครื่องนั้นไม่มีอะไรทำ Service เลย

**ตรวจว่าไม่มี kube-proxy จริง ๆ:**
```bash
kubectl -n kube-system get ds
kubectl get pods -A | grep -c kube-proxy
```
**ควรเห็น:** ไม่มี `kube-proxy` ในรายการ ds และ grep คืน `0`

---

## 5 · ทดสอบ connectivity เต็มรูปแบบ

**ทำที่:** 👑 master01 ใน `tmux` · **ต้องมีก่อน:** ข้อ 4 True ครบ 6 · `kubectl get nodes` เป็น `Ready`
ทุกเครื่องแล้ว · ทุก node ดึง image จากอินเทอร์เน็ตได้ (ชุดทดสอบใช้ image จาก `quay.io`)

Cilium มีชุดทดสอบในตัว ซึ่งครอบคลุมกว่าการ ping เอง — **รันให้ผ่านก่อนไปต่อ**

**🔴 ต้องรันใน `tmux` เสมอ ห้ามรันตรง ๆ ผ่าน ssh**

```bash
dnf install -y tmux 2>/dev/null; tmux new -s cil "cilium connectivity test 2>&1 | tee /root/k8s/cilium-conn-test.log"
```

หลุดแล้วกลับเข้าไปดูต่อ: `tmux attach -t cil` · ดู log ย้อนหลัง: `less /root/k8s/cilium-conn-test.log`

> **ทำไมต้อง `tmux`** — เทสต์ใช้เวลา 10-20 นาที และระหว่างทางมันจะ **apply NetworkPolicy
> ชุด deny-all ลงใน namespace ทดสอบเป็นระยะ** (`all-ingress-deny`, `all-egress-deny`, …)
> ถ้า ssh หลุดกลางคัน process โดน SIGHUP ตาย **แต่ policy ที่ apply ไปแล้วยังค้างอยู่**
> ไม่มีใครเก็บกวาดให้ · แล้วถ้ารันซ้ำทับเลยจะเจอ pod ค้างกับ policy เก่าปนกันจนอ่านผลไม่ออก
>
> เจอจริงในการติดตั้งรอบแรก — ssh หลุดตอน test 12/137 (`all-egress-deny-knp`)
>
> ไม่อยากลง `tmux` ใช้ `nohup cilium connectivity test > /root/k8s/cilium-conn-test.log 2>&1 &`
> แล้ว `tail -f` ก็ได้ — `tail` หลุดไม่กระทบตัวเทสต์

**ควรเห็นท้ายสุด:** `✅ All ... tests successful`
**ใช้เวลา ~10-20 นาที** และจะสร้าง namespace `cilium-test-1` ชั่วคราว

**ถ้ารอบก่อนหลุดกลางคัน ต้องล้างก่อนรันใหม่เสมอ:**

```bash
cilium connectivity test --test-namespace cilium-test-1 --cleanup 2>/dev/null; kubectl delete ns cilium-test-1 --ignore-not-found
kubectl get ns | grep cilium-test    # ต้องว่าง
```

> **"ค้าง" กับ "พัง" แยกกันที่ log ยังเดินอยู่ไหม** ไม่ใช่ที่หน้าจอนิ่ง —
> บางเทสต์เงียบเป็นนาทีได้ปกติ นี่คือเหตุผลที่ต้องมี `tee` ไว้ดูย้อนหลัง

**ถ้าตกเป็นกลุ่ม — ดูว่าตกกลุ่มไหน** (บรรทัด `❌ N/82 tests failed` ตามด้วยรายชื่อ):

| เทสต์ที่ตก | สาเหตุ | แก้ |
|---|---|---|
| **ทุกตัวที่มี L7** (`echo-ingress-l7` · `client-egress-l7-*` · `*tls-sni*` · `to-fqdns*`) `exit code 28` แต่ `pod-to-pod` ผ่าน | firewalld ปิดทาง pod → Envoy/DNS proxy บน host — ขาดบรรทัด `--zone=trusted --add-source` ใน[บท 01 ข้อ 8.1](01-prepare-os.md) (เจอจริง 17 ก.ย. 2026 ตก 26 เทสต์) | ตรวจทุกเครื่อง `firewall-cmd --zone=trusted --list-sources` ต้องได้ `10.246.0.0/16` · ไม่มีให้รันบรรทัดนั้น + `--reload` แล้วรันซ้ำเฉพาะกลุ่ม: `cilium connectivity test --test echo-ingress-l7 --test to-fqdns` |
| `pod-to-pod` ข้าม node ตก | VXLAN `8472/udp` ไม่เปิด | [บท 13 ข้อ 5.1](13-troubleshooting.md) |
| `check-log-errors` ตัวเดียว · ข้อความมี `CONFIG_INET_DIAG_DESTROY` | `values.yaml` ที่ใช้ไม่มี `socketLB.terminatePodConnections: false` (ข้อ 2) | แก้ไฟล์แล้ว `helm upgrade cilium cilium/cilium --version "${CILIUM_VERSION}" -n kube-system -f /root/k8s/config/cilium/values.yaml` · รอ `rollout status ds/cilium` แล้วรันเทสต์ซ้ำ |

**และทดสอบข้อนี้ด้วยเสมอ — จดผลลงบทที่ 13 ไม่ว่าจะผ่านหรือไม่:**
```bash
# firewalld เขียนกฎ nftables ใหม่ทั้งชุดตอน reload — pod ต้องยังคุยกันได้หลังจากนี้
firewall-cmd --reload && sleep 5 && cilium connectivity test --test 'pod-to-pod'
```

**ลบ namespace ทดสอบทิ้ง:**
```bash
kubectl delete ns cilium-test-1 --ignore-not-found
```

---

## 6 · ตั้ง LoadBalancer IP pool

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 5 ผ่าน · ชื่อ interface ใน `l2-announcement-policy.yaml`
ตรงกับ worker จริง (ตรวจไว้แล้วในข้อ 2)

```bash
kubectl apply -f /root/k8s/config/cilium/lb-ippool.yaml
kubectl get ciliumloadbalancerippool
```
**ควรเห็น:** `default-pool` และคอลัมน์ `AVAILABLE` เป็น `10`

```bash
kubectl apply -f /root/k8s/config/cilium/l2-announcement-policy.yaml
kubectl get ciliuml2announcementpolicy
```
**ควรเห็น:** `default-l2-policy`

> ถ้า `kubectl apply` ฟ้องว่าไม่รู้จัก resource ให้ตรวจ apiVersion ของจริงก่อน:
> ```bash
> kubectl api-resources | grep -i -E 'ippool|l2announcement'
> ```
> LB-IPAM เป็น `cilium.io/v2` ส่วน L2AnnouncementPolicy ยังเป็น `cilium.io/v2alpha1` — **คนละอันกัน**

---

## 7 · 🔴 ทดสอบ LoadBalancer จริง

**ทำที่:** 7.1 · 7.5 (drain) · 7.6 บน 👑 master01 — **แต่ `curl` ใน 7.3 และ 7.5 ต้องยิงจากเครื่องในวง
`192.168.50.0/24` ที่ไม่ใช่ node** (7.2 บอกว่าทำไมและมีทางสำรอง) · **ต้องมีก่อน:** ข้อ 6 —
`AVAILABLE` ของ pool เป็น `10` และ L2 policy มีอยู่

ขั้นนี้พิสูจน์ว่า Cilium ประกาศ LoadBalancer IP ออกมาบน LAN ได้จริง
เป็นข้อที่พังบ่อยที่สุดในบทนี้ และพังด้วยสาเหตุที่มองไม่เห็นจาก `kubectl`

### 7.1 สร้างของทดสอบ

```bash
kubectl create deployment lbtest --image=nginx:alpine --replicas=2
kubectl expose deployment lbtest --type=LoadBalancer --port=80
kubectl get svc lbtest
```

**ควรเห็นภายในไม่กี่วินาที:**
```
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
lbtest   LoadBalancer   10.247.x.x      192.168.50.200   80:3xxxx/TCP
```

ถ้า `EXTERNAL-IP` ยังเป็น `<pending>` แปลว่า pool มีปัญหา — ย้อนไปหัวข้อ 6 ก่อน

### 7.2 เลือกเครื่องที่จะใช้ยิง — อ่านตารางนี้ก่อนลงมือ

L2 announcement ทำงานด้วยการ **ตอบ ARP** ซึ่งวิ่งได้เฉพาะใน broadcast domain เดียวกัน
**เครื่องที่ใช้ยิงจึงเปลี่ยนความหมายของผลลัพธ์ทั้งหมด**

| ยิงจาก | ผลบอกอะไร | ใช้ตัดสินข้อนี้ได้ไหม |
|---|---|---|
| เครื่องในวง `192.168.50.0/24` ที่ **ไม่ใช่ node** | ทั้ง ARP และเส้นทาง HTTP | ✅ **ใช่ — ทางหลัก** |
| node ของ cluster ด้วย `arping` | ARP อย่างเดียว | ✅ ใช้แทนได้ |
| node ของ cluster ด้วย `curl` | แค่ Service/pod ทำงาน **ไม่ผ่าน ARP เลย** | ❌ **ห้ามใช้** |
| เครื่องวงอื่น เช่น `10.212.x.x` | ความสามารถ ARP ของ **router** | ❌ ไม่เกี่ยวกับข้อนี้ |

> 🔴 **สองแถวล่างคือกับดัก ทำให้ไล่ปัญหาผิดทางได้ง่ายมาก**
>
> `curl` บน node โดน eBPF ของ Cilium ดักตั้งแต่ชั้น socket ไม่เคยกลายเป็น ARP request
> **ต่อให้ L2 announcement พังสนิทก็ยังได้ `200 OK`**
>
> เครื่องวงอื่นยิงผ่าน router — จะติดครั้งแรกแล้วค้างยาวตามอายุ ARP cache ของ router
> `arp -a` บนเครื่องนั้นขึ้น `No ARP Entries Found` เป็นเรื่องปกติ **ไม่ใช่หลักฐานว่าอะไรพัง**
>
> ยืนยัน IP ของเครื่องที่จะใช้ก่อนเสมอ: `ip -br addr` (Linux) · `ipconfig` (Windows)

### 7.3 ยิงทดสอบ

**ทางหลัก** — จากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node:

```bash
curl -I http://192.168.50.200
```
**ควรเห็น:** `HTTP/1.1 200 OK` และ header ของ nginx

**ทางสำรอง** — ถ้ายังไม่มีเครื่องนั้น ให้ยิง `arping` จาก node ที่ **ไม่ได้ถือ lease**
(`arping` คุยที่ชั้น L2 ตรง ๆ จึงไม่โดน eBPF ดัก)

```bash
kubectl -n kube-system get lease -o custom-columns=NAME:.metadata.name,HOLDER:.spec.holderIdentity | grep l2announce
```

ได้ชื่อ node ที่ถือแล้ว ssh เข้า **เครื่องอื่น** แล้วยิง:

```bash
IF=$(ip -br addr | awk '/192\.168\.50\./{print $1; exit}')
arping -c3 -I "$IF" 192.168.50.200
```

**ควรเห็น:** `Unicast reply from 192.168.50.200 [MAC]` ครบทั้ง 3 ครั้ง
เทียบ MAC ให้ตรงกับ node ที่ถือ lease: `ssh <node ที่ถือ> "ip -br link show ens192"`

> ถ้าไม่มีคำสั่ง `arping`: `dnf install -y iputils`
>
> ทางสำรองนี้ยืนยัน ARP ได้ แต่ยืนยันเส้นทางจากผู้ใช้จริงไม่ได้
> ต้องหาเครื่องในวงนั้นมาทดสอบซ้ำก่อนขึ้น production

### 7.4 ถ้าไม่ผ่าน — ไล่ทีละชั้น

ดูว่า agent ของ node ที่ถือ lease program ARP responder ลงไปจริงหรือยัง:

```bash
NODE=k8s-worker03      # เปลี่ยนเป็นตัวที่ถือ lease จริง
P=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name)
kubectl -n kube-system exec $P -c cilium-agent -- cilium-dbg shell -- db/show l2-announce
```

**ควรเห็น:** แถว `192.168.50.200` คู่กับชื่อ NIC จริงของ node นั้น

| ผลที่ได้ | แปลว่า | ไปที่ |
|---|---|---|
| ตารางว่าง | ชื่อ NIC ไม่เข้า regex ใน `interfaces:` ของ policy | หัวข้อ 2 |
| มีแถวครบ แต่ `arping` จากในวงเดียวกันไม่ตอบ | switch บล็อก ARP | ทีม network |
| มีแถวครบ · `arping` ผ่าน · แต่ curl จากวงอื่นไม่ติด | router ระหว่างวง | ทีม network |

สองกรณีล่างเป็นเรื่องนอก cluster — **อย่ารื้อ Cilium** สิ่งที่ต้องขอทีม network คือ
ยกเว้น **Dynamic ARP Inspection · port security · IP source guard** ให้ช่วง `192.168.50.200-209`
เพราะ node ตอบ ARP แทน IP ที่ไม่ใช่ของตัวเอง ซึ่งหน้าตาเหมือน ARP spoofing เป๊ะ

ถ้าองค์กรยกเว้นให้ไม่ได้: เปลี่ยนไปใช้ BGP mode (ให้ SE ตั้ง peer + เปิด `179/tcp`)
หรือถอยไปใช้ NodePort แล้วให้ hardware LB ยิงเข้ามา

### 7.5 ทดสอบ failover ของ LB IP

**ทำที่:** 👑 master01 ทั้งหมด ยกเว้นขั้น "ยิงซ้ำ" ที่ยิงจากเครื่องเดียวกับที่ใช้ใน 7.3
· **ต้องมีก่อน:** 7.3 ผ่าน (รู้แล้วว่า node ไหนตอบ ARP และ MAC อะไร)

พิสูจน์ว่าถ้า node ที่ถือ IP หายไป node อื่นรับหน้าที่ต่อเอง — วัดด้วยของเดียวกับ 7.3:
`curl` ต้องกลับมาได้ หรือ `arping` ต้องได้ **MAC คนละตัว** กับก่อน drain

**1 · ดูว่าใครถืออยู่ แล้วเก็บชื่อไว้ในตัวแปร:**

```bash
HOLDER=$(kubectl -n kube-system get lease cilium-l2announce-default-lbtest -o jsonpath='{.spec.holderIdentity}')
echo "$HOLDER"
```

**ควรเห็น:** ชื่อ worker ตัวเดียว เช่น `k8s-worker02` — ตัวเดียวกับที่ MAC ตรงใน 7.3

**2 · เอา node นั้นออกจากการให้บริการ:**

```bash
kubectl drain "$HOLDER" --ignore-daemonsets --delete-emptydir-data
sleep 10
kubectl -n kube-system get lease cilium-l2announce-default-lbtest -o jsonpath='{.spec.holderIdentity}{"\n"}'
```

**ควรเห็น:** ชื่อ worker **อีกตัว** ไม่ใช่ `$HOLDER` — ถ้ายังเป็นตัวเดิม รออีก 10 วินาทีแล้วดูใหม่
(lease หมดอายุ 15 วินาที)

**3 · ยิงซ้ำจากเครื่องเดิมที่ใช้ใน 7.3:**

- ทางหลัก: `curl -I http://192.168.50.200` → ต้องได้ `200 OK` เหมือนเดิม
- ทางสำรอง (`arping` จาก node ที่ไม่ใช่ตัวถือ): MAC ที่ตอบ **ต้องเปลี่ยน** เป็นของ worker ในข้อ 2
  · ถ้ายังเป็น MAC เดิม = failover ไม่เกิดจริง (ดู 7.4)

**4 · คืน node เข้าคลัสเตอร์ — ห้ามลืม:**

```bash
kubectl uncordon "$HOLDER"
kubectl get nodes                      # ต้องไม่มี SchedulingDisabled
```

> ลืม `uncordon` แล้วบทถัด ๆ ไปจะ schedule pod ไม่ลง และไปโผล่เป็นอาการอื่นที่ดูไม่เกี่ยวกันเลย
> · IP **ไม่ย้ายกลับ** มาที่ `$HOLDER` เองหลัง uncordon — ปกติ ไม่ต้องทำอะไร

### 7.6 เก็บกวาด

```bash
kubectl delete deploy,svc lbtest
kubectl get nodes                      # ต้องไม่มี SchedulingDisabled ค้าง
```

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl get nodes` — ทั้ง 6 เครื่อง **`Ready`**
- [ ] `cilium status` — Cilium, Operator, Hubble Relay ทั้งหมด **OK**
- [ ] `KubeProxyReplacement: True`
- [ ] **ไม่มี** DaemonSet `kube-proxy`
- [ ] `cilium connectivity test` — **ผ่านทุกข้อ**
- [ ] `firewall-cmd --reload` แล้ว pod ยังคุยกันได้ (จดผลลงบทที่ 13)
- [ ] LB pool `AVAILABLE = 10`
- [ ] **curl เข้า LoadBalancer IP จากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node ได้**
      (ถ้าไม่มีเครื่องนั้น: `arping` จาก worker ตัวที่ไม่ได้ถือ lease ต้องได้ reply)
- [ ] drain node ที่ถือ IP แล้ว IP ย้ายเองและ curl กลับมาได้
- [ ] ลบ resource ทดสอบทิ้งหมดแล้ว

**➡️ ต่อที่ [บทที่ 06 — ตรวจรับระบบ](06-verify.md)**
