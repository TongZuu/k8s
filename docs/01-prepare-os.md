# บทที่ 01 — เตรียม OS

> **รันที่: 🖥️ ทุกเครื่อง (ทั้ง 6 เครื่อง)**
> **เวลาที่ใช้:** ~20 นาที/เครื่อง · reboot 1 ครั้ง
> บทนี้เหมือนกันหมดทุกเครื่อง ยกเว้น **ขั้นที่ 1** (hostname) และ **ขั้นที่ 5** (partition)

---

## 0 · โหลดตัวแปร

```bash
set -a && source /root/k8s/versions.env && set +a
echo "K8S=$K8S_VERSION  VIP=$VIP  IFACE=$NODE_IFACE"
```

**ควรเห็น:** `K8S=1.36.3  VIP=192.168.50.100  IFACE=ens192`
ถ้าค่าไหนว่าง แปลว่ายังไม่ได้ source — หยุดแล้วแก้ก่อน

---

## 1 · Hostname และ /etc/hosts

รันเฉพาะบรรทัดที่ตรงกับเครื่องที่กำลังทำอยู่:

```bash
hostnamectl set-hostname k8s-master01    # บน 192.168.50.101
hostnamectl set-hostname k8s-master02    # บน 192.168.50.102
hostnamectl set-hostname k8s-master03    # บน 192.168.50.103
hostnamectl set-hostname k8s-worker01    # บน 192.168.50.104
hostnamectl set-hostname k8s-worker02    # บน 192.168.50.105
hostnamectl set-hostname k8s-worker03    # บน 192.168.50.106
```

จากนั้นวาง `/etc/hosts` ชุดเดียวกันนี้ลง **ทุกเครื่อง**:

```bash
# ลบบล็อกเดิมก่อน — ทำให้รันซ้ำได้โดยไม่มีบรรทัดซ้ำ
sed -i '/^# BEGIN k8s cluster$/,/^# END k8s cluster$/d' /etc/hosts

# ไล่รายชื่อเครื่องจาก versions.env ไม่พิมพ์เอง — เพิ่มเครื่องใหม่แล้วบล็อกนี้ตามให้เอง
{
  echo "# BEGIN k8s cluster"
  echo "${VIP}  ${VIP_HOSTNAME}"
  for r in $(grep -oE '^(MASTER|WORKER)[0-9]+_IP=' /root/k8s/versions.env | sed 's/_IP=//' | sort -u); do
      ip="${r}_IP"; nm="${r}_NAME"
      echo "${!ip}  ${!nm}"
  done
  echo "${REGISTRY_IP}  ${REGISTRY_HOST}"
  echo "# END k8s cluster"
} >> /etc/hosts
```

**ตรวจ:**
```bash
sed -n '/^# BEGIN k8s cluster$/,/^# END k8s cluster$/p' /etc/hosts
```
**ควรเห็น:** ครบทุกเครื่องใน `versions.env` + VIP + registry และไม่มีบรรทัดไหนที่ IP ว่าง

> **บล็อกนี้รันซ้ำได้** — `sed` ลบของเดิมก่อนทุกครั้ง และ Ansible ก็ใช้ marker
> `# BEGIN k8s cluster` ชุดเดียวกัน ทำมือแล้วรัน playbook ทับได้เลย ไม่ซ้ำ
>
> ถ้าเครื่องไหนเคยรันด้วย `cat >>` แบบเดิมมาก่อน จะมีบรรทัดค้างอยู่นอกบล็อก
> ล้างทีเดียวด้วย (ทำครั้งเดียวพอ):
> ```bash
> \cp -f /etc/hosts /etc/hosts.bak
> sed -i -E '/^# BEGIN k8s cluster$/,/^# END k8s cluster$/!{/^[0-9.]+[[:space:]]+(k8s-(vip|master[0-9]+|worker[0-9]+)|registry\.myhr\.co\.th)[[:space:]]*$/d}' /etc/hosts
> grep -c k8s-master01 /etc/hosts    # ต้องได้ 1
> ```

> **เพิ่มเครื่องใหม่เข้า cluster** ให้แก้ [`versions.env`](versions.env) กับ
> [`inventory.ini`](../ansible/inventory.ini) แล้วรันบล็อกนี้ใหม่บน**ทุกเครื่อง**
> (หรือ `ansible-playbook prepare-os.yml` ซึ่งวางบล็อกเดียวกันให้ทั้ง cluster)
> — ขั้นตอนเต็มอยู่ที่ [บทที่ 12 · เพิ่ม worker](12-day2-operations.md)

> `/etc/hosts` ใช้ได้แต่เปราะ — เพิ่ม node ทีต้องไปแก้ทุกเครื่อง
> ถ้าทีม network ทำ DNS record ให้ได้ ให้ย้ายไป DNS แล้วลบบล็อกนี้ทิ้ง

**ตรวจ:**
```bash
# ดูก่อนว่าตัวแปรขยายครบจริง ไม่มีบรรทัดไหนเหลือ ${...}
tail -8 /etc/hosts

hostname && ping -c1 ${MASTER01_NAME} && ping -c1 ${REGISTRY_HOST}
```
**ควรเห็น:** ชื่อเครื่องถูกต้อง และ ping ทั้งสองปลายทางได้

