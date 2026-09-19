# บทที่ 08 — Storage

> **รันที่: 👑 master01** · ยกเว้นข้อ 1 ที่ `ssh` ไป worker03 จาก**เครื่องคุณ**
> **ลำดับ: 1 → 2** — ข้อ 2 apply PV ที่ชี้โฟลเดอร์ของข้อ 1 · ไม่มีโฟลเดอร์ PV ก็ `Available` ได้
> แต่ pod ในบท 09 จะค้าง `Init:0/1` ด้วย `FailedMount ... does not exist` (เจอจริง 20 ก.ย. 2026)
> **เวลาที่ใช้:** ~15 นาที
> **บทนี้สั้นที่สุดในชุด — และนั่นคือเจตนา**

---

## 🔴 ข้อสรุป: cluster นี้ไม่มี CSI และไม่มี dynamic provisioning

**ไม่ใช่เพราะลืม แต่เป็นการตัดสินใจ (D8)** — workload ทั้งหมดเป็น stateless
ฐานข้อมูลอยู่นอก cluster ตลอด

```bash
kubectl get storageclass
```
**ควรเห็น:** `No resources found` ← **ถูกต้องแล้ว**

**ผลที่ตามมา:** `PersistentVolumeClaim` ที่ไม่ระบุ PV จะค้าง `Pending` ตลอดไป
ไม่มีใครมา provision ให้ — และนั่นคือพฤติกรรมที่เราต้องการ เพราะมันบังคับให้
ทุกคนที่อยากใช้ storage ต้องมาคุยกันก่อน ไม่ใช่แอบสร้างขึ้นมาเงียบ ๆ

> ⚠️ **ประกาศเรื่องนี้ให้ทีม dev รู้ตั้งแต่วันแรก**
> วันหนึ่งจะมีคนอยากลง Redis หรือ Kafka แล้วมาติดตรงนี้ — ให้เป็นบทสนทนาที่วางแผนไว้
> ไม่ใช่เซอร์ไพรส์ตอนใกล้ deadline

---

## แล้ว Prometheus กับ Loki ล่ะ

นี่คือคำถามที่ต้องตอบให้ชัด เพราะ **บทที่ 09 ต้องเก็บข้อมูลลง disk จริง**
ถ้าใช้ `emptyDir` ข้อมูลจะหายทุกครั้งที่ pod restart ซึ่งทำให้ตอบคำถาม
"เมื่อคืนตอนตีสามเกิดอะไรขึ้น" ไม่ได้ — ซึ่งเป็นเหตุผลเดียวที่เราติดตั้งมัน

**ทางออก: static `local` PersistentVolume**

`local` volume เป็น**ฟีเจอร์ใน Kubernetes core** ไม่ใช่ CSI driver
เราสร้าง PV ขึ้นมาด้วยมือชี้ไปที่ directory บน node ที่กำหนด — ไม่ต้องลง provisioner อะไรเลย

| | dynamic provisioning (CSI) | static local PV |
|---|---|---|
| ต้องลง driver | ✅ ต้อง | ❌ ไม่ต้อง |
| ใครสร้าง PV | อัตโนมัติ | **เราสร้างเองทีละอัน** |
| pod ย้าย node ได้ | ✅ | ❌ ผูกกับ node ที่ระบุ |
| เหมาะกับ | application ทั่วไป | **infrastructure ที่มีตัวเดียวและเรารู้ว่ามันอยู่ไหน** |

**นี่ไม่ได้ขัดกับ D8** — D8 บอกว่าไม่มี CSI และไม่มี dynamic provisioning สำหรับ application
ส่วนนี่คือ PV ที่เราสร้างเองสำหรับ infrastructure ของเราเอง 3 ตัว จบ

---

## ราคาที่ต้องยอมรับ

pod ที่ใช้ local PV **ผูกกับ node นั้นถาวร** ย้ายไม่ได้ ผลตรง ๆ คือ:

> ตอน rolling reboot เครื่องที่ถือ PV อยู่ **Prometheus และ Loki จะดับประมาณ 5 นาที**
> แปลว่าคุณไม่มี monitoring ในช่วงที่กำลังทำงานเสี่ยงพอดี

