# Ansible — แทนบทที่ 01 และ 02

รันขั้นตอนเตรียม OS และติดตั้ง container runtime ให้ทุกเครื่องพร้อมกัน
แทนการ SSH เข้าไป copy-วางทีละเครื่อง (บท 01+02 มี 47 บล็อกคำสั่ง × 6 เครื่อง)

> **playbook ตอบว่า "ทำให้" · [คู่มือ .md](../docs/README.md) ตอบว่า "ทำอะไรและทำไม"**
> ทุกอย่างที่ playbook ทำมีที่มาจากบท [01](../docs/01-prepare-os.md) และ [02](../docs/02-container-runtime.md) โดยตรง
> ถ้าสองอย่างไม่ตรงกัน **คู่มือถูก** แล้วต้องแก้ playbook ตาม

---

## สถานะ

| เครื่อง | บท 01 | ทำด้วย |
|---|---|---|
| master01 | ✅ | **ทำมือ** — เครื่องอ้างอิง ใช้เทียบว่า playbook ทำถูกไหม |
| master02 | ✅ | playbook (รันจริง + reboot ผ่าน) |
| master03 | ✅ | playbook |
| worker01 | ✅ | playbook — **เครื่องแรกที่พิสูจน์เส้นทาง worker** |
| worker02–03 | ⬜ | ยังไม่ได้รัน |

| playbook | แทนบท | สถานะ |
|---|---|---|
| `prepare-os.yml` | 01 | ✅ ใช้จริงครบ 6 เครื่อง |
| `container-runtime.yml` | 02 | 🔄 `--check` บน master01 ได้ `changed=0 failed=0` · **ยังไม่เคยติดตั้งของจริง** (master01 มีของครบอยู่ก่อนแล้ว) |
| `ha-layer.yml` | 03 ข้อ 1-3 | ✅ รันจริงครบ 3 master (28 ส.ค. 2026) · **failover test ผ่านแล้ว** (28 ส.ค. 2026 · 5.1 หยุด keepalived, 5.2 หยุด HAProxy, 5.4 `kubectl` ผ่าน VIP ไม่ขาด) · ⬜ ยังไม่ได้จดเวลา failover เป็นตัวเลข · ⬜ ข้อ 5.3 (reboot) เลื่อนไปทำหลังบท 05 |
| `create-cluster.yml` | 04 | ⬜ **ยังไม่เคยรัน** — บท 04 ทำมือทั้งหมด (28 ส.ค. – 1 ก.ย. 2026): init + join master02/03 + join worker ครบ 6 node · **เส้นทางของ playbook จึงยังไม่เคยถูกพิสูจน์เลยสักบรรทัด** ถึงจะแก้ไปหลายรอบระหว่างทำมือก็ตาม |
| `cilium.yml` | 05 | ⬜ **ยังไม่เคยรัน** |

บท 03 ครอบคลุมแค่ **ข้อ 1-3 (วาง config)** — **ข้อ 5 (failover test) ยังต้องทำมือ**
เพราะต้องมีคนเห็นว่า VIP ย้ายเครื่องจริงตอนดึงปลั๊ก service ขึ้นเขียวไม่ได้แปลว่า HA ทำงาน

> เดิมบันทึกไว้ว่า "ไม่ทำ playbook เพราะ config ต่างกันทุกเครื่อง" — **เหตุผลนั้นกลับด้าน**
> ค่าที่ต่างรายเครื่อง (`state` `priority` `router_id` ชื่อ interface) คือสิ่งที่ template
> กับ inventory จัดการได้แม่นกว่าคนคัดลอกไฟล์เอง ตอนทำมือจริงเจอพลาดครบทุกแบบ:
> หยิบไฟล์ผิดเครื่อง · `cp` ติด alias `-i` เลยไม่ทับ · `auth_pass` ว่างเพราะ `read` ไม่ได้ค่า ·
> `ens192` ไม่มีบนเครื่องที่ NIC ชื่อ `ens33` — ไม่มีข้อไหนเกิดได้กับ `copy`/`template` ที่ idempotent