---

## 1.1 · ตั้ง resolver option — ทำให้ทุกอย่างที่เหลือเร็วขึ้น 6 เท่า

**ค่าตั้งต้นของ glibc ทำให้ทุกการแปลงชื่อใหม่ช้าลง 5 วินาที บนเครือข่ายชุดนี้**

resolver ยิงคำถาม `A` (IPv4) กับ `AAAA` (IPv6) ออกไปพร้อมกันบน socket เดียว
firewall/NAT ระหว่างทางทิ้งคำตอบตัวที่สองบางครั้ง resolver จึงรอจนครบ timeout 5 วินาที
แล้วค่อยถามใหม่ — **ทุกครั้งที่เป็นชื่อที่ยังไม่เคยถาม**

วัดผลจริงบน master01: `helm show chart` ของ Envoy Gateway (ไฟล์ไม่กี่ร้อย KB)

| | เวลา |
|---|---|
| ก่อนแก้ | **26.9 วินาที** |
| หลังแก้ | **4.1 วินาที** |

> อาการนี้มองไม่ออกจากอะไรเลยนอกจากจับเวลา ไม่มี error ไม่มี log
> ทุกคำสั่งทำงานสำเร็จหมด แค่ "รู้สึกว่าเน็ตช้า" ซึ่งเป็นข้อสรุปที่ผิด —
> เลข `user`/`sys` ของ `time` ต่ำมาก แปลว่าเครื่องนั่งรออยู่เฉย ๆ ไม่ได้ทำงาน
>
**ขอบเขตของปัญหานี้ — กระทบอะไรบ้าง:**

| อะไร | แปลชื่อด้วย | กระทบ |
|---|---|---|
| pod → service ภายใน (`xxx.svc.cluster.local`) | CoreDNS ใน cluster | ไม่ |
| pod → pod ด้วย IP · etcd · apiserver ผ่าน VIP | ไม่ใช้ DNS / `/etc/hosts` | ไม่ |
| **containerd ดึง image** | resolv.conf ของ node | **ใช่** |
| **pod → ชื่อภายนอก** | CoreDNS forward ต่อไปที่ resolv.conf ของ node | **ทางอ้อม** |
| pod ที่ตั้ง `dnsPolicy: Default` (CoreDNS เองก็ใช้) | resolv.conf ของ node ตรง ๆ | **ใช่** |

> **"ดึง image ช้า" ไม่ได้จบที่ตอนติดตั้ง** — containerd ดึง image ใหม่ทุกครั้งที่ pod
> ไปเกิดบน node ที่ยังไม่มี image นั้น คือตอน scale out · ตอน reschedule ·
> และ**ทุกครั้งที่ drain node ซึ่งเราทำทุก 1-2 เดือน** ([บท 12](12-day2-operations.md))
> สิ่งที่เห็นหน้างานคือ pod ค้าง `ContainerCreating` นานผิดปกติ
> ซึ่งไม่มีอะไรชี้กลับมาที่ DNS เลยสักอย่าง

> **pod รับ `options` ชุดนี้ไปด้วย** — kubelet เอา options จาก resolv.conf ของ node
> ไปผสมให้ pod ไม่ได้เขียนใหม่ทั้งหมด ซึ่งไม่เป็นปัญหา: `single-request-reopen`
> เพิ่มรอบเดินทางไป CoreDNS หนึ่งรอบซึ่งอยู่ในหลักไมโครวินาที และ `timeout:2`
> ยังสั้นกว่า default 5 วินาทีด้วยซ้ำ ตรวจของจริงได้ที่:
> ```bash
> kubectl -n kube-system exec deploy/coredns -- cat /etc/resolv.conf
> ```

**หาชื่อ connection ของ NetworkManager ก่อน:**
```bash
CONN=$(nmcli -g GENERAL.CONNECTION device show "${NODE_IFACE}" | head -1)
echo "connection = [$CONN]"
```
**ควรเห็น:** ชื่อในวงเล็บไม่ว่าง — ถ้าว่างแปลว่า `NODE_IFACE` ใน `versions.env` ไม่ตรงกับ
interface จริง ตรวจด้วย `ip -br a` แล้วแก้ไฟล์ก่อน

**ตั้งค่า:**
```bash
nmcli connection modify "$CONN" ipv4.dns-options "single-request-reopen,timeout:2,attempts:2"
nmcli connection up "$CONN"
grep ^options /etc/resolv.conf
```
**ควรเห็น:** `options single-request-reopen timeout:2 attempts:2`

> 🔴 **ห้ามแก้ `/etc/resolv.conf` ตรง ๆ** — บรรทัดแรกของไฟล์เขียนว่า
> `# Generated by NetworkManager` แก้แล้วมันเขียนทับคืนตอน reboot หรือ restart network
> ซึ่งเป็นกับดักที่แย่เป็นพิเศษ เพราะของหายไปเงียบ ๆ หลังจากที่ทดสอบผ่านไปแล้ว
> **และเครื่องที่ติดตั้งใหม่จะได้ค่าเดิมกลับมาทุกครั้ง** จึงต้องอยู่ใน playbook ไม่ใช่ทำมือ

