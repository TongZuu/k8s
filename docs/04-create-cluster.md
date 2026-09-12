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

**ถ้าเพิ่งแก้ไฟล์ในrepo ต้องส่งขึ้นเครื่องก่อน** — รันจากrepoบนเครื่องตัวเอง ไม่ใช่บน master01
(ไฟล์ใน `/root/k8s/` เป็นคนละก๊อปปี้กับrepo แก้ในrepoแล้วเครื่องไม่รู้เรื่องด้วย)

```bash
scp config/kubeadm/kubeadm-config.yaml config/kubeadm/audit-policy.yaml root@192.168.50.101:/root/k8s/config/kubeadm/
```

ต่อไปนี้รันบน **master01**:

```bash
# 🔴 audit ต้องครบสองอย่างก่อน init ไม่งั้น apiserver ไม่ขึ้น
mkdir -p /var/log/kubernetes                 # ปลายทางของ audit log
install -D -m 0600 /root/k8s/config/kubeadm/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
ls -l /etc/kubernetes/audit-policy.yaml /var/log/kubernetes
```

> **ทำไมต้องมีไฟล์นี้ก่อน** — `kubeadm-config.yaml` ประกาศ `extraVolumes` แบบ `pathType: File`
> ชี้มาที่ `/etc/kubernetes/audit-policy.yaml` ถ้าไฟล์ไม่มี kubelet จะไม่ยอมสร้าง pod ของ apiserver
> แล้ว `kubeadm init` จะค้างจนหมดเวลา 4 นาทีโดยที่ error ไม่ได้พูดถึง audit เลยสักคำ
>
> **และต้องทำบน master ทุกตัวก่อน join ด้วย** (ดูข้อ 4) เพราะ master02/03 ดึง
> ClusterConfiguration เดียวกันมาสร้าง manifest ของตัวเอง

```bash
# ด่าน 1 — ตรวจเฉพาะไฟล์ config ไม่แตะเครื่อง (เจอค่าผิด/field ผิดตรงนี้)
kubeadm config validate --config=/root/k8s/config/kubeadm/kubeadm-config.yaml
```

**ควรเห็น:** `ok` (ไม่มี error) · exit status 0

```bash
# ด่าน 2 — ตรวจว่าเครื่องพร้อมด้วย (port, swap, containerd, image)
kubeadm init phase preflight --config=/root/k8s/config/kubeadm/kubeadm-config.yaml --dry-run 2>&1 | tail -20
```

> **แยกสองด่านเพราะข้อความ error คนละแบบ** — `config validate` อ่านแค่ไฟล์
> ถ้ามันผ่านแล้ว preflight ยังฟ้อง แปลว่าปัญหาอยู่ที่เครื่อง ไม่ใช่ที่ไฟล์

> **`[ERROR DirAvailable--var-lib-etcd]: /var/lib/etcd is not empty`**
> ปกติคือ `lost+found` ที่ ext4 แถมมากับ partition ที่แยกไว้ในบทที่ 01 ไม่ใช่ข้อมูล etcd
> **ดูก่อนลบเสมอ** — `ls -la /var/lib/etcd`
>
> | เห็นอะไร | แปลว่า | ทำอะไร |
> |---|---|---|
> | มีแค่ `lost+found` | filesystem ใหม่ปกติ | `rm -rf /var/lib/etcd/lost+found` แล้ว preflight ใหม่ |
> | มี `member/` | เคย `kubeadm init` มาก่อน | ต้อง `kubeadm reset -f` ก่อน ห้ามลบมือเปล่า |
> | มีโฟลเดอร์อื่น เช่น `myhr` | ของเก่าที่ติดมาจาก `/home` ตอนย้าย partition | ตรวจว่าไม่มีข้อมูลที่ต้องเก็บ แล้ว `rmdir` (ไม่ใช่ `rm -rf` — `rmdir` จะปฏิเสธถ้าข้างในไม่ว่าง) |
>
> ห้ามแก้ด้วย `--ignore-preflight-errors=DirAvailable--var-lib-etcd` เพราะถ้าเป็นข้อมูลเก่าจริง
> etcd จะขึ้นมาพร้อม member เดิมที่ไม่มีใครรู้จัก แล้วไปพังตอน join

> **`[WARNING Firewalld]`** ไม่ใช่ error — บทที่ 01 ข้อ 8 เปิดพอร์ตไว้ครบแล้ว
> ยืนยันได้ด้วย `firewall-cmd --list-all` (master ต้องมี `6443 8443 2379-2380 10250 10257 10259` และ `protocols: vrrp`)

