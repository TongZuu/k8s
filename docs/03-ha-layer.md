# บทที่ 03 — HA Layer (keepalived + HAProxy)

> **รันที่: 🎩 master ทั้ง 3 เครื่อง** (`.101` `.102` `.103`)
> **เวลาที่ใช้:** ~20 นาที + ทดสอบ failover ~15 นาที
> **⚠️ บทนี้ต้องผ่าน failover test ก่อนไปบทที่ 04 เด็ดขาด**

---

## ทำไมบทนี้ห้ามข้าม

`controlPlaneEndpoint` ที่ใส่ตอน `kubeadm init` จะถูกฝังลงใน **certificate ของทั้ง cluster**
และ kubeconfig ของทุก component แก้ทีหลังหมายถึงต้องออก certificate ใหม่ทั้งชุดและแก้ทุก node

ถ้าไป `kubeadm init` โดย VIP ยังไม่ทำงาน **คุณจะต้องรื้อ cluster ทำใหม่ทั้งหมด**

---

## ทำไมเป็น systemd ไม่ใช่ static pod

cluster เดิมรัน keepalived/HAProxy เป็น static pod ใน `/etc/kubernetes/manifests`
ซึ่งมีปัญหาสองข้อ:

1. **หายไปพร้อม `kubeadm reset`** — ซึ่งคือช่วงที่คุณต้องการมันที่สุด
2. **ลำดับ bootstrap งง** — VIP ต้องมีก่อน cluster แต่ static pod ต้องมี kubelet ก่อน

เป็น systemd แล้ว: อยู่รอดข้าม `kubeadm reset`/upgrade, debug ด้วย `journalctl` ได้ตั้งแต่ก่อนมี cluster
และ image `osixia/keepalived` ที่ของเดิมใช้ก็ไม่มีคนดูแลมาหลายปีแล้ว

---

## 0 · โหลดตัวแปร

```bash
set -a && source /root/k8s/versions.env && set +a
echo "VIP=$VIP:$VIP_PORT  IFACE=$NODE_IFACE  VRID=$VRRP_ROUTER_ID"
```
**ควรเห็น:** `VIP=192.168.50.100:8443  IFACE=ens192  VRID=60`

**ยืนยันชื่อ interface จริง — อย่าเชื่อค่าใน versions.env โดยไม่ตรวจ:**
```bash
ip -br addr show | grep 192.168.50
```
**ควรเห็น:** ชื่อ interface พร้อม IP ของเครื่องนี้ เช่น `ens192  UP  192.168.50.101/24`

> ⚠️ **ชื่อ NIC ไม่จำเป็นต้องเหมือนกันทุกเครื่อง** — ขึ้นกับว่า VM ถูกสร้างด้วย
> virtual hardware รุ่นไหน (`ens192` มักเป็น VMXNET3 · `ens33`/`ens32` มักเป็น E1000)
> **อย่าจดค่าจากเครื่องแรกแล้วเหมาว่าใช้ได้ทุกเครื่อง** — ต้องดูทีละเครื่อง
>
> **สถานะของ cluster นี้ (11 ก.ย. 2026):** ทั้ง 6 เครื่องเป็น `ens192` ตรงกันหมดแล้ว
> — master02 (`192.168.50.102`) เคยเป็น `ens33` เครื่องเดียวในหกเครื่อง และถูกปรับมา
> เป็น `ens192` ก่อนการติดตั้งรอบนี้ · `NODE_IFACE=ens192` ใน `versions.env` จึงใช้ได้
> ทุกเครื่องแล้ว (ก่อนหน้านี้บท 01 ข้อ 1.1/1.2 จะฟ้อง `NOCONN` บน master02)
>
> **ยังต้องตรวจทีละเครื่องอยู่** — ใช้เวลาไม่ถึงนาที แต่ถ้าชื่อไม่ตรง keepalived จะ
> start ไม่ขึ้นเลย (อาการเต็ม ๆ อยู่ท้ายข้อ 3)
>
> ไฟล์ `keepalived-*.conf` เขียน `ens192` ไว้ตายตัว 2 จุด ข้อ 3 จึงมีขั้นตอนแก้ให้ตรงกับ
> เครื่องที่ทำอยู่แบบอัตโนมัติ — ไม่ต้องมาไล่แก้ในรีโปเอง