**พิสูจน์ว่าได้ผลจริง — ต้องจับเวลา ดูเฉย ๆ ไม่รู้เรื่อง:**
```bash
time getent ahosts auth.docker.io > /dev/null
```
**ควรเห็น:** `real` ต่ำกว่า 1 วินาที (ถ้ายังเห็น ~5 วินาที แปลว่ายังไม่ติด)

> ถ้ายังรู้สึกช้าอยู่ ลองเปลี่ยนเป็น `single-request` (ไม่มี `-reopen`) ซึ่งบังคับให้ถาม
> `A` เสร็จก่อนแล้วค่อยถาม `AAAA` แทนที่จะยิงพร้อมกัน แลกด้วย round trip เพิ่มหนึ่งครั้ง
> แต่ตัดปัญหาคำตอบหายทิ้งไปเลย — เอาอันที่วัดแล้วเร็วกว่า

> 📋 **ยังค้าง: nameserver ควรเป็นของภายใน ไม่ใช่ `8.8.8.8`**
> public DNS แปลชื่อ `registry.myhr.co.th` ไม่ได้ เราจึงต้องพึ่ง `/etc/hosts` ในข้อ 1
> และ [บทที่ 07](07-gateway-tls.md) จบด้วยการต้องมี record ของ `*.myhr.co.th`
> ชี้มาที่ Gateway IP ซึ่งก็ต้องใช้ DNS ภายในเหมือนกัน
> ถ้าองค์กรมี DNS server ภายใน ให้ตั้งเป็นตัวแรกแล้วให้ public DNS เป็นตัวสำรอง:
> ```
> nmcli connection modify "$CONN" ipv4.dns "<DNS ภายใน> 8.8.8.8" ipv4.ignore-auto-dns yes
> ```
> จะแก้ทั้งเรื่องช้าและตัดความจำเป็นของ `/etc/hosts` ไปพร้อมกัน

---

## 1.2 · ปิด IPv6 ที่ interface

**เครื่องได้ IPv6 address มาแต่ไม่มี route ออกไปข้างนอก** ซึ่งแย่กว่าไม่มี IPv6 เลย
เพราะโปรแกรมเห็นว่าตัวเองมี IPv6 ใช้ได้ ก็เลือกใช้ แล้วไปตายกลางทาง

อาการจริงที่เจอตอนลง Envoy Gateway:
```
Error: INSTALLATION FAILED: failed to perform "Fetch" on source:
Get "https://production.cloudfront.docker.com/...":
dial tcp [2600:1f18:21e1:b400:9:4855:aac0:93a1]:443: connect: network is unreachable
```

> **สิ่งที่ยืนยันแล้วบนเครื่องจริง:** `curl` ต่อ IPv6 ไม่ได้ (`curl: (7)`) แต่ `curl -4` ได้ `401`
> ปกติ · `ip -6 addr` มีแค่ `fe80::` (link-local) และ **ไม่มี default route ของ IPv6**
> · `helm install` รอบหนึ่งล้มด้วย error ข้างบน อีกรอบผ่าน — **เกิดเป็นครั้งคราว
> ไม่ใช่ทุกครั้ง** ขึ้นกับว่ารอบนั้นหยิบ address ตัวไหนมาใช้
>
> ที่ยังไม่ได้พิสูจน์คือ *ทำไม*บางรอบถึงไม่ถอยไป IPv4 — แต่ไม่ต้องรู้ก็ตัดสินใจได้
> เพราะสิ่งที่แน่นอนคือ **เครื่องมี IPv6 address ที่ใช้งานออกข้างนอกไม่ได้เลย**
> การเก็บมันไว้ไม่มีประโยชน์ มีแต่โอกาสให้โปรแกรมหยิบไปใช้แล้วล้ม
>
> อาการแบบ "ลองใหม่แล้วผ่าน" อันตรายกว่าล้มทุกครั้ง เพราะจะไปโผล่อีกทีตอน worker
> ดึง image ในบทหลัง ในรูป `ImagePullBackOff` ที่ทำซ้ำไม่ได้

**ตรวจก่อน:**
```bash
ip -6 addr show "${NODE_IFACE}" | grep inet6
ip -6 route show default || echo "ไม่มี default route ของ IPv6"
```
**ถ้ามี address แต่ไม่มี default route** = ต้องปิด

**ปิด:**
```bash
CONN=$(nmcli -g GENERAL.CONNECTION device show "${NODE_IFACE}" | head -1)
nmcli connection modify "$CONN" ipv6.method disabled
nmcli connection up "$CONN"

ip -6 addr show "${NODE_IFACE}" | grep -c inet6
```
**ควรเห็น:** `0`

> **ปิดที่ interface ไม่ใช่ `sysctl disable_ipv6` ทั้งเครื่อง** — แคบกว่า และ NetworkManager
> จำค่าไว้ข้าม reboot ให้เอง เหมือนกับ `dns-options` ในข้อ 1.1
>
> **ปลอดภัยกับ Cilium** — cluster นี้เป็น IPv4 ล้วน (`POD_CIDR` และ `SVC_CIDR` เป็น IPv4)
> และ [`cilium/values.yaml`](../config/cilium/values.yaml) ไม่ได้เปิด `ipv6` ไว้
> ถ้าวันหนึ่งจะใช้ IPv6 จริง ต้องกลับมาแก้ทั้งสองที่พร้อมกัน
>
> **ต้องทำครบทั้ง 6 เครื่อง** — เครื่องที่ตกหล่นจะดึง image ไม่ได้เป็นครั้งคราวแบบสุ่ม
> ขึ้นกับว่า DNS ตอบ IPv6 มาก่อนหรือเปล่าในครั้งนั้น ซึ่งเป็นอาการที่ทำซ้ำไม่ได้