> **ถ้า preflight ฟ้องแบบนี้:**
> ```
> error: invalid configuration for GroupVersionKind /, Kind=:
> kind and apiVersion is mandatory information that must be specified
> ```
> แปลว่ามี YAML document ที่ไม่มี `kind` อยู่ในไฟล์ config — ไม่ใช่ค่าใน config ผิด
> สาเหตุที่เจอบ่อยสุดคือมี `---` คั่นอยู่ระหว่างคอมเมนต์หัวไฟล์กับบรรทัด `apiVersion:` แรก
> เพราะ kubeadm หั่น document ด้วยการมองหาบรรทัด `---` ตรง ๆ ไม่ได้ parse YAML ก่อน
> คอมเมนต์ที่ถูกคั่นออกมาจึงกลายเป็น document หนึ่งอันที่ไม่มี kind
>
> ข้อความนี้ไม่บอกไฟล์และไม่บอกบรรทัด · ตรวจล่วงหน้าได้ด้วย
> `awk -f config/kubeadm-docsplit.awk config/kubeadm/kubeadm-config.yaml` (อยู่ใน `validate-repo.sh` ข้อ 3 แล้ว)
> · หมายเหตุ: `kubectl apply` ข้าม document ว่างให้เอง ไฟล์อื่นใน `config/` จึงเขียนแบบนั้นได้ไม่พัง

> **ถ้าฟ้องเรื่อง bootstrap token:**
> ```
> error unmarshaling configuration schema.GroupVersionKind{... Kind:"InitConfiguration"}:
> the bootstrap token "" was not of the form "\\A([a-z0-9]{6})\\.([a-z0-9]{16})\\z"
> ```
> คราวนี้ kubeadm อ่านไฟล์ออกแล้ว แต่ค่าข้างในผิด — `token: ""` ไม่ใช่ "ปล่อยว่างให้สุ่มเอง"
> v1beta4 แปลงค่าว่างเป็น token ไม่ได้ · **วิธีให้ kubeadm สุ่มให้คือไม่ใส่ field `token` เลย**
> ([`kubeadm-config.yaml`](../config/kubeadm/kubeadm-config.yaml) แก้แล้ว — ถ้ายังเจอแปลว่าไฟล์บนเครื่องเป็นตัวเก่า)

> **ไม่ต้องสร้าง token เอง** — `bootstrapTokens` ใน [`kubeadm-config.yaml`](../config/kubeadm/kubeadm-config.yaml)
> ไม่มี field `token` จึงให้ kubeadm สุ่มให้เองตอน `init` และมีอายุตาม `ttl: 2h` ที่ระบุไว้
>
> token ที่ได้จะโผล่ในคำสั่ง join ท้าย log · ถ้าหมดอายุแล้วออกใหม่ได้ตลอดด้วย
> `kubeadm token create --ttl 2h --print-join-command` (ดูข้อ 4)

### 🔴 คำสั่ง init

```bash
kubeadm init \
  --config=/root/k8s/config/kubeadm/kubeadm-config.yaml \
  --upload-certs \
  --skip-phases=addon/kube-proxy \
  | tee /root/k8s/kubeadm-init.log
echo "exit=${PIPESTATUS[0]}"        # ต้องเป็น 0 เท่านั้น
```

> **ทำไมต้องมี `PIPESTATUS`** — exit status ของ pipeline คือของ `tee` ไม่ใช่ของ `kubeadm`
> ถ้า `init` ล้มแต่ `tee` เขียนไฟล์สำเร็จ shell จะถือว่าคำสั่งนี้สำเร็จ
> ใครเอาไปใส่ script แล้วเช็ค `$?` จะได้ 0 ทั้งที่ cluster ไม่เกิด

**ระหว่างรอ** ขั้นที่นานที่สุดคือ `[wait-control-plane]` — ถ้าค้างเกิน 1 นาที เปิดอีก terminal แล้วดู:

```bash
crictl ps -a --name kube-apiserver
```

restart รัว ๆ หรือไม่ขึ้นเลย = ดู [บทที่ 13 ข้อ 12.3](13-troubleshooting.md) เกือบทั้งหมดคือ audit policy mount ไม่ได้


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
\cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
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

### ตรวจว่า audit log บันทึกจริง

ตั้ง flag ไว้ไม่ได้แปลว่าได้ log — ต้องเห็นไฟล์โตขึ้นจริงถึงจะนับว่าผ่าน