**ยืนยันว่ายังไม่มีใครใช้ VIP:**
```bash
ping -c2 -W1 "$VIP"
```
**ควรเห็น:** `100% packet loss` — ถ้ามีคนตอบ **ให้หยุด** แล้วไปคุยกับทีม network

---

## 1 · ติดตั้ง

```bash
dnf install -y keepalived haproxy
```

**ตรวจว่าได้ package ของ OS ไม่ใช่ container image:**
```bash
keepalived --version 2>&1 | head -1
haproxy -v | head -1
```
**ควรเห็น:** keepalived 2.2.x และ HAProxy 3.x (เลขแน่นอนตามที่ OL 9.8 ให้มา — **จดลง `versions.env`**)

---

## 2 · วาง HAProxy config

ไฟล์เดียวกันทั้ง 3 เครื่อง ไม่มีอะไรต่างกัน:

```bash
\cp -f /root/k8s/config/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg
```
**ควรเห็น:** `Configuration file is valid`

> ⚠️ `Configuration file is valid` **ไม่ได้แปลว่าไฟล์ถูกทับสำเร็จ** — ไฟล์ default ที่มากับ package
> ก็ผ่าน syntax check เหมือนกัน ต้องตรวจ**เนื้อใน**ด้วย:

```bash
grep -cE '^[[:space:]]*bind[[:space:]]+\*:8443' /etc/haproxy/haproxy.cfg
```
**ควรเห็น:** `1` — ถ้าได้ `0` แปลว่ายังเป็นไฟล์ default อยู่ (`bind *:5000`) ให้กลับไปตรวจว่า path ต้นทางถูกไหม

> ที่ต้องใช้ `-E` กับ `[[:space:]]+` เพราะในไฟล์จริง `bind` กับ `*:8443` คั่นด้วยช่องว่างหลายตัว
> (จัดคอลัมน์ให้อ่านง่าย) — เขียน `grep 'bind \*:8443'` เฉย ๆ จะได้ `0` ทั้งที่ไฟล์ถูกต้อง

```bash
systemctl enable haproxy
systemctl restart haproxy
ss -lnt | grep ':8443'
```
**ควรเห็น:** `LISTEN 0 ... *:8443`

> **ทำไมไม่ใช่ `systemctl enable --now haproxy`**
> `--now` จะ **start เฉพาะตอนที่ service ยังไม่รัน** ถ้ามันรันอยู่แล้ว (เช่น คุณเคยลอง start
> ก่อนวางไฟล์ config หรือย้อนกลับมาทำข้อนี้ซ้ำ) คำสั่งจะผ่านไปเงียบ ๆ โดย **ไม่โหลด config ใหม่**
> process เดิมยังถือไฟล์เก่าอยู่ แล้ว `ss` ก็จะไม่เห็นอะไรทั้งที่ไฟล์บนดิสก์ถูกต้องแล้ว
>
> `restart` ทำงานถูกทั้งสองกรณี — ยังไม่รันก็ start ให้ รันอยู่ก็โหลดใหม่ให้

> ตอนนี้ backend ทั้ง 3 ตัวจะ **DOWN** หมด เพราะยังไม่มี kube-apiserver — **ถูกต้องแล้ว**
> ดูได้ด้วย `curl -s "http://127.0.0.1:8404/stats;csv" | awk -F, '$1=="kube-apiserver-backend"{print $2, $18, "check="$37}'`
> · ก่อนสร้าง cluster backend จะ `DOWN` ทั้งหมดเป็นเรื่องปกติ เพราะยังไม่มี apiserver ให้ตรวจ
> · หลังบทที่ 04 ต้องกลับมาดูอีกครั้งว่าขึ้น `UP check=L7OK` จริง

---

## 3 · วาง keepalived config

> **ระวัง: ไฟล์ต่างกันต่อเครื่อง** สามบล็อกข้างล่างเป็นทางเลือก **รันแค่บล็อกเดียว**
> ให้ตรงกับเครื่องที่กำลังทำอยู่ — ถ้ารันทั้งสามบล็อกบนเครื่องเดียว จะเหลือของ master03
> ค้างอยู่ แล้วเจอ split brain ตอนข้อ 4

**🎩 บน master01:**
```bash
\cp -f /root/k8s/config/keepalived/keepalived-master01.conf /etc/keepalived/keepalived.conf
```

