# บทที่ 06 — ตรวจรับระบบ

> **รันที่: 👑 master01 เป็นหลัก** · ยกเว้น 3 จุดที่บอกไว้: หน้าต่างเฝ้า `kubectl` ในข้อ 4 ต้องอยู่บน
> **master02** (เพราะจะปิด master01) · `dnf`/`reboot` ในข้อ 6 ทำ**บนเครื่องที่กำลังซ้อม** ·
> `scp` ในข้อ 7 ทำจาก**เครื่องคุณ**
> **ลำดับ: 1 → 7 ตามลำดับ** — ข้อ 4-6 ทำให้เครื่องดับทีละเครื่อง ต้องรอกลับ `Ready` ครบก่อนไปข้อถัดไปเสมอ
> **เวลาที่ใช้:** ~40 นาที + รอเครื่อง reboot ในข้อ 6 (~3 นาที × 6)
> **ทำหลังบทที่ 05 เสร็จ และทำซ้ำอีกครั้งก่อนรับ workload จริง**

บทนี้ไม่ได้ติดตั้งอะไร แต่เป็นการพิสูจน์ว่า cluster ที่ได้ **ทนสถานการณ์จริงได้**
ไม่ใช่แค่ "ติดตั้งสำเร็จ"

---

## 1 · สุขภาพพื้นฐาน

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** [บท 05](05-cilium.md) ผ่านเกณฑ์ท้ายบทครบ · ลบของทดสอบ `lbtest` แล้ว

```bash
set -a && source /root/k8s/versions.env && set +a

kubectl get nodes -o wide
kubectl get pods -A
kubectl -n kube-system get deploy,ds
```

**ต้องได้:**
- 6 node สถานะ `Ready` ทุกตัว version `v1.36.3`
- ไม่มี pod ที่ `CrashLoopBackOff` / `Error` / `Pending`
- DaemonSet `cilium` = `6/6`
- **ไม่มี** `kube-proxy`

```bash
kubectl get --raw='/readyz?verbose' | tail -20
```
**ควรเห็น:** ทุกบรรทัดเป็น `ok` และปิดท้าย `readyz check passed`

---

## 2 · DNS

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 1 ผ่าน · node ดึง image จากอินเทอร์เน็ตได้ (`busybox`)

```bash
kubectl -n kube-system get deploy coredns
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```
**ควรเห็น:** ตอบกลับด้วย IP ในช่วง `10.247.0.0/16`

> CoreDNS ที่ kubeadm ลงให้มาแค่ 2 replica และ **ไม่มี PodDisruptionBudget**
> ซึ่งเป็นปัญหาโดยตรงกับเรา เพราะต้อง drain node ทุก 1-2 เดือน — แก้ในข้อ 5 ก่อนซ้อม drain ในข้อ 6

---

## 3 · pod คุยข้าม node

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 2 ผ่าน · node ดึง `nginx:alpine` · `curlimages/curl` ·
`nicolaka/netshoot` ได้ (ตัวสุดท้าย ~300MB ดึงครั้งแรกรอสักครู่) · จบข้อนี้ต้องลบ `nettest` ทิ้งก่อนไปข้อ 4

```bash
kubectl create deployment nettest --image=nginx:alpine --replicas=6
kubectl expose deployment nettest --port=80
kubectl get pods -l app=nettest -o wide     # ต้องกระจายหลาย node

# ยิงจาก pod ตัวหนึ่งไปหา Service (ผ่าน eBPF ของ Cilium ไม่ใช่ kube-proxy)
kubectl run curltest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://nettest
```
**ควรเห็น:** `200`

**ทดสอบ MTU — ข้อที่ลืมกันบ่อยที่สุด:**
```bash
TARGET=$(kubectl get pod -l app=nettest -o jsonpath='{.items[5].status.podIP}')
kubectl run mtutest --rm -it --restart=Never --image=nicolaka/netshoot -- ping -c3 -M do -s 1422 "$TARGET"
```
**ควรเห็น:** `3 received, 0% packet loss` · ห้ามมี `message too long` หรือ `Frag needed`

