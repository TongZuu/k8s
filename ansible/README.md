# Ansible — แทนบทที่ 01 และ 02

รันขั้นตอนเตรียม OS และติดตั้ง container runtime ให้ทั้ง 6 เครื่องด้วยคำสั่งเดียวต่อบท
แทนการ SSH เข้าไป copy-วางทีละเครื่อง

> **playbook ตอบว่า "ทำให้" · [คู่มือ .md](../docs/README.md) ตอบว่า "ทำอะไรและทำไม"**
> ทุกอย่างที่ playbook ทำมีที่มาจากบท [01](../docs/01-prepare-os.md) และ
> [02](../docs/02-container-runtime.md) โดยตรง · ถ้าสองอย่างไม่ตรงกัน **คู่มือถูก** แล้วต้องแก้ playbook ตาม

> **ตั้งแต่บท 03 ไป ทำมือตามคู่มือ** — HA layer, สร้าง cluster, Cilium เป็นขั้นที่ต้องมีคน
> ตรวจและเห็นผลจริงด้วยตา (VIP ย้ายเครื่องไหม · node join ครบไหม) ไม่ใช่ขั้นที่ควรวิ่งผ่านอัตโนมัติ
> · ไป [บทที่ 03](../docs/03-ha-layer.md) เมื่อจบข้อ 2 ข้างล่าง

---

## 0 · เตรียมเครื่องที่ใช้รัน — ครั้งเดียว

### WSL2 + Ansible

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

> ต้องเป็น `ansible` (ตัวเต็ม) ไม่ใช่ `ansible-core` เพราะ playbook ใช้ module จาก
> `ansible.posix` (sysctl, selinux, firewalld) และ `community.general` (modprobe)
> ถ้าลง `ansible-core` มาแล้ว เติมด้วย:
> ```bash
> ansible-galaxy collection install ansible.posix community.general
> ```

### repo อยู่บนไดรฟ์ D: — แก้ permission ก่อน

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

เปิดใหม่แล้วให้ Ansible ยืนยันเอง:

```bash
cd /mnt/d/workspace/k8s/ansible && ansible --version | head -3
```

**ควรเห็น:** `config file = /mnt/d/workspace/k8s/ansible/ansible.cfg`
ถ้าได้ `config file = None` หรือมี warning เรื่อง world writable แปลว่ายังไม่ผ่าน

### VPN

เครื่อง cluster อยู่หลัง Fortinet SSL VPN — ทดสอบก่อนว่า WSL ทะลุไปได้ไหม:

```bash
ping -c2 192.168.50.101
```

**ถ้าไม่ผ่านทั้งที่ Windows ผ่าน** — โหมด NAT ของ WSL ไม่ได้รับ route ของ VPN มาด้วย
เปิด mirrored networking:

```powershell
@"
[wsl2]
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
"@ | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding utf8
wsl --shutdown
```

> `.wslconfig` มีผลกับ WSL **ทุก distro รวม `docker-desktop`** ถ้า container มีปัญหา
> ย้อนกลับด้วย `Remove-Item "$env:USERPROFILE\.wslconfig"; wsl --shutdown`

### SSH key

**ถ้าเพิ่งลง OS ใหม่ ต้องล้าง `known_hosts` ก่อน** — เครื่องที่ลงใหม่ได้ host key ชุดใหม่
แต่ของเก่ายังค้างในไฟล์ `ssh-copy-id` ข้างล่างจะถูกปฏิเสธด้วย `REMOTE HOST IDENTIFICATION HAS CHANGED!`

```bash
for ip in 101 102 103 104 105 106; do
  ssh-keygen -f ~/.ssh/known_hosts -R 192.168.50.$ip
done
```

> ถ้า **ไม่ได้** ลง OS ใหม่แล้วเจอข้อความนี้ ให้หยุดตรวจก่อน — มันคือสิ่งที่ข้อความนั้นเตือนจริง ๆ