```bash
ls -l /var/log/kubernetes/audit.log
tail -1 /var/log/kubernetes/audit.log | head -c 300; echo
```

**ควรเห็น:** ไฟล์มีขนาด > 0 และบรรทัดสุดท้ายเป็น JSON ที่มี `"kind":"Event"`

ถ้าไฟล์ไม่มีหรือขนาดเป็น 0:
```bash
crictl logs "$(crictl ps -a --name kube-apiserver -q | head -1)" 2>&1 | grep -i "audit policy"
```
เจอ `No audit policy file provided, no events will be recorded` = apiserver ไม่เห็น policy
(ดู [บทที่ 13 ข้อ 12.3](13-troubleshooting.md))

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

**ลำดับเครื่อง — ทำตามนี้จะสลับเครื่องแค่ 4 ครั้ง ไม่ต้องเด้งไปมา:**

| ขั้น | เครื่อง | ทำอะไร |
|---|---|---|
| 4.1 | 👑 master01 | เตรียมไฟล์ + ออกบัตรผ่าน — **ทำครั้งเดียวใช้ได้ทั้งสองเครื่อง** |
| 4.2 | 🎩 master02 | ทำครบทุกอย่างในเครื่องนี้รวดเดียว จนถึง join เสร็จ |
| 4.3 | 👑 master01 | ตรวจว่า master02 เข้ามาจริง |
| 4.4 | 🎩 master03 | ทำซ้ำ 4.2 แล้วกลับไปตรวจด้วย 4.3 |

> **ห้ามทำ master02 กับ master03 พร้อมกัน** — etcd รับ member ทีละราย
> ต้องเห็น master02 ขึ้นครบใน 4.3 ก่อนถึงจะเริ่ม master03

### 4.1 · 👑 บน master01 — เตรียมของให้ทั้งสองเครื่อง

**ส่ง audit policy ไปทั้ง master02 และ master03:**

```bash
for ip in 102 103; do
  ssh root@192.168.50.$ip 'mkdir -p /root/k8s/config/kubeadm'
  scp /root/k8s/config/kubeadm/audit-policy.yaml root@192.168.50.$ip:/root/k8s/config/kubeadm/
done
```

**ออก certificate-key และคำสั่ง join ชุดใหม่:**

```bash
kubeadm init phase upload-certs --upload-certs | tail -1
kubeadm token create --ttl 2h --print-join-command
```

**เก็บผลลัพธ์สองบรรทัดนี้ไว้** — บรรทัดแรกคือ `certificate-key` บรรทัดที่สองคือคำสั่ง join

> **🔴 คำสั่งที่ `--print-join-command` พิมพ์ออกมาเป็นของ worker เสมอ** — ไม่มี `--control-plane`
> ให้ ถ้าเอาไปรันบน master ตรง ๆ จะได้ worker ที่ชื่อเหมือน master แต่ไม่มี control plane
> ต้องเติมสองบรรทัดนี้เองเสมอ แล้วจะได้หน้าตาแบบในขั้น 4.2:
>
> ```
>   --control-plane \
>   --certificate-key <ค่าจากบรรทัดแรก>
> ```

> **🔴 ค่าที่ใช้ต้องมาจากการรันรอบเดียวกัน** — `upload-certs` เข้ารหัส cert ใหม่ด้วย key ใหม่ทุกครั้ง
> ที่รัน ดังนั้น**พอรันรอบใหม่ key รอบก่อนจะใช้ไม่ได้ทันที** ไม่ต้องรอหมดอายุ
> หยิบ key เก่าจาก `kubeadm-init.log` มาใช้ = `cipher: message authentication failed`
> ตอน join (ดู [บทที่ 13 ข้อ 12.5](13-troubleshooting.md))
>
> ถ้าจะ join ทั้ง master02 และ master03 ให้ใช้ค่าชุดเดียวกันทั้งสองเครื่องได้เลย ภายใน 2 ชั่วโมง
> แต่ถ้าเผลอรัน `upload-certs` คั่นกลาง ต้องเอาค่าชุดใหม่ไปใช้กับเครื่องที่เหลือ

> **`--ttl 2h` ห้ามลืม** — `kubeadm token create` มี default เป็น **24 ชั่วโมง**
> ซึ่งสวนทางกับ `ttl: "2h"` ที่ตั้งใจตั้งไว้ใน `kubeadm-config.yaml` ตั้งแต่ `init`
> ลืมใส่ = แอบมีบัตรผ่านเข้า cluster อายุ 24 ชม. ลอยอยู่โดยไม่มีใครรู้

