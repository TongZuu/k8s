# บทที่ 05 — Cilium (CNI + kube-proxy replacement + LB-IPAM)

> **รันที่: 👑 master01 เท่านั้น** (Helm กระจายไปทุก node ให้เอง)
> **เวลาที่ใช้:** ~25 นาที
> **ต้องผ่านบทที่ 04** — node ทั้ง 6 ต้องขึ้นครบแล้วในสถานะ `NotReady`

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

---

## 1 · ติดตั้ง Helm 4 และ Cilium CLI

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

```bash
grep -E 'k8sServiceHost|k8sServicePort|clusterPoolIPv4PodCIDRList|kubeProxyReplacement' \
  /root/k8s/config/cilium/values.yaml
```

**ต้องตรงกับ `versions.env`:**

| ค่า | ต้องเป็น |
|---|---|
| `kubeProxyReplacement` | `true` |
| `k8sServiceHost` | `192.168.50.100` (VIP) |
| `k8sServicePort` | `8443` |
| `clusterPoolIPv4PodCIDRList` | `10.246.0.0/16` |

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

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -i 'KubeProxyReplacement'
```
**ควรเห็น:** `KubeProxyReplacement:   True   [<ชื่อ interface ของ node นั้น> 192.168.50.10X ...]`

ถ้าเห็น `False` หรือ `Disabled` **ให้หยุด** — cluster จะไม่มีอะไรทำ Service เลย

**ตรวจว่าไม่มี kube-proxy จริง ๆ:**
```bash
kubectl -n kube-system get ds
kubectl get pods -A | grep -c kube-proxy
```
**ควรเห็น:** ไม่มี `kube-proxy` ในรายการ ds และ grep คืน `0`

---

## 5 · ทดสอบ connectivity เต็มรูปแบบ

Cilium มีชุดทดสอบในตัว ซึ่งครอบคลุมกว่าการ ping เอง — **รันให้ผ่านก่อนไปต่อ**

```bash
cilium connectivity test
```

**ควรเห็นท้ายสุด:** `✅ All ... tests successful`
**ใช้เวลา ~10-15 นาที** และจะสร้าง namespace `cilium-test-1` ชั่วคราว

ถ้าไม่ผ่าน ให้ดูก่อนว่าเป็นเรื่อง firewalld หรือเปล่า:
```bash
# ลองเพิ่ม interface ของ Cilium เข้า trusted zone แล้วทดสอบซ้ำ (ทำทุก node)
firewall-cmd --permanent --zone=trusted --add-interface=cilium_host
firewall-cmd --permanent --zone=trusted --add-interface=cilium_net
firewall-cmd --permanent --zone=trusted --add-interface=cilium_vxlan
firewall-cmd --reload
```

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

นี่คือขั้นที่พิสูจน์ว่า L2 announcement ผ่าน switch ได้จริง
**ถ้าองค์กรเปิด ARP inspection ไว้ ข้อนี้จะพังตรงนี้**

```bash
kubectl create deployment lbtest --image=nginx:alpine --replicas=2
kubectl expose deployment lbtest --type=LoadBalancer --port=80
kubectl get svc lbtest -w
```

**ควรเห็นภายในไม่กี่วินาที:**
```
NAME     TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
lbtest   LoadBalancer   10.247.x.x      192.168.50.200   80:3xxxx/TCP
```

### ทดสอบจากเครื่อง **นอก cluster** — สำคัญมาก

```bash
curl -I http://192.168.50.200
```
**ควรเห็น:** `HTTP/1.1 200 OK` และหน้า nginx

> ⚠️ **ถ้า `EXTERNAL-IP` ขึ้นแต่ curl ไม่ติด = ARP ถูกบล็อก**
> ตรวจจากเครื่องนอก cluster: `arp -n 192.168.50.200` ต้องเห็น MAC ของ worker ตัวใดตัวหนึ่ง
> ถ้าไม่เห็น ให้กลับไปคุยกับทีม network เรื่อง Dynamic ARP Inspection / port security
>
> ทางออกถ้าแก้ไม่ได้: เปลี่ยนไปใช้ BGP mode (ต้องให้ SE ตั้ง peer + เปิด `179/tcp`)
> หรือถอยไปใช้ NodePort แล้วให้ hardware LB ยิงเข้ามา

**ดูว่า node ไหนกำลังตอบ ARP:**
```bash
kubectl -n kube-system get lease | grep l2announce
```

### ทดสอบ failover ของ LB IP

```bash
# หา node ที่ถือ IP อยู่ แล้ว drain มัน
kubectl drain k8s-worker01 --ignore-daemonsets --delete-emptydir-data
# จากเครื่องนอก cluster — curl ต้องกลับมาได้ภายในไม่กี่วินาที
curl -I http://192.168.50.200
kubectl uncordon k8s-worker01
```

**เก็บกวาด:**
```bash
kubectl delete svc lbtest && kubectl delete deployment lbtest
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
- [ ] **curl เข้า LoadBalancer IP จากเครื่องนอก cluster ได้**
- [ ] drain node ที่ถือ IP แล้ว IP ย้ายเองและ curl กลับมาได้
- [ ] ลบ resource ทดสอบทิ้งหมดแล้ว

**➡️ ต่อที่ [บทที่ 06 — ตรวจรับระบบ](06-verify.md)**
