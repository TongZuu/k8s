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
**ควรเห็น:** `ens192  UP  192.168.50.10X/24`
ถ้าชื่อไม่ใช่ `ens192` ให้แก้ทั้งใน `versions.env` และในไฟล์ `keepalived-*.conf` ทั้ง 3 ไฟล์

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
cp /root/k8s/config/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg
```
**ควรเห็น:** `Configuration file is valid`

```bash
systemctl enable --now haproxy
ss -lnt | grep ':8443'
```
**ควรเห็น:** `LISTEN 0 ... *:8443`

> ตอนนี้ backend ทั้ง 3 ตัวจะ **DOWN** หมด เพราะยังไม่มี kube-apiserver — **ถูกต้องแล้ว**
> ดูได้ด้วย `curl -s http://127.0.0.1:8404/stats`

---

## 3 · วาง keepalived config

> **ระวัง: ไฟล์ต่างกันต่อเครื่อง** เลือกให้ตรงกับเครื่องที่กำลังทำอยู่

```bash
# บน master01 เท่านั้น
cp /root/k8s/config/keepalived/keepalived-master01.conf /etc/keepalived/keepalived.conf

# บน master02 เท่านั้น
cp /root/k8s/config/keepalived/keepalived-master02.conf /etc/keepalived/keepalived.conf

# บน master03 เท่านั้น
cp /root/k8s/config/keepalived/keepalived-master03.conf /etc/keepalived/keepalived.conf
```

**ใส่รหัส VRRP จริง — ต้องเหมือนกันทั้ง 3 เครื่อง:**
```bash
read -rsp 'VRRP auth_pass: ' VRRP_PASS && echo
sed -i "s|<VRRP_AUTH_PASS>|${VRRP_PASS}|" /etc/keepalived/keepalived.conf
unset VRRP_PASS
chmod 600 /etc/keepalived/keepalived.conf

# ตรวจว่าแทนที่สำเร็จจริง — ต้องไม่เหลือ placeholder
grep -c '<VRRP_AUTH_PASS>' /etc/keepalived/keepalived.conf
```
**ควรเห็น:** `0` — ถ้าได้ `1` แปลว่า `sed` ไม่โดน ให้ตรวจว่า copy ไฟล์ถูกตัวหรือยัง

> ⚠️ `auth_pass` ของ keepalived ใช้ได้ **ไม่เกิน 8 ตัวอักษร** ตัวที่เกินจะถูกตัดทิ้งเงียบ ๆ
> ถ้าตั้งยาวกว่านั้นแล้วแต่ละเครื่องพิมพ์ไม่เหมือนกัน จะกลายเป็นว่า **ทุกเครื่องคิดว่าตัวเองเป็น MASTER**
> รหัสนี้กัน VRRP packet หลงเข้ามาเท่านั้น ไม่ใช่ระบบความปลอดภัยจริง

**วาง health check script:**
```bash
cp /root/k8s/config/keepalived/check_apiserver.sh /etc/keepalived/check_apiserver.sh
chmod 700 /etc/keepalived/check_apiserver.sh

# ทดสอบสคริปต์ก่อนให้ keepalived เรียก
/etc/keepalived/check_apiserver.sh; echo "exit=$?"
```
**ควรเห็น:** `exit=0` (ตอนนี้ยังไม่มี apiserver แต่ HAProxy ฟัง 8443 อยู่แล้วจึงผ่าน)

```bash
systemctl enable --now keepalived
```

---

## 4 · ตรวจว่า VIP ขึ้นที่ master01

**บน master01:**
```bash
ip -4 addr show "$NODE_IFACE" | grep "$VIP"
```
**ควรเห็น:** `inet 192.168.50.100/24 scope global secondary ens192`

**บน master02 และ master03:**
```bash
ip -4 addr show "$NODE_IFACE" | grep "$VIP" || echo "ไม่มี VIP — ถูกต้อง"
```
**ควรเห็น:** `ไม่มี VIP — ถูกต้อง`

**จากเครื่องไหนก็ได้:**
```bash
ping -c3 "$VIP"
```
**ควรเห็น:** ตอบครบ 3 packet

> ถ้า VIP ขึ้นมากกว่าหนึ่งเครื่องพร้อมกัน = **split brain** สาเหตุที่พบบ่อย 3 ข้อ:
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
ip -4 addr show "$NODE_IFACE" | grep "$VIP"
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

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] VIP `192.168.50.100` ขึ้นที่ **เครื่องเดียวเท่านั้น**
- [ ] `ping $VIP` ได้จากทุก node รวมทั้ง worker
- [ ] `ss -lnt | grep 8443` เห็น HAProxy ฟังอยู่ทั้ง 3 master
- [ ] **failover 5.1 ผ่าน** — หยุด keepalived แล้ว VIP ย้าย ping ขาดไม่เกิน 3 packet
- [ ] **failover 5.2 ผ่าน** — หยุด HAProxy แล้ว VIP ย้ายเองภายใน ~10 วินาที
- [ ] **failover 5.3 ผ่าน** — reboot แล้ว service ขึ้นเอง
- [ ] VIP กลับมาอยู่ที่ master01 หลังทดสอบเสร็จ

> **จดเวลาที่ใช้ในการ failover จริงลงคู่มือ** เป็น baseline
> ถ้าวันหนึ่ง failover ช้ากว่านี้มาก แปลว่ามีอะไรเปลี่ยนไป

**➡️ ต่อที่ [บทที่ 04 — สร้าง Cluster](04-create-cluster.md)**
