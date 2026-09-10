# บทที่ 12 — Day-2 Operations

> **ผู้อ่าน: ops** · **บทที่สำคัญที่สุดในคู่มือทั้งชุด**
> ทุกหัวข้อเป็น runbook ที่ต้องทำตามได้ตอนตีสาม

---

## 🔴 ทำไมบทนี้คือเหตุผลของการรื้อทำใหม่ทั้งหมด

คู่มือชุดเดิมพา cluster ขึ้นมาได้ แต่**ไม่มีบทไหนบอกวิธีทำให้มันอยู่ต่อ** —
ไม่มี backup, ไม่มีการต่ออายุ cert, ไม่มีวิธี upgrade

พอ cert หมดอายุและเวอร์ชัน EOL ทางเดียวที่เหลือคือรื้อทำใหม่ ซึ่งคือสิ่งที่กำลังทำอยู่ตอนนี้

**ถ้าเลือกได้แค่บทเดียวที่จะทำให้ดีที่สุด เลือกบทนี้**

---

## ตารางงานประจำ

| งาน | ความถี่ | ใครทำ | หัวข้อ |
|---|---|---|---|
| etcd snapshot | **ทุกวัน** (อัตโนมัติ) + ก่อนแตะอะไรก็ตาม | CronJob | [1](#1--etcd-backup) |
| ตรวจ backup กู้ได้จริง | ทุกไตรมาส | ops | [2](#2--กู้-etcd) |
| ตรวจอายุ certificate | ทุกเดือน + alert | ops | [3](#3--ต่ออายุ-certificate) |
| **Patch kernel / rolling reboot** | **ทุก 1-2 เดือน** | ops | [4](#4--rolling-reboot-patch-kernel) |
| Patch upgrade Kubernetes | ทุก 1-2 เดือน | ops | [5](#5--upgrade-kubernetes) |
| Minor upgrade Kubernetes | ปีละ 1-2 ครั้ง | ops | [5](#5--upgrade-kubernetes) |
| Cilium upgrade | ตามรอบ | ops | [6](#6--upgrade-cilium) |
| เพิ่ม/ถอด node | ตามต้องการ | ops | [7](#7--เพิ่ม-หรือ-ถอด-node) |
| ทบทวน capacity + cluster-admin | ทุกไตรมาส | ops | [8](#8--งานทบทวนรายไตรมาส) |

---

## 1 · etcd backup

### ตั้งอัตโนมัติ

```bash
kubectl apply -f /root/k8s/config/day2/etcd-backup-cronjob.yaml
kubectl -n kube-system get cronjob etcd-backup
```

**ทดสอบทันทีอย่ารอถึงพรุ่งนี้:**
```bash
kubectl -n kube-system create job --from=cronjob/etcd-backup etcd-backup-test
kubectl -n kube-system logs job/etcd-backup-test
```

### backup ด้วยมือ — ทำก่อนแตะอะไรก็ตาม

```bash
TS=$(date +%Y%m%d-%H%M%S)
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "/var/lib/etcd/snap-${TS}.db"

# ตรวจว่าไฟล์ใช้ได้จริง
kubectl -n kube-system exec etcd-k8s-master01 -- \
  etcdutl --write-out=table snapshot status "/var/lib/etcd/snap-${TS}.db"

# 🔴 คัดลอกออกนอก cluster ทันที
scp root@192.168.50.101:/var/lib/etcd/snap-${TS}.db /backup/etcd/
sha256sum "/backup/etcd/snap-${TS}.db" > "/backup/etcd/snap-${TS}.db.sha256"
```

> 🔴 **snapshot ที่อยู่บนเครื่องเดียวกับ etcd ไม่ช่วยอะไรตอนเครื่องพัง**
> ต้องออกไปอยู่นอก cluster และ**ต้องมี checksum** ไม่งั้นจะไม่รู้ว่าไฟล์เสียจนถึงวันที่ต้องกู้
>
> ⚠️ **snapshot มี Secret ที่เข้ารหัสด้วย encryption key อยู่ข้างใน**
> ถ้า key หายจะถอดรหัสไม่ได้เลย — เก็บ key แยกจาก backup และเก็บสำเนาออฟไลน์

---

## 2 · กู้ etcd

> **ซ้อมใน lab เท่านั้น** ห้ามซ้อมบน production
> จดเวลาที่ใช้จริงเป็น RTO baseline

### กรณี A — เสีย master 1 ตัว (quorum ยังอยู่)

**ไม่ต้องกู้จาก backup** ให้ถอด member เดิมออกแล้ว join ใหม่ (ดูหัวข้อ 7)

### กรณี B — เสีย quorum (master ตาย 2 ใน 3)

```bash
# 1. หยุด control plane ทุกเครื่อง
mv /etc/kubernetes/manifests /etc/kubernetes/manifests.off      # ทำทั้ง 3 master
crictl ps | grep -E 'etcd|apiserver'                            # ต้องไม่เหลือ

# 2. กู้บน master01
mv /var/lib/etcd /var/lib/etcd.broken
etcdutl snapshot restore /backup/etcd/snap-XXXX.db \
  --name k8s-master01 \
  --initial-cluster k8s-master01=https://192.168.50.101:2380 \
  --initial-advertise-peer-urls https://192.168.50.101:2380 \
  --data-dir /var/lib/etcd

# 3. เปิด control plane เฉพาะ master01
mv /etc/kubernetes/manifests.off /etc/kubernetes/manifests
kubectl get nodes                       # ต้องกลับมาใช้งานได้

# 4. master02/03 ล้างแล้ว join ใหม่เป็น control plane (ดูหัวข้อ 7)
```

**ตรวจหลังกู้:**
```bash
kubectl get nodes && kubectl get pods -A | grep -v Running
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```

---

## 3 · ต่ออายุ certificate

**cert ของ kubeadm อายุ 1 ปี** และต่ออายุอัตโนมัติ**เฉพาะตอน upgrade เท่านั้น**
cluster ที่ตั้งไว้แล้วไม่เคย upgrade จะมี cert หมดอายุเงียบ ๆ

```bash
# ตรวจทุกเดือน — ทำบนทุก master
kubeadm certs check-expiration
```

**ต่ออายุ — ทำทีละ master:**
```bash
# 1. backup ก่อนเสมอ
\cp -rf /etc/kubernetes/pki /root/k8s/pki-backup-$(date +%Y%m%d)

# 2. ต่ออายุทั้งชุด
kubeadm certs renew all

# 3. restart control plane โดยขยับไฟล์ manifest ออกแล้วใส่กลับ
cd /etc/kubernetes/manifests
mv kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml /tmp/
sleep 20
mv /tmp/{kube-apiserver,kube-controller-manager,kube-scheduler,etcd}.yaml .

# 4. รอจน healthz ผ่านก่อนไปเครื่องถัดไป
until kubectl get --raw='/healthz' 2>/dev/null | grep -q ok; do sleep 3; done

# 5. อัปเดต kubeconfig ของ admin ด้วย (cert ในนั้นก็หมดอายุเหมือนกัน)
\cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"

kubeadm certs check-expiration
```
**ควรเห็น:** ทุกบรรทัดกลับไปเป็น ~364 วัน

> **CA มีอายุ 10 ปี** ตราบใดที่ CA ยังไม่หมด cert อื่นต่ออายุได้เสมอ
> แม้จะหมดอายุไปแล้วก็ตาม — **cert หมดไม่ใช่จุดจบ** แต่ก็อย่าปล่อยให้ถึงจุดนั้น

### 3.1 cert ของ Gateway — `kubeadm certs check-expiration` มองไม่เห็น

cert ที่ Envoy Gateway เสิร์ฟให้ผู้ใช้เป็นคนละชุดกับ cert ของ control plane
`kubeadm certs check-expiration` ไม่รายงานให้ ต้องตรวจแยก **ทุกเดือนพร้อมกัน**

```bash
for s in myhr-public-tls myhr-internal-tls; do
  kubectl -n envoy-gateway-system get secret "$s" >/dev/null 2>&1 || continue
  echo "== $s"
  kubectl -n envoy-gateway-system get secret "$s" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -issuer -enddate
done
```

**`myhr-internal-tls` (จาก internal CA — มีเฉพาะถ้าทำภาคผนวก ข ของบท 07)**
cert-manager ต่ออายุให้เองเมื่อเหลือ 30 วัน
ข้อนี้แค่ตรวจว่ามันทำงานจริง `enddate` ต้องขยับออกไปเรื่อย ๆ ถ้าค้างที่เดิมสองเดือนติดให้ดู:
```bash
kubectl -n envoy-gateway-system describe certificate myhr-internal-tls | tail -20
```

### เปลี่ยน `myhr-public-tls` เป็นใบใหม่

🔴 **ไม่มีอะไรต่ออายุให้** ต้องขอไฟล์ชุดใหม่จาก CA แล้วเปลี่ยนเอง
**ทำตอนใบเก่ายังไม่หมดอายุ** จะได้ไม่มี downtime

**1 · ตรวจไฟล์ใหม่ก่อน ยังไม่แตะเครื่อง** — รันที่ไหนก็ได้ที่มี `openssl` (เครื่อง admin ก็ได้):
```bash
bash config/gateway/import-public-cert.sh --dry-run <fullchain ใหม่> <key ใหม่>
```
ต้องได้ `ok` ครบ 5 ข้อ — ไม่ผ่านให้กลับไปคุยกับ CA ก่อน อย่าเอาขึ้นเครื่อง

**2 · สำรองของเดิมก่อนทับ** (บน master01):
```bash
cp -a /root/certs/fullchain.pem /root/certs/fullchain.pem.$(date +%Y%m%d)
cp -a /root/certs/privkey.pem   /root/certs/privkey.pem.$(date +%Y%m%d)
```

**3 · วางไฟล์ใหม่ทับ แล้วรันสคริปต์เดิม** — ใช้ `apply` จึงเขียนทับ Secret ได้ ไม่ต้อง delete ก่อน:
```bash
bash /root/k8s/config/gateway/import-public-cert.sh \
     /root/certs/fullchain.pem /root/certs/privkey.pem
```

**4 · ตรวจ "บนสายจริง" — ไม่ใช่ดูแค่ Secret**
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
echo | openssl s_client -connect "${GW_IP}:443" -servername hr.myhr.co.th 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```
**`notAfter` ต้องเป็นวันใหม่**

> 🔴 **Secret เปลี่ยนแล้ว ไม่ได้แปลว่า Envoy เสิร์ฟใบใหม่แล้ว** — เป็นคนละคำถามกัน
> `kubectl get secret` ตอบว่า "เก็บอะไรไว้" ส่วน `openssl s_client` ตอบว่า
> "ส่งอะไรออกไปให้ผู้ใช้จริง" ซึ่งเป็นคำถามที่เราสนใจ
>
> TLS handshake เกิดก่อน routing คำสั่งนี้จึงใช้ได้แม้ไม่มี HTTPRoute ของชื่อนั้น
> · `-servername` คือ SNI **ต้องใส่** ไม่งั้นได้ใบ default มาแทน

**ถ้า `notAfter` ยังเป็นวันเก่าหลังผ่านไป 1-2 นาที** — Envoy ยังไม่รับใบใหม่ ให้ restart proxy:
```bash
kubectl -n envoy-gateway-system get deploy
```
หาแถวที่ชื่อขึ้นต้นด้วย `envoy-` แต่**ไม่ใช่** `envoy-gateway` (ตัวนั้นคือ controller) แล้ว:
```bash
kubectl -n envoy-gateway-system rollout restart deploy/<ชื่อที่ได้>
```
แล้วตรวจข้อ 4 ซ้ำ

**ถ้าใบใหม่มีปัญหา — ย้อนกลับด้วยไฟล์ที่สำรองไว้ข้อ 2:**
```bash
cp -a /root/certs/fullchain.pem.YYYYMMDD /root/certs/fullchain.pem
cp -a /root/certs/privkey.pem.YYYYMMDD   /root/certs/privkey.pem
bash /root/k8s/config/gateway/import-public-cert.sh \
     /root/certs/fullchain.pem /root/certs/privkey.pem
```

**ถ้ามี internal cert อยู่ด้วย (ภาคผนวก ข ของบท 07) ต้องรันตัวตรวจชื่อทับซ้ำ** —
cert ใบใหม่ที่ CA ใส่ SAN เพิ่มมาให้โดยไม่ได้ขอ จะไปทับกับ internal cert ได้
ตั้งแต่วันที่ต่ออายุ โดยไม่มีอะไรเตือน:
```bash
bash /root/k8s/config/gateway/check-cert-overlap.sh
```

> cert ของ Gateway หมดอายุ = **ทุก service ล่มพร้อมกันจากมุมของผู้ใช้** ทั้งที่ pod ยังเขียวหมด
> เป็นเคสที่หาสาเหตุนานที่สุดถ้าไม่ได้เตรียมไว้ก่อน เพราะทุก dashboard ยังปกติ

---

## 4 · Rolling reboot (patch kernel)

> 🔴 **งานประจำที่หนักที่สุดของ cluster ชุดนี้**
> เราใช้ Oracle Linux แบบฟรีจึงไม่มี Ksplice — ปะ kernel ต้อง reboot ทุกครั้ง

### ก่อนเริ่ม — ตรวจ 3 ข้อ

```bash
# 1. ทุก Deployment มี PDB และ replica >= 2
kubectl get deploy -A -o json | jq -r '.items[]
  | select(.spec.replicas < 2)
  | "\(.metadata.namespace)/\(.metadata.name): replicas=\(.spec.replicas)"'
# ต้องไม่คืนอะไรเลย (นอกจาก namespace ระบบ)

# 2. capacity พอให้ drain 1 เครื่อง
kubectl describe nodes | grep -A5 'Allocated resources'
# ผลรวม requests ต้องไม่เกิน 32 vCPU / 96 GB

# 3. ไม่มี pod ที่ผิดปกติค้างอยู่
kubectl get pods -A | grep -v -E 'Running|Completed'
```

### ลำดับ — สำคัญ

> **เริ่มจาก `k8s-worker03` เสมอ** เพราะเป็นเครื่องที่ถือ local PV ของ monitoring
> ทำเครื่องนี้ก่อนจะได้มี monitoring ครบตอนทำเครื่องที่เหลือ

```
worker03 → worker01 → worker02 → master02 → master03 → master01
```

master01 ทำท้ายสุดเพราะถือ VIP อยู่ (priority สูงสุด)

### ทำทีละเครื่อง

```bash
NODE=k8s-worker03

# --- 1. ย้าย pod ออก -------------------------------------------------------
kubectl cordon "$NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

**ถ้า drain ค้าง:**
```bash
kubectl get pods -o wide --field-selector spec.nodeName="$NODE" -A
kubectl get pdb -A     # ดูว่า ALLOWED DISRUPTIONS เป็น 0 ตัวไหน
```
สาเหตุที่พบบ่อย: PDB ที่ `minAvailable` เท่ากับ `replicas` → **ไม่มีวันปล่อย**

```bash
# --- 2. patch แล้ว reboot (บนเครื่องนั้น) ----------------------------------
ssh root@<NODE_IP>
set -a && source /root/k8s/versions.env && set +a

dnf versionlock delete kernel-uek kernel-uek-core kernel-uek-modules
dnf update -y
dnf versionlock add kernel-uek kernel-uek-core kernel-uek-modules   # 🔴 ล็อกกลับทันที
dnf versionlock list | grep kernel-uek                              # ยืนยัน

reboot
```

```bash
# --- 3. ตรวจหลังกลับมา -----------------------------------------------------
uname -r                                    # ต้องลงท้าย uek
systemctl is-active containerd kubelet
findmnt /var/lib/containerd || findmnt /var/lib/etcd    # partition ยัง mount

# บน master ต้องเช็คเพิ่ม
systemctl is-active keepalived haproxy

# --- 4. เปิดรับ pod กลับ ---------------------------------------------------
kubectl uncordon "$NODE"
kubectl get nodes                           # ต้องกลับเป็น Ready
```

**รอจน `Ready` และ pod กลับมาครบก่อนไปเครื่องถัดไป — ห้ามทำสองเครื่องพร้อมกัน**

### หลังจบทุกเครื่อง

```bash
# kernel ต้องตรงกันทั้ง 6 เครื่อง
for ip in 101 102 103 104 105 106; do
  echo -n "192.168.50.$ip: "; ssh "root@192.168.50.$ip" uname -r
done
```
**อัปเดตเลข `KERNEL_UEK` ใน `versions.env` ถ้ามีการเปลี่ยน**

> alert `NodeKernelVersionMismatch` จะดังระหว่างทำ — **เป็นเรื่องปกติ**
> แต่ถ้ายังดังหลังจบงานแล้ว แปลว่ามีเครื่องที่ patch ไม่สำเร็จ

---

## 5 · Upgrade Kubernetes

### Patch upgrade (1.36.3 → 1.36.x) — ความเสี่ยงต่ำ

รวมกับ rolling reboot ในหัวข้อ 4 ได้เลย ประหยัดรอบ drain

**บน master01:**
```bash
NEW=1.36.5
dnf install -y --disableexcludes=kubernetes "kubeadm-${NEW}"
kubeadm upgrade plan
kubeadm upgrade apply "v${NEW}"
```

**บน master02/03:**
```bash
dnf install -y --disableexcludes=kubernetes "kubeadm-${NEW}"
kubeadm upgrade node
```

**ทุกเครื่อง (รวม worker) — ทีละเครื่องพร้อม drain:**
```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
dnf install -y --disableexcludes=kubernetes "kubelet-${NEW}" "kubectl-${NEW}"
systemctl daemon-reload && systemctl restart kubelet
kubectl uncordon "$NODE"
```

**อัปเดต `versions.env` แล้ว `dnf versionlock` ใหม่ทุกเครื่อง**

### Minor upgrade (1.36 → 1.37) — ต้องวางแผน

> 🔴 **อ่าน release note ของเวอร์ชันปลายทางก่อนเสมอ** ไม่ใช่ทำตามแบบปิดตา
> แต่ละ release มี deprecation และ gotcha ของตัวเอง

**ห้ามข้าม minor** — ต้องไป 1.36 → 1.37 → 1.38 ทีละขั้น

```bash
# 1. backup etcd ก่อนเสมอ (หัวข้อ 1)

# 2. เปลี่ยน repo เป็น minor ใหม่ — ขั้นที่คนลืมบ่อยที่สุด
sed -i 's|/v1.36/|/v1.37/|g' /etc/yum.repos.d/kubernetes.repo
dnf clean all && dnf makecache

# 3. ที่เหลือเหมือน patch upgrade
```

**ตรวจหลัง upgrade:**
```bash
kubectl get nodes            # version ต้องตรงกันทั้ง 6
kubeadm certs check-expiration   # upgrade ต่ออายุ cert ให้อัตโนมัติ — ควรกลับเป็น ~364 วัน
cilium status
```

> **ข้อดีที่มักถูกมองข้าม:** `kubeadm upgrade` ต่ออายุ certificate ให้อัตโนมัติ
> การ upgrade อย่างน้อยปีละครั้งจึงแก้ปัญหา cert หมดอายุไปในตัว

---

## 6 · Upgrade Cilium

> 🔴 **เสี่ยงกว่า Kubernetes upgrade สำหรับ cluster ชุดนี้**
> Cilium ทำทั้ง CNI + kube-proxy + LB-IPAM — พลาดทีเดียวดับหมดทั้ง 3 อย่าง
> และ **ไม่มี kube-proxy ให้ถอยกลับ**

```bash
# 0. กำหนดเวอร์ชันปลายทาง แล้วเขียนกลับลง versions.env เมื่อ upgrade เสร็จ
NEW_CILIUM=1.20.2          # ← แก้เป็นเวอร์ชันที่จะขึ้นจริง

# 1. อ่าน upgrade note ของเวอร์ชันปลายทางก่อน — บังคับ
# 2. backup etcd
# 3. ดู values ปัจจุบัน
helm -n kube-system get values cilium > /root/k8s/cilium-values-current.yaml

# 4. รัน pre-flight ที่ Cilium เตรียมไว้ให้ (ดึง image ล่วงหน้า ลด downtime)
helm install cilium-preflight cilium/cilium --version "${NEW_CILIUM}" \
  --namespace kube-system \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false
kubectl -n kube-system get ds cilium-pre-flight-check
helm uninstall cilium-preflight -n kube-system

# 5. upgrade จริง
helm upgrade cilium cilium/cilium --version "${NEW_CILIUM}" \
  --namespace kube-system -f /root/k8s/config/cilium/values.yaml

kubectl -n kube-system rollout status ds/cilium --timeout=10m
```

**ตรวจทันทีหลังเสร็จ:**
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
cilium status --wait
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system get "$p" -o jsonpath='{.spec.nodeName}{" "}'
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    cilium-dbg status 2>/dev/null | grep -i KubeProxyReplacement
done                                   # ต้อง True ครบทุกเครื่อง ไม่ใช่แค่เครื่องแรก
kubectl get svc -A | grep LoadBalancer        # EXTERNAL-IP ต้องยังอยู่
curl -I "http://${GW_IP}"                     # จากเครื่องทดสอบในวง 192.168.50.0/24
cilium connectivity test
```

**ถ้าพัง — rollback:**
```bash
helm rollback cilium -n kube-system
kubectl -n kube-system rollout status ds/cilium
```

---

## 7 · เพิ่ม หรือ ถอด node

### เพิ่ม worker

**ในrepo — แก้ 2 ไฟล์ ที่เหลืออ่านต่อจากสองไฟล์นี้เองหมด:**

| ไฟล์ | เพิ่มอะไร |
|---|---|
| [`docs/versions.env`](versions.env) | `WORKER04_IP=192.168.50.107` และ `WORKER04_NAME=k8s-worker04` |
| [`ansible/inventory.ini`](../ansible/inventory.ini) | `k8s-worker04 ansible_host=192.168.50.107` ใต้ `[workers]` |

```bash
bash config/validate-repo.sh
```

ต้องผ่าน — ตัวตรวจอ่านรายชื่อเครื่องจาก `versions.env` เอง ถ้าลืมใส่ใน `inventory.ini`
มันจะฟ้องชื่อเครื่องที่ขาดออกมาตรง ๆ

**บนเครื่องใหม่ — ทำ [บทที่ 01](01-prepare-os.md) และ [02](02-container-runtime.md) ให้ครบก่อน**
(partition แยกของ worker คือ `/var/lib/containerd` · firewalld ต้องเปิดพอร์ตชุด worker)

**`/etc/hosts` ของ *ทุกเครื่อง* ต้องรู้จักเครื่องใหม่ ไม่ใช่แค่เครื่องใหม่รู้จักคนอื่น** —
วิธีที่ถูกคือรัน playbook ให้ทั้ง cluster (มันวางบล็อกเดียวกันทุกเครื่อง แบบ idempotent):

```bash
ansible-playbook prepare-os.yml
```

**join เครื่องใหม่ด้วย playbook** — ต้องมี master01 อยู่ในรอบด้วยเพราะ token ออกจากเครื่องนั้น:

```bash
ansible-playbook create-cluster.yml --limit 'k8s-master01,k8s-worker04'
```

หรือทำมือ: ออก token บน master01 แล้ว join บนเครื่องใหม่

```bash
kubeadm token create --ttl 2h --print-join-command
```

**ตรวจหลัง join:**

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=k8s-worker04
```

**ควรเห็น:** node ใหม่เป็น `Ready` ภายในไม่กี่นาที (Cilium ลง agent ให้เองผ่าน DaemonSet
ไม่ต้องทำอะไรเพิ่มในบทที่ 05) และมี pod ของ Cilium ขึ้นบนเครื่องนั้น

> **สิ่งที่ *ไม่* ต้องทำสำหรับ worker** — ไม่ต้องแก้ `certSANs`, ไม่ต้องแตะ HAProxy/keepalived,
> ไม่ต้องมี `audit-policy.yaml` (ใช้กับ apiserver ซึ่งอยู่บน master เท่านั้น)
> · ถ้าเพิ่ม **master** ต่างออกไปมาก: `certSANs` ใน `kubeadm-config.yaml` ต้องมี IP/ชื่อเครื่องใหม่
> **ตั้งแต่ก่อน `kubeadm init`** แก้ทีหลังต้องออก cert ใหม่ทั้งชุด · และต้องเพิ่ม backend
> ใน `haproxy.cfg` ของทุก master กับตั้ง `priority` ของ keepalived ให้ไม่ชนกัน

### เพิ่ม control plane

```bash
# บน master01 — ต้องได้ทั้ง certificate-key และ token ใหม่
kubeadm init phase upload-certs --upload-certs      # certificate-key อายุ 2 ชม.
kubeadm token create --ttl 2h --print-join-command
```
แล้วต่อท้ายด้วย `--control-plane --certificate-key <KEY>`

### ถอด node

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
kubectl delete node "$NODE"

# บนเครื่องที่ถอด
kubeadm reset -f
rm -rf /etc/cni/net.d /var/lib/cni
iptables -F && iptables -t nat -F 2>/dev/null || true
```

**ถ้าถอด control plane ต้องเอา etcd member ออกด้วย:**
```bash
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  member list

kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl ... member remove <MEMBER_ID>
```

> ⚠️ **keepalived/HAProxy เป็น systemd จึงอยู่รอด `kubeadm reset`**
> ถ้าถอด master ออกถาวร ต้องไปแก้ `haproxy.cfg` บนเครื่องที่เหลือให้เอา backend นั้นออกด้วย
> และแก้ `priority` ของ keepalived ให้ยังเรียงกันถูก

---

## 8 · งานทบทวนรายไตรมาส

```bash
# 1. capacity — เทียบ requests กับที่ใช้จริง
kubectl top nodes
kubectl describe nodes | grep -A5 'Allocated resources'

# 2. ใครเป็น cluster-admin บ้าง — ลบคนที่ไม่ได้อยู่แล้ว
kubectl get clusterrolebinding -o json | jq -r '.items[]
  | select(.roleRef.name=="cluster-admin") | .metadata.name as $n
  | (.subjects // [])[] | "\($n)\t\(.kind)/\(.name)"'

# 3. ซ้อมกู้ etcd ใน lab — จดเวลาที่ใช้จริง

# 4. ตรวจ image ที่ยังใช้ tag ไม่ pin digest
kubectl get pods -A -o json | jq -r '.items[].spec.containers[].image' \
  | grep -v '@sha256:' | sort -u

# 5. registry garbage collection
#    Docker Registry เปล่าไม่มี retention policy — disk จะโตไปเรื่อย ๆ จนเต็ม
ssh root@${REGISTRY_IP} 'registry garbage-collect /etc/docker/registry/config.yml'
```

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] CronJob backup etcd ทำงานและ**ทดสอบรันแล้ว**
- [ ] snapshot ออกไปอยู่นอก cluster พร้อม checksum
- [ ] encryption key เก็บ**แยกจาก backup** และมีสำเนาออฟไลน์
- [ ] 🔴 **ซ้อมกู้ etcd ใน lab สำเร็จแล้ว และจด RTO ไว้**
- [ ] alert cert ใกล้หมดอายุทำงาน · จดวันหมดอายุลงปฏิทินทีมแล้ว
- [ ] 🔴 **ซ้อม rolling reboot ครบ 6 เครื่องโดยไม่มี service ดับ**
- [ ] ทีมรู้ลำดับ **worker03 ก่อนเสมอ · master01 ท้ายสุด**
- [ ] ซ้อม patch upgrade อย่างน้อย 1 ครั้ง
- [ ] ซ้อม Cilium upgrade **ใน lab** อย่างน้อย 1 ครั้ง
- [ ] runbook ทุกหัวข้อมีคนที่ไม่ได้เขียนทำตามได้จริง

**➡️ ต่อที่ [บทที่ 13 — Troubleshooting](13-troubleshooting.md)**
