# บทที่ 13 — Troubleshooting

> **ผู้อ่าน: ทุกคน · เปิดตอนมีปัญหา**
> เรียงตาม**อาการที่เห็น** ไม่ใช่ตามชื่อ component
> เพราะตอนตีสามคุณไม่รู้ว่าปัญหาอยู่ชั้นไหน

---

## เริ่มที่นี่เสมอ — 60 วินาทีแรก

```bash
kubectl get nodes                                    # node ตายไหม
kubectl get pods -A | grep -v -E 'Running|Completed' # อะไรผิดปกติ
kubectl get events -A --sort-by=.lastTimestamp | tail -20
cilium status                                        # network ยังดีไหม
```

**ถ้า `kubectl` เองใช้ไม่ได้** ข้ามไป [อาการที่ 1](#1-kubectl-ใช้ไม่ได้เลย)

---

## ตั้งตัวแปรก่อนเริ่มไล่

คำสั่งในบทนี้ใช้ `$NS` / `$POD` / `$APP` / `$SVC` / `$NODE` ซ้ำ ๆ **ตั้งค่าให้ตรงกับของที่กำลังมีปัญหาก่อน**
ไม่งั้น copy ไปวางแล้วจะได้ error เรื่อง namespace ว่าง ซึ่งชวนหลงทางตอนตีสาม

```bash
NS=myhr-prod                                   # namespace ที่มีปัญหา
APP=zeeme-ads                                  # ชื่อ Deployment
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name="$APP" -o name | head -1 | cut -d/ -f2)
SVC=$APP
NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
echo "NS=$NS POD=$POD NODE=$NODE"
```

> 🔴 **`-l app.kubernetes.io/name=` ไม่ใช่ `-l app=`** — manifest ของเราติด label ตาม
> แบบแผน `app.kubernetes.io/*` (ดู `deployments/zeeme-ads/deployment.yaml`) ถ้าใช้ `-l app=`
> จะไม่ match อะไรเลย แล้ว `$POD` จะกลายเป็นค่าว่างโดยไม่มี error สักบรรทัด
> · แต่ใน **LogQL ของ Loki ใช้ `app=`** เพราะ Alloy แปลงชื่อ label ให้แล้ว (`alloy-values.yaml`)
> สองที่นี้เขียนไม่เหมือนกันโดยตั้งใจ ไม่ใช่พิมพ์ผิด

> `$POD_A` / `$POD_B` / `$POD_B_IP` ใช้เฉพาะหัวข้อ **5 · pod คุยข้าม node ไม่ได้** — ตั้งค่าที่หัวข้อนั้น

---

## สารบัญอาการ

| # | อาการ | มักเป็นเรื่องของ |
|---|---|---|
| [1](#1-kubectl-ใช้ไม่ได้เลย) | `kubectl` ใช้ไม่ได้เลย | VIP / HAProxy / cert |
| [2](#2-node-notready) | node `NotReady` | kubelet / containerd / Cilium |
| [3](#3-pod-ค้าง-pending) | pod ค้าง `Pending` | capacity / quota / PVC |
| [4](#4-pod-crashloopbackoff) | pod `CrashLoopBackOff` | probe / config / image |
| [5](#5-pod-ข้าม-node-ไม่ได้) | pod ข้าม node ไม่ได้ | firewalld / VXLAN / MTU |
| [6](#6-dns-ไม่ตอบ) | DNS ไม่ตอบ | CoreDNS / NetworkPolicy |
| [7](#7-loadbalancer-ip-ขึ้นแต่เข้าไม่ได้) | LB IP ขึ้นแต่เข้าไม่ได้ | **ARP inspection** |
| [8](#8-x509-error) | `x509` error | cert หมดอายุ / certSANs |
| [9](#9-image-pull-ไม่ผ่าน) | image pull ไม่ผ่าน | registry / secret |
| [10](#10-drain-ค้าง) | `drain` ค้าง | PDB / replica |
| [11](#11-pod-running-แต่เรียกไม่ได้) | pod `Running` แต่เรียกไม่ได้ | NetworkPolicy |
| [12](#12-kubeadm-init-ตายตั้งแต่ยังไม่เริ่ม) | `kubeadm init` ตายตั้งแต่ยังไม่เริ่ม | ไฟล์ `--config` — โครงไฟล์ / ค่าข้างใน |
| [12.6](#126-init-ตายที่-wait-control-plane--could-not-bootstrap-the-admin-user--context-deadline-exceeded) | init ตายที่ `wait-control-plane` ทั้งที่ cluster ขึ้นแล้ว | จังหวะ — POST แรกรอเกิน 10s · reset แล้ว init ใหม่ |
| [13](#13-r-command-not-found) | `$'\r': command not found` | ไฟล์ CRLF ที่ scp มาจาก Windows |

> **อาการที่เฉพาะเจาะจงกับ Cilium + Envoy Gateway** (404/503 จาก Gateway, HTTPRoute ไม่ผูก,
> cert ของ listener, ARP/L2, NetworkPolicy ตัด Envoy) อยู่ในหน้าแยกที่ค้นด้วยข้อความ error ได้:
> [`../html/cilium-envoy-scenarios.html`](../html/cilium-envoy-scenarios.html) —
> **28 อาการ** เรียงตามความถี่ที่เจอจริง + **25 แบบแผน** ว่าควรออกแบบยังไงตั้งแต่แรก
> บทนี้ยังเป็นจุดตั้งต้นเสมอ

> 🔍 **เมื่อ `kubectl logs` ไม่มีของให้ดูแล้ว** (pod ตายไปแล้ว · rollout ทับไปแล้ว ·
> ต้องดูย้อนหลังข้ามคืน) ให้ไปที่ [บทที่ 14 — ดู log ใน Grafana ตามอาการของ pod](14-grafana-logs.md)
> ซึ่งเรียงตามอาการชุดเดียวกับสารบัญข้างบน

---

## 1. `kubectl` ใช้ไม่ได้เลย

```
The connection to the server 192.168.50.100:8443 was refused
```

### ไล่ตามลำดับ

```bash
# 1. VIP ยังมีอยู่ไหม และอยู่เครื่องเดียวหรือเปล่า
for ip in 101 102 103; do
  echo -n "master$ip: "
  ssh root@192.168.50.$ip "ip -4 addr show | grep -c 192.168.50.100"
done
```
- ได้ `0` ทั้งหมด → **ไม่มีใครถือ VIP** ไปข้อ 1.1
- ได้ `1` มากกว่าหนึ่งเครื่อง → **split brain** ไปข้อ 1.2
- ได้ `1` เครื่องเดียว → ไปข้อ 1.3

### 1.1 ไม่มีใครถือ VIP
```bash
systemctl status keepalived
journalctl -u keepalived -n 50 --no-pager
/etc/keepalived/check_apiserver.sh; echo "exit=$?"
```
ถ้า script คืน exit 1 แปลว่า HAProxy ตาย → `systemctl restart haproxy`

### 1.2 Split brain (VIP ขึ้นหลายเครื่อง)

**แยกให้ออกก่อนว่าเป็น split brain จริง หรือ VIP กระพริบ** — อาการคล้ายกันแต่คนละสาเหตุ
รันคำสั่งข้อ 1 ซ้ำอีกรอบห่างกัน 10 วินาที:

- **เลข `1` อยู่ที่เดิม แต่มีหลายเครื่อง** → split brain จริง อ่านต่อข้างล่าง
- **เลข `1` ย้ายเครื่องไปมา** → **กระพริบ** ไปที่ [1.2b](#12b-vip-กระพริบ) ข้างล่างแทน

สาเหตุของ split brain จริง 3 ข้อ เรียงตามความน่าจะเป็น:
```bash
grep auth_pass /etc/keepalived/keepalived.conf   # ต้องตรงกันทั้ง 3 เครื่อง
```
> ⚠️ `auth_pass` ของ keepalived ใช้ได้แค่ **8 ตัวอักษร** ที่เกินถูกตัดทิ้งเงียบ ๆ
> ถ้าตั้งยาวกว่านั้นแล้วพิมพ์ไม่เหมือนกัน แต่ละเครื่องจะคิดว่าตัวเองเป็น MASTER

```bash
firewall-cmd --list-protocols     # ต้องมี vrrp
grep virtual_router_id /etc/keepalived/keepalived.conf   # ต้องเป็น 60 ทั้ง 3 เครื่อง
```
ข้อสุดท้าย: switch บล็อก multicast `224.0.0.18` → ต้องคุยกับทีม network

### 1.2b VIP กระพริบ

VRRP ทำงานปกติ (ไม่ใช่ split brain) แต่ VIP ย้ายเครื่องไปมาไม่หยุด ยืนยันด้วย:
```bash
journalctl -u keepalived -n 40 --no-pager | grep -iE 'Entering|transition'
```
**อาการ:** เห็น `Entering MASTER STATE` / `Entering BACKUP STATE` สลับกันทุก ~6-12 วินาที

สาเหตุคือ `check_apiserver.sh` ทำให้ **เครื่องที่ถือ VIP หัก priority ตัวเอง** จนเสีย VIP
แล้วเครื่องที่รับไปก็ตกด้วยเหตุผลเดียวกัน วนไม่จบ ตรวจว่าสคริปต์บนเครื่องมีด่าน 2 หรือยัง:
```bash
grep -c "':6443 '" /etc/keepalived/check_apiserver.sh
```
**ควรเห็น:** `1` — ถ้าได้ `0` แปลว่าเป็นสคริปต์รุ่นเก่าที่ไม่มี guard ให้เอาจากรีโปมาทับ:
```bash
\cp -f /root/k8s/config/keepalived/check_apiserver.sh /etc/keepalived/check_apiserver.sh
```

> เจอบ่อยสุด**ตอน bootstrap ก่อน `kubeadm init`** เพราะ HAProxy ยังไม่มี backend เป็น ๆ
> เครื่องที่ถือ VIP จึงยิง `/healthz` ไม่ผ่านเสมอ ด่าน 2 จึงข้ามการตรวจนั้นไปจนกว่าจะมี
> `kube-apiserver` ฟังที่ `:6443` จริง

### 1.3 VIP ปกติ แต่ยังต่อไม่ได้

**แยกให้ออกก่อนว่าเจอ `refused` หรือ `EOF`** — คนละสาเหตุกัน:

| ข้อความ | แปลว่า |
|---|---|
| `connection refused` | ไม่มีใครฟังที่ `:8443` — HAProxy ตายหรือไม่ได้ start |
| `EOF` / `broken pipe` | HAProxy รับ connection แล้วปิดทันที = **ไม่มี backend ตัวไหน UP** |

```bash
ss -lnt | grep 8443                          # HAProxy ฟังอยู่ไหม
curl -s "http://127.0.0.1:8404/stats;csv" | awk -F, '$1=="kube-apiserver-backend"{print $2, $18, "check="$37, "code="$38}'
```

ช่อง `check` บอกว่า health check ล้มที่ชั้นไหน ซึ่งชี้สาเหตุได้ตรงกว่าคำว่า `DOWN`:

| check | ชั้นที่ล้ม | มักเป็นเพราะ |
|---|---|---|
| `L4CON` | ต่อ TCP ไม่ติด | apiserver ไม่ได้รัน · firewalld ปิด `6443` ระหว่าง master |
| `L6RSP` | TLS handshake | ค่า check ใน `haproxy.cfg` ชนกัน (`httpchk` + `ssl-hello-chk` ใช้ร่วมกันไม่ได้) — ดู 1.3b |
| `L7STS` | HTTP ตอบมาแต่ status ไม่ใช่ 200 | `/healthz` ยังไม่พร้อม หรือ apiserver กำลัง start |
| `L7OK` | ผ่าน | ปัญหาไม่ได้อยู่ที่ backend นี้ |

> **DOWN ครบทั้ง 3 ตัวรวม master01 ตอนเพิ่ง `kubeadm init` เสร็จ** มักไม่ใช่ปัญหาของ HAProxy
> แต่คือ apiserver ยังไม่ขึ้นจริง · **`/etc/kubernetes/admin.conf` มีอยู่ไม่ได้แปลว่า init สำเร็จ**
> kubeadm เขียนไฟล์นี้ตั้งแต่ก่อนขั้น `wait-control-plane` ดังนั้น init ที่ล้มทีหลังก็ทิ้งไฟล์นี้ไว้ได้
> ย้อนไปดูว่า `kubeadm init` จบด้วย `exit=0` และมีบรรทัด
> `Your Kubernetes control-plane has initialized successfully!` หรือเปล่า

```bash
crictl ps -a --name kube-apiserver           # ขึ้นไหม restart ไปกี่รอบ
crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -30
```

#### 1.3b ทุก backend `DOWN check=L6RSP` — config ของ HAProxy ชนกันเอง

เกิดกับเครื่องที่ยังถือ `haproxy.cfg` รุ่นที่มีทั้ง `option httpchk` และ `option ssl-hello-chk`
สองอันนี้ใช้ร่วมกันไม่ได้ · check เลยกลายเป็น "ทัก TLS แล้วรอ HTTP 200" ซึ่งไม่มีวันผ่าน

**ตรวจให้ครบทุก master — เครื่องที่แก้ไปแล้วเครื่องเดียวไม่พอ:**

```bash
for ip in 101 102 103; do
  echo "--- master$ip ---"
  ssh root@192.168.50.$ip "grep -c '^[[:space:]]*option[[:space:]]\+ssl-hello-chk' /etc/haproxy/haproxy.cfg"
done
```

**ควรเห็น:** `0` ทั้งสามเครื่อง — ได้ `1` ที่ไหนคือเครื่องนั้นยังพัง

**แก้:**

```bash
for ip in 101 102 103; do
  ssh root@192.168.50.$ip "sed -i '/^[[:space:]]*option[[:space:]]\+ssl-hello-chk/d' /etc/haproxy/haproxy.cfg && haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl restart haproxy"
done
```

> **ทำไมต้องแก้ทุกเครื่อง ไม่ใช่แค่เครื่องที่ถือ VIP** — HAProxy ของแต่ละ master ตรวจ backend
> ของตัวเอง และ `check_apiserver.sh` ของ keepalived บนเครื่องนั้นก็อ่านผลจากตัวเดียวกัน
> เครื่องที่ HAProxy เห็น backend DOWN หมดจะ**ไม่ยอมรับ VIP ตอน failover** —
> cluster จะดูปกติทุกอย่างจนกว่าจะถึงวันที่ master01 ล่มจริง แล้วถึงรู้ว่าไม่มีใครรับ VIP ต่อ
>
> อย่าลืม sync `/root/k8s/config/haproxy/haproxy.cfg` บนเครื่องให้ตรงกับrepoด้วย
> ไม่งั้นครั้งหน้าที่ใครก๊อปไฟล์นั้นไปวางทับ `/etc/haproxy/` ก็กลับไปพังเหมือนเดิม

> **SELinux ไม่ใช่สาเหตุใน cluster นี้** — บทที่ 01 ข้อ 7 ตั้งเป็น `Permissive` ไว้แล้ว
> (ถ้าเครื่องไหน `getenforce` ได้ `Enforcing` แปลว่าหลุดจากมาตรฐาน ให้แก้ที่บท 01 ก่อน
> ไม่ใช่มาไล่เปิด boolean ทีละตัวอย่าง `haproxy_connect_any`)

**ทางลัดฉุกเฉิน — ข้าม VIP ต่อตรงที่ master:**
```bash
kubectl --server=https://192.168.50.101:6443 \
        --certificate-authority=/etc/kubernetes/pki/ca.crt \
        --client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
        --client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
        get nodes
```

---

## 2. node `NotReady`

```bash
kubectl describe node "$NODE" | grep -A10 Conditions
```

### บนเครื่องนั้น
```bash
systemctl status kubelet containerd
journalctl -u kubelet -n 80 --no-pager | grep -iE 'error|fail'
df -h /                       # disk เต็มไหม — สาเหตุที่พบบ่อยมาก
free -h
uname -r                      # kernel ตรงกับเครื่องอื่นไหม
```

| อาการใน log | สาเหตุ |
|---|---|
| `no space left on device` | disk เต็ม — ดูข้อ 2.1 |
| `network plugin is not ready` | Cilium ไม่ขึ้นบน node นี้ |
| `failed to get sandbox image` | containerd ดึง pause image ไม่ได้ |
| `x509: certificate has expired` | ดูอาการที่ 8 |
| `misconfiguration: kubelet cgroup driver` | `SystemdCgroup` ไม่ตรง — ดูบทที่ 02 |

### 2.1 disk เต็ม
```bash
du -sh /var/log/* /var/lib/containerd 2>/dev/null | sort -h | tail
crictl rmi --prune                          # ลบ image ที่ไม่มีใครใช้
journalctl --vacuum-size=500M
```
**ถ้าเป็น `k8s-worker03`** อาจเป็น `/var/lib/monitoring` โต — ลด retention (บทที่ 09)

### 2.2 Cilium ไม่ขึ้นบน node นี้
```bash
kubectl -n kube-system get pods -l k8s-app=cilium -o wide | grep "$NODE"
kubectl -n kube-system logs -l k8s-app=cilium --field-selector spec.nodeName="$NODE" --tail=50
```

---

## 3. pod ค้าง `Pending`

```bash
kubectl -n "$NS" describe pod "$POD" | tail -25
```

| ข้อความ | สาเหตุและวิธีแก้ |
|---|---|
| `Insufficient cpu` / `memory` | cluster เต็ม หรือชน ResourceQuota → `kubectl -n $NS describe quota` |
| `didn't match pod topology spread constraints` | `replicas` มากกว่าจำนวน node ที่รับได้ |
| `persistentvolumeclaim ... not found` | **cluster นี้ไม่มี dynamic storage (D8)** — ตั้งใจ |
| `node(s) had untolerated taint` | node ถูก cordon อยู่ → `kubectl get nodes` |
| `0/6 nodes are available` | ดูรายละเอียดต่อท้าย มันบอกเหตุผลรายเครื่อง |

> ถ้าเจอ `Insufficient` ตอนกำลัง drain อยู่ **นั่นคืออาการของ capacity เกินเพดาน N+1**
> ผลรวม requests ต้องไม่เกิน 32 vCPU / 96 GB

---

## 4. pod `CrashLoopBackOff`

```bash
kubectl -n "$NS" logs "$POD" --previous | tail -50    # --previous สำคัญ
kubectl -n "$NS" describe pod "$POD" | grep -A5 'Last State'
```

| Exit code | ความหมาย |
|---|---|
| `0` | จบเองแบบปกติ — น่าจะใช้ Deployment ผิดประเภท |
| `1` | application error → ดู log |
| `137` | **OOM killed** → เพิ่ม `limits.memory` |
| `143` | ถูก SIGTERM → `terminationGracePeriodSeconds` สั้นไป |

### สาเหตุอันดับ 1 สำหรับ Spring Boot: `livenessProbe` ฆ่าก่อนเริ่มเสร็จ
```bash
kubectl -n "$NS" get deploy "$APP" -o yaml | grep -A8 startupProbe
```
**ถ้าไม่มี `startupProbe` = นี่คือสาเหตุ** — `livenessProbe` เริ่มนับตั้งแต่ pod เกิด
Spring Boot ที่ใช้เวลาเริ่ม 60 วินาทีจะถูกฆ่าตั้งแต่ยังไม่ทันขึ้น แล้ววนแบบนี้ตลอดไป
แก้โดยเพิ่ม `startupProbe` ตามแม่แบบในบทที่ 11

### `violates PodSecurity "restricted"`
manifest ยังใช้ `runAsUser: 0` — เทียบกับแม่แบบ (บทที่ 11)

> 🔍 **`--previous` ให้ดูได้แค่รอบก่อนหน้า 1 รอบ** — pod ที่วน crash มาทั้งคืน รอบแรก
> ซึ่งเป็นรอบที่บอกสาเหตุจริงหายไปแล้ว **แต่ Loki เก็บครบทุกรอบ**
> ดูวิธีไล่ที่ [บทที่ 14 ข้อ 1](14-grafana-logs.md#1--pod-crashloopbackoff)

---

## 5. pod ข้าม node ไม่ได้

**อาการคลาสสิก:** pod บน node เดียวกันคุยกันได้ ข้าม node ไม่ได้

```bash
# หา pod สองตัวคนละ node แล้ว ping กัน
kubectl get pods -o wide -n "$NS"

# ตั้งค่าจากผลด้านบน — ต้องเป็น pod คนละ node กัน
POD_A=<ชื่อ pod ตัวที่ 1>
POD_B=<ชื่อ pod ตัวที่ 2 คนละ node>
POD_B_IP=$(kubectl -n "$NS" get pod "$POD_B" -o jsonpath='{.status.podIP}')
kubectl -n "$NS" exec "$POD_A" -- ping -c3 "$POD_B_IP"
```

### 5.1 firewalld — สาเหตุอันดับ 1
```bash
firewall-cmd --list-ports | grep 8472        # VXLAN ของ Cilium
firewall-cmd --list-all
```
ถ้าขาด:
```bash
firewall-cmd --permanent --add-port=8472/udp
firewall-cmd --permanent --add-port=4240/tcp
firewall-cmd --reload
```

**ถ้าอาการเกิดขึ้นทันทีหลัง `firewall-cmd --reload`:**
firewalld เขียนกฎ nftables ใหม่ทั้งชุดตอน reload ลองเพิ่ม interface ของ Cilium เข้า trusted zone:
```bash
firewall-cmd --permanent --zone=trusted --add-interface=cilium_host
firewall-cmd --permanent --zone=trusted --add-interface=cilium_net
firewall-cmd --permanent --zone=trusted --add-interface=cilium_vxlan
firewall-cmd --reload
```

### 5.2 MTU — "ping ผ่าน แต่ HTTP ค้าง"
```bash
kubectl -n "$NS" exec "$POD_A" -- ping -c3 -M do -s 1372 "$POD_B_IP"
```
ถ้า `ping` ธรรมดาผ่านแต่อันนี้ล้ม → **MTU ผิด**
แก้โดยตั้ง `MTU: 1450` ใน `config/cilium/values.yaml` แล้ว `helm upgrade`

> อาการที่จะเจอตอนใช้จริง: HTTP request ใหญ่ ๆ ค้าง หรือ TLS handshake ล้มเป็นบางครั้ง
> ซึ่งหลอกให้ไปไล่หาปัญหาที่ application

### 5.3 kernel module หายหลัง reboot
```bash
lsmod | grep -E '^overlay|^br_netfilter'
cat /etc/modules-load.d/k8s.conf
```
ถ้าไฟล์ไม่มี = ปัญหาเดียวกับ cluster เดิม → กลับไปทำบทที่ 01 ขั้นที่ 6

### 5.4 ดูของจริงด้วย Hubble
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --namespace "$NS" --verdict DROPPED --last 50
done
```
> วนทุก agent เพราะ flow อยู่ใน ring buffer ของเครื่องที่ pod รันเท่านั้น —
> `exec ds/cilium` ได้เครื่องเดียว ถามผิดเครื่องจะได้ผลว่างทั้งที่มี flow ถูก drop จริง

---

## 6. DNS ไม่ตอบ

```bash
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```

### 6.1 CoreDNS ตาย
```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
```

### 6.2 NetworkPolicy บล็อก — พบบ่อยที่สุดหลังทำบทที่ 10
```bash
kubectl -n "$NS" get networkpolicy
```
**ถ้ามี `default-deny-all` แต่ไม่มี `allow-dns-egress` = นี่คือสาเหตุ**
```bash
kubectl apply -f /root/k8s/config/security/allow-dns.yaml
```

> อาการหลอก: application ขึ้น `Running` ปกติ แต่ log เต็มไปด้วย
> `UnknownHostException` หรือ `could not resolve host`

### 6.3 DNS ช้าเป็นระยะ
ปกติสำหรับ cluster ที่มี microservices เรียกกันเยอะ — พิจารณา NodeLocal DNSCache
และเพิ่ม CoreDNS replica

---

## 7. LoadBalancer IP ขึ้นแต่เข้าไม่ได้

> 🔴 **อาการหลอกที่สุดในคู่มือทั้งชุด** — ทุกอย่างใน Kubernetes ดูปกติหมด

```bash
kubectl get svc -A | grep LoadBalancer     # EXTERNAL-IP ขึ้นปกติ
```

### 7.0 เช็คก่อนอย่างอื่น — เครื่องที่ใช้ทดสอบอยู่วงไหน

```bash
ip -br addr        # Linux
ipconfig           # Windows
```

> 🔴 **ถ้า IP ไม่ได้ขึ้นต้นด้วย `192.168.50.` ให้หยุดตรงนี้ — ผลทดสอบใช้ไม่ได้**
>
> ARP ข้าม subnet ไม่ได้ เครื่องที่อยู่วงอื่นจะ**ไม่มีวัน**มี ARP entry ของ `192.168.50.200`
> `arp -a` ที่ขึ้น `No ARP Entries Found` ในกรณีนี้ **ไม่ได้แปลว่าอะไรผิด** — มันปกติ
> ที่เห็นเป็น "ติดครั้งแรกแล้วตายยาว" คืออายุ ARP cache ของ **router** ไม่ใช่อาการของ cluster
>
> หาเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node มาทดสอบ
> หรือใช้ `arping` จาก node ที่ไม่ได้ถือ lease แทน (วิธีอยู่ในบทที่ 05 หัวข้อ 7)

> 🔴 **`curl http://192.168.50.200` บน node เองผ่านเสมอ — ห้ามใช้เป็นเกณฑ์ผ่าน**
> บน node มี eBPF ของ Cilium ดัก LoadBalancer IP ตั้งแต่ชั้น socket
> แพ็กเก็ตไม่เคยถูกแปลงเป็น ARP request ด้วยซ้ำ
> **ต่อให้ L2 announcement พังสนิท curl บน node ก็ยังได้ `200 OK`**
> มันยืนยันได้แค่ว่า Service + endpoint + pod ทำงาน ซึ่งคนละเรื่องกับ ARP
> ใช้ `arping` เท่านั้นในการตัดสิน


### 7.1 จากเครื่องทดสอบที่อยู่ในวง `192.168.50.0/24`
```bash
ping -c2 192.168.50.200
arp -n 192.168.50.200
```

**ถ้า `arp` ไม่เห็น MAC ของ worker ตัวไหนเลย = ARP ถูกบล็อก**

**สาเหตุ:** L2 announcement ทำงานโดยให้ node ตอบ ARP แทน IP ที่ไม่ใช่ของตัวเอง
ซึ่ง**หน้าตาเหมือน ARP spoofing เป๊ะ** ถ้า switch เปิด **Dynamic ARP Inspection**
หรือ **port security** ไว้ จะบล็อกทิ้ง

**วิธีแก้:** ต้องให้ทีม network ยกเว้นช่วง `192.168.50.200-209` ให้
ถ้าทำไม่ได้ → เปลี่ยนไปใช้ BGP mode หรือถอยไป NodePort (ดูบทที่ 05)

### ตรวจฝั่ง Cilium
```bash
kubectl get ciliumloadbalancerippool
kubectl get ciliuml2announcementpolicy
kubectl -n kube-system get lease | grep l2announce      # ใครกำลังตอบ ARP
kubectl -n kube-system logs -l name=cilium-operator --tail=50 | grep -i l2

# agent ของ node ที่ถือ lease program entry ลงไปจริงหรือยัง (แทน worker03 ด้วยตัวที่ถือ)
NODE=k8s-worker03      # เปลี่ยนเป็นตัวที่ถือ lease จริง
P=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o name)
kubectl -n kube-system exec $P -c cilium-agent -- cilium-dbg shell -- db/show l2-announce
```

**ตาราง `l2-announce` ต้องมีแถว `192.168.50.200` คู่กับชื่อ NIC จริงของ node นั้น**
ถ้าว่าง = ชื่อ NIC ไม่เข้า regex ใน `interfaces:` ของ policy
ถ้ามีครบแต่ยิงจากในวงเดียวกันก็ไม่ตอบ = switch บล็อก ไม่ใช่เรื่อง Cilium

**ถ้า `EXTERNAL-IP` เป็น `<pending>`:** pool หมดหรือยังไม่ได้สร้าง
```bash
kubectl describe ciliumloadbalancerippool default-pool
```

---

## 8. `x509` error

### 8.1 cert ของ cluster หมดอายุ
```bash
kubeadm certs check-expiration
```
**ถ้าหมดแล้ว → ยังกู้ได้** ตราบใดที่ CA ยังไม่หมด (CA อายุ 10 ปี)
ทำตามบทที่ 12 หัวข้อ 3

### 8.2 `certificate is valid for ... not 192.168.50.100`
`certSANs` ขาด — ต้องออก cert ใหม่:
```bash
grep -A15 certSANs /root/k8s/config/kubeadm/kubeadm-config.yaml
# เพิ่มชื่อ/IP ที่ขาด แล้ว:
mv /etc/kubernetes/pki/apiserver.{crt,key} /tmp/
kubeadm init phase certs apiserver --config=/root/k8s/config/kubeadm/kubeadm-config.yaml
# แล้ว restart apiserver
```

### 8.3 client ฝั่งนอกฟ้อง unknown authority

ดูก่อนว่า cert ที่ Gateway เสิร์ฟอยู่มาจากไหน:

```bash
for s in myhr-public-tls myhr-internal-tls; do
  kubectl -n envoy-gateway-system get secret "$s" >/dev/null 2>&1 || continue
  echo "== $s"
  kubectl -n envoy-gateway-system get secret "$s" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject -dates
done
```

ดูว่าชื่อที่ client เรียกอยู่ในใบไหน แล้วแยกตามนั้น:

- **ใบจาก internal CA** — `issuer` เป็น `CN=MyHR Internal CA`
  แปลว่ายังไม่ได้ลง root CA ที่เครื่อง client นั้น ดูบทที่ 07 ภาคผนวก ข
- **ใบจาก public CA** — `issuer` เป็น CA ภายนอก แต่ client ยังฟ้อง
  แปลว่า **chain ขาด intermediate** ไม่ใช่เรื่องของเครื่อง client
  (เบราว์เซอร์ที่เคย cache intermediate ไว้จะยังผ่าน จึงดูเหมือนพังเป็นบางเครื่อง)
  ตรวจและแก้ด้วย:

```bash
bash /root/k8s/config/gateway/import-public-cert.sh --dry-run \
     /root/certs/fullchain.pem /root/certs/privkey.pem
```

---

## 9. image pull ไม่ผ่าน

> วิธีสร้าง/ซ่อม `regcred` อยู่ที่ [บทที่ 10 หัวข้อ 7](10-security.md) —
> เช็ก `curl https://$REGISTRY_HOST/v2/` ก่อนเสมอ ถ้าไม่ได้ `401` แปลว่าไม่ใช่ปัญหารหัส
> แล้วสร้าง secret กี่รอบก็ไม่หาย

```bash
kubectl -n "$NS" describe pod "$POD" | grep -A5 Failed
```

| ข้อความ | สาเหตุ |
|---|---|
| `401 Unauthorized` | `imagePullSecrets` ผิดหรือไม่มี |
| `x509: certificate signed by unknown authority` | CA ของ registry ไม่ได้ลงบน node |
| `http: server gave HTTP response to HTTPS client` | registry เป็น HTTP แต่ containerd คิดว่า HTTPS |
| `no such host` | DNS หรือ `/etc/hosts` |

```bash
# ทดสอบจาก node โดยตรง
crictl pull registry.myhr.co.th/myhr/zeeme-ads:1.0.0
cat /etc/containerd/certs.d/registry.myhr.co.th/hosts.toml

# secret มีในทุก namespace ที่ต้องใช้ไหม — secret ไม่ข้าม namespace
kubectl get secret regcred -n "$NS"
```

---

## 10. `drain` ค้าง

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s
# ค้างที่: "evicting pod ... Cannot evict pod as it would violate PDB"
```

```bash
kubectl get pdb -A
```
**หา PDB ที่ `ALLOWED DISRUPTIONS = 0`** — นั่นคือตัวที่บล็อก

| สาเหตุ | วิธีแก้ |
|---|---|
| `minAvailable` = `replicas` | ลด `minAvailable` หรือเพิ่ม `replicas` |
| `replicas: 1` + มี PDB | เพิ่มเป็น 2 — PDB ช่วยไม่ได้ถ้ามีตัวเดียว |
| pod ใหม่ขึ้นไม่ได้เพราะ cluster เต็ม | capacity เกินเพดาน N+1 |

**ทางออกฉุกเฉิน (ยอมให้ service ดับ):**
```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --disable-eviction
```
> ⚠️ `--disable-eviction` **ข้าม PDB ทั้งหมด** ใช้เฉพาะตอนฉุกเฉินจริง ๆ
> และต้องรู้ว่า service จะดับ

---

## 11. pod `Running` แต่เรียกไม่ได้

```bash
kubectl -n "$NS" get endpoints "$SVC"
```
**ถ้า `ENDPOINTS` ว่าง** → selector ของ Service ไม่ตรงกับ label ของ pod
หรือ `readinessProbe` ยังไม่ผ่าน

```bash
kubectl -n "$NS" get pods --show-labels
kubectl -n "$NS" get svc "$SVC" -o jsonpath='{.spec.selector}'; echo
```

**ถ้า endpoints มีแต่ยังเรียกไม่ได้ → เกือบทุกครั้งเป็น NetworkPolicy:**
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --namespace "$NS" --verdict DROPPED --last 20
done
```
**นี่คือวิธีที่ถูกต้อง — ดูของจริงว่าอะไรถูก drop แล้วเปิดเฉพาะเส้นนั้น**
ไม่ใช่เดาเอาจากเอกสาร

**ทดสอบจากใน cluster ก่อนโทษ Gateway:**
```bash
kubectl -n "$NS" run t --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv "http://${SVC}"
```

> 🔍 **ถ้าอยากรู้ว่า request วิ่งไปถึงไหนแล้วหายตรงไหน** ให้เทียบ log ของ Envoy Gateway
> กับ log ของ app ในหน้าเดียวกัน — [บทที่ 14 ข้อ 4](14-grafana-logs.md#4--pod-running-แต่-client-ได้-5xx)
> มีตารางอ่านผลว่าฝั่งไหนเงียบแปลว่าอะไร

---

## 12. `kubeadm init` ตายตั้งแต่ยังไม่เริ่ม

**อาการ** — `kubeadm init` หรือ `kubeadm init phase preflight --dry-run` จบทันที
ยังไม่ทันแตะเครื่องหรือดึง image

**เช็คให้ไวที่สุด** — แยกก่อนว่าปัญหาอยู่ที่ "ไฟล์" หรือ "เครื่อง":

```bash
kubeadm config validate --config=/root/k8s/config/kubeadm/kubeadm-config.yaml
```

อ่านแค่ไฟล์ ไม่แตะเครื่องเลย · ผ่านแล้วจะพิมพ์ `ok` และ exit 0
ถ้า `ok` แต่ preflight ยังฟ้อง แปลว่าปัญหาอยู่ที่เครื่อง ไม่ใช่ที่ไฟล์

### 12.1 `GroupVersionKind /, Kind=` — kubeadm อ่านไฟล์ไม่ออก

```
error: invalid configuration for GroupVersionKind /, Kind=:
kind and apiVersion is mandatory information that must be specified
```

**ไม่ใช่ค่าใน config ผิด** — แปลว่ามี YAML document ในไฟล์ `--config` ที่ไม่มี `kind`
`/, Kind=` ที่ว่างเปล่าคือ GroupVersionKind ที่อ่านไม่ได้ ไม่ใช่ชื่อ kind ที่ผิด

**สาเหตุ** — kubeadm หั่น document ด้วยการมองหาบรรทัดที่ขึ้นต้นด้วย `---` ตรง ๆ
ไม่ได้ parse YAML ก่อน ชิ้นที่มีตัวอักษรอยู่แต่ไม่มี `apiVersion`+`kind` จะถูกปฏิเสธทันที
ที่เจอบ่อยสุดคือ `---` ที่คั่นระหว่างคอมเมนต์หัวไฟล์กับ `apiVersion:` บรรทัดแรก —
คอมเมนต์ที่ถูกคั่นออกมากลายเป็น document หนึ่งอันที่ไม่มี kind

`---` ท้ายไฟล์ล้วน ๆ ไม่พัง แต่ `---` ที่ตามด้วยคอมเมนต์หรือบรรทัดว่างพังเหมือนกัน

**หาให้เจอว่าบรรทัดไหน** — ข้อความของ kubeadm ไม่บอกทั้งไฟล์และบรรทัด:

```bash
cd /root/k8s && awk -f config/kubeadm-docsplit.awk config/kubeadm/kubeadm-config.yaml
```

ไม่พิมพ์อะไร = ผ่าน · พิมพ์ออกมา = บอกช่วงบรรทัดของ document ที่ไม่มี kind
(`bash config/validate-repo.sh` ข้อ 3 เรียกตัวนี้ให้แล้ว)

**แก้** — ลบบรรทัด `---` ที่ทำให้คอมเมนต์กลายเป็น document แยก แล้วรัน preflight ซ้ำ

> **ทำไม lint ถึงไม่จับ** — PyYAML และ `kubectl apply` ข้าม document ว่างให้เอง
> ไฟล์จึง "parse ผ่าน" ทุกเครื่องมือ แต่ตายที่ kubeadm ตัวเดียว
> ไฟล์อื่นใน `config/` ที่เขียนแบบเดียวกันจึงไม่พัง เพราะไปทาง `kubectl`

### 12.2 `the bootstrap token ""` — อ่านไฟล์ออกแล้วแต่ค่าข้างในผิด

```
error unmarshaling configuration schema.GroupVersionKind{Group:"kubeadm.k8s.io",
Version:"v1beta4", Kind:"InitConfiguration"}:
the bootstrap token "" was not of the form "\\A([a-z0-9]{6})\\.([a-z0-9]{16})\\z"
```

ต่างจาก 12.1 ตรงที่ครั้งนี้ kubeadm บอก kind มาครบ = หั่น document ได้แล้ว
ติดที่ **ค่า** ไม่ใช่ที่โครงไฟล์

`token: ""` **ไม่ได้แปลว่า "ปล่อยว่างให้สุ่มเอง"** — v1beta4 แปลงค่าว่างเป็น
`BootstrapTokenString` ไม่ได้เลยตายตั้งแต่ตอน unmarshal
วิธีให้ kubeadm สุ่ม token ให้คือ **ไม่ใส่ field `token`** ใน `bootstrapTokens` เลย
(จะกำหนดเองก็ได้ แต่ต้องเป็นรูป `abcdef.0123456789abcdef` เท่านั้น)

```yaml
bootstrapTokens:
  - ttl: "2h"                           # ไม่มีบรรทัด token: อยู่เหนือ ttl
    usages: ["signing", "authentication"]
    groups: ["system:bootstrappers:kubeadm:default-node-token"]
```

> อาการตระกูลนี้ (`error unmarshaling configuration ...`) คือ **ค่าใน config ผิด**
> ทุกครั้ง ไล่จากชื่อ field และรูปแบบค่าที่ kubeadm บอกมาในบรรทัดเดียวกัน

### 12.3 apiserver ไม่ขึ้น หรือขึ้นแล้วแต่ `audit.log` ว่าง

audit ของ cluster นี้ประกอบด้วย 3 ชิ้นที่ต้องมาพร้อมกัน ขาดชิ้นไหนอาการต่างกัน

| ขาดอะไร | อาการ |
|---|---|
| ไฟล์ `/etc/kubernetes/audit-policy.yaml` บนเครื่อง | **apiserver ไม่ขึ้นเลย** — `extraVolumes` เป็น `pathType: File` kubelet จึงไม่ยอมสร้าง pod · `kubeadm init` ค้างจนหมดเวลา หรือ node ที่เพิ่ง join ไม่ยอม Ready |
| flag `audit-policy-file` | apiserver ขึ้นปกติ **แต่ไม่บันทึกอะไรเลย** — มีแค่ warning `No audit policy file provided, no events will be recorded for log backend` |
| `extraVolumes` ของ `/var/log/kubernetes` | apiserver ขึ้นปกติ เขียน log ได้ **แต่เขียนลงในคอนเทนเนอร์** — โฟลเดอร์บนโฮสต์ว่าง และ log หายทุกครั้งที่ pod restart |

**ไล่ตามลำดับนี้:**

```bash
ls -l /etc/kubernetes/audit-policy.yaml          # ต้องมีบน master ทุกตัว
crictl ps -a --name kube-apiserver               # pod ขึ้นไหม restart รัวไหม
journalctl -u kubelet --since "-10min" | grep -i "audit-policy\|failed to mount"
```

```bash
grep -A20 'name: audit' /etc/kubernetes/manifests/kube-apiserver.yaml
```
**ควรเห็น:** ทั้ง `--audit-policy-file`, `--audit-log-path` ในส่วน `command:`
และ volume ทั้ง `audit-policy` กับ `audit-log` ในส่วน `volumes:`

> **บน master ที่เพิ่ง join** อาการจะหลอกเป็นพิเศษ เพราะ `kubeadm join --control-plane`
> รอแค่ etcd member เข้าครบ ไม่ได้รอ apiserver ของเครื่องนั้น · **join จึงผ่านสวยทั้งที่ apiserver ไม่เกิด**
> ตรวจด้วย `kubectl -n kube-system get pods -l component=kube-apiserver -o wide` ว่ามีครบทุก master
> · แก้ได้โดยไม่ต้อง reset หรือ join ใหม่ แค่วางไฟล์ที่ขาด

**แก้** — วางไฟล์ policy แล้วให้ kubelet สร้าง pod ใหม่:

```bash
mkdir -p /var/log/kubernetes
install -D -m 0600 /root/k8s/config/kubeadm/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
```

kubelet เห็นไฟล์ครบแล้วจะสร้าง pod ให้เองภายในไม่กี่วินาที (static pod ไม่ต้องสั่งอะไร)

> **แก้ค่า audit หลังสร้าง cluster ไปแล้ว** ต้องแก้ `/etc/kubernetes/manifests/kube-apiserver.yaml`
> **ด้วยมือทีละ master** เพราะ kubeadm ไม่ได้ generate manifest ใหม่ให้จาก configmap
> (แก้ configmap `kubeadm-config` อย่างเดียวไม่มีผลกับเครื่องที่ตั้งไปแล้ว)
> จึงเป็นเหตุผลว่าทำไมต้องตั้งให้ถูกตั้งแต่บทที่ 04 ก่อน `init`

### 12.4 preflight ฟ้อง `/var/lib/etcd is not empty`

```
[ERROR DirAvailable--var-lib-etcd]: /var/lib/etcd is not empty
```

kubeadm ขอ `dataDir` ที่ว่างเปล่าจริง ๆ — ไม่สนว่าของข้างในเป็นของ filesystem เอง
บน cluster นี้ `/var/lib/etcd` เป็น partition แยกที่ย้ายมาจาก `/home` ในบทที่ 01
ext4 จึงแถม `lost+found` มาให้ทุกเครื่องตั้งแต่แรก และถ้าเครื่องนั้นเคยมีคนใช้ `/home`
โฟลเดอร์ของเดิมจะติดมาด้วย (เครื่องที่ VM template แบ่ง partition มาให้เลยจะมีแค่ `lost+found`)

**ดูก่อนลบเสมอ:**

```bash
ls -la /var/lib/etcd
```

| เห็นอะไร | แปลว่า | ทำอะไร |
|---|---|---|
| มีแค่ `lost+found` | filesystem ใหม่ปกติ ไม่ใช่ข้อมูล | `rm -rf /var/lib/etcd/lost+found` |
| มี `member/` | เคย init มาก่อน | `kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock` แล้วค่อยล้าง |
| มีโฟลเดอร์อื่น (เช่น `myhr`) | ของที่ติดมาจาก `/home` ตอนย้าย partition ในบท 01 | ตรวจว่าว่างจริงแล้ว `rmdir` — มันจะปฏิเสธถ้าข้างในมีของ ต่างจาก `rm -rf` ที่ลบทิ้งเงียบ ๆ |

**อย่าใช้ `--ignore-preflight-errors=DirAvailable--var-lib-etcd` เพื่อข้ามไป** —
ถ้าเป็นข้อมูล etcd เก่าจริง cluster จะขึ้นมาพร้อม member เดิมที่ไม่มีอยู่แล้ว
แล้วไปพังตอน join master ตัวที่สอง ซึ่งไล่หายากกว่ามาก

> ป้องกันที่ต้นทางแล้วในบทที่ 01 ข้อ 5 (ลบ `lost+found` ตอนย้าย partition)

### 12.5 join master ล้มที่ `download-certs` — `cipher: message authentication failed`

```
[download-certs] Downloading the certificates in Secret "kubeadm-certs" in the "kube-system" Namespace
error execution phase control-plane-prepare/download-certs: error downloading certs:
error decoding secret data with provided key: cipher: message authentication failed
```

**ไม่ใช่ token ผิด และไม่ใช่ของหมดอายุ** — token ผ่านมาแล้ว (ถ้า token ผิดจะตายตั้งแต่ preflight)
ที่ผิดคือ `--certificate-key` ถอดรหัส Secret `kubeadm-certs` ไม่ออก

**สาเหตุ** — `kubeadm init phase upload-certs --upload-certs` **เข้ารหัส cert ใหม่ด้วย key ใหม่ทุกครั้ง**
key ของรอบก่อนจึงใช้ไม่ได้ทันทีที่รันรอบใหม่ ไม่ต้องรอหมดอายุ
เจอบ่อยตอน join master ตัวที่สองแล้วหยิบ key เดิมจาก `kubeadm-init.log` หรือจากรอบก่อนหน้ามาใช้

**แก้ — ออกคู่ใหม่แล้วใช้ทันที (บน master01):**

```bash
kubeadm init phase upload-certs --upload-certs | tail -1
kubeadm token create --ttl 2h --print-join-command
```

**ต้องเอาค่าจากการรันรอบเดียวกันเท่านั้น** · ทั้งสองอย่างมีอายุ 2 ชั่วโมง

| ข้อความที่เจอ | แปลว่า |
|---|---|
| `cipher: message authentication failed` | key ไม่ตรงกับ Secret ปัจจุบัน — มีการ upload-certs ใหม่ไปแล้ว |
| `secrets "kubeadm-certs" not found` | Secret หมดอายุหรือถูกลบไปแล้ว — ต้อง `upload-certs` ใหม่ |
| `couldn't validate the identity of the API Server` | `--discovery-token-ca-cert-hash` ผิด ไม่ใช่เรื่อง key |

---

### 12.6 init ตายที่ `wait-control-plane` — `could not bootstrap the admin user` · `context deadline exceeded`

```
error execution phase wait-control-plane: cannot obtain client without bootstrap:
could not bootstrap the admin user in file admin.conf: unable to create ClusterRoleBinding:
Post "https://192.168.50.101:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings?timeout=10s":
context deadline exceeded
```

**ต่างจาก 12.3 ตรงที่ cluster ขึ้นแล้วจริง** — ต้องแยกให้ออกก่อน เพราะทางแก้คนละทาง:

```bash
crictl ps | grep -E 'apiserver|etcd|controller|scheduler'      # 12.6: Running ครบ 4 · 12.3: apiserver ไม่มี
curl -sk -o /dev/null -w '%{http_code} %{time_total}s\n' https://192.168.50.101:6443/readyz   # 12.6: 200 ในหลักสิบ ms
kubectl --kubeconfig /etc/kubernetes/super-admin.conf get clusterrolebinding kubeadm:cluster-admins   # 12.6: NotFound
```

**เกิดอะไรขึ้น** — kubeadm เห็น `/healthz` ตอบแล้วยิง POST แรก (สร้าง ClusterRoleBinding
`kubeadm:cluster-admins` ให้ `admin.conf`) โดยรอได้ 10 วินาที แต่ apiserver ที่เพิ่งขึ้นยัง
สร้าง RBAC ของระบบเองอยู่เป็นร้อยรายการหลัง etcd เพิ่ง Running · POST เลยต่อคิวเกิน 10 วินาที
**เป็นจังหวะ ไม่ใช่ config ผิด ไม่ใช่ disk ช้า** (เจอจริง 18 ก.ย. 2026: etcd fsync 97% ≤ 2ms
audit-policy ครบ ทุกอย่างปกติ)

**ผลที่ทิ้งไว้:** `admin.conf` มีแต่ **Forbidden** (CRB ที่ผูกมันไม่ถูกสร้าง) และ phase ที่เหลือ
ทั้งหมด — `upload-config` · `mark-control-plane` · `bootstrap-token` · `kubelet-finalize` ·
`addon` (CoreDNS) — **ไม่ได้รัน** เพราะ init หยุดก่อนถึง

**แก้ — reset แล้ว init ใหม่** ยังไม่มีเครื่องไหน join จึงไม่มีอะไรเสีย และเร็วกว่าไล่รัน phase
ที่ขาดทีละตัวด้วยมือ (5 phase พลาดตัวเดียว = cluster ครึ่งใบที่ไล่ยากกว่าเดิม):

```bash
kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
rm -rf /etc/cni/net.d /var/lib/cni
ls -A /var/lib/etcd            # ต้องว่าง (ดู 12.4 ถ้ามี lost+found)
```

แล้วทำ[บท 04 ข้อ 2](04-create-cluster.md)ซ้ำตั้งแต่ `install audit-policy` — `reset` ล้าง
`/etc/kubernetes/` ไปด้วย · รอบสองมักผ่านเพราะ image อยู่ครบและ apiserver ไม่ต้องรออะไร

> **อย่าไปสร้าง CRB เองด้วย `super-admin.conf` แล้วเดินต่อ** — มันแก้แค่ `admin.conf` แต่ phase
> อีก 5 อย่างยังขาดอยู่ · `super-admin.conf` มีไว้**ดู**ว่าเกิดอะไรขึ้น (อย่างบล็อกตรวจข้างบน)
> ไม่ใช่ไว้ซ่อม init ที่จบไม่ครบ

---

## 13. `$'\r': command not found`

```
/root/k8s/versions.env: line 13: $'\r': command not found
```

ไฟล์บนเครื่องเป็น **CRLF** — มาจากการ scp ตอนที่repoยังไม่มี [`.gitattributes`](../.gitattributes)
บังคับ LF หรือมีคนแก้ไฟล์บนเครื่องด้วยเครื่องมือฝั่ง Windows · bash อ่าน `\r`
ท้ายบรรทัดเป็นชื่อคำสั่ง และถ้าสคริปต์นั้นตั้ง `set -e` ไว้จะตายทันทีตรงบรรทัดนั้น

**อาการที่หลอกกว่า:** ถ้าไม่ตาย ค่าตัวแปรจะมี `\r` ติดไปด้วยเงียบ ๆ —
`VIP="192.168.50.100\r"` แล้วทุกคำสั่งที่ใช้ค่านี้จะต่อไม่ติดโดยไม่มี error บอกสาเหตุ

**ตรวจว่ามีไฟล์ไหนบ้าง:**
```bash
grep -rlU $'\r' /root/k8s/versions.env /root/k8s/config 2>/dev/null || echo "ไม่มี CRLF"
```

**แก้ทีเดียวทุกไฟล์:**
```bash
grep -rlU $'\r' /root/k8s/versions.env /root/k8s/config 2>/dev/null | xargs -r sed -i 's/\r$//'
```

> repoบังคับ LF ไว้แล้วผ่าน `.gitattributes` ไฟล์ที่ scp ขึ้นมา**หลังจากนั้น**จึงไม่มีปัญหานี้
> ที่ยังเจอคือสำเนาเก่าที่ค้างอยู่บนเครื่องตั้งแต่ก่อนหน้า — แก้ครั้งเดียวจบ
> หรือจะ scp ทับใหม่จากrepoก็ได้เหมือนกัน

---

## รวมคำสั่งที่ใช้บ่อย

```bash
# ภาพรวม 60 วินาที
kubectl get nodes && kubectl get pods -A | grep -v Running && cilium status

# ดู flow ที่ถูก drop
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do echo "== $p"; kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --verdict DROPPED --last 30; done

# HAProxy backend
curl -s http://127.0.0.1:8404/stats

# etcd health
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table

# ใครถือ VIP
for ip in 101 102 103; do echo -n "$ip: "; ssh root@192.168.50.$ip 'ip -4 a s | grep -c 192.168.50.100'; done

# kernel ตรงกันไหมทั้ง 6 เครื่อง
for ip in 101 102 103 104 105 106; do echo -n "$ip: "; ssh root@192.168.50.$ip uname -r; done
```

---

## 📝 บทนี้ต้องโตขึ้นเรื่อย ๆ

**ทุกครั้งที่แก้ปัญหาได้ ให้เพิ่มลงบทนี้** — อาการที่เห็น, สาเหตุจริง, วิธีแก้

นี่คือส่วนที่ทำให้คู่มือชุดนี้ต่างจากชุดเดิม
คู่มือเดิมไม่มีบทนี้เลย ความรู้จึงอยู่ในหัวคนไม่กี่คน และหายไปพร้อมคนนั้น

### บันทึกจากการติดตั้งจริง

**28 ส.ค. 2026 · `kubectl` ได้ `EOF` จาก VIP ทั้งที่ `kubeadm init` สำเร็จ**

- **อาการ** — `kubeadm init` จบสวย พิมพ์คำสั่ง join ครบ · `crictl ps` เห็น `kube-apiserver` `Running` ไม่ restart เลย
  แต่ `kubectl cluster-info` ได้ `Get "https://192.168.50.100:8443/api?timeout=32s": EOF` ซ้ำ ๆ
- **ที่ไล่ผิดทางตอนแรก** — เดาว่าเป็น SELinux (`haproxy_connect_any`) ทั้งที่บทที่ 01 ตั้ง `Permissive` ไว้แล้ว
  · ตัวที่ชี้ถูกคือช่อง `check` ในหน้า stats ของ HAProxy ไม่ใช่คำว่า `DOWN` เฉย ๆ
- **สาเหตุจริง** — `haproxy.cfg` มีทั้ง `option httpchk` + `http-check expect status 200` และ `option ssl-hello-chk`
  สองอันนี้ใช้ร่วมกันไม่ได้ · check เลยกลายเป็น "ทัก TLS แล้วรอ HTTP 200" ซึ่งไม่มีวันผ่าน
  backend จึง `DOWN` ครบทั้ง 3 ตัว แล้ว HAProxy ปิด connection ทันที = `EOF` ฝั่ง client
- **แก้** — ถอด `option ssl-hello-chk` ออก (แก้ในrepoแล้ว) · หลัง restart ได้ `UP check=L7OK` ทันที
- **กันไม่ให้เกิดซ้ำ** — `validate-repo.sh` ดักไม่ให้มี check สองแบบพร้อมกัน ·
  ขั้นตรวจในบทที่ 04 เปลี่ยนจาก `grep` หาชื่อ server (ผ่านเสมอ) เป็นอ่านช่อง `status` กับ `check`

**28 ส.ค. 2026 · failover test ผ่าน — แต่ลำดับในคู่มือเดิมผิด**

- ข้อ 5.1 (หยุด keepalived) และ 5.2 (หยุด HAProxy) ผ่าน · ข้อ 5.4 (`kubectl` ผ่าน VIP
  ระหว่างย้าย) ผ่าน ไม่มีปัญหา · ข้อ 5.3 (reboot) เลื่อนไปทำหลังบท 05
- **สิ่งที่เรียนรู้:** คู่มือเดิมเขียนว่า "failover test ต้องผ่านก่อน `kubeadm init`"
  ซึ่งทำได้แค่ครึ่งเดียว — ก่อนมี cluster ไม่มี apiserver ฟังที่ `:6443`
  ด่าน 2 ของ [`check_apiserver.sh`](../config/keepalived/check_apiserver.sh) จึง `exit 0`
  ออกไปก่อน **ด่าน 3 (ยิง `/healthz` ผ่าน VIP) ไม่เคยถูกรันเลย**
  · การทดสอบก่อน init จึงพิสูจน์ได้แค่ว่า "IP ย้ายเป็น" ไม่ใช่ "ย้ายแล้วใช้งานต่อได้"
- แก้แล้วในบท 03 (เพิ่มข้อ 5.4) และใน `CHECKLIST.md`
- ⬜ **ยังค้าง: ยังไม่ได้จดเวลา failover เป็นตัวเลข** — ต้องวัดรอบหน้า ไม่ใช่เดา

**สิ่งที่ต้องจดจาก Phase 1 (lab) โดยเฉพาะ:**
- [ ] `firewall-cmd --reload` ตอน Cilium รันอยู่ — pod ยังคุยกันได้ไหม
- [ ] ต้องเพิ่ม cilium interface เข้า trusted zone หรือเปล่า
- [ ] switch เปิด ARP inspection ไหม และแก้ยังไง
- [ ] MTU ต้องตั้งเองหรือ Cilium ตรวจถูก
- [ ] เวลา failover ของ keepalived จริงกี่วินาที
- [ ] เวลา drain + reboot + กลับมา Ready ต่อเครื่องกี่นาที