**🎩 บน master02:**
```bash
\cp -f /root/k8s/config/keepalived/keepalived-master02.conf /etc/keepalived/keepalived.conf
```

**🎩 บน master03:**
```bash
\cp -f /root/k8s/config/keepalived/keepalived-master03.conf /etc/keepalived/keepalived.conf
```

**ตรวจว่าได้ไฟล์ของเครื่องนี้จริง — ไม่ใช่ไฟล์ตัวอย่างที่มากับ package และไม่ใช่ของเครื่องอื่น:**
```bash
grep -c "router_id $(hostname -s)" /etc/keepalived/keepalived.conf
```
**ควรเห็น:** `1` — ถ้าได้ `0` แปลว่า copy ไม่โดน หรือหยิบไฟล์ผิดเครื่อง **ให้หยุดแก้ก่อน**
เพราะถ้าปล่อยไป จะได้ `priority` ซ้ำกันสองเครื่องแล้วเจอ split brain ตอนข้อ 4

**แก้ชื่อ interface ให้ตรงกับเครื่องนี้ — ทำทุกเครื่อง ไม่ว่าข้อ 0 จะเห็นชื่ออะไร:**
```bash
IFACE=$(ip -o -4 addr show | awk '$4 ~ /^192\.168\.50\./ {print $2; exit}')
echo "interface ของเครื่องนี้: [${IFACE}]"

if [ -z "$IFACE" ]; then
    echo "❌ หา interface ที่ถือ IP 192.168.50.x ไม่เจอ — ไม่แตะไฟล์"
else
    sed -i "s/\bens192\b/${IFACE}/g" /etc/keepalived/keepalived.conf
fi

grep -n 'interface \|dev ' /etc/keepalived/keepalived.conf
```
**ควรเห็น:** ชื่อในวงเล็บไม่ว่าง และสองบรรทัดสุดท้ายเป็นชื่อ interface จริงของเครื่องนี้ทั้งคู่

> ถ้าปล่อยชื่อผิดไว้ keepalived จะ **start ไม่ขึ้น** โดยขึ้น log ว่า
> `WARNING - interface ens192 for vrrp_instance VI_K8S doesn't exist` ตามด้วย
> `exited with permanent error CONFIG` — เป็น config error ไม่ใช่ปัญหา network

**ใส่รหัส VRRP จริง — ต้องเหมือนกันทั้ง 3 เครื่อง:**

> บล็อกนี้คัดลอกทั้งก้อนมาวางได้ — บรรทัดแรกจะ**หยุดรอให้พิมพ์รหัส**
> ตัวอักษรจะไม่ขึ้นบนจอ (`-s` ปิดการแสดงผล) ดูเหมือนค้างแต่ไม่ได้ค้าง
> พิมพ์แล้วกด Enter บรรทัดที่เหลือจะรันต่อเอง

```bash
read -rsp 'VRRP auth_pass: ' VRRP_PASS && echo "รับมา ${#VRRP_PASS} ตัวอักษร"

if [ -z "$VRRP_PASS" ]; then
    echo "❌ ไม่ได้พิมพ์อะไรเลย — ไม่แตะไฟล์ ให้รันบล็อกนี้ใหม่"
else
    sed -i "s|<VRRP_AUTH_PASS>|${VRRP_PASS}|" /etc/keepalived/keepalived.conf
    chmod 600 /etc/keepalived/keepalived.conf
fi
unset VRRP_PASS

# ตรวจค่าที่ลงไปจริง — ไม่ใช่แค่ดูว่า placeholder หายไปแล้ว
awk '$1=="auth_pass"{print "auth_pass = [" $2 "]"}' /etc/keepalived/keepalived.conf
```
**ควรเห็น:** จำนวนตัวอักษรมากกว่า `0` และบรรทัดสุดท้ายเป็น `auth_pass = [รหัสจริงของคุณ]`

> ⚠️ ถ้าเห็น `auth_pass = [!]` แปลว่ารหัสว่าง — `sed` เขียนค่าว่างทับ placeholder ไปแล้ว
> keepalived จะ **parse ไฟล์ไม่ผ่านและ start ไม่ขึ้น** ต้อง `\cp -f` ไฟล์ต้นฉบับมาทับใหม่
> แล้วทำข้อนี้ซ้ำ — แก้ที่ไฟล์ตรง ๆ ไม่ได้เพราะ placeholder หายไปแล้ว
>
> ห้ามเช็กด้วย `grep -c '<VRRP_AUTH_PASS>'` อย่างเดียว — ค่าว่างก็ทำให้ placeholder หายเหมือนกัน
> มันจะได้ `0` เหมือนตอนสำเร็จทุกประการ

