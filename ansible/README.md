# Ansible — แทนบทที่ 01 และ 02

รันขั้นตอนเตรียม OS และติดตั้ง container runtime ให้ทุกเครื่องพร้อมกัน
แทนการ SSH เข้าไป copy-วางทีละเครื่อง (บท 01+02 มี 47 บล็อกคำสั่ง × 6 เครื่อง)

---

## 🔴 อ่านก่อน — playbook ชุดนี้ยังไม่เคยรันจริง

เขียนจากบท [01](../docs/01-prepare-os.md) และ [02](../docs/02-container-runtime.md) โดยตรง
**ตรวจแล้วแค่ว่า YAML syntax ถูก** ยังไม่เคยยิงใส่เครื่องจริงแม้แต่ครั้งเดียว

ความต่างของความเสียหายเวลาผิด:

```
คู่มือผิด     → วาง → เห็น error → หยุด          เสีย 1 เครื่อง
playbook ผิด → รันทีเดียว 6 เครื่องพร้อมกัน       เสีย 6 เครื่อง
```

**ห้ามรันใส่ production เป็นที่แรกเด็ดขาด** ทำตามลำดับในหัวข้อ "วิธีรันครั้งแรก" ด้านล่าง

---

## ต้องมีอะไรบ้าง

**เครื่องปลายทางทั้ง 6 — ไม่ต้องลงอะไร** Ansible ใช้ SSH ล้วน ขอแค่ `sshd` กับ `python3`
ซึ่ง OL 9.8 มีมาให้แล้วทั้งคู่

**เครื่องที่รัน Ansible** — Ansible เป็น control node บน Windows ไม่ได้ ใช้ WSL2:

```bash
wsl --install -d Ubuntu          # รันใน PowerShell ครั้งเดียว
```

จากใน WSL:

```bash
sudo apt update && sudo apt install -y ansible
ansible --version                 # ต้องได้ 2.15 ขึ้นไป
```

> ⚠️ ต้องเป็น `ansible` (ตัวเต็ม) ไม่ใช่ `ansible-core` เพราะ playbook ใช้ module จาก
> `ansible.posix` (sysctl, selinux, firewalld) และ `community.general` (modprobe)
> ถ้าลง `ansible-core` มาแล้ว เติมด้วย:
> ```bash
> ansible-galaxy collection install ansible.posix community.general
> ```

**SSH key** — Ansible เข้าเครื่องโดยไม่ถามรหัสผ่านไม่ได้:

```bash
ssh-keygen -t ed25519
for ip in 101 102 103 104 105 106; do ssh-copy-id root@192.168.50.$ip; done
```

ทดสอบว่าเข้าได้ครบ:

```bash
cd ansible
ansible k8s_nodes -m ping
```
**ควรเห็น:** ทั้ง 6 เครื่องตอบ `SUCCESS` — ถ้าเครื่องไหนไม่ตอบ แก้ให้จบก่อนไปต่อ

---

## วิธีรันครั้งแรก — ห้ามข้ามลำดับ

### ขั้น 1 · ทำมือหนึ่งเครื่องก่อน  ✅ เสร็จแล้ว (27 ส.ค. 2026 — master01)

ต้องรู้ก่อนว่า "ถูกต้อง" หน้าตาเป็นยังไง ถึงจะบอกได้ว่า playbook ทำถูกหรือเปล่า

### ขั้น 2 · 🔑 `--check` ใส่เครื่องที่ทำมือเสร็จแล้ว — ต้องได้ changed=0

**นี่คือการทดสอบที่ดีที่สุดที่มี** เพราะเรารู้คำตอบล่วงหน้า:
เครื่องนั้นอยู่ในสถานะปลายทางที่ถูกต้องอยู่แล้ว **playbook ที่เขียนถูกจึงต้องบอกว่าไม่มีอะไรต้องเปลี่ยน**

```bash
ansible-playbook prepare-os.yml --check --diff --limit k8s-master01 --skip-tags reboot
```

| ผลที่ได้ | แปลว่า |
|---|---|
| `changed=0` | playbook ตรงกับสิ่งที่คู่มือทำ — เชื่อถือได้ ไปขั้น 3 |
| `changed=N` | **playbook ไม่ตรงกับคู่มือ** อ่าน `--diff` ว่ามันอยากเปลี่ยนอะไร แล้วตัดสินว่าใครผิด |
| `failed` | assert ไม่ผ่าน — อ่านข้อความ มักเป็นเรื่อง versionlock หรือ partition |

> ⚠️ ใส่ `--skip-tags reboot` เสมอในขั้นนี้ ไม่งั้นมันจะ reboot เครื่องที่เพิ่งทำเสร็จ

> **`changed=N` ไม่ได้แปลว่า playbook ผิดเสมอไป** — บาง task รายงาน changed ทุกครั้งโดยธรรมชาติ
> (เช่น `dnf config-manager` ที่ไม่มีทางรู้ว่า repo เปิดอยู่แล้ว) ดู `--diff` ประกอบเสมอ