> ใช้ `nicolaka/netshoot` ไม่ใช่ `exec` เข้า pod nginx — `ping` ใน image ตระกูล alpine เป็นของ busybox
> ไม่รู้จัก `-M do` (ห้าม fragment) จะพ่น usage แล้ว `exit code 1` · `-s 1422` = MTU ของ pod 1450 − header 28
> คือก้อนใหญ่สุดที่ต้องผ่านได้โดยไม่แตก (VXLAN ห่ออีก 50 พอดี 1500 ของ node)

> ถ้าล้ม แปลว่า MTU ตั้งผิด อาการที่จะเจอตอนใช้จริงคือ
> **"ping ผ่าน แต่ HTTP request ใหญ่ ๆ ค้าง"** หรือ **"TLS handshake ล้มเป็นบางครั้ง"**
> ซึ่งหลอกให้ไปไล่หาปัญหาที่ application แก้โดยตั้ง `MTU: 1450` ใน `values.yaml` แล้ว `helm upgrade`

```bash
kubectl delete deployment nettest && kubectl delete svc nettest
```

---

## 4 · 🔴 ทดสอบ master ตาย

**ทำที่:** หน้าต่างเฝ้า `kubectl` และ `etcdctl` บน **👑 master02** (มี kubeconfig จาก[บท 04 ข้อ 4.2](04-create-cluster.md))
— **ห้าม**เปิดบน master01 เพราะเครื่องที่จะปิดคือ master01 หน้าต่างจะดับไปด้วย · การปิดเครื่องทำจาก **vCenter**
· **ต้องมีก่อน:** ข้อ 3 จบและลบ `nettest` แล้ว · VIP อยู่ที่ master01 (`ip -4 addr show ens192 | grep 192.168.50.100`
บน master01 ต้องได้ 1 บรรทัด — ถ้าอยู่เครื่องอื่น ให้ปิดเครื่องนั้นแทนและเฝ้าจาก master ที่เหลือ)

พิสูจน์ว่า HA ที่ทำมาทั้งบทที่ 03 ใช้ได้จริงตอน node หายไปทั้งเครื่อง — [บท 03 ข้อ 5.4](03-ha-layer.md)
พิสูจน์แค่หยุด service ข้อนี้ดึงปลั๊กทั้งเครื่อง

**1 · บน master02 — เปิดหน้าต่างเฝ้าค้างไว้:**
```bash
while true; do
  printf '%s ' "$(date +%T)"
  kubectl get --raw='/healthz' 2>&1 | head -c 40
  echo
  sleep 1
done
```

**2 · จาก vCenter — Power Off master01** (ปิดจริง ไม่ใช่ `systemctl stop` — keepalived ต้องหายไปพร้อมเครื่อง):

**ควรเห็นในหน้าต่างเฝ้า:**
- `kubectl` สะดุดไม่เกิน **2-3 วินาที** แล้วกลับมาทำงานต่อ
- VIP ย้ายไป master อีกตัว
- `kubectl get nodes` เห็นเครื่องนั้นเป็น `NotReady` ภายใน ~40 วินาที
- **pod บน worker ทั้งหมดยังทำงานปกติ**

**3 · บน master02 (หน้าต่างใหม่) — etcd ต้องยังมี quorum:**

```bash
kubectl -n kube-system exec -it etcd-k8s-master02 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```
**ควรเห็น:** 2 ใน 3 member ตอบ และยังมี leader — **quorum ยังอยู่**

**4 · จาก vCenter — Power On master01** แล้วดูจาก master02 ว่ากลับเข้า cluster เองภายใน ~2 นาที
โดยไม่ต้องสั่งอะไร: `kubectl get nodes` เป็น `Ready` ครบ 3 master · VIP กลับมาที่ master01 เอง
(keepalived ตั้ง preempt ไว้ priority 110 ชนะ) — ปิดหน้าต่างเฝ้าได้ (Ctrl-C)

> ⚠️ **ห้ามปิด master 2 ตัวพร้อมกัน** — จะเสีย quorum และ cluster จะหยุดทันที
> ถ้าอยากทดสอบข้อนี้ ให้ทำใน lab เท่านั้น และเตรียม etcd snapshot ไว้ก่อน

---