> ⚠️ `auth_pass` ของ keepalived ใช้ได้ **ไม่เกิน 8 ตัวอักษร** ตัวที่เกินจะถูกตัดทิ้งเงียบ ๆ
> ถ้าตั้งยาวกว่านั้นแล้วแต่ละเครื่องพิมพ์ไม่เหมือนกัน จะกลายเป็นว่า **ทุกเครื่องคิดว่าตัวเองเป็น MASTER**
> รหัสนี้กัน VRRP packet หลงเข้ามาเท่านั้น ไม่ใช่ระบบความปลอดภัยจริง

**วาง health check script:**
```bash
\cp -f /root/k8s/config/keepalived/check_apiserver.sh /etc/keepalived/check_apiserver.sh
chmod 700 /etc/keepalived/check_apiserver.sh

# ทดสอบสคริปต์ก่อนให้ keepalived เรียก
/etc/keepalived/check_apiserver.sh; echo "exit=$?"
```
**ควรเห็น:** `exit=0` — ผ่านที่ **ด่าน 2** ของสคริปต์ ซึ่งยอมให้ผ่านเมื่อยังไม่มี `kube-apiserver`
ฟังที่ `:6443` บนเครื่องนี้ (คือช่วง bootstrap ตอนนี้) ยังไม่ได้พิสูจน์เส้นทาง VIP อะไรทั้งนั้น

> ด่าน 2 มีไว้กัน VIP กระพริบ — ถ้าไม่มี เครื่องที่ถือ VIP จะยิง `/healthz` ไม่ผ่าน
> (เพราะ HAProxy ยังไม่มี backend เป็น ๆ) แล้วโดนหัก priority 20 จนเสีย VIP ให้เครื่องอื่น
> ซึ่งก็จะตกด้วยเหตุผลเดียวกัน วนไม่จบทุก ~6-12 วินาที **จนกว่าจะมี cluster**

```bash
systemctl enable keepalived
systemctl restart keepalived
```
(เหตุผลเดียวกับ HAProxy — `restart` ไม่ใช่ `enable --now` เพื่อให้ config ที่เพิ่งวางถูกโหลดแน่นอน)

---

## 4 · ตรวจว่า VIP ขึ้นที่ master01

**บน master01:**
```bash
ip -4 addr show | grep "$VIP"
```
**ควรเห็น:** `inet 192.168.50.100/24 scope global secondary <ชื่อ interface ของเครื่องนี้>`

**บน master02 และ master03:**
```bash
ip -4 addr show | grep "$VIP" || echo "ไม่มี VIP — ถูกต้อง"
```
**ควรเห็น:** `ไม่มี VIP — ถูกต้อง`

**จากเครื่องไหนก็ได้:**
```bash
ping -c3 "$VIP"
```
**ควรเห็น:** ตอบครบ 3 packet

**ยืนยันว่า VIP นิ่งจริง ไม่ใช่แค่บังเอิญถูกจังหวะ — รันซ้ำห่างกัน 10 วินาที:**
```bash
for ip in 101 102 103; do echo -n "$ip: "; ssh root@192.168.50.$ip "ip -4 a s | grep -c 192.168.50.100"; done
```
**ควรเห็น:** `101: 1` · `102: 0` · `103: 0` **เหมือนกันทั้งสองรอบ**

> **ถ้าเลข `1` ย้ายเครื่องไปมา = VIP กระพริบ ไม่ใช่ split brain** — สองอย่างนี้อาการต่างกัน
> และสาเหตุคนละเรื่อง อย่าเอาไปรวมกัน
>
> ยืนยันด้วย log — กระพริบจะเห็นสลับ MASTER/BACKUP ถี่ ๆ:
> ```bash
> journalctl -u keepalived -n 40 --no-pager | grep -iE 'Entering|transition'
> ```
> ถ้าเจอ ให้ตรวจว่า `check_apiserver.sh` บนเครื่องมีด่าน 2 (`grep -q ':6443 '`) หรือยัง
> — สคริปต์รุ่นที่ไม่มีด่านนี้จะทำให้เครื่องที่ถือ VIP หัก priority ตัวเองจนเสีย VIP วนไปเรื่อย ๆ