> **ออกใหม่ทุกครั้ง ไม่ต้องไปงมใน `kubeadm-init.log`** — `certificate-key` หมดอายุใน 2 ชั่วโมง
> และ token หมดตาม `ttl: 2h` ที่ตั้งไว้ · ออกใหม่ถูกกว่าการมานั่งเดาว่าของเก่ายังใช้ได้ไหม
> ทั้งสองคำสั่งรันซ้ำได้ไม่มีผลข้างเคียง

### 4.2 · 🎩 บน master02 — ทำครบทุกอย่างในเครื่องนี้

**เตรียมเครื่อง** — audit policy, ที่เก็บ log, และล้าง `/var/lib/etcd` ให้ว่าง:

```bash
set -a && source /root/k8s/versions.env && set +a
mkdir -p /var/log/kubernetes
install -D -m 0600 /root/k8s/config/kubeadm/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
ls -l /etc/kubernetes/audit-policy.yaml
ls -la /var/lib/etcd
```

**ควรเห็น:** ไฟล์ `audit-policy.yaml` ขนาดไม่เป็น 0 · และ `/var/lib/etcd` **ต้องว่าง**

`/var/lib/etcd` ของ master02/03 ก็มี `lost+found` (และอาจมีโฟลเดอร์เก่าจาก `/home`) เหมือน master01
ถ้าไม่ว่าง `kubeadm join` จะตายที่ preflight ด้วย `[ERROR DirAvailable--var-lib-etcd]`:

```bash
rm -rf /var/lib/etcd/lost+found; rmdir /var/lib/etcd/* 2>/dev/null; ls -A /var/lib/etcd
```

**ควรเห็น:** ไม่มีอะไรพิมพ์ออกมาเลย · ถ้ายังเหลืออะไรอยู่ = มีข้อมูลจริงข้างใน
ห้ามลบทับ ให้ไปดู [บทที่ 13 ข้อ 12.4](13-troubleshooting.md) ก่อน
(ใช้ `rmdir` เพราะมันปฏิเสธถ้าโฟลเดอร์ไม่ว่าง ต่างจาก `rm -rf` ที่ลบทิ้งเงียบ ๆ)

> **warning สองอันนี้ตอน join ปกติ ไม่ต้องแก้:**
> · `No kubeproxy.config.k8s.io/v1alpha1 config is loaded ... configmaps "kube-proxy" is forbidden`
> — ถูกต้องแล้ว เพราะ cluster นี้ไม่มี kube-proxy configmap อยู่จริง (ตั้งใจ skip ไว้ตั้งแต่ `init`)
> · `[WARNING Firewalld]` — เปิดพอร์ตครบแล้วในบทที่ 01 ข้อ 8

> **🔴 ห้ามข้ามขั้นนี้** — master ที่ join ดึง `ClusterConfiguration` จาก configmap `kubeadm-config`
> มาสร้าง manifest ของตัวเอง จึงมี `extraVolumes` ชุดเดียวกับ master01
> ไม่มีไฟล์ policy = apiserver ของเครื่องนี้ไม่ขึ้น อาการจะเป็น
> "join สำเร็จแต่ node ไม่ Ready และ etcd ไม่ครบ" ซึ่งไล่หายากมาก

**join เข้า control plane** — เอาค่าจาก 4.1 มาเติมสามช่อง:

```bash
kubeadm join 192.168.50.100:8443 \
  --token <BOOTSTRAP_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> \
  --control-plane \
  --certificate-key <CERTIFICATE_KEY> \
  --cri-socket unix:///run/containerd/containerd.sock
```

**ตั้ง kubeconfig ให้เครื่องนี้ด้วย** (จะได้ใช้ `kubectl` จาก master02 ได้):

