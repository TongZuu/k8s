# บทที่ 04 — สร้าง Cluster

> **รันที่: 👑 master01 ก่อน → 🎩 master02-03 → ⚙️ worker ทุกตัว**
> **เวลาที่ใช้:** ~30 นาที
> **⚠️ ต้องผ่าน failover test ของบทที่ 03 มาก่อน**

---

## ตรวจก่อนเริ่ม — 4 ข้อ

รันบน **master01**:

```bash
set -a && source /root/k8s/versions.env && set +a

ip -4 addr show | grep -q "$VIP" && echo "1. VIP อยู่ที่เครื่องนี้ ✓" || echo "1. VIP ไม่ได้อยู่ที่นี่ — ตรวจก่อน"
ss -lnt | grep -q ':8443' && echo "2. HAProxy ฟังอยู่ ✓"
systemctl is-active containerd | grep -q active && echo "3. containerd ทำงาน ✓"
crictl info | jq -r '.config.containerd.runtimes.runc.options.SystemdCgroup' | grep -q true && echo "4. SystemdCgroup=true ✓"
```

**ต้องได้ ✓ ครบ 4 ข้อ** ถ้าข้อไหนไม่ผ่านให้กลับไปแก้บทก่อนหน้า

> VIP **ไม่จำเป็น** ต้องอยู่ที่ master01 ตอน init (HAProxy จะ forward ให้เอง)
> แต่ทำตอนอยู่ที่ master01 จะไล่ log ง่ายกว่า

---

## 1 · 👑 ดึง image ล่วงหน้า

```bash
kubeadm config images list --kubernetes-version "v${K8S_VERSION}"
kubeadm config images pull --kubernetes-version "v${K8S_VERSION}"
```

**ควรเห็น:** รายการ image และข้อความ `Pulled` ทีละบรรทัด ไม่มี error

> ทำแยกขั้นเพื่อให้แยกได้ว่าปัญหาคือ "ดึง image ไม่ได้" กับ "init ไม่ผ่าน"
> ถ้ารวมกันแล้วพัง จะไล่หาสาเหตุยากกว่า

---

## 2 · 👑 เตรียม config และ init

```bash
mkdir -p /var/log/kubernetes    # ปลายทางของ audit log ที่ระบุใน config

# ตรวจ config ก่อนใช้จริง
kubeadm init phase preflight --config=/root/k8s/config/kubeadm/kubeadm-config.yaml --dry-run 2>&1 | tail -20
```

**สร้าง bootstrap token แล้วใส่ลง config** (หรือลบบล็อก `bootstrapTokens` ออกให้ kubeadm สร้างเอง):

```bash
TOKEN=$(kubeadm token generate)
sed -i "s|<BOOTSTRAP_TOKEN>|${TOKEN}|" /root/k8s/config/kubeadm/kubeadm-config.yaml
```

### 🔴 คำสั่ง init

```bash
kubeadm init \
  --config=/root/k8s/config/kubeadm/kubeadm-config.yaml \
  --upload-certs \
  --skip-phases=addon/kube-proxy \
  | tee /root/k8s/kubeadm-init.log
```

> **`--skip-phases=addon/kube-proxy` ห้ามลืม** — ถ้าลืม kube-proxy จะถูกติดตั้ง
> แล้วไปชนกับ Cilium kube-proxy replacement ในบทที่ 05
> ถ้าเผลอลืม แก้ได้ด้วย `kubectl -n kube-system delete ds kube-proxy` และลบ configmap `kube-proxy`
> แต่ทำให้ถูกตั้งแต่แรกดีกว่า

**ควรเห็นท้ายสุด:**
```
Your Kubernetes control-plane has initialized successfully!
...
You can now join any number of control-plane nodes ...
  kubeadm join 192.168.50.100:8443 --token ... --control-plane --certificate-key ...
Then you can join any number of worker nodes ...
  kubeadm join 192.168.50.100:8443 --token ... 
```

> 🔒 **`kubeadm-init.log` มี certificate key และ token อยู่ข้างใน**
> เก็บให้ปลอดภัย และ **ห้าม commit ลง git** — `certificate-key` หมดอายุใน 2 ชั่วโมง
> ส่วน token หมดตาม `ttl` ที่ตั้งไว้

---

## 3 · 👑 ตั้ง kubeconfig

```bash
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

kubectl cluster-info
```

**ควรเห็น:** `Kubernetes control plane is running at https://192.168.50.100:8443`
← **ต้องเป็น VIP:8443** ถ้าเห็น IP ของ master01 แปลว่า `controlPlaneEndpoint` ไม่ได้ผล ให้หยุดและรื้อทำใหม่

```bash
kubectl get nodes
```
**ควรเห็น:** `k8s-master01   NotReady   control-plane   ...`
**`NotReady` ถูกต้องแล้ว** — เพราะยังไม่มี CNI (จะลงในบทที่ 05)

### เรื่อง `admin.conf` กับ `super-admin.conf`

ตั้งแต่ 1.29 kubeadm สร้างสองไฟล์:

| ไฟล์ | สิทธิ์ | ใช้เมื่อไหร่ |
|---|---|---|
| `/etc/kubernetes/admin.conf` | ผ่าน RBAC ปกติ (`kubeadm:cluster-admins`) | **ใช้ตัวนี้เป็นหลัก** |
| `/etc/kubernetes/super-admin.conf` | bypass RBAC ทั้งหมด | เฉพาะตอนกู้ RBAC พัง |