แลก key (ถามรหัส root เครื่องละครั้ง):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''   # ข้ามถ้ามี key อยู่แล้ว
for ip in 101 102 103 104 105 106; do
  ssh-copy-id -o StrictHostKeyChecking=accept-new root@192.168.50.$ip
done
```

### ยืนยันก่อนไปต่อ

```bash
ansible k8s_nodes -m ping
```

**ต้องได้ `SUCCESS` หกบรรทัด** ไม่มีเครื่องไหนถามรหัสอีก

| ถ้าเจอ | แปลว่า | แก้ |
|---|---|---|
| `Permission denied (publickey,...)` | ยังไม่ได้แลก key กับเครื่องนั้น | `ssh-copy-id` เครื่องนั้นซ้ำ |
| `UNREACHABLE` ทั้งที่ `ssh` ธรรมดาผ่าน | socket ค้างจาก `ControlPersist` หลังเครื่อง reboot | `rm -f ~/.ansible/cp/*` หรือรอ 60 วิ |

---

## 1 · `prepare-os.yml` — บท 01

รันเครื่องแรกเครื่องเดียวก่อน — ถ้า playbook มีปัญหาจะรู้ที่เครื่องเดียว ไม่ใช่หกเครื่อง:

```bash
ansible-playbook prepare-os.yml --limit k8s-master01
```

playbook reboot เครื่องให้เองแล้ว assert ซ้ำหลังบูต · จบแล้วรัน `--check` ซ้ำเครื่องเดิม
เพื่อพิสูจน์ว่า idempotent — **ต้องได้ `changed=0`**:

```bash
ansible-playbook prepare-os.yml --check --diff --limit k8s-master01 --skip-tags reboot
```

ผ่านแล้วอีก 5 เครื่องรวดเดียว (reboot ยังทีละเครื่อง — `serial: 1` ในตัว playbook):

```bash
ansible-playbook prepare-os.yml --limit 'k8s_nodes:!k8s-master01'
```

> **อย่าเริ่มด้วย `--check` บนเครื่องเปล่า** — check mode ไม่สร้างของจริง task ที่พึ่งผล
> ของ task ก่อนหน้าจึงล้ม เป็นข้อจำกัดของ Ansible ไม่ใช่บั๊ก · `--check` มีค่าหลังติดตั้งเสร็จ
> (ตรวจ drift) ไม่ใช่ก่อน

**สิ่งเดียวที่ playbook ตรวจแต่ไม่ทำให้:** kernel ต้องเป็นสาย `6.12` และเป็น `uek`
มาตั้งแต่ VM template — ถ้าผิดสาย playbook หยุดที่ task แรก ๆ ก่อนแตะอะไร
(สลับ kernel + reboot 6 เครื่องพร้อมกันคือความเสี่ยงที่ไม่ควรเป็นของอัตโนมัติ)
· หางเลข errata (`105`/`203`/`206`) ไม่คุม — ไม่กระทบ Cilium และเปลี่ยนทุกรอบ patch
· `versionlock` playbook ทำให้เอง · partition แยกเป็นทางเลือก
([บท 01 ข้อ 5](../docs/01-prepare-os.md)) playbook แค่บอกสถานะ

| ถ้าเจอ | แก้ |
|---|---|
| `kernel บนเครื่องนี้คือ ... แต่ versions.env ระบุสาย 6.12` | เครื่องมาผิด kernel — แก้ที่ template อย่าให้ playbook สลับให้ |
| `/etc/hosts` มี `k8s-master01` สองบรรทัด | เคยรันคู่มือรุ่นเก่า (ก่อน 27 ส.ค. 2026) ที่ไม่มี marker — playbook ลบบรรทัดนอกบล็อกให้เองแล้ว ถ้ายังซ้ำให้ `grep -n k8s- /etc/hosts` ดูว่าอันไหนอยู่นอก `# BEGIN/END k8s cluster` |

---

## 2 · `container-runtime.yml` — บท 02

ต้องผ่านข้อ 1 ครบทุกเครื่องก่อน · รันทั้ง cluster:

```bash
ansible-playbook container-runtime.yml
```

ค่าของ registry อยู่ใน [`group_vars/all.yml`](group_vars/all.yml) ตั้งไว้ตรงของจริงแล้ว
(`https` · CA สาธารณะ ไม่ต้องแจกไฟล์) — **ไม่ต้องแก้อะไรก่อนรัน**

**ถ้า registry เปลี่ยนที่อยู่หรือเปลี่ยนเป็น internal CA** ค่อยตรวจแล้วแก้สองบรรทัดนั้น:

```bash
curl -sI https://registry.myhr.co.th/v2/ || curl -sI http://registry.myhr.co.th/v2/
```

| ที่เห็น | ตั้ง |
|---|---|
| `https://` ตอบ `HTTP/2 401` หรือ `200` | `registry_scheme: https` (401 = ปกติ มันขอ auth) |
| `https://` ไม่ตอบ แต่ `http://` ตอบ | `registry_scheme: http` |
| `https://` ขึ้น `SSL certificate problem` | registry ใช้ internal CA → ใส่ path ไฟล์ CA ใน `registry_ca_file` |

| ถ้าเจอ | แก้ |
|---|---|
| ค้างนานตอนดาวน์โหลด | release asset ของ GitHub redirect ไป host ที่ช้ากว่ามาก (35-55 MB กินเวลาเป็นนาที) · รอได้ · หรือโหลดครั้งเดียวแล้ว `scp /root/k8s/dl/*` ไปวางที่เครื่องอื่น playbook เห็น checksum ตรงจะไม่โหลดซ้ำ |
| node ออก `github.com` ไม่ได้ | วางไฟล์ที่ `/root/k8s/dl/` เองก่อน task ดาวน์โหลดจะข้ามให้ |

---

## จบแล้ว → ทำมือต่อที่ [บทที่ 03](../docs/03-ha-layer.md)

ก่อนไป ตรวจว่าทั้ง 6 เครื่องอยู่ในสภาพเดียวกัน — playbook idempotent จึงใช้เป็นตัวตรวจได้:

```bash
ansible-playbook prepare-os.yml --check --skip-tags reboot
ansible-playbook container-runtime.yml --check
```

ทั้งสองต้อง `changed=0 failed=0` ทุกเครื่อง · คำสั่งคู่นี้ใช้ได้ตลอดอายุ cluster
เพื่อจับ config drift — ไม่ใช่แค่ตอนติดตั้ง

---

## แหล่งความจริงของเวอร์ชัน

playbook **ไม่มีเลขเวอร์ชันหรือ IP เขียนไว้ตรง ๆ เลย** — `pre_tasks` แรกจะ `source versions.env`
ด้วย bash แล้วแปลงเป็นตัวแปรของ Ansible ใช้ semantics เดียวกับที่คู่มือทำ
แก้ [`../docs/versions.env`](../docs/versions.env) ที่เดียวจึงมีผลทั้งคู่มือและ playbook

`inventory.ini` ต้องมี IP ตรงกับ `versions.env` — `config/validate-repo.sh` ข้อ 5 ตรวจให้

---

## คำสั่งที่ใช้บ่อย

| อยากทำอะไร | คำสั่ง |
|---|---|
| ดูว่าจะเปลี่ยนอะไร ไม่แก้จริง | `ansible-playbook prepare-os.yml --check --diff --skip-tags reboot` |
| รันแค่เครื่องเดียว | `... --limit k8s-worker01` |
| รันทุกเครื่องยกเว้นหนึ่ง | `... --limit 'k8s_nodes:!k8s-master01'` |
| รันแค่ worker | `... --limit workers` |
| ดูรายละเอียดตอนพัง | เติม `-vvv` |
| ทดสอบว่าคุยกับทุกเครื่องได้ | `ansible k8s_nodes -m ping` |
| ดูค่าอะไรบนทุกเครื่องพร้อมกัน | `ansible k8s_nodes -a 'uname -r'` |