## 5 · ปิดช่องว่างที่ kubeadm ทิ้งไว้ — ก่อนซ้อม drain

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 4 จบ master01 กลับ `Ready` · ต้องทำ**ก่อน**ข้อ 6
ไม่งั้น drain เครื่องที่ CoreDNS อยู่ทั้ง 2 ตัว DNS จะดับทั้ง cluster

kubeadm ลง CoreDNS มาแค่ 2 replica และ**ไม่มี PDB** ซึ่งจะทำให้ DNS ดับตอน drain

```bash
kubectl -n kube-system patch deploy coredns -p '{"spec":{"replicas":3}}'

cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: coredns
  namespace: kube-system
spec:
  minAvailable: 2
  selector:
    matchLabels:
      k8s-app: kube-dns
EOF

kubectl -n kube-system get pdb
```
**ควรเห็น:** `coredns   minAvailable 2   ALLOWED DISRUPTIONS 1`

> **ไฟล์นี้ต้องเก็บลง git ด้วย** ไม่ใช่ apply แล้วจบ — เราไม่มี GitOps มาบังคับให้

---

## 6 · 🔴 ซ้อม rolling reboot

**ทำที่:** `kubectl` (cordon/drain/uncordon) บน 👑 master01 — **ยกเว้นรอบที่ซ้อม master01 เอง
ให้สั่งจาก master02** · บล็อก `dnf` + `reboot` ทำ**บนเครื่องที่กำลังซ้อม** (ssh เข้าไป)
· **ต้องมีก่อน:** ข้อ 5 (PDB ของ CoreDNS มีแล้ว) · `kubectl get nodes` `Ready` ครบ 6 · ทำ**ทีละเครื่อง**
รอกลับ `Ready` ก่อนเริ่มเครื่องถัดไป

**นี่คือข้อที่สำคัญที่สุดของบทนี้** เพราะไม่มี Ksplice จึงต้องทำแบบนี้ทุก 1-2 เดือนตลอดอายุ cluster
ต้องพิสูจน์ตอนที่ยังไม่มี workload ไม่ใช่มาลองครั้งแรกตอนมี CVE จริง

ทำทีละเครื่อง เริ่มจาก worker แล้วค่อยขึ้น master:

```bash
NODE=k8s-worker01

kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s
```
**ควรเห็น:** `node/k8s-worker01 drained` ภายในเวลาที่กำหนด

> ถ้า drain **ค้าง** สาเหตุคือ PDB ที่ตั้งไว้ทำให้ evict ไม่ได้ หรือมี pod ที่ไม่มีเจ้าของ
> ดูว่าค้างที่อะไร: `kubectl get pods -o wide --field-selector spec.nodeName=$NODE`

```bash
# ssh เข้าเครื่องนั้น
dnf versionlock delete kernel-uek kernel-uek-core kernel-uek-modules
dnf update -y
dnf versionlock add kernel-uek kernel-uek-core kernel-uek-modules   # ล็อกกลับทันที
reboot
```

หลังเครื่องกลับมา:
```bash
uname -r                        # ต้องตรงกับที่ตั้งใจ
kubectl uncordon "$NODE"
kubectl get nodes               # ต้องกลับเป็น Ready
```

**ทำซ้ำจนครบทั้ง 6 เครื่อง** — master ทำหลังสุดและทีละตัวเท่านั้น

**หลังจบ ให้อัปเดตเลข kernel ใน `versions.env` ถ้ามีการเปลี่ยน**

---

## 7 · ซ้อม etcd backup และ restore

**ทำที่:** 👑 master01 · `scp` คัดลอก snapshot ออกทำจาก**เครื่องคุณ** · **ต้องมีก่อน:** ข้อ 6 จบ
ครบ 6 เครื่อง `Ready` (snapshot ต้องเป็นสภาพหลังซ้อม ไม่ใช่ระหว่างซ้อม)

backup ที่ไม่เคยกู้สำเร็จ = ไม่มี backup

```bash
kubectl -n kube-system exec -it etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot-test.db

kubectl -n kube-system exec -it etcd-k8s-master01 -- \
  etcdutl --write-out=table snapshot status /var/lib/etcd/snapshot-test.db
```
**ควรเห็น:** ตาราง hash / revision / total size