### ขั้น 3 · รันจริงใส่เครื่องที่ยังไม่ได้ทำ หนึ่งเครื่อง

```bash
ansible-playbook prepare-os.yml --limit k8s-master02
```

แล้วเทียบกับเครื่องที่ทำมือ — ต้องเหมือนกันทุกบรรทัด:

```bash
ansible k8s-master01,k8s-master02 -m script -a 'config/audit-node.sh'
```

### ขั้น 4 · ผ่านแล้วค่อยยิงที่เหลือ

```bash
ansible-playbook prepare-os.yml --limit 'k8s-master03,workers'
ansible-playbook container-runtime.yml
```

---

## สิ่งที่ playbook ตั้งใจ "ไม่ทำ"

| บท 01 ข้อ | ทำไมไม่ทำ | ต้องทำที่ไหนแทน |
|---|---|---|
| **2 · สลับ/ตรึง kernel** | เปลี่ยน kernel แล้ว reboot อัตโนมัติพร้อมกัน 6 เครื่องคือความเสี่ยงที่ไม่จำเป็น | VM template (Phase 0) |
| **5 · ย้าย partition `/home`** | `umount` + แก้ `/etc/fstab` + `mount -a` พลาดแล้ว**เครื่องบูตไม่ขึ้น** | แบ่ง partition ตอนสร้าง template |
| **9 · วัด fsync ด้วย fio** | เป็นการ**วัด** ไม่ใช่การตั้งค่า ต้องมีคนอ่านตัวเลขแล้วตัดสินใจ | ทำมือตามบท 01 |

ทั้งสามข้อมี task **ตรวจ** ว่าทำมาแล้วหรือยัง ถ้ายังไม่ได้ทำ playbook จะหยุดพร้อมบอกเหตุผล
ไม่ใช่ทำต่อไปเงียบ ๆ

---

## แหล่งความจริงของเวอร์ชัน

playbook **ไม่มีเลขเวอร์ชันหรือ IP เขียนไว้ตรง ๆ เลย** — task แรกจะ `source versions.env`
ด้วย bash แล้วแปลงเป็นตัวแปรของ Ansible ใช้ semantics เดียวกับที่คู่มือทำเป๊ะ

แปลว่าแก้ [`../docs/versions.env`](../docs/versions.env) ที่เดียวยังใช้ได้เหมือนเดิม
ตรงตามกติกาข้อ 1 ของคู่มือ

ค่าที่ **ไม่ได้** อยู่ใน `versions.env` อยู่ใน [`group_vars/all.yml`](group_vars/all.yml):

| ตัวแปร | ต้องตั้งก่อนรัน `container-runtime.yml` |
|---|---|
| `registry_scheme` | `https` หรือ `http` — **ต้องยืนยันของจริงก่อน** ไม่ใช่เดา |
| `registry_ca_file` | path ของ CA ถ้า registry ใช้ internal CA (เว้นว่าง = ไม่ต้องลง) |

ตรวจว่า registry เป็นแบบไหน:

```bash
curl -sI https://registry.myhr.co.th/v2/ || curl -sI http://registry.myhr.co.th/v2/
```

---

## คำสั่งที่ใช้บ่อย

| อยากทำอะไร | คำสั่ง |
|---|---|
| ดูว่าจะเปลี่ยนอะไร ไม่แก้จริง | `ansible-playbook prepare-os.yml --check --diff` |
| รันแค่เครื่องเดียว | `ansible-playbook prepare-os.yml --limit k8s-worker01` |
| รันแค่ worker | `ansible-playbook prepare-os.yml --limit workers` |
| ข้ามการ reboot | `ansible-playbook prepare-os.yml --skip-tags reboot` |
| ดูรายละเอียดตอนพัง | เติม `-vvv` |
| ตรวจว่าเครื่องยังตรงสเปกไหม | `ansible-playbook prepare-os.yml --check` (รันซ้ำได้ตลอด) |

**ข้อสุดท้ายคือประโยชน์ที่แท้จริง** — playbook idempotent รันซ้ำกี่รอบก็ได้ผลเดิม
เอามาใช้เป็นเครื่องมือ**ตรวจ config drift** ได้ตลอดอายุ cluster ไม่ใช่แค่ตอนติดตั้ง
ซึ่งตอบความเสี่ยงข้อ "node บูตคนละ kernel โดยไม่รู้ตัว" ใน blueprint โดยตรง

---

## เมื่อไหร่ควรใช้จริง

| Phase | ใช้ยังไง |
|---|---|
| **Phase 1 lab** | ทำมือ 1 เครื่อง → รัน playbook ใส่ที่เหลือ → เทียบผล → แก้ playbook |
| **Phase 3 รื้อสร้างใหม่** | นี่คือรอบที่คุ้มที่สุด และเป็นการทดสอบ playbook ไปในตัว |
| **Phase 4 production** | ใช้ตัวที่ผ่าน Phase 3 มาแล้วเท่านั้น |

**อย่าใช้ playbook นี้กับ production ก่อนที่มันจะผ่าน Phase 3**
