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
POD=$(kubectl -n "$NS" get pod -l app="$APP" -o name | head -1 | cut -d/ -f2)
SVC=$APP
NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
echo "NS=$NS POD=$POD NODE=$NODE"
```

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
  ssh root@192.168.50.$ip "ip -4 addr show ens192 | grep -c 192.168.50.100"
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
สาเหตุ 3 ข้อ เรียงตามความน่าจะเป็น:
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

### 1.3 VIP ปกติ แต่ยังต่อไม่ได้
```bash
ss -lnt | grep 8443                          # HAProxy ฟังอยู่ไหม
curl -s http://127.0.0.1:8404/stats | head   # backend ขึ้นกี่ตัว
crictl ps | grep kube-apiserver              # apiserver รันอยู่ไหม
crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -30
```

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
kubectl -n kube-system exec -it ds/cilium -- \
  hubble observe --namespace "$NS" --verdict DROPPED --last 100
```

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

### จากเครื่องนอก cluster
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
```

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
ยังไม่ได้ลง root CA ที่เครื่อง client — ดูบทที่ 07 ขั้นที่ 3

---

## 9. image pull ไม่ผ่าน

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
kubectl -n kube-system exec -it ds/cilium -- \
  hubble observe --namespace "$NS" --verdict DROPPED --last 50
```
**นี่คือวิธีที่ถูกต้อง — ดูของจริงว่าอะไรถูก drop แล้วเปิดเฉพาะเส้นนั้น**
ไม่ใช่เดาเอาจากเอกสาร

**ทดสอบจากใน cluster ก่อนโทษ Gateway:**
```bash
kubectl -n "$NS" run t --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sv "http://${SVC}"
```

---

## รวมคำสั่งที่ใช้บ่อย

```bash
# ภาพรวม 60 วินาที
kubectl get nodes && kubectl get pods -A | grep -v Running && cilium status

# ดู flow ที่ถูก drop
kubectl -n kube-system exec -it ds/cilium -- hubble observe --verdict DROPPED --last 100

# HAProxy backend
curl -s http://127.0.0.1:8404/stats

# etcd health
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table

# ใครถือ VIP
for ip in 101 102 103; do echo -n "$ip: "; ssh root@192.168.50.$ip 'ip -4 a s ens192 | grep -c 192.168.50.100'; done

# kernel ตรงกันไหมทั้ง 6 เครื่อง
for ip in 101 102 103 104 105 106; do echo -n "$ip: "; ssh root@192.168.50.$ip uname -r; done
```

---

## 📝 บทนี้ต้องโตขึ้นเรื่อย ๆ

**ทุกครั้งที่แก้ปัญหาได้ ให้เพิ่มลงบทนี้** — อาการที่เห็น, สาเหตุจริง, วิธีแก้

นี่คือส่วนที่ทำให้คู่มือชุดนี้ต่างจากชุดเดิม
คู่มือเดิมไม่มีบทนี้เลย ความรู้จึงอยู่ในหัวคนไม่กี่คน และหายไปพร้อมคนนั้น

**สิ่งที่ต้องจดจาก Phase 1 (lab) โดยเฉพาะ:**
- [ ] `firewall-cmd --reload` ตอน Cilium รันอยู่ — pod ยังคุยกันได้ไหม
- [ ] ต้องเพิ่ม cilium interface เข้า trusted zone หรือเปล่า
- [ ] switch เปิด ARP inspection ไหม และแก้ยังไง
- [ ] MTU ต้องตั้งเองหรือ Cilium ตรวจถูก
- [ ] เวลา failover ของ keepalived จริงกี่วินาที
- [ ] เวลา drain + reboot + กลับมา Ready ต่อเครื่องกี่นาที