> ทั้งสามตัวที่ยังไม่เคยรัน ตรวจมาแล้วแค่ YAML syntax กับ scanner ไล่ pattern บั๊ก
> ที่เคยเจอ — **ทำมือหนึ่งเครื่องก่อนเสมอ** แล้วค่อย `--check` ใส่เครื่องนั้น
>
> **`create-cluster.yml` ได้กับดักจากการทำมือรอบ 28 ส.ค. – 1 ก.ย. 2026 มาใส่ไว้แล้วทั้งหมด**
> (audit policy ก่อน init/join · เคลียร์ `lost+found` · `kubeadm config validate` ·
> รอ apiserver ขึ้นจริงหลัง join · ไม่หมุน certificate-key เกินจำเป็น · `--ttl 2h`)
> แต่ **"ใส่ไว้แล้ว" ไม่เท่ากับ "ผ่านแล้ว"** — cluster ถัดไปต้องรันของจริงถึงจะรู้

---

## ติดตั้งครั้งเดียว

### 1 · WSL2 + Ansible

Ansible เป็น control node บน Windows ไม่ได้ ต้องมี Linux:

```powershell
wsl --install -d Ubuntu
wsl --set-default Ubuntu
```

> distro `docker-desktop` เป็น VM ภายในของ Docker Desktop — **อย่าลงอะไรในนั้น**
> มันถูกล้างทุกครั้งที่ Docker อัปเดต

จากใน Ubuntu:

```bash
sudo apt update && sudo apt install -y ansible
```

> ⚠️ ต้องเป็น `ansible` (ตัวเต็ม) ไม่ใช่ `ansible-core` เพราะ playbook ใช้ module จาก
> `ansible.posix` (sysctl, selinux, firewalld) และ `community.general` (modprobe)
> ถ้าลง `ansible-core` มาแล้ว เติมด้วย:
> ```bash
> ansible-galaxy collection install ansible.posix community.general
> ```

### 2 · ⚠️ repo อยู่บนไดรฟ์ D: — ต้องแก้ permission ก่อน

WSL mount ไดรฟ์ Windows แบบ world-writable (777) และ
**Ansible จะเมิน `ansible.cfg` ที่อยู่ในโฟลเดอร์ world-writable แบบเงียบ ๆ**
ผลคือมันไม่โหลด `inventory.ini` ให้ แล้วคุณจะเจอ "ไม่พบ host" ทั้งที่ไฟล์อยู่ตรงนั้น

```bash
sudo tee /etc/wsl.conf <<'EOF'
[automount]
options = "metadata,umask=22,fmask=11"
EOF
```

ปิด WSL ให้สนิทจาก PowerShell — ปิดแค่หน้าต่างไม่พอ:

```powershell
wsl --shutdown
```

เปิดใหม่แล้วให้ Ansible ยืนยันเอง (แม่นกว่าไปนั่งดูเลขสิทธิ์):

```bash
cd /mnt/d/workspace/k8s/ansible && ansible --version | head -3
```

**ควรเห็น:** `config file = /mnt/d/workspace/k8s/ansible/ansible.cfg`
ถ้าได้ `config file = None` หรือมี warning เรื่อง world writable แปลว่ายังไม่ผ่าน

> เลขสิทธิ์ที่ได้จะเป็น `755` สำหรับโฟลเดอร์ และ `744` สำหรับไฟล์ — **ถูกต้องแล้ว**
> สิ่งที่ Ansible ตรวจคือ *โฟลเดอร์* ที่คุณยืนอยู่ ไม่ใช่สิทธิ์ของตัวไฟล์

### 3 · VPN

เครื่อง cluster อยู่หลัง Fortinet SSL VPN — ทดสอบก่อนว่า WSL ทะลุไปได้ไหม

```bash
ping -c2 192.168.50.101
```