**ยอมรับได้ในระดับนี้** เพราะ metric ที่ขาดไป 5 นาทีต่อรอบ patch ไม่ใช่เรื่องใหญ่
และทางเลือกอื่น (ลง CSI, หรือยก monitoring ออกไป VM แยก) แพงกว่ามาก

**แต่ต้องรู้ตัว** และเวลาทำ rolling reboot ให้ **เริ่มจาก node ที่ถือ monitoring ก่อนเสมอ**
จะได้มี monitoring ครบตอนทำเครื่องที่เหลือ

---

## 1 · เตรียม directory บน worker03

**ทำที่:** จาก**เครื่องคุณ** (WSL/Git Bash ที่มี key ครบ 6 เครื่อง) — คำสั่งเดียว `ssh` เข้าไปทำให้
· **ต้องมีก่อน:** [บท 06](06-verify.md) ผ่าน · worker03 `Ready`

เลือก `k8s-worker03` เป็นเครื่องเก็บ monitoring — จะได้ไม่ปนกับ workload หลัก
**โฟลเดอร์ต้องอยู่บน worker03 เครื่องเดียวเท่านั้น** — PV ในข้อ 2 ผูกกับเครื่องนี้ด้วย `nodeAffinity`
สร้างบน master01 ไม่มีผลอะไร

```bash
ssh root@192.168.50.106 'mkdir -p /var/lib/monitoring/{prometheus,loki,grafana} && chmod 700 /var/lib/monitoring/* && ls -ld /var/lib/monitoring/* && df -h /var/lib/monitoring'
```
**ควรเห็น:** 3 บรรทัด `drwx------` (`grafana` · `loki` · `prometheus`) แล้ว `df` ว่างอย่างน้อย ~200 GB บน root filesystem

> ระวัง: `/var/lib/containerd` เป็น partition แยก 100 GB แต่ `/var/lib/monitoring`
> อยู่บน **root** ซึ่งมี 400 GB ร่วมกับ log และ OS
> ตั้ง retention ในบทที่ 09 ให้ไม่กินเกิน ~200 GB และ**ต้องมี alert ที่ disk usage**

**ติด label ให้ node เพื่อให้อ่านง่าย:**
```bash
# บน master01
kubectl label node k8s-worker03 myhr.co.th/monitoring=true
```

---

## 2 · สร้าง StorageClass และ PV

```bash
kubectl apply -f /root/k8s/config/storage/local-storage-class.yaml
kubectl apply -f /root/k8s/config/storage/monitoring-pv.yaml

kubectl get sc
kubectl get pv
```

**ควรเห็น:**
```
NAME            PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE
local-storage   kubernetes.io/no-provisioner   Retain          WaitForFirstConsumer

NAME              CAPACITY   RECLAIM POLICY   STATUS      CLAIM
prometheus-data   150Gi      Retain           Available   monitoring/prometheus-monitoring-...-0
loki-data         50Gi       Retain           Available   monitoring/storage-loki-0
grafana-data      5Gi        Retain           Available   monitoring/monitoring-grafana
```

**`STATUS: Available` แต่มีชื่อใน `CLAIM` แล้ว — ถูกต้อง** คือจองไว้ให้ PVC นั้นโดยเฉพาะ
แล้วจะกลายเป็น `Bound` เมื่อบทที่ 09 สร้าง PVC มาขอจริง

> **`WaitForFirstConsumer` สำคัญ** — ทำให้ scheduler เลือก node ก่อนแล้วค่อยผูก PV
> ถ้าใช้ `Immediate` จะผูก PV ก่อนแล้ว pod อาจถูก schedule ไปคนละเครื่องจนค้างตลอดกาล
>
> **`Retain` ก็สำคัญ** — ลบ PVC แล้วข้อมูลยังอยู่ ต้องมาลบ directory เองด้วยมือ
> ปลอดภัยกว่า `Delete` มากสำหรับข้อมูลที่กู้กลับไม่ได้

---

### 🔴 ทำไมทุก PV ต้องมี `claimRef` — ข้อนี้ห้ามลบ

Kubernetes จับคู่ PVC กับ PV **โดยไม่ดูชื่อเลย** มันดูแค่ 3 อย่าง:

1. `storageClassName` ตรงกันไหม
2. `accessModes` เข้ากันได้ไหม
3. ขนาด PV **≥** ที่ PVC ขอ

