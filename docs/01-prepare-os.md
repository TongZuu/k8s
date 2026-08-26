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

cat >> /etc/hosts <<EOF
# BEGIN k8s cluster
${VIP}  ${VIP_HOSTNAME}
${MASTER01_IP}  ${MASTER01_NAME}
${MASTER02_IP}  ${MASTER02_NAME}
${MASTER03_IP}  ${MASTER03_NAME}
${WORKER01_IP}  ${WORKER01_NAME}
${WORKER02_IP}  ${WORKER02_NAME}
${WORKER03_IP}  ${WORKER03_NAME}
${REGISTRY_IP}  ${REGISTRY_HOST}
# END k8s cluster
EOF
```

> **บล็อกนี้รันซ้ำได้** — `sed` ลบของเดิมก่อนทุกครั้ง และ Ansible ก็ใช้ marker
> `# BEGIN k8s cluster` ชุดเดียวกัน ทำมือแล้วรัน playbook ทับได้เลย ไม่ซ้ำ
>
> ถ้าเครื่องไหนเคยรันด้วย `cat >>` แบบเดิมมาก่อน จะมีบรรทัดค้างอยู่นอกบล็อก
> ล้างทีเดียวด้วย (ทำครั้งเดียวพอ):
> ```bash
> cp /etc/hosts /etc/hosts.bak
> sed -i -E '/^# BEGIN k8s cluster$/,/^# END k8s cluster$/!{/^[0-9.]+[[:space:]]+(k8s-(vip|master0[1-3]|worker0[1-3])|registry\.myhr\.co\.th)[[:space:]]*$/d}' /etc/hosts
> grep -c k8s-master01 /etc/hosts    # ต้องได้ 1
> ```

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

## 2 · ยืนยัน kernel และตรึงไว้

Oracle Linux ให้ kernel มาสองตัว เราใช้ **UEK 8U2** ตามค่า default
**ห้ามผสม UEK กับ RHCK ใน cluster เดียวกัน** เด็ดขาด

```bash
uname -r
```

**ควรเห็น:** ลงท้าย `el9uek` และขึ้นต้น `6.12.0-` เช่น `6.12.0-204.92.4.3.1.el9uek.x86_64`

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

## 5 · ย้าย partition `/home`

Kubernetes ไม่ใช้ `/home` เลย ขณะที่ของที่โตเร็วทั้งหมดไปกองใต้ `/var`
ย้าย partition 100 GB นี้ไปรับงานที่มีประโยชน์แทน

> ⚠️ ทำ **ก่อน** ติดตั้ง containerd และก่อน `kubeadm init` — ย้ายทีหลังต้องหยุด service

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
```

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
firewall-cmd --permanent --add-port=10250/tcp         # kubelet API
firewall-cmd --permanent --add-port=10257/tcp         # controller-manager
firewall-cmd --permanent --add-port=10259/tcp         # scheduler
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

> **ไม่ต้องเปิด `10256/tcp`** (kube-proxy health) เพราะเราไม่ติดตั้ง kube-proxy
> **ไม่ต้องเปิด `179/tcp`** (BGP) เพราะใช้ L2 announcement ไม่ใช่ BGP mode

### หมายเหตุ — interface ของ Cilium กับ firewalld

หลังลง Cilium ในบทที่ 05 ถ้าเจอว่า pod ข้าม node ไม่ได้ ให้ลองเพิ่ม interface ของ Cilium
เข้า zone `trusted` แล้วทดสอบซ้ำ:

```bash
firewall-cmd --permanent --zone=trusted --add-interface=cilium_host
firewall-cmd --permanent --zone=trusted --add-interface=cilium_net
firewall-cmd --permanent --zone=trusted --add-interface=cilium_vxlan
firewall-cmd --reload
```

> **ต้องทดสอบใน lab ว่าจำเป็นจริงไหม** — อย่าใส่ไว้ล่วงหน้าโดยไม่รู้เหตุผล
> และต้องทดสอบด้วยว่า `firewall-cmd --reload` ตอน Cilium รันอยู่แล้ว pod ยังคุยกันได้
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
```

**ต้องได้:** kernel เลขเดียวกันทั้ง 6 เครื่อง · swap `0B` · selinux `Permissive` · modules `2/2` · fwd `1` · time `Normal`

> ถ้า kernel ไม่ตรงกันแม้แต่เครื่องเดียว **ให้หยุดแล้วแก้ก่อน** อย่าไปบทที่ 02
> node ที่ kernel ต่างกันจะให้อาการ network ต่างกันเป็นราย node ซึ่งเป็นบั๊กที่หาสาเหตุยากที่สุดแบบหนึ่ง

**➡️ ต่อที่ [บทที่ 02 — Container Runtime](02-container-runtime.md)**