```bash
mkdir -p "$HOME/.kube"
\cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

### 4.3 · 👑 กลับมาที่ master01 — ตรวจว่าเข้าจริง

```bash
kubectl get nodes
kubectl -n kube-system get pods -l component=etcd -o wide
```

**ควรเห็น:** node เพิ่มมาอีกหนึ่งตัว และมี pod `etcd-k8s-master02` เพิ่มตาม

**🔴 `join` สำเร็จ ไม่ได้แปลว่า control plane เครื่องนั้นใช้งานได้** — `kubeadm join --control-plane`
รอแค่ etcd member เข้าครบแล้ว mark node ก็จบ **ไม่ได้รอให้ apiserver ของเครื่องนั้นขึ้น**
ถ้าลืมวาง `audit-policy.yaml` ใน 4.2 คำสั่ง join จะผ่านสวย แต่ apiserver ของเครื่องนั้นไม่เกิด
ต้องดูสองอย่างนี้ถึงจะรู้:

```bash
kubectl -n kube-system get pods -l component=kube-apiserver -o wide
```

**ควรเห็น:** `kube-apiserver-k8s-master02` สถานะ `Running` — ถ้าไม่มีแถวนี้เลยคือ kubelet
ยังสร้าง pod ไม่ได้ · **แก้ได้โดยไม่ต้อง reset หรือ join ใหม่** แค่วางไฟล์ที่ขาดลงไป
kubelet จะสร้าง static pod ให้เองภายในไม่กี่วินาที (รันบนเครื่องที่ขาด):

```bash
install -D -m 0600 /root/k8s/config/kubeadm/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
```

```bash
curl -s "http://127.0.0.1:8404/stats;csv" | awk -F, '$1=="kube-apiserver-backend"{print $2, $18, "check="$37}'
```

**ควรเห็น:** `k8s-master02` เปลี่ยนจาก `DOWN check=L4CON` เป็น `UP check=L7OK` ภายในไม่กี่วินาที
ถ้ายัง `DOWN` อยู่หลังผ่านไปหนึ่งนาที แปลว่า apiserver ของ master02 ไม่ขึ้น —
เกือบทั้งหมดคือลืมขั้นเตรียม audit policy ใน 4.2 (ดู [บทที่ 13 ข้อ 12.3](13-troubleshooting.md))

### 4.4 · 🎩 master03 — ทำซ้ำ

**ผ่าน 4.3 แล้วเท่านั้น** จึงไปทำ 4.2 ทั้งชุดบน master03 แล้วกลับมาตรวจด้วย 4.3 อีกรอบ
ค่า token กับ certificate-key จาก 4.1 ยังใช้ได้ ถ้ายังไม่เกิน 2 ชั่วโมง
**และยังไม่มีใครรัน `upload-certs` คั่นกลาง** — ถ้ารันไปแล้วต้องออกชุดใหม่ตาม 4.1 อีกรอบ
แล้วใช้ค่าใหม่ทั้งคู่

---

## 5 · ⚙️ Join worker ทั้ง 3 เครื่อง

| ขั้น | เครื่อง | ทำอะไร |
|---|---|---|
| 5.1 | 👑 master01 | ออกคำสั่ง join สำหรับ worker |
| 5.2 | ⚙️ worker ทั้ง 3 | join — **ขนานกันได้ ไม่ต้องรอทีละตัว** |
| 5.3 | 👑 master01 | ตรวจว่าเข้าครบ |

### 5.1 · 👑 บน master01

```bash
kubeadm token create --ttl 2h --print-join-command
```

### 5.2 · ⚙️ บน worker แต่ละเครื่อง

เติมค่าจาก 5.1 แล้วรันได้พร้อมกันทั้ง 3 เครื่อง:

```bash
kubeadm join 192.168.50.100:8443 \
  --token <BOOTSTRAP_TOKEN> \
  --discovery-token-ca-cert-hash sha256:<CA_CERT_HASH> \
  --cri-socket unix:///run/containerd/containerd.sock
```

> **ไม่มี `--control-plane` และไม่มี `--certificate-key`** — สองอย่างนี้ใช้เฉพาะ master
>
> **worker ไม่ต้องมี `audit-policy.yaml`** — ไฟล์นั้นใช้กับ kube-apiserver ซึ่งรันบน master เท่านั้น
> และ worker ก็ไม่ต้องตั้ง kubeconfig ด้วย (สั่งงาน cluster จาก master01)

### 5.3 · 👑 กลับมาที่ master01

```bash
kubectl get nodes
```

**ควรเห็น:** ครบ 6 เครื่อง — worker ขึ้นเป็น `ROLES <none>` ซึ่งถูกต้องแล้ว

---

## 6 · 👑 ตรวจสถานะรวม — บน master01 ทั้งหมด

ทุกคำสั่งในข้อนี้รันบน master01 เครื่องเดียว ไม่ต้องย้ายเครื่อง

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

**ตรวจ HAProxy ของ master01 เอง:**
```bash
curl -s "http://127.0.0.1:8404/stats;csv" | awk -F, '$1=="kube-apiserver-backend"{print $2, $18, "check="$37}'
```
**ควรเห็น:** ทั้ง 3 เครื่อง `UP` และ `check=L7OK` — ทุกช่องต้องครบ ไม่ใช่แค่มีชื่อโผล่มา

**ตรวจ HAProxy ของอีกสองเครื่องด้วย — ยิงจาก master01 ไม่ต้องย้ายเครื่อง:**
```bash
for ip in 102 103; do
  echo "--- master$ip ---"
  ssh root@192.168.50.$ip 'curl -s "http://127.0.0.1:8404/stats;csv"' | awk -F, '$1=="kube-apiserver-backend"{print $2, $18, "check="$37}'