> ถ้า VIP ขึ้นมากกว่าหนึ่งเครื่อง **แล้วค้างอยู่อย่างนั้น** = **split brain** ตัวจริง
> (ต่างจากกระพริบตรงที่ไม่สลับ ทุกเครื่องคิดว่าตัวเองเป็น MASTER พร้อมกัน)
> สาเหตุที่พบบ่อย 3 ข้อ:
> 1. `auth_pass` ไม่ตรงกัน (ดูเรื่อง 8 ตัวอักษรด้านบน)
> 2. firewalld ยังไม่เปิด `--add-protocol=vrrp` — ตรวจด้วย `firewall-cmd --list-protocols`
> 3. switch บล็อก multicast `224.0.0.18`
>
> ดู log ด้วย: `journalctl -u keepalived -n 50 --no-pager`

---

## 5 · 🔴 ทดสอบ failover — ห้ามข้ามข้อนี้

นี่คือขั้นตอนเดียวที่พิสูจน์ว่า HA ทำงานจริง ไม่ใช่แค่ config ดูถูก

### เตรียม — เปิดหน้าต่างที่ 2 ค้างไว้ ping VIP ตลอดเวลา

```bash
ping "$VIP" | ts '%H:%M:%.S' 2>/dev/null || ping "$VIP"
```

### ทดสอบ 5.1 — หยุด keepalived บนเครื่องที่ถือ VIP

**บน master01:**
```bash
systemctl stop keepalived
```

**ตรวจภายใน 5 วินาที บน master02:**
```bash
ip -4 addr show | grep "$VIP"
```
**ควรเห็น:** VIP ย้ายมาที่ master02 แล้ว · หน้าต่าง ping ขาดไม่เกิน **2-3 packet**

**คืนค่า:**
```bash
systemctl start keepalived    # บน master01
```
**ควรเห็น:** VIP กลับไปที่ master01 ภายในไม่กี่วินาที (เพราะ priority สูงกว่า)

### ทดสอบ 5.2 — หยุด HAProxy (health check ต้องจับได้)

**บนเครื่องที่ถือ VIP อยู่:**
```bash
systemctl stop haproxy
```

**ควรเห็น:** ภายใน ~10 วินาที (`interval 3` × `fall 2` + margin) VIP ย้ายไปเครื่องอื่น
เพราะ `check_apiserver.sh` คืน exit 1 → priority ลด 20 → ต่ำกว่าเครื่องถัดไป

ดู log ยืนยัน:
```bash
journalctl -u keepalived -n 20 --no-pager | grep -i -E 'script|priority|state'
```

**คืนค่า:**
```bash
systemctl start haproxy
```

### ทดสอบ 5.3 — reboot เครื่องที่ถือ VIP

```bash
reboot
```
**ควรเห็น:** VIP ย้ายทันที · หลังเครื่องกลับมา keepalived และ HAProxy ขึ้นเองโดยไม่ต้องสั่ง
(นี่คือสิ่งที่ `systemctl enable` ทำ — และคือเหตุผลที่เราไม่ใช้ static pod)

**ตรวจหลังกลับมา:**
```bash
systemctl is-enabled keepalived haproxy
systemctl is-active  keepalived haproxy
```
**ควรเห็น:** `enabled` ทั้งคู่ และ `active` ทั้งคู่

### 🔴 ทดสอบ 5.4 — พิสูจน์ด้วย `kubectl` จริง (ทำได้หลัง[บทที่ 04](04-create-cluster.md) เท่านั้น)

ข้อ 5.1-5.3 ทำได้ตั้งแต่ยังไม่มี cluster แต่มันพิสูจน์ได้แค่ว่า **keepalived ย้าย IP เป็น**
ยังไม่ได้พิสูจน์ว่า **ย้ายแล้วใช้งานต่อได้** ซึ่งเป็นสิ่งที่เราต้องการจริง ๆ