---

## 2 · ยืนยัน kernel และตรึงไว้

Oracle Linux ให้ kernel มาสองตัว เราใช้ **UEK 8U2** ตามค่า default
**ห้ามผสม UEK กับ RHCK ใน cluster เดียวกัน** เด็ดขาด

```bash
uname -r
```

**ควรเห็น:** ลงท้าย `el9uek` และขึ้นต้น `6.12.0-` เช่น `6.12.0-206.104.3.3.el9uek.x86_64`

> **เลขที่รันอยู่กับเลขที่จะบูตรอบหน้าอาจไม่ใช่ตัวเดียวกัน** — ISO/template ลง kernel
> รุ่นหนึ่ง แล้ว `dnf update` ตอนติดตั้งดึงรุ่นใหม่มาวางไว้แต่ยังไม่ได้บูต ดูทั้งสองค่า:
>
> ```bash
> uname -r                          # ที่รันอยู่ตอนนี้
> grubby --default-kernel           # ที่จะบูตรอบหน้า
> rpm -q kernel-uek                 # ที่ติดตั้งไว้ทั้งหมด
> ```
>
> `KERNEL_UEK` ใน `versions.env` เป็นแค่**สาย** (`6.12`) ไม่ใช่เลขเต็ม — ทั้งสองค่าข้างบน
> จึงผ่านตราบที่ยังเป็น `6.12.x-…uek` · เจอจริง 11 ก.ย. 2026: 6 เครื่องรัน 105/203 ปนกัน
> แต่ทุกเครื่องมี 206 รอบูต — ถ้าคุมเลขเต็มจะตรงกับใครก็ไม่ครบ จึงตกลงคุมแค่สาย
> ส่วน "ทุกเครื่องต้องเลขเดียวกัน" ให้ alert `NodeKernelVersionMismatch` (บท 09) จับ

> **สิ่งที่บังคับคือสาย `6.12` และต้องเป็น `uek`** — สองอย่างนี้เปลี่ยน feature set
> ที่ Cilium ใช้จริง ถ้าเห็น `5.14` (RHCK) หรือ `6.13` **ให้หยุดทันที**
> 
> **หางเลขต่างกัน (203/204/205) ไม่ทำให้ cluster พัง** — เป็น errata ของ Oracle
> แต่ควรทำให้ตรงกันอยู่ดี เพราะวันที่มีอาการแปลกเฉพาะ node เดียว คำถามแรก
> ที่ทุกคนถามคือ *"เครื่องนี้ต่างจากเครื่องอื่นตรงไหน"* — ถ้า kernel ตรงกันหมด
> ตอบได้ใน 5 วินาที ถ้าไม่ตรงต้องเสียเวลาพิสูจน์ว่าไม่เกี่ยว
> 
> **ทำให้ตรงตอนยังไม่มี workload ถูกที่สุด** — reboot ได้อิสระ ไม่ต้อง drain ไม่ต้องรอ PDB

ถ้าเครื่องบูต RHCK อยู่ (ไม่มีคำว่า `uek`) ให้สลับกลับ:

```bash
grubby --info=ALL | grep -E '^(index|kernel)' | grep -B1 uek
grubby --set-default /boot/vmlinuz-*uek*.x86_64
reboot
```

**ตรึงเวอร์ชันไม่ให้ `dnf update` ยก kernel เอง:**

```bash
dnf install -y python3-dnf-plugin-versionlock
dnf versionlock add kernel-uek kernel-uek-core kernel-uek-modules
dnf versionlock list
```

> `prepare-os.yml` ทำข้อนี้ให้เอง (ลง plugin + ล็อก ถ้ายังไม่ได้ล็อก) — ทำมือเฉพาะ
> ตอนไม่ได้ใช้ Ansible

**ควรเห็น:** รายการ `kernel-uek-*` โผล่ในลิสต์ versionlock

> **สำคัญ:** ตอน patch kernel ตามรอบ (บทที่ 12) ต้อง `dnf versionlock delete` ชั่วคราว
> แล้ว **ล็อกกลับทันทีหลัง reboot** ไม่งั้น node จะค่อย ๆ ไหลไปคนละเวอร์ชันโดยไม่มีใครรู้

---

## 3 · จัดการ repo

ปิด repo ที่จะไปทับของที่เราติดตั้งเอง:

```bash
# ol9_addons มี containerd ของ Oracle ซึ่งจะไปทับตัวที่เราลงจาก tarball ในบทที่ 02
dnf config-manager --disable ol9_addons 2>/dev/null || true

# เปิดเฉพาะที่ต้องใช้
dnf config-manager --enable ol9_baseos_latest ol9_appstream ol9_UEKR8

dnf repolist enabled
```