**คัดลอกออกนอก cluster ทันที** — snapshot ที่อยู่บนเครื่องเดียวกับ etcd ไม่ช่วยอะไรตอนเครื่องพัง

```bash
sha256sum /var/lib/etcd/snapshot-test.db    # เก็บ checksum ไว้ด้วย
```

จาก**เครื่องคุณ** (WSL):

```bash
scp root@192.168.50.101:/var/lib/etcd/snapshot-test.db ~/etcd-snapshot-$(date +%F).db
```

> **ซ้อม restore จริงต้องทำใน lab** ไม่ใช่บน production
> จดเวลาที่ใช้จริงลงคู่มือเป็น RTO baseline — บทที่ 12 จะเป็นตัว runbook เต็ม

---

## ✅ เช็กลิสต์ตรวจรับ

### ระบบพื้นฐาน
- [ ] 6 node `Ready` version `v1.36.3` ตรงกันหมด
- [ ] `kubectl cluster-info` ชี้ที่ `https://192.168.50.100:8443`
- [ ] `/readyz?verbose` ผ่านทุกข้อ
- [ ] ไม่มี pod ผิดปกติใน namespace ไหนเลย
- [ ] ไม่มี `kube-proxy`

### เครือข่าย
- [ ] `cilium status` OK ทุกบรรทัด · `KubeProxyReplacement: True`
- [ ] `cilium connectivity test` ผ่านทั้งชุด
- [ ] DNS ตอบถูกต้อง
- [ ] MTU test ผ่าน (`ping -M do -s 1422` จาก netshoot)
- [ ] curl เข้า LoadBalancer IP จากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node ได้
- [ ] `firewall-cmd --reload` แล้ว pod ยังคุยกันได้

### ความทนทาน
- [ ] **ปิด master 1 ตัวแล้ว cluster ยังใช้งานได้** · quorum ยังอยู่
- [ ] master กลับเข้า cluster เองหลังเปิดกลับ
- [ ] **rolling reboot ครบทั้ง 6 เครื่องโดยไม่มี service ดับ**
- [ ] LB IP ย้าย node เองเมื่อ node ที่ถือ reboot (drain อย่างเดียวไม่ย้าย — agent ยังรัน)

### Day-2
- [ ] etcd snapshot สร้างได้ · `snapshot status` อ่านได้ · คัดลอกออกนอก cluster แล้ว
- [ ] `kubeadm certs check-expiration` — **จดวันหมดอายุลงปฏิทินทีมแล้ว**
- [ ] CoreDNS 3 replica + PDB
- [ ] `versions.env` ตรงกับของที่ติดตั้งจริงทุกบรรทัด

### ก่อนรับ workload จริง
- [ ] ทุก Deployment ที่จะย้ายเข้ามา **มี PDB และ replica ≥ 2**
- [ ] ผลรวม `requests` ทุก pod **ไม่เกิน 32 vCPU / 96 GB** (เพดาน N+1)
- [ ] มี alert เตือนเมื่อผลรวม requests เกิน 90% ของเพดาน

---

## ยังไม่ได้ทำในชุดนี้

คู่มือ 6 บทนี้ให้ cluster ที่ทำงานได้และทนได้ แต่ยัง**ไม่พร้อมรับ production**
จนกว่าจะมีอีก 4 อย่าง เรียงตามลำดับที่ควรทำ:

| ลำดับ | บท | ทำไมสำคัญ |
|---|---|---|
| 1 | **บทที่ 12 — Day-2 Operations** | backup อัตโนมัติ, cert renewal, upgrade runbook · **ถ้าเลือกได้แค่บทเดียว เลือกบทนี้** |
| 2 | **บทที่ 09 — Observability** | ถ้าไม่มี จะตอบไม่ได้ว่า "เมื่อคืนตอนตีสามเกิดอะไรขึ้น" |
| 3 | **บทที่ 10 — Security Baseline** | RBAC, PSA, NetworkPolicy default-deny, etcd encryption at rest |
| 4 | **บทที่ 07 — Envoy Gateway + TLS** | ทางเข้าจริงของ `zeeme-*` ทั้งหมด |

**อย่าย้าย workload เข้ามาก่อนที่ backup และ alert จะทำงานจริง**
นั่นคือบทเรียนตรง ๆ จาก cluster เดิม
