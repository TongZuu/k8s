# บทที่ 08 — Storage

> **รันที่: 👑 master01 + เตรียม directory บน worker**
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

## 1 · เตรียม directory บน worker

เลือก `k8s-worker03` เป็นเครื่องเก็บ monitoring — จะได้ไม่ปนกับ workload หลัก

**⚙️ รันบน `k8s-worker03` (192.168.50.106) เท่านั้น:**

```bash
mkdir -p /var/lib/monitoring/{prometheus,loki,grafana}
chmod 700 /var/lib/monitoring/*
df -h /var/lib/monitoring
```
**ควรเห็น:** พื้นที่ว่างอย่างน้อย ~200 GB บน root filesystem

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

NAME              CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS
prometheus-data   150Gi      RWO            Retain           Available
loki-data         50Gi       RWO            Retain           Available
grafana-data      5Gi        RWO            Retain           Available
```

**`STATUS: Available` ถูกต้องแล้ว** — จะกลายเป็น `Bound` เมื่อบทที่ 09 สร้าง PVC มาขอ

> **`WaitForFirstConsumer` สำคัญ** — ทำให้ scheduler เลือก node ก่อนแล้วค่อยผูก PV
> ถ้าใช้ `Immediate` จะผูก PV ก่อนแล้ว pod อาจถูก schedule ไปคนละเครื่องจนค้างตลอดกาล
>
> **`Retain` ก็สำคัญ** — ลบ PVC แล้วข้อมูลยังอยู่ ต้องมาลบ directory เองด้วยมือ
> ปลอดภัยกว่า `Delete` มากสำหรับข้อมูลที่กู้กลับไม่ได้

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
- [ ] PV ทั้ง 3 ตัวสถานะ `Available`
- [ ] directory บน `k8s-worker03` สร้างแล้ว และมีพื้นที่พอ
- [ ] node `k8s-worker03` มี label `myhr.co.th/monitoring=true`
- [ ] **ทีม dev รู้แล้วว่า cluster นี้ไม่มี dynamic storage**
- [ ] บันทึกไว้ในเอกสารส่งมอบว่า **rolling reboot ต้องเริ่มจาก worker03 เสมอ**

**➡️ ต่อที่ [บทที่ 09 — Observability](09-observability.md)**