**ควรเห็น:** มีแค่ `ol9_baseos_latest`, `ol9_appstream`, `ol9_UEKR8` (+ repo ของ Kubernetes ที่จะเพิ่มในขั้นที่ 8)
**ต้องไม่เห็น** `ol9_addons`

**ปิด Ksplice** — เราใช้ Oracle Linux แบบฟรีจึงไม่มีสิทธิ์ใช้ ปล่อยไว้จะได้แค่ log error รกทุกวัน:

```bash
systemctl disable --now ksplice-uptrack.service 2>/dev/null || true
```

---

## 4 · ลง package พื้นฐาน

```bash
dnf install -y \
  chrony open-vm-tools tar curl wget \
  iproute-tc socat conntrack-tools ethtool \
  bash-completion jq

systemctl enable --now chronyd
```

**ตรวจเวลา — ข้อนี้ห้ามข้าม เพราะ TLS cert และ etcd raft พังทันทีถ้าเวลาเพี้ยน:**

```bash
chronyc tracking | grep -E 'Reference ID|System time|Leap status'
```

**ควรเห็น:** `Leap status : Normal` และ `System time` ต่างไม่เกินหลัก **มิลลิวินาที**
ถ้าเห็น `Not synchronised` ให้หยุดแล้วแก้ NTP ก่อน

---

## 5 · ย้าย partition `/home` — ทางเลือก ไม่ใช่ข้อบังคับ

Kubernetes ไม่ใช้ `/home` เลย ขณะที่ของที่โตเร็วทั้งหมดไปกองใต้ `/var`
ย้าย partition 100 GB นี้ไปรับงานที่มีประโยชน์แทน

> ⚠️ ทำ **ก่อน** ติดตั้ง containerd และก่อน `kubeadm init` — ย้ายทีหลังต้องหยุด service

> **ข้ามข้อนี้ได้ และ `prepare-os.yml` ไม่บล็อกแล้ว** (11 ก.ย. 2026)
> master disk 400 GB · worker 500 GB · `/home` กินแค่ 100 GB → `/var` เหลือ 300-400 GB
> ซึ่งเกินพอ · etcd ใช้ระดับ GB ส่วน containerd cache ระดับสิบ GB
>
> **สิ่งที่ได้จากการทำข้อนี้** มีอย่างเดียวคือ **กำแพงกันพื้นที่** — วันที่ image cache
> หรือ log บวมผิดปกติ มันจะเต็มแค่ partition ตัวเองแทนที่จะลาก `/` ไปด้วย
> · **ไม่ได้ช่วยเรื่องความเร็วของ etcd** เพราะ LV ทั้งสองอยู่บน datastore ก้อนเดียวกัน
>
> **ผลพลอยได้ของการไม่ทำ:** กับดัก `lost+found` ข้างล่างหายไปเลย เพราะ
> `/var/lib/etcd` จะเป็นแค่โฟลเดอร์เปล่าบน `/` ที่ kubeadm นับว่าว่างอยู่แล้ว

**ดูก่อนว่า `/home` คือ device อะไร:**
```bash
lsblk -f
findmnt /home
```

### 🎩 บน master ทั้ง 3 เครื่อง — ย้ายไปเป็น `/var/lib/etcd`

```bash
HOME_DEV=$(findmnt -no SOURCE /home)
echo "จะย้าย $HOME_DEV ไปเป็น /var/lib/etcd"

umount /home
mkdir -p /var/lib/etcd
sed -i 's|[[:space:]]/home[[:space:]]|  /var/lib/etcd  |' /etc/fstab
mount -a
chmod 700 /var/lib/etcd
rm -rf /var/lib/etcd/lost+found       # ext4 แถมมาให้ทุก filesystem — kubeadm จะนับว่าไม่ว่าง
ls -A /var/lib/etcd                   # ต้องไม่พิมพ์อะไรเลย
```

> **`lost+found` ต้องลบ** — บทที่ 04 จะตายที่ preflight ด้วย
> `[ERROR DirAvailable--var-lib-etcd]: /var/lib/etcd is not empty`
> เพราะ kubeadm ขอ dataDir ที่ว่างเปล่าจริง ๆ ไม่สนว่าข้างในเป็นของ filesystem เอง
> ลบได้ปลอดภัย · `e2fsck` สร้างคืนให้เองเมื่อจำเป็น (หรือสั่ง `mklost+found` เอง)
>
> **ถ้า `ls -A` ยังมีอย่างอื่นโผล่มา** แปลว่าเป็นของเดิมที่เคยอยู่ใน `/home` (เช่นโฟลเดอร์ของผู้ใช้)
> ตรวจให้แน่ว่าไม่มีอะไรต้องเก็บ แล้วเอาออกด้วย `rmdir` ทีละอัน — มันจะปฏิเสธถ้าข้างในไม่ว่าง
> ต่างจาก `rm -rf` ที่ลบข้อมูลทิ้งโดยไม่เตือน

### ⚙️ บน worker ทั้ง 3 เครื่อง — ย้ายไปเป็น `/var/lib/containerd`