แล้วเลือก **PV ที่เล็กที่สุดที่ยังใหญ่พอ**

ถ้าไม่จองไว้ล่วงหน้า PVC ก้อนเล็กจะไปคว้าก้อนของคนอื่น แล้วไล่แย่งกันเป็นทอด ๆ:

```
PVC 2Gi     → คว้า grafana-data (5Gi)      ← ก้อนเล็กสุดที่พอ
PVC 5Gi     → เหลือแต่ loki-data (50Gi)
PVC 50Gi    → เหลือแต่ prometheus-data (150Gi)
PVC 150Gi   → ไม่เหลือ → Pending ตลอดกาล
```

และเพราะ `WaitForFirstConsumer` ทำให้ลำดับขึ้นกับว่า pod ไหนถูก schedule ก่อน
ผลคือ **ติดตั้งผ่านบ้างไม่ผ่านบ้าง** ซึ่งหาสาเหตุยากกว่าพังทุกรอบมาก

`claimRef` คือการจองล่วงหน้าว่าก้อนนี้เป็นของ PVC ชื่ออะไร namespace ไหน — ตัดการเดาทิ้งหมด

> **ถ้าชื่อ PVC ในไฟล์ไม่ตรงกับที่ chart สร้างจริง** (เช่น chart เปลี่ยนสูตรตั้งชื่อ)
> อาการจะเป็น **PVC ค้าง `Pending` และ PV ยังขึ้น `Available`** ซึ่งเห็นชัดและแก้ง่าย
> ไม่ใช่การผูกผิดตัวแบบเงียบ ๆ — ตรวจชื่อจริงได้หลังทำบทที่ 09:
>
> ```bash
> kubectl -n monitoring get pvc -o custom-columns=NAME:.metadata.name,VOL:.spec.volumeName
> ```

---

## ถ้าวันหนึ่งต้องเปิด D8 จริง

ถ้ามี workload ที่ต้องการ persistent storage แบบ dynamic ขึ้นมา **อย่าแก้ทีละเคส**
ให้กลับมาตัดสินใจใหม่ทั้งข้อ เรียงตามที่ควรพิจารณาก่อน:

| ตัวเลือก | เหมาะเมื่อ | ต้นทุน |
|---|---|---|
| **vSphere CSI** | อยู่บน VMware อยู่แล้ว | ต้องได้สิทธิ์ vCenter · ดูแลเวอร์ชันให้เข้ากับ vSphere |
| **NFS CSI** | ต้องการ RWX หลาย pod เขียนพร้อมกัน | NFS server เป็น single point of failure |
| **local-path-provisioner** | อยากได้ dynamic แต่ยอมให้ผูก node | pod ย้าย node ไม่ได้ ต้อง backup ระดับ application เอง |
| **Longhorn** | อยากได้ replicated block + snapshot | กิน CPU/RAM/disk ของ worker และเพิ่มระบบที่ต้องดูแล |

**ตัวที่ควรหยิบก่อนคือ vSphere CSI** เพราะใช้ datastore เดิมที่มีอยู่ ไม่ต้องซื้อของใหม่

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl get storageclass` มีแค่ `local-storage` ตัวเดียว
- [ ] PV ทั้ง 3 ตัวสถานะ `Available` **และคอลัมน์ `CLAIM` มีชื่อจองไว้แล้วทุกก้อน**
- [ ] รู้ว่า **Alertmanager ไม่ใช้ PV** (ใช้ `emptyDir` + gossip) จึงมีแค่ 3 ก้อน ไม่ใช่ 4
- [ ] directory บน `k8s-worker03` สร้างแล้ว และมีพื้นที่พอ — ตรวจจากเครื่องคุณ:
      `ssh root@192.168.50.106 'ls -d /var/lib/monitoring/{prometheus,loki,grafana}'` ต้องได้ 3 บรรทัด ไม่มี `No such file`
- [ ] node `k8s-worker03` มี label `myhr.co.th/monitoring=true`
- [ ] **ทีม dev รู้แล้วว่า cluster นี้ไม่มี dynamic storage**
- [ ] บันทึกไว้ในเอกสารส่งมอบว่า **rolling reboot ต้องเริ่มจาก worker03 เสมอ**

**➡️ ต่อที่ [บทที่ 09 — Observability](09-observability.md)**