done
```

> **ต้องตรวจทั้ง 3 เครื่อง** เพราะ HAProxy ของแต่ละ master ตรวจ backend ของตัวเอง
> และ `check_apiserver.sh` ของ keepalived บนเครื่องนั้นก็อ่านผลจาก HAProxy ตัวเดียวกัน
> เครื่องที่ HAProxy เห็น backend DOWN หมดจะทำให้ VIP ไม่ยอมอยู่กับมัน
>
> `check=L7OK` แปลว่า HAProxy ยิง `GET /healthz` แล้วได้ 200 จริง ·
> ถ้าเห็น `L4CON`/`L6RSP`/`L7STS` ให้ไปที่ [บทที่ 13 ข้อ 1.3](13-troubleshooting.md)
> · เดิมข้อนี้ใช้ `grep -o 'k8s-master0[123]'` ซึ่ง**ผ่านเสมอ** เพราะชื่อ server อยู่ในหน้า stats
> ตั้งแต่ config ถูกโหลด ต่อให้ backend DOWN ครบทั้ง 3 ตัวก็ยัง grep เจอ

### 🔒 เก็บกวาดบัตรผ่าน — ทำหลัง join ครบทุกเครื่องแล้ว

`upload-certs` ฝาก **CA key ของ control plane** ไว้ใน Secret `kubeadm-certs` (เข้ารหัสด้วย
certificate-key ที่พิมพ์ออกมา) ส่วน token ที่ออกไว้ก็ยังใช้ join ได้จนกว่าจะหมดอายุ
ทั้งสองอย่างมีอายุสั้นและหายเองได้ แต่ไม่มีเหตุผลให้เก็บไว้เมื่อ join ครบแล้ว

```bash
kubeadm token list
kubectl -n kube-system get secret kubeadm-certs
```

```bash
kubeadm token list -o jsonpath='{range .items[*]}{.token_id}{"
"}{end}' 2>/dev/null | xargs -r kubeadm token delete
kubectl -n kube-system delete secret kubeadm-certs --ignore-not-found
```

**ควรเห็น:** `kubeadm token list` ว่าง และ Secret หายไป

> ต้องออก token ใหม่ทีหลังก็ทำได้ตลอดด้วย `kubeadm token create --ttl 2h --print-join-command`
> · ถ้าจะเพิ่ม master ทีหลังต้อง `kubeadm init phase upload-certs --upload-certs` ใหม่อีกรอบ
>
> การ join ที่ทำไปแล้วไม่ได้รับผลกระทบเลย — node ที่เข้ามาแล้วใช้ cert ของตัวเองใน
> `/etc/kubernetes/kubelet.conf` ไม่ได้พึ่ง token หรือ Secret นี้อีก

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl cluster-info` ชี้ไปที่ **`https://192.168.50.100:8443`**
- [ ] `kubectl get nodes` เห็นครบ **6 เครื่อง** ทุกตัว version `v1.36.3`
- [ ] etcd มี **3 member** และมี leader 1 ตัว
- [ ] **ไม่มี** DaemonSet ชื่อ `kube-proxy`
- [ ] `/etc/kubernetes/pki/` มี cert ครบบน master ทั้ง 3
- [ ] เก็บ `kubeadm-init.log` ไว้ที่ปลอดภัยแล้ว และ**ไม่ได้อยู่ใน git**
- [ ] ลบ bootstrap token ที่เหลือ และ Secret `kubeadm-certs` ทิ้งแล้ว

**ตรวจอายุ certificate ไว้เป็น baseline:**
```bash
kubeadm certs check-expiration
```
**ควรเห็น:** cert ทั่วไปเหลือ ~364 วัน · CA เหลือ ~3649 วัน
**จดวันหมดอายุลงปฏิทินทีมทันที** — นี่คือสิ่งที่ cluster เดิมพลาดจนต้องรื้อทำใหม่

**➡️ ต่อที่ [บทที่ 05 — Cilium](05-cilium.md)**