```bash
HOME_DEV=$(findmnt -no SOURCE /home)
echo "จะย้าย $HOME_DEV ไปเป็น /var/lib/containerd"

umount /home
mkdir -p /var/lib/containerd
sed -i 's|[[:space:]]/home[[:space:]]|  /var/lib/containerd  |' /etc/fstab
mount -a
```

**ตรวจทั้งสองแบบ:**
```bash
findmnt /var/lib/etcd || findmnt /var/lib/containerd
grep -v '^#' /etc/fstab | grep -E 'etcd|containerd'
```
**ควรเห็น:** mount point ใหม่ขึ้นมา และไม่มีบรรทัด `/home` เหลือใน fstab แล้ว

> **ทำไมต้องแยก** — บน master ถ้า image กิน root จนเต็ม etcd จะเขียนไม่ได้และ **ทั้ง cluster หยุด**
> บน worker ถ้า image เต็ม root จะทำให้ `/var/log` เขียนไม่ได้จน node กลายเป็น `NotReady` ทั้งเครื่อง
>
> **หมายเหตุ:** ถ้า 400/500 GB เป็น VMDK ลูกเดียวแบ่ง partition จะได้แค่ **แยกพื้นที่** ไม่ได้แยก I/O
> ให้วัด fsync ในขั้นที่ 9 แล้วตัดสินว่าต้องขอ VMDK แยกให้ etcd ไหม

---

## 6 · kernel module และ sysctl

```bash
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system >/dev/null
```

**ตรวจ:**
```bash
lsmod | grep -E '^overlay|^br_netfilter'
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
```
**ควรเห็น:** ทั้งสอง module โหลดอยู่ และ sysctl ทั้งสองค่าเป็น `= 1`

> ต้องโหลด `br_netfilter` **ก่อน** ตั้ง sysctl ไม่งั้น `net.bridge.*` จะ set ไม่ติด
> ไฟล์ `/etc/modules-load.d/k8s.conf` คือสิ่งที่ทำให้มันยังอยู่หลัง reboot
> — คู่มือชุดเดิมไม่มีไฟล์นี้ พอ reboot แล้ว pod จึงคุยข้าม node ไม่ได้

---

## 7 · ปิด swap และตั้ง SELinux

```bash
swapoff -a
sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

**ตรวจ:**
```bash
free -h | grep -i swap
getenforce
grep -i '^SELINUX=' /etc/selinux/config
```
**ควรเห็น:** swap ทุกช่องเป็น `0B` · `getenforce` คืน `Permissive` · ไฟล์ config เป็น `SELINUX=permissive`

> **SELinux permissive คือการยอมรับความเสี่ยง ไม่ใช่ best practice**
> เป็นแนวทางมาตรฐานของ kubeadm เพื่อเลี่ยง denial ตอน container เขียน volume
> ถ้าองค์กรมีข้อกำหนดว่าต้อง `enforcing` ต้องทำ policy module เพิ่มและทดสอบใน lab ก่อน

---

## 8 · firewalld

firewalld **เปิดอยู่** ตามที่ทีมยืนยัน จึงต้องเปิดพอร์ตให้ครบ
ถ้าขาดข้อใดข้อหนึ่ง อาการจะไปโผล่ตอน `kubeadm init` หรือตอน pod คุยข้าม node

### 🎩 บน master ทั้ง 3 เครื่อง

```bash
firewall-cmd --permanent --add-port=6443/tcp          # kube-apiserver
firewall-cmd --permanent --add-port=8443/tcp          # HAProxy frontend (VIP)
firewall-cmd --permanent --add-port=2379-2380/tcp     # etcd client + peer
firewall-cmd --permanent --add-port=2381/tcp          # etcd metrics (บท 09)
firewall-cmd --permanent --add-port=10250/tcp         # kubelet API
firewall-cmd --permanent --add-port=10257/tcp         # controller-manager
firewall-cmd --permanent --add-port=10259/tcp         # scheduler
firewall-cmd --permanent --add-port=9100/tcp          # node-exporter (บท 09)
firewall-cmd --permanent --add-protocol=vrrp          # keepalived เลือก master
firewall-cmd --permanent --add-port=8472/udp          # Cilium VXLAN
firewall-cmd --permanent --add-port=4240/tcp          # Cilium health
firewall-cmd --permanent --add-port=4244-4245/tcp     # Hubble
firewall-cmd --reload
```

### ⚙️ บน worker ทั้ง 3 เครื่อง

```bash
firewall-cmd --permanent --add-port=10250/tcp         # kubelet API
firewall-cmd --permanent --add-port=30000-32767/tcp   # NodePort range
firewall-cmd --permanent --add-port=9100/tcp          # node-exporter (บท 09)
firewall-cmd --permanent --add-port=8472/udp          # Cilium VXLAN
firewall-cmd --permanent --add-port=4240/tcp          # Cilium health
firewall-cmd --permanent --add-port=4244-4245/tcp     # Hubble
firewall-cmd --reload
```

**ตรวจทั้งสองแบบ:**
```bash
firewall-cmd --list-all
```
**ควรเห็น:** พอร์ตครบตามรายการของบทบาทนั้น และ master ต้องมี `protocols: vrrp`

### 🔴 เปิดทางเข้าออกวง pod — ทำทุกเครื่อง ห้ามข้าม

เปิดพอร์ตอย่างเดียว**ไม่พอ** พอร์ตข้างบนคุมแค่ traffic ที่ปลายทางเป็นตัวเครื่องเอง
และมาจาก `ens192` — traffic ของ pod ผ่านทางที่ firewalld ปิดอยู่อีก **2 ทาง**:

1. **`FORWARD` — จากข้างนอกไปหา pod** (NodePort · LoadBalancer IP) · zone `public` มีแค่ `ens192`
   และ `forward: yes` อนุญาตเฉพาะ `ens192` → `ens192` ส่วน packet ที่ไปหา pod ต้องออกทาง `lxc...`
   ที่ Cilium สร้างแบบไดนามิกและ**ไม่อยู่ใน zone ไหนเลย** → policy `kube-pods` ข้างล่างเปิดให้
2. **`INPUT` — จาก pod เข้า host stack** · Envoy L7 proxy และ DNS proxy ของ Cilium ฟังอยู่บน host
   ไม่ใช่ใน pod · packet จาก pod เข้ามาทาง `lxc...` ตกไป zone `public` ซึ่งไม่มีพอร์ตของ proxy
   (สุ่ม 10000-20000) → `reject` → ทุกอย่างที่ผ่าน L7 policy timeout · บรรทัด `--zone=trusted
   --add-source` เปิดให้ (source ชนะ interface ใน firewalld — ใช้ได้ไม่ว่า packet เข้าทางไหน)

**⚙️ รันทุกเครื่องทั้ง 6:**
```bash
set -a && source /root/k8s/versions.env && set +a