เหตุผลอยู่ใน [`check_apiserver.sh`](../config/keepalived/check_apiserver.sh) ด่าน 2 —
ตอนยังไม่มี apiserver ฟังที่ `:6443` สคริปต์จะ `exit 0` ออกไปเลย **ด่าน 3
(ยิง `/healthz` ผ่าน VIP) จึงไม่เคยถูกรันเลยสักครั้ง** จนกว่าจะมี cluster จริง

**เงื่อนไขก่อนเริ่ม — ต้องผ่านทั้งหมด ไม่งั้นการทดสอบจะ "ผ่าน" แบบหลอก:**

```bash
for ip in 101 102 103; do
  echo -n "master$ip: "
  ssh root@192.168.50.$ip 'curl -s "http://127.0.0.1:8404/stats;csv"'     | awk -F, '$1=="kube-apiserver-backend"{printf "%s=%s ", $2, $37}'
  echo
done
```

**ควรเห็น:** `L7OK` ครบ 3 ตัวในทุกเครื่อง (9 ช่อง) — ถ้าเครื่องไหนได้ `L6RSP` ให้แก้ก่อน
([บทที่ 13 ข้อ 1.3b](13-troubleshooting.md)) เพราะ VIP อาจย้ายไปเครื่องที่ส่ง traffic ต่อไม่ได้
ซึ่งแย่กว่าไม่ย้ายเลย

**หน้าต่างที่ 2 — วน `kubectl` ผ่าน VIP ค้างไว้ตลอดการทดสอบ:**

```bash
while true; do
  printf '%s ' "$(date +%H:%M:%S)"
  kubectl get --raw='/healthz' 2>&1 | tr -d '
'
  echo
  sleep 1
done
```

**หน้าต่างที่ 1 — หยุด keepalived บนเครื่องที่ถือ VIP:**

```bash
systemctl stop keepalived
```

**เกณฑ์ผ่านที่แท้จริง:** หน้าต่างที่ 2 ขาดได้ไม่เกิน **2-3 บรรทัด** แล้วกลับมาเป็น `ok` เอง
โดยไม่ต้องแตะ kubeconfig หรือรีสตาร์ตอะไรทั้งสิ้น

**คืนค่า แล้วยืนยันว่า VIP กลับบ้าน:**

```bash
systemctl start keepalived
sleep 5; for ip in 101 102 103; do echo -n "master$ip: "; ssh root@192.168.50.$ip "ip -4 addr show | grep -c 192.168.50.100"; done
```

**ควรเห็น:** `1` ที่ master01 เครื่องเดียว · อีกสองเครื่องเป็น `0`

> **จดผลลงบทที่ 13 ทุกครั้ง** — เวลาที่ VIP ใช้ย้ายจริงกี่วินาที คือตัวเลขที่ต้องใช้
> ตอนตอบทีมว่า downtime ของ control plane ตอน failover เท่าไหร่ · เดาไม่ได้ ต้องวัด

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] VIP `192.168.50.100` ขึ้นที่ **เครื่องเดียวเท่านั้น**
- [ ] `ping $VIP` ได้จากทุก node รวมทั้ง worker
- [ ] `ss -lnt | grep 8443` เห็น HAProxy ฟังอยู่ทั้ง 3 master
- [ ] **failover 5.1 ผ่าน** — หยุด keepalived แล้ว VIP ย้าย ping ขาดไม่เกิน 3 packet
- [ ] **failover 5.2 ผ่าน** — หยุด HAProxy แล้ว VIP ย้ายเองภายใน ~10 วินาที
- [ ] **failover 5.3 ผ่าน** — reboot แล้ว service ขึ้นเอง
- [ ] VIP กลับมาอยู่ที่ master01 หลังทดสอบเสร็จ
- [ ] **failover 5.4 ผ่าน** — 🔴 ทำหลังบทที่ 04 · `kubectl` ผ่าน VIP ขาดไม่เกิน 2-3 วินาทีตอนย้าย
      (ข้อ 5.1-5.3 ทำก่อนมี cluster ได้ แต่พิสูจน์แค่ว่า IP ย้ายเป็น ไม่ได้พิสูจน์ว่าใช้งานต่อได้)

> **จดเวลาที่ใช้ในการ failover จริงลงคู่มือ** เป็น baseline
> ถ้าวันหนึ่ง failover ช้ากว่านี้มาก แปลว่ามีอะไรเปลี่ยนไป

**➡️ ต่อที่ [บทที่ 04 — สร้าง Cluster](04-create-cluster.md)**
