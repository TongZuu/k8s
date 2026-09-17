# บทที่ 06 — ตรวจรับระบบ

> **รันที่: 👑 master01**
> **เวลาที่ใช้:** ~40 นาที
> **ทำหลังบทที่ 05 เสร็จ และทำซ้ำอีกครั้งก่อนรับ workload จริง**

บทนี้ไม่ได้ติดตั้งอะไร แต่เป็นการพิสูจน์ว่า cluster ที่ได้ **ทนสถานการณ์จริงได้**
ไม่ใช่แค่ "ติดตั้งสำเร็จ"

---

## 1 · สุขภาพพื้นฐาน

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

```bash
kubectl -n kube-system get deploy coredns
kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```
**ควรเห็น:** ตอบกลับด้วย IP ในช่วง `10.247.0.0/16`

> CoreDNS ที่ kubeadm ลงให้มาแค่ 2 replica และ **ไม่มี PodDisruptionBudget**
> ซึ่งเป็นปัญหาโดยตรงกับเรา เพราะต้อง drain node ทุก 1-2 เดือน — แก้ในขั้นที่ 7

---

## 3 · pod คุยข้าม node

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
POD=$(kubectl get pod -l app=nettest -o jsonpath='{.items[0].metadata.name}')
TARGET=$(kubectl get pod -l app=nettest -o jsonpath='{.items[5].status.podIP}')
kubectl exec "$POD" -- ping -c3 -M do -s 1372 "$TARGET"
```
**ควรเห็น:** ตอบครบ 3 packet ไม่มี `Frag needed`

> ถ้าล้ม แปลว่า MTU ตั้งผิด อาการที่จะเจอตอนใช้จริงคือ
> **"ping ผ่าน แต่ HTTP request ใหญ่ ๆ ค้าง"** หรือ **"TLS handshake ล้มเป็นบางครั้ง"**
> ซึ่งหลอกให้ไปไล่หาปัญหาที่ application แก้โดยตั้ง `MTU: 1450` ใน `values.yaml` แล้ว `helm upgrade`

```bash
kubectl delete deployment nettest && kubectl delete svc nettest
```

---

## 4 · 🔴 ทดสอบ master ตาย

พิสูจน์ว่า HA ที่ทำมาทั้งบทที่ 03 ใช้ได้จริงตอน node หายไปทั้งเครื่อง

**เปิดหน้าต่างที่ 2 ค้างไว้:**
```bash
while true; do
  printf '%s ' "$(date +%T)"
  kubectl get --raw='/healthz' 2>&1 | head -c 40
  echo
  sleep 1
done
```

**ปิด master ที่ถือ VIP อยู่ (shutdown จริงจาก vCenter ไม่ใช่แค่หยุด service):**

**ควรเห็น:**
- `kubectl` สะดุดไม่เกิน **2-3 วินาที** แล้วกลับมาทำงานต่อ
- VIP ย้ายไป master อีกตัว
- `kubectl get nodes` เห็นเครื่องนั้นเป็น `NotReady` ภายใน ~40 วินาที
- **pod บน worker ทั้งหมดยังทำงานปกติ**

```bash
kubectl -n kube-system exec -it etcd-k8s-master02 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```
**ควรเห็น:** 2 ใน 3 member ตอบ และยังมี leader — **quorum ยังอยู่**

**เปิดเครื่องกลับ** แล้วตรวจว่ากลับเข้า cluster เองภายใน ~2 นาที โดยไม่ต้องสั่งอะไร

> ⚠️ **ห้ามปิด master 2 ตัวพร้อมกัน** — จะเสีย quorum และ cluster จะหยุดทันที
> ถ้าอยากทดสอบข้อนี้ ให้ทำใน lab เท่านั้น และเตรียม etcd snapshot ไว้ก่อน

---

## 5 · 🔴 ซ้อม rolling reboot

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
# บนเครื่องนั้น
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

## 6 · ซ้อม etcd backup และ restore

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

> **ซ้อม restore จริงต้องทำใน lab** ไม่ใช่บน production
> จดเวลาที่ใช้จริงลงคู่มือเป็น RTO baseline — บทที่ 12 จะเป็นตัว runbook เต็ม

---

## 7 · ปิดช่องว่างที่ kubeadm ทิ้งไว้

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
- [ ] MTU test ผ่าน (`ping -M do -s 1372`)
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