ผ่านแล้วจบ ไม่ต้องแก้อะไร · ถ้าไม่ผ่านดู [แก้ปัญหา](#แก้ปัญหาที่เคยเจอจริง)

### 4 · SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
for ip in 101 102 103 104 105 106; do
  ssh-copy-id -o StrictHostKeyChecking=accept-new root@192.168.50.$ip
done
```

ถามรหัส root เครื่องละครั้ง · `accept-new` ตัดคำถาม fingerprint ที่ต้องพิมพ์ `yes` ทุกรอบออก

**ยืนยันครบทั้ง 6 ก่อนรัน playbook เสมอ:**

```bash
ansible k8s_nodes -m ping
```

ต้องได้ `SUCCESS` หกบรรทัด ไม่มีเครื่องไหนถามรหัสอีก
ถ้าเครื่องไหนขึ้น `Permission denied (publickey,...)` แปลว่ายังไม่ได้แลก key กับเครื่องนั้น

---

## ก่อนรันทุกเครื่อง — 3 ข้อที่ playbook ไม่ทำให้

playbook **ตรวจ** ทั้งสามข้อและหยุดถ้ายังไม่ได้ทำ แต่ **ไม่ทำให้** โดยเจตนา

ดูสถานะรวดเดียว:

```bash
for ip in 101 102 103 104 105 106; do
  echo "=== .$ip ==="
  ssh root@192.168.50.$ip 'uname -r'
  ssh root@192.168.50.$ip 'bash -s' < ../config/audit-node.sh 2>&1 | grep -E 'versionlock|partition'
done
```

| ต้องมี | ทำไม playbook ไม่ทำ |
|---|---|
| kernel สาย `6.12` และเป็น `uek` | เปลี่ยน kernel + reboot พร้อมกัน 6 เครื่องคือความเสี่ยงฟรี ๆ |
| `versionlock` kernel-uek | ควรอยู่ใน VM template |
| ย้าย partition `/home` แล้ว | `umount` + แก้ `/etc/fstab` พลาดแล้ว **เครื่องบูตไม่ขึ้น** |

### ย้าย partition — 🔴 master กับ worker คนละปลายทาง

**master → `/var/lib/etcd`**

```bash
findmnt /home                     # ยืนยันว่าเป็น partition แยกจริงก่อน
umount /home
mkdir -p /var/lib/etcd
sed -i 's|[[:space:]]/home[[:space:]]|  /var/lib/etcd  |' /etc/fstab
mount -a
chmod 700 /var/lib/etcd           # ข้อกำหนดของ etcd
findmnt /var/lib/etcd && grep -v '^#' /etc/fstab | grep -E 'etcd|/home'
```

**worker → `/var/lib/containerd`**

```bash
findmnt /home
umount /home
mkdir -p /var/lib/containerd
sed -i 's|[[:space:]]/home[[:space:]]|  /var/lib/containerd  |' /etc/fstab
mount -a
findmnt /var/lib/containerd && grep -v '^#' /etc/fstab | grep -E 'containerd|/home'
```

🔴 **บรรทัดสุดท้ายคือด่านสุดท้ายก่อน reboot** — ต้องเห็น mount point ใหม่ และ
**ต้องไม่เหลือบรรทัด `/home`** ใน fstab · fstab ผิดแล้วเครื่องไม่กลับมา ต้องไปแก้ที่ console ของ VMware

### ล้าง /etc/hosts ถ้าเคยรันคู่มือรุ่นเก่า

คู่มือรุ่นก่อน 27 ส.ค. 2026 ใช้ `cat >>` ซึ่งไม่มี marker — playbook มองไม่เห็นแล้วเพิ่มบล็อกที่สองทับ

```bash
cp /etc/hosts /etc/hosts.bak
sed -i -E '/^# BEGIN k8s cluster$/,/^# END k8s cluster$/!{/^[0-9.]+[[:space:]]+(k8s-(vip|master0[1-3]|worker0[1-3])|registry\.myhr\.co\.th)[[:space:]]*$/d}' /etc/hosts
grep -c k8s-master01 /etc/hosts   # ต้องได้ 0 หรือ 1 ไม่ใช่ 2
```

ทำครั้งเดียวพอ — คู่มือปัจจุบันและ playbook ใช้ marker `# BEGIN k8s cluster` ชุดเดียวกันแล้ว

---

## ลำดับการรัน — ห้ามข้าม

### ขั้น 1 · ทำมือหนึ่งเครื่องก่อน ✅

ต้องรู้ก่อนว่า "ถูกต้อง" หน้าตาเป็นยังไง ถึงจะบอกได้ว่า playbook ทำถูกหรือเปล่า

### ขั้น 2 · 🔑 `--check` ใส่เครื่องที่ทำมือเสร็จแล้ว

**การทดสอบที่ดีที่สุดที่มี** เพราะรู้คำตอบล่วงหน้า — เครื่องนั้นอยู่ในสถานะปลายทางที่ถูกต้องอยู่แล้ว

```bash
ansible-playbook prepare-os.yml --check --diff --limit k8s-master01 --skip-tags reboot
```

| ผล | แปลว่า |
|---|---|
| `changed=0` | playbook ตรงกับคู่มือ |
| `changed=N` | อ่าน `--diff` ว่ามันอยากเปลี่ยนอะไร แล้วตัดสินว่าใครผิด |
| `failed` | assert ไม่ผ่าน — มักเป็น kernel, versionlock หรือ partition |

> ⚠️ ใส่ `--skip-tags reboot` เสมอในขั้นนี้ ไม่งั้นมันจะ reboot เครื่องที่เพิ่งทำเสร็จ

> **`changed=N` ไม่ได้แปลว่า playbook ผิดเสมอไป** — บาง task รายงาน changed ทุกครั้ง
> โดยธรรมชาติ ดู `--diff` ประกอบเสมอ

> **`--check` ตรวจได้ไม่ครบ** — Ansible ข้าม `shell`/`command` ทุกตัวใน check mode
> (`skipped=6` ที่เห็นคือพวกนั้น) `changed=0` จึงยังไม่ใช่หลักฐานเต็ม
> ตัวที่พิสูจน์จริงคือ [ขั้น 5](#ขั้น-5--พิสูจน์ว่า-playbook-เทียบเท่าการทำมือ)

> **ทำไม `versions.env` โหลดใน `pre_tasks` ไม่ใช่ play แยก** — `--limit` มีผลกับ *ทุก* play
> ถ้าแยก play ที่ `hosts: localhost` ไว้ต่างหาก พอสั่ง `--limit k8s-master01` มันจะตัด play นั้นทิ้ง
> แล้วตัวแปรจะไม่มีอยู่จริงตอน play ถัดไปทำงาน (เจอจริงตอนทดสอบครั้งแรก)

### ขั้น 3 · รันจริงใส่เครื่องที่ยังไม่ได้ทำ หนึ่งเครื่อง

```bash
ansible-playbook prepare-os.yml --check --diff --limit k8s-master02 --skip-tags reboot   # ดูก่อน
ansible-playbook prepare-os.yml --limit k8s-master02                                     # แล้วยิงจริง
```

**ไม่ใส่ `--skip-tags reboot` ตอนรันจริง** — บท 01 ข้อ 10 บอกว่าห้ามข้าม reboot
ต้องพิสูจน์ว่าทุกอย่างยังอยู่หลังบูต · playbook รอเครื่องกลับมาเอง แล้ว assert ซ้ำให้

### รัน `create-cluster.yml` เฉพาะบางเครื่อง (`--limit`)

cluster สร้างไปแล้วบางส่วนด้วยมือ แล้วอยากให้ playbook ทำเครื่องที่เหลือ — ใช้ `--limit` ได้
แต่**ต้องมี master01 อยู่ในรอบเสมอ** เพราะ token กับคำสั่ง join ออกจากเครื่องนั้น

```bash
ansible-playbook create-cluster.yml --limit 'k8s-master01,k8s-worker01'
```

playbook ข้ามงานที่ทำไปแล้วเอง: `kubeadm init` ข้ามถ้ามี `/etc/kubernetes/admin.conf` ·
join ข้ามถ้ามี `/etc/kubernetes/kubelet.conf` · master ตัวอื่นที่ไม่ได้อยู่ใน `--limit`
จะไม่ถูกแตะเลย

สองอย่างที่ทำไว้เพื่อให้ `--limit` ใช้ได้จริง:

- **ข้อตรวจท้าย playbook เทียบกับเครื่องที่อยู่ในรอบนี้ ไม่ใช่ทั้ง inventory** — `--limit`
  ไม่ได้ทำให้ `groups['k8s_nodes']` เล็กลง ถ้าเทียบกับ group ตรง ๆ การรันทีละเครื่องจะ fail
  ทุกครั้งทั้งที่ทำงานถูก · ความครบของ cluster เทียบกับ inventory ยังรายงานให้ดู แต่ไม่ fail
- **`upload-certs` รันเฉพาะรอบที่มี master ซึ่งยังไม่มี `/etc/kubernetes/kubelet.conf`** —
  คำสั่งนี้เข้ารหัส cert ใหม่ด้วย key ใหม่ทุกครั้ง ทำให้ `certificate-key` ที่ออกไปก่อนหน้า
  ใช้ไม่ได้ทันที · เงื่อนไขจึงดูที่ "ยังมี master ที่ต้อง join จริงไหม" ไม่ใช่แค่ "มี master
  อยู่ใน `--limit` ไหม" ไม่งั้นการรันเต็มบน cluster ที่ join ครบแล้วจะหมุน key ทิ้งฟรี ๆ
  แล้วไปทำให้ key ที่คนอื่นถืออยู่ระหว่าง join ใช้ไม่ได้
  (ดู [บท 13 ข้อ 12.5](../docs/13-troubleshooting.md))

> `--check` กับ playbook นี้บอกอะไรได้ไม่มากในเครื่องที่ยังไม่ join เพราะ `kubeadm join`
> เป็น command task ที่ถูกข้ามใน check mode แล้วข้อตรวจท้ายก็จะไม่ผ่านตามไปด้วย
> ใช้ `--list-hosts` ดูว่าจะแตะเครื่องไหนบ้างจะตรงประเด็นกว่า

### ขั้น 4 · เส้นทาง worker ต้องทดสอบแยก

master กับ worker เดินคนละกิ่งใน playbook — **ผ่าน master ไม่ได้แปลว่า worker ผ่าน**

```bash
ansible-playbook prepare-os.yml --check --diff --limit k8s-worker01 --skip-tags reboot
```

รูปร่างตัวเลขที่ควรเห็น เทียบกับ master ที่สถานะเดียวกัน:

| | master | worker |
|---|---|---|
| `changed` | 8 | **7** (ไม่มี task เปิด VRRP) |
| `skipped` | 6 | **7** |

และใน `--diff` ต้องเห็น:

- เปิดพอร์ต **5 ตัว** ไม่ใช่ 9 — ต้องมี `30000-32767/tcp` (NodePort)
- **ไม่มี** task `เปิด VRRP`
- assert partition มองหา `/var/lib/containerd` ไม่ใช่ `/var/lib/etcd`

ผ่านแล้วค่อย:

```bash
ansible-playbook prepare-os.yml --limit k8s-worker01
ansible-playbook prepare-os.yml --limit 'k8s-worker02,k8s-worker03'
```

### ขั้น 5 · 🔑 พิสูจน์ว่า playbook เทียบเท่าการทำมือ

**นี่คือเกณฑ์ผ่านของทั้งเรื่อง** — เทียบเครื่องที่ทำมือกับเครื่องที่ playbook ทำ

```bash
for ip in 101 102; do ssh root@192.168.50.$ip 'bash -s' < ../config/audit-node.sh > /tmp/a$ip.txt; done
diff <(sed '1,3d;s/k8s-master0[0-9]/NODE/g' /tmp/a101.txt) \
     <(sed '1,3d;s/k8s-master0[0-9]/NODE/g' /tmp/a102.txt) && echo ">>> เหมือนกันทุกบรรทัด <<<"
```

(ตัด 3 บรรทัดหัวที่มีชื่อเครื่องกับเวลา และแทนชื่อ master01/02 เป็น `NODE` เพื่อให้เทียบได้)

เทียบ worker กับ master ก็ได้ — **ควรต่างแค่ 3 จุดที่ตั้งใจ** (ชื่อเครื่อง, partition, รายการพอร์ต):

```bash
for ip in 102 104; do ssh root@192.168.50.$ip 'bash -s' < ../config/audit-node.sh > /tmp/b$ip.txt; done
diff /tmp/b102.txt /tmp/b104.txt
```

ต่างเรื่องอื่น = ช่องโหว่ในเส้นทาง worker

---

## สิ่งที่ playbook ตั้งใจ "ไม่ทำ"

| บท 01 ข้อ | ทำไม | ต้องทำที่ไหนแทน |
|---|---|---|
| **2 · สลับ/ตรึง kernel** | เปลี่ยน kernel แล้ว reboot พร้อมกัน 6 เครื่องคือความเสี่ยงที่ไม่จำเป็น | VM template (Phase 0) |
| **5 · ย้าย partition `/home`** | `umount` + แก้ `/etc/fstab` พลาดแล้ว **เครื่องบูตไม่ขึ้น** | แบ่ง partition ตอนสร้าง template |
| **9 · วัด fsync ด้วย fio** | เป็นการ **วัด** ต้องมีคนอ่านตัวเลขแล้วตัดสินใจ | ทำมือตามบท 01 |

ทั้งสามข้อมี task **ตรวจ** ว่าทำมาแล้วหรือยัง ถ้ายังไม่ได้ทำ playbook จะหยุดพร้อมบอกเหตุผล
ไม่ใช่ทำต่อไปเงียบ ๆ

### เรื่อง kernel — บังคับแค่ major.minor

```
บังคับ  : สาย 6.12 + ต้องเป็น uek   → หลุดไป RHCK 5.14 หรือ 6.13 = หยุดทันที
เตือน   : หางเลข 203/204/205        → errata ของ Oracle ไม่กระทบ Cilium
```

เครื่องที่หางเลขไม่ตรงกับ `KERNEL_UEK` จะขึ้นคำเตือนทุกครั้งที่รัน แต่ไม่หยุดงาน
สถานะปัจจุบันและแผนจัดการอยู่ใน [CHECKLIST หมวด C2](../docs/CHECKLIST.md)

---

## แหล่งความจริงของเวอร์ชัน

playbook **ไม่มีเลขเวอร์ชันหรือ IP เขียนไว้ตรง ๆ เลย** — `pre_tasks` แรกจะ `source versions.env`
ด้วย bash แล้วแปลงเป็นตัวแปรของ Ansible ใช้ semantics เดียวกับที่คู่มือทำเป๊ะ

แปลว่าแก้ [`../docs/versions.env`](../docs/versions.env) ที่เดียวยังใช้ได้เหมือนเดิม
ตรงตามกติกาข้อ 1 ของคู่มือ

ค่าที่ **ไม่ได้** อยู่ใน `versions.env` อยู่ใน [`group_vars/all.yml`](group_vars/all.yml):

| ตัวแปร | ต้องตั้งก่อนรัน `container-runtime.yml` |
|---|---|
| `registry_scheme` | `https` หรือ `http` — **ต้องยืนยันของจริงก่อน** ไม่ใช่เดา |
| `registry_ca_file` | path ของ CA ถ้า registry ใช้ internal CA (เว้นว่าง = ไม่ต้องลง) |

```bash
curl -sI https://registry.myhr.co.th/v2/ || curl -sI http://registry.myhr.co.th/v2/
```

---

## แก้ปัญหาที่เคยเจอจริง

### `container-runtime.yml` ค้างนานตอนดาวน์โหลด

release asset ของ GitHub **redirect ไป `release-assets.githubusercontent.com`**
ซึ่งเป็นคนละ host กับ `github.com` และช้ากว่ามาก (วัดจาก node จริง: github.com 1.3 วิ
vs asset host 11.4 วิ แค่ HEAD) ดาวน์โหลด 35-55 MB จึงกินเวลาเป็นนาที

playbook จะ**ข้ามการดาวน์โหลดถ้าเวอร์ชันที่ติดตั้งอยู่ตรงแล้ว** ดูบรรทัด
`สิ่งที่ต้องทำบนเครื่องนี้` ตอนต้นว่ามันตัดสินใจยังไง

ถ้ายังช้าและอยากตัดปัญหา — โหลดครั้งเดียวแล้วกระจายเอง:

```bash
# จากเครื่องที่โหลดเสร็จแล้ว
for ip in 102 103 104 105 106; do
  scp /root/k8s/dl/{containerd*.tar.gz*,runc.amd64,cni-plugins*.tgz,containerd.service} \
      root@192.168.50.$ip:/root/k8s/dl/
done
```

playbook เห็นไฟล์ที่ checksum ตรงแล้วจะไม่โหลดซ้ำ

### `--check` ล้มบนเครื่องเปล่า — `dest '...' must be an existing dir`

**ไม่ใช่บั๊ก** — ใน check mode Ansible ไม่ได้สร้างของจริง task ที่พึ่งผลของ
task ก่อนหน้าจึงล้ม เช่น `unarchive` ลง `/opt/cni/bin` ที่ `file` module
เพิ่งรายงานว่า *จะ* สร้าง แต่ยังไม่ได้สร้าง

| เครื่อง | ใช้ `--check` ได้ไหม |
|---|---|
| ติดตั้งเสร็จแล้ว | ✅ **มีประโยชน์ที่สุด** — `changed=0` แปลว่ายังตรงสเปก |
| ยังเปล่าอยู่ | ❌ จะล้มที่ task แรกที่ต่อเนื่องกัน — **รันจริงไปเลย** |

`--check` มีค่าตอนใช้ตรวจ drift ไม่ใช่ตอนติดตั้งครั้งแรก

### `scp: Permission denied` ตอนกระจายไฟล์จาก master01

คีย์ที่แจกคือของ **WSL → root@nodes** ส่วน root บน master01 ไม่มีคีย์ไปเครื่องอื่น
ส่ง agent ไปด้วยเพื่อให้ไฟล์วิ่งใน LAN ไม่ผ่าน VPN:

```bash
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519
ssh -A root@192.168.50.101
```

แล้วบน master01:

```bash
for ip in 102 103 104 105 106; do
  ssh -o StrictHostKeyChecking=accept-new root@192.168.50.$ip 'mkdir -p /root/k8s/dl'
  scp /root/k8s/dl/* root@192.168.50.$ip:/root/k8s/dl/
done
```

### `Permission denied (publickey,gssapi-keyex,...)`

ยังไม่ได้แลก SSH key กับเครื่องนั้น:

```bash
ssh-copy-id -o StrictHostKeyChecking=accept-new root@192.168.50.<ip>
```

### `UNREACHABLE` / `Connection closed by ... port 22` ทั้งที่ ssh ธรรมดาผ่าน

Ansible เปิด SSH socket ค้างไว้ 60 วินาที (`ControlPersist`) เพื่อใช้ซ้ำ
ถ้าเครื่องปลายทาง reboot หรือ sshd รีสตาร์ทระหว่างนั้น socket เดิมตายแต่ Ansible ยังหยิบมาใช้

```bash
rm -f ~/.ansible/cp/*
```

หรือรอ 60 วินาทีให้หมดอายุเอง · **ไม่ต้องปิด multiplexing** — มันช่วยเรื่องความเร็วมาก

### `object of type 'HostVarsVars' has no attribute 'v'`

`--limit` ตัด play ที่โหลด `versions.env` ทิ้ง — แก้แล้วตั้งแต่ 27 ส.ค. 2026
(ย้ายไปเป็น `pre_tasks` ใน play เดียวกับ node) ถ้ายังเจอแปลว่าใช้ playbook เวอร์ชันเก่า

### `The 'community.general.yaml' callback plugin has been removed`

`ansible.cfg` ชี้ callback ที่ถูกถอดใน community.general 12.0.0 — แก้แล้ว
ใช้ `stdout_callback = default` + `result_format = yaml` แทน

### `create-cluster.yml` ตายที่ task "ทุก document ใน kubeadm-config.yaml ต้องมี apiVersion และ kind"

task นี้รันบน control node ก่อนส่งไฟล์ขึ้นเครื่อง มันจำลองวิธีที่ kubeadm หั่น `--config`
คือหั่นที่บรรทัดขึ้นต้นด้วย `---` ตรง ๆ ไม่ได้ parse YAML ก่อน ชิ้นที่มีตัวอักษรอยู่
แต่ไม่มี `apiVersion`+`kind` (เช่นคอมเมนต์หัวไฟล์ที่ถูก `---` คั่นออกมา) ทำให้ `kubeadm init`
ตายด้วย `GroupVersionKind /, Kind=` โดยไม่บอกว่าไฟล์ไหนบรรทัดไหน

ข้อความ fail ของ task บอกช่วงบรรทัดมาให้แล้ว — แก้ที่
[`config/kubeadm/kubeadm-config.yaml`](../config/kubeadm/kubeadm-config.yaml) บน control node
แล้วรันซ้ำ ตรวจเองก่อนได้ด้วย:

```bash
awk -f config/kubeadm-docsplit.awk config/kubeadm/kubeadm-config.yaml
```

> ต้องมี task นี้เพราะ `--syntax-check`, yamllint และ PyYAML ข้ามคอมเมนต์ก่อน `---` ให้หมด
> ไฟล์จึงผ่านทุกด่านฝั่ง Ansible แล้วไปตายที่ kubeadm ตัวเดียว — ดู
> [บท 13 ข้อ 12](../docs/13-troubleshooting.md)

### `create-cluster.yml` ตายที่ task "kubeadm ต้องอ่าน config แล้วผ่าน validate"

task นี้คือ `kubeadm config validate` ซึ่งอ่านแค่ไฟล์ ไม่แตะเครื่อง — ตายตรงนี้แปลว่า
**ค่าใน config ผิด** ไม่ใช่เครื่องไม่พร้อม อ่านค่าที่มันบอกมาแล้วแก้ที่
[`config/kubeadm/kubeadm-config.yaml`](../config/kubeadm/kubeadm-config.yaml) บน control node

ตัวที่เคยเจอ: `token: ""` ใน `bootstrapTokens` — ไม่ได้แปลว่า "ปล่อยว่างให้สุ่มเอง"
ต้องไม่มี field `token` เลย kubeadm ถึงจะสุ่มให้ (ดู [บท 13 ข้อ 12.2](../docs/13-troubleshooting.md))

### WSL ทะลุ VPN ไม่ได้

ถ้า `ping 192.168.50.101` จาก WSL ไม่ผ่านทั้งที่ Windows ผ่าน — โหมด NAT ของ WSL
ไม่ได้รับ route ของ VPN มาด้วย เปิด mirrored networking:

```powershell
@"
[wsl2]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
"@ | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding utf8
wsl --shutdown
```

> ⚠️ `.wslconfig` มีผลกับ WSL **ทุก distro รวม `docker-desktop`** ถ้า container มีปัญหา
> ย้อนกลับด้วย `Remove-Item "$env:USERPROFILE\.wslconfig"; wsl --shutdown`

---

## คำสั่งที่ใช้บ่อย

| อยากทำอะไร | คำสั่ง |
|---|---|
| ดูว่าจะเปลี่ยนอะไร ไม่แก้จริง | `ansible-playbook prepare-os.yml --check --diff` |
| รันแค่เครื่องเดียว | `ansible-playbook prepare-os.yml --limit k8s-worker01` |
| รันแค่ worker ทั้งกลุ่ม | `ansible-playbook prepare-os.yml --limit workers` |
| ข้ามการ reboot | `... --skip-tags reboot` |
| ดูรายละเอียดตอนพัง | เติม `-vvv` |
| ทดสอบว่าคุยกับทุกเครื่องได้ | `ansible k8s_nodes -m ping` |
| รัน audit ทุกเครื่อง | `ansible k8s_nodes -m script -a '../config/audit-node.sh'` |
| ตรวจว่าเครื่องยังตรงสเปกไหม | `ansible-playbook prepare-os.yml --check` |

**ข้อสุดท้ายคือประโยชน์ที่แท้จริง** — playbook idempotent รันซ้ำกี่รอบก็ได้ผลเดิม
เอามาใช้เป็นเครื่องมือ **ตรวจ config drift** ได้ตลอดอายุ cluster ไม่ใช่แค่ตอนติดตั้ง
ซึ่งตอบความเสี่ยงข้อ "node บูตคนละ kernel โดยไม่รู้ตัว" ใน blueprint โดยตรง

---

## เมื่อไหร่ควรใช้จริง

| Phase | ใช้ยังไง |
|---|---|
| **Phase 1 lab** | ทำมือ 1 เครื่อง → รัน playbook ใส่ที่เหลือ → เทียบผล → แก้ playbook |
| **Phase 3 รื้อสร้างใหม่** | รอบที่คุ้มที่สุด และเป็นการทดสอบ playbook ไปในตัว |
| **Phase 4 production** | ใช้ตัวที่ผ่าน Phase 3 มาแล้วเท่านั้น |

**อย่าใช้ playbook นี้กับ production ก่อนที่มันจะผ่าน Phase 3**