> `super-admin.conf` มีอยู่แค่บน master01 เท่านั้น **อย่าคัดลอกไปไหน**
> เก็บไว้เป็นทางออกสุดท้ายเวลาเผลอลบ ClusterRoleBinding ของตัวเอง

---

## 4 · 🎩 Join master02 และ master03

รันบน **master02 ก่อน แล้วรอให้เสร็จ** จึงทำ master03 — อย่าทำพร้อมกัน
เพราะ etcd ต้องการให้ member เข้าทีละตัว

```bash
set -a && source /root/k8s/versions.env && set +a
```

ใช้คำสั่งจาก `kubeadm-init.log` — หน้าตาแบบนี้:

```bash
kubeadm join 192.168.50.100:8443 \
  --token <BOOTSTRAP_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> \
  --control-plane \
  --certificate-key <CERTIFICATE_KEY> \
  --cri-socket unix:///run/containerd/containerd.sock
```

### ถ้าเกิน 2 ชั่วโมงไปแล้ว (certificate-key หมดอายุ)

รันบน **master01** เพื่อออกชุดใหม่:

```bash
kubeadm init phase upload-certs --upload-certs        # ได้ certificate-key ใหม่
kubeadm token create --print-join-command             # ได้ token + hash ใหม่
```
แล้วเอาสองอย่างมาต่อกันเป็นคำสั่ง join ข้างบน

**ตรวจหลัง join แต่ละตัว (บน master01):**
```bash
kubectl get nodes
kubectl -n kube-system get pods -l component=etcd -o wide
```
**ควรเห็น:** node เพิ่มขึ้นทีละตัว และมี pod `etcd-k8s-masterXX` เพิ่มตาม

**ตั้ง kubeconfig บน master02/03 ด้วย:**
```bash
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

---

## 5 · ⚙️ Join worker ทั้ง 3 เครื่อง

worker join พร้อมกันได้ ไม่ต้องรอทีละตัว

```bash
kubeadm join 192.168.50.100:8443 \
  --token <BOOTSTRAP_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> \
  --cri-socket unix:///run/containerd/containerd.sock
```

> **ไม่มี `--control-plane` และไม่มี `--certificate-key`** — สองอย่างนี้ใช้เฉพาะ master

ถ้า token หมดอายุ รันบน master01: `kubeadm token create --print-join-command`

---

## 6 · ตรวจสถานะรวม

รันบน **master01**:

```bash
kubectl get nodes -o wide
```

**ควรเห็นครบ 6 เครื่อง สถานะ `NotReady` ทั้งหมด:**
```
NAME            STATUS     ROLES           VERSION   INTERNAL-IP
k8s-master01    NotReady   control-plane   v1.36.3   192.168.50.101
k8s-master02    NotReady   control-plane   v1.36.3   192.168.50.102
k8s-master03    NotReady   control-plane   v1.36.3   192.168.50.103
k8s-worker01    NotReady   <none>          v1.36.3   192.168.50.104
k8s-worker02    NotReady   <none>          v1.36.3   192.168.50.105
k8s-worker03    NotReady   <none>          v1.36.3   192.168.50.106
```

**`NotReady` ทั้งหมดคือสิ่งที่ถูกต้องในขั้นนี้** — จะกลายเป็น `Ready` หลังลง Cilium

**ยืนยันว่าไม่มี kube-proxy:**
```bash
kubectl -n kube-system get ds
```
**ต้องไม่เห็น** `kube-proxy` ในรายการ — ถ้าเห็นแปลว่าลืม `--skip-phases` ให้ลบทิ้ง:
```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
```

**ตรวจ etcd ว่าครบ 3 member และมี leader:**
```bash
kubectl -n kube-system exec -it etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```
**ควรเห็น:** 3 แถว และมีเครื่องเดียวที่ `IS LEADER = true`

**ตรวจว่า HAProxy เห็น backend ขึ้นครบแล้ว** (บน master ตัวใดก็ได้):
```bash
curl -s http://127.0.0.1:8404/stats | grep -o 'k8s-master0[123]' | head
```

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl cluster-info` ชี้ไปที่ **`https://192.168.50.100:8443`**
- [ ] `kubectl get nodes` เห็นครบ **6 เครื่อง** ทุกตัว version `v1.36.3`
- [ ] etcd มี **3 member** และมี leader 1 ตัว
- [ ] **ไม่มี** DaemonSet ชื่อ `kube-proxy`
- [ ] `/etc/kubernetes/pki/` มี cert ครบบน master ทั้ง 3
- [ ] เก็บ `kubeadm-init.log` ไว้ที่ปลอดภัยแล้ว และ**ไม่ได้อยู่ใน git**

**ตรวจอายุ certificate ไว้เป็น baseline:**
```bash
kubeadm certs check-expiration
```
**ควรเห็น:** cert ทั่วไปเหลือ ~364 วัน · CA เหลือ ~3649 วัน
**จดวันหมดอายุลงปฏิทินทีมทันที** — นี่คือสิ่งที่ cluster เดิมพลาดจนต้องรื้อทำใหม่

**➡️ ต่อที่ [บทที่ 05 — Cilium](05-cilium.md)**