firewall-cmd --permanent --new-policy=kube-pods
firewall-cmd --permanent --policy=kube-pods --add-ingress-zone=ANY
firewall-cmd --permanent --policy=kube-pods --add-egress-zone=ANY
firewall-cmd --permanent --policy=kube-pods --set-target=CONTINUE
firewall-cmd --permanent --policy=kube-pods --add-rich-rule="rule family=ipv4 destination address=${POD_CIDR} accept"
firewall-cmd --permanent --policy=kube-pods --add-rich-rule="rule family=ipv4 source address=${POD_CIDR} accept"
firewall-cmd --permanent --zone=trusted --add-source=${POD_CIDR}
firewall-cmd --reload
```

**ตรวจ:**
```bash
firewall-cmd --info-policy=kube-pods; firewall-cmd --zone=trusted --list-sources
```
**ควรเห็น:** `target: CONTINUE` · `ingress-zones: ANY` · `egress-zones: ANY` · rich rule 2 บรรทัด
· บรรทัดสุดท้าย `10.246.0.0/16`

> 🔴 **อาการถ้าลืมข้อนี้ — หาสาเหตุยากที่สุดในชุด (เจอจริง 6 ก.ย. 2026)**
> SSH เข้า node ได้ปกติ (`INPUT`) แต่ **NodePort และ LoadBalancer IP เข้าไม่ได้เลย**
> จากเครื่องนอกคลัสเตอร์ ขณะที่ node ยิงหากันเองได้หมด
>
> ทุกอย่างจะดูถูกต้องไปหมด — Gateway ได้ `ADDRESS` · HTTPRoute `Accepted=True` ·
> Cilium ตอบ ARP ให้ LB IP · BPF map มี backend ครบ · conntrack สร้าง entry ให้ ·
> `cilium monitor` ไม่มี drop สักบรรทัด · `curl` จาก node ได้ `302`
>
> ตัวชี้ขาดคือ `tcpdump` บน node: **เห็น SYN เข้ามาแล้วไม่มี SYN-ACK ตอบกลับ**
>
> `target: CONTINUE` + rich rule 2 ข้อ = เปิดเฉพาะ traffic ที่เกี่ยวกับวง pod
> ไม่ได้เปิด forward ทั้งเครื่อง

> 🔴 **อาการถ้าลืมบรรทัด `--add-source` (เจอจริง 17 ก.ย. 2026)** — `cilium connectivity test`
> ในบท 05 ตก 26 เทสต์ ทุกตัวเป็นเทสต์ที่มี L7 policy (`echo-ingress-l7` · `client-egress-l7-*` ·
> `tls-sni` · `to-fqdns`) ด้วย `exit code 28` (timeout) ขณะที่ `pod-to-pod` และ `no-policies` ผ่าน
> · ตกทั้ง pod บน node เดียวกันและคนละ node · Hubble ไม่มี drop เพราะ firewalld ทิ้งใน host stack
> หลังจาก BPF ส่งต่อไปแล้ว · เติม source แล้วรันเฉพาะกลุ่มที่ตก → ผ่านทันที (60/60 action)

---


> **ไม่ต้องเปิด `10256/tcp`** (kube-proxy health) เพราะเราไม่ติดตั้ง kube-proxy
> **ไม่ต้องเปิด `179/tcp`** (BGP) เพราะใช้ L2 announcement ไม่ใช่ BGP mode

### หมายเหตุ — interface ของ Cilium กับ firewalld

**ไม่ต้อง**เอา `cilium_host` / `cilium_net` / `cilium_vxlan` เข้า zone `trusted` — ทดสอบแล้ว
(17 ก.ย. 2026) ว่าสิ่งที่ขาดคือ **source** ของวง pod ไม่ใช่ interface (packet จาก pod เข้ามาทาง
`lxc...` ซึ่งชื่อสุ่ม ใส่ใน zone ไม่ได้) · ข้อ 8.1 ข้างบนครอบคลุมแล้ว

> ยังต้องทดสอบว่า `firewall-cmd --reload` ตอน Cilium รันอยู่แล้ว pod ยังคุยกันได้ (บท 05 ข้อ 5)
> เพราะ firewalld เขียนกฎ nftables ใหม่ทั้งชุดตอน reload · **จดผลลง บทที่ 13 ไม่ว่าจะผ่านหรือไม่**

---

## 9 · วัด disk latency ของ etcd

> **🎩 รันเฉพาะ master ทั้ง 3 เครื่อง**

etcd ต้องการ fsync p99 ต่ำกว่า ~10 ms ถ้าไม่ผ่าน cluster จะตอบช้าและ leader election สะดุด
โดยที่ log ไปโผล่ที่ apiserver ทำให้ไล่หาสาเหตุยากมาก

```bash
dnf install -y fio
fio --rw=write --ioengine=sync --fdatasync=1 --directory=/var/lib/etcd \
    --size=22m --bs=2300 --name=etcd-fsync-test
```

**ควรเห็น:** บรรทัด `fsync/fdatasync/sync_file_range:` แล้วดูค่า `99.00th` ใน `sync percentiles`
**ต้องต่ำกว่า 10000 (µs) = 10 ms**

```bash
rm -f /var/lib/etcd/etcd-fsync-test*
```

> **บันทึกตัวเลขที่วัดได้ลงคู่มือเป็น baseline** เวลา cluster ช้าในอนาคตจะได้เทียบได้ว่า disk แย่ลงหรือเปล่า
> ถ้าไม่ผ่าน 10 ms ให้ขอ VMDK แยกสำหรับ etcd หรือย้ายไป datastore ที่ไม่แชร์กับ VM อื่นเยอะ

---

## 10 · Reboot แล้วตรวจซ้ำ

**ข้อนี้ห้ามข้าม** — จุดประสงค์คือพิสูจน์ว่าทุกอย่างยังอยู่หลัง reboot
ซึ่งเป็นสิ่งที่คู่มือชุดเดิมพลาด

```bash
reboot
```

หลังเครื่องกลับมา:

```bash
uname -r                                          # ต้องลงท้าย uek และตรงกับ versions.env
lsmod | grep -E '^overlay|^br_netfilter'          # ต้องมีทั้งสอง
sysctl net.ipv4.ip_forward                        # ต้องเป็น 1
free -h | grep -i swap                            # ต้องเป็น 0B
getenforce                                        # ต้องเป็น Permissive
findmnt /var/lib/etcd || findmnt /var/lib/containerd   # partition ต้องยัง mount อยู่
firewall-cmd --list-ports                         # ต้องครบ
chronyc tracking | grep 'Leap status'             # ต้อง Normal
```

---

## ✅ เกณฑ์ผ่านของบทนี้

รันบน **ทุกเครื่อง** แล้วเทียบกัน — ทั้ง 6 เครื่องต้องได้ผลเหมือนกันทุกข้อ

```bash
echo "=== $(hostname) ==="
echo "kernel : $(uname -r)"
echo "swap   : $(free -h | awk '/Swap/{print $2}')"
echo "selinux: $(getenforce)"
echo "modules: $(lsmod | grep -cE '^overlay|^br_netfilter')/2"
echo "fwd    : $(sysctl -n net.ipv4.ip_forward)"
echo "time   : $(chronyc tracking | awk -F': ' '/Leap status/{print $2}')"
echo "dns    : $(grep -c '^options.*single-request' /etc/resolv.conf)/1"
```

**ต้องได้:** kernel เลขเดียวกันทั้ง 6 เครื่อง · swap `0B` · selinux `Permissive` · modules `2/2` · fwd `1` · time `Normal` · dns `1/1`

**และจับเวลาการแปลงชื่อด้วย — ข้อนี้ดูจากตัวเลขอย่างเดียวไม่พอ:**
```bash
time getent ahosts auth.docker.io > /dev/null
```
**ต้องได้:** `real` ต่ำกว่า 1 วินาที · ถ้าเห็น ~5 วินาที แปลว่าข้อ 1.1 ยังไม่ติดบนเครื่องนี้

> เครื่องที่ตกข้อ dns จะยังใช้งานได้ทุกอย่าง แค่ช้าลง 5 วินาทีต่อชื่อใหม่หนึ่งชื่อ
> ซึ่งไปโผล่เป็น "บทที่ 09 ลงนานเป็นชั่วโมง" โดยไม่มีอะไรชี้กลับมาที่ต้นเหตุ

> ถ้า kernel ไม่ตรงกันแม้แต่เครื่องเดียว **ให้หยุดแล้วแก้ก่อน** อย่าไปบทที่ 02
> node ที่ kernel ต่างกันจะให้อาการ network ต่างกันเป็นราย node ซึ่งเป็นบั๊กที่หาสาเหตุยากที่สุดแบบหนึ่ง

**➡️ ต่อที่ [บทที่ 02 — Container Runtime](02-container-runtime.md)**
