# บทที่ 14 — ดู log ใน Grafana ตามอาการของ pod

> **รันที่: 🖥️ เบราว์เซอร์บนเครื่องของคุณ** (บาง section ต้องมี `kubectl` ควบคู่)
> **เวลาที่ใช้:** ~20 นาทีอ่านรอบแรก · หลังจากนั้นใช้เป็นแผ่นเปิดตอนของพัง
> **ต้องผ่านบทที่ 09** — Loki + Alloy ต้องเก็บ log อยู่จริง

---

## บทนี้ต่างจากบทที่ 09 และ 13 ยังไง

| บท | ตอบคำถามว่า |
|---|---|
| [09](09-observability.md) | **ติดตั้ง**ยังไง · log เดินทางยังไง · กฎที่ต้องบอกทีม dev |
| [13](13-troubleshooting.md) | ของพังแล้ว ไล่ด้วย **`kubectl`** ยังไง |
| **14 (บทนี้)** | ของพังแล้ว จะ**เปิด Grafana หาคำตอบ**ยังไง — ทีละอาการ |

บทที่ 13 เป็นจุดตั้งต้นเสมอเพราะ `kubectl` เร็วกว่าและตอบได้ตรงกว่าในหลายเคส
**บทนี้ใช้ตอนที่ `kubectl` ตอบไม่ได้แล้ว** ซึ่งมี 3 สถานการณ์หลัก:

1. **pod ตายไปแล้วและถูกแทนที่** — `kubectl logs` ไม่มีของให้ดูอีกต่อไป แต่ Loki ยังมี
2. **ต้องดูย้อนหลังข้ามช่วงเวลา** — "เมื่อคืนตอนตีสามเกิดอะไรขึ้น"
3. **ต้องดูหลาย pod / หลาย node พร้อมกัน** แล้วหาว่าอันไหนเริ่มก่อน

---

## 🔴 กฎข้อเดียวที่ต้องรู้ก่อนเปิด Grafana

> **Loki มีเฉพาะสิ่งที่ container เขียนออก `stdout`/`stderr` เท่านั้น**

ผลที่ตามมาซึ่งทำให้คนเข้าใจผิดบ่อยที่สุด:

| ของที่ **ไม่มี**ใน Loki | อยู่ที่ไหนแทน |
|---|---|
| Kubernetes **Event** (`FailedScheduling`, `Liveness probe failed`, `OOMKilled`, `Failed to pull image`) | `kubectl describe pod` · และดูเป็น **metric** ได้ (ดู [ข้อ 3](#3--pod-ถูกฆ่าเพราะ-oom-exit-137)) |
| pod ที่ **container ไม่เคยสตาร์ท** (`Pending`, `ImagePullBackOff`, `CreateContainerConfigError`, ถูก PSA ปฏิเสธ) | ไม่มี log ให้ดู เพราะยังไม่มี process ที่เขียนอะไรออกมา → [บทที่ 13 ข้อ 3](13-troubleshooting.md#3-pod-ค้าง-pending) และ [ข้อ 9](13-troubleshooting.md#9-image-pull-ไม่ผ่าน) |
| log ที่ app เขียนลง**ไฟล์**ในคอนเทนเนอร์ | ไม่มีใครเก็บให้ — ผิดกฎข้อ 1 ของบทที่ 09 |
| log เก่ากว่า **14 วัน** | ถูก compactor ลบไปแล้ว กู้ไม่ได้ |

**เพราะฉะนั้นเวลาค้นแล้วไม่เจออะไรเลย อย่าเพิ่งสรุปว่า Loki พัง**
ให้ไล่ [ข้อ 6](#6--pod-ทำงานอยู่-แต่ค้น-log-ไม่เจอสักบรรทัด) ซึ่งแยกให้ว่า "ไม่มี log"
กับ "หา log ไม่เจอ" คนละเรื่องกัน

---

## 0 · ตั้ง 4 อย่างก่อนพิมพ์ query แรก

เปิด `https://grafana.myhr.co.th` → เมนูซ้าย **Explore** → มุมซ้ายบนเลือก data source **Loki**
(ถ้าเข้าเว็บไม่ได้ ใช้ทาง `ssh -L` ใน [บทที่ 09 ข้อ 4](09-observability.md#4--เข้า-grafana))

**ทั้ง 4 ข้อนี้คือสาเหตุของ "ค้นไม่เจอ" ส่วนใหญ่ ตั้งให้ถูกก่อนโทษ query:**

| ตั้งอะไร | ทำไม |
|---|---|
| **1 · ช่วงเวลา** (มุมขวาบน) | ค่าเริ่มต้นคือ **Last 1 hour** — pod ที่พังตอนตี 3 จะไม่โผล่ ให้เลื่อนคร่อมเวลาที่เกิดเหตุจริงเสมอ |
| **2 · timezone** | Grafana แสดงตาม timezone ของเบราว์เซอร์ แต่ log ที่ app เขียนอาจเป็น UTC — **ตัวเลขในบรรทัด log กับเวลาที่ Grafana แปะข้างซ้ายอาจต่างกัน 7 ชั่วโมง** ยึดเวลาข้างซ้ายของ Grafana เป็นหลักเวลาเทียบกับ metric |
| **3 · Line limit** | ค่าเริ่มต้น 1000 บรรทัด และมันตัดโดยเอา**ของใหม่ที่สุด** — ตอน pod รัว log บรรทัดแรกที่บอกสาเหตุจะหลุดหาย ให้เพิ่มเป็น 5000 หรือหุบช่วงเวลาให้แคบลง |
| **4 · ลำดับเวลา** | สลับเป็น **Oldest first** เวลาไล่หาเหตุ — เพราะบรรทัดที่อธิบายสาเหตุคือบรรทัด**แรก** ส่วนที่เหลือคือผลพวง |

> 🔴 **`|= "error"` เป็น case-sensitive** — จะไม่เจอ `ERROR`, `Error`, `Err`
> ให้ใช้ `|~ "(?i)error"` เสมอ นี่คือกับดักที่ทำให้คนสรุปผิดว่า "ไม่มี error"
**บทนี้มีคำสั่ง `kubectl` แทรกอยู่ด้วยเป็นระยะ — ตั้งตัวแปรชุดเดียวกับบทที่ 13 ไว้ก่อน:**
```bash
NS=myhr-prod                                   # namespace ที่มีปัญหา
APP=zeeme-ads                                  # ชื่อ Deployment
POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name="$APP" -o name | head -1 | cut -d/ -f2)
echo "NS=$NS APP=$APP POD=$POD"
```

> 🔴 **`-l app.kubernetes.io/name=` ไม่ใช่ `-l app=`** — manifest ของเราติด label ตาม
> แบบแผน `app.kubernetes.io/*` (ดู `deployments/zeeme-ads/deployment.yaml`) ถ้าใช้ `-l app=`
> จะไม่ match อะไรเลย แล้ว `$POD` จะกลายเป็นค่าว่างโดยไม่มี error สักบรรทัด
> · แต่ใน **LogQL ของ Loki ใช้ `app=`** เพราะ Alloy แปลงชื่อ label ให้แล้ว (`alloy-values.yaml`)
> สองที่นี้เขียนไม่เหมือนกันโดยตั้งใจ ไม่ใช่พิมพ์ผิด

> ตัวอย่าง LogQL ทั้งบทใช้ `myhr-prod` / `zeeme-ads` เป็นคู่เดียวกับตัวแปรข้างบน
> **แต่ช่อง query ของ Grafana ไม่รู้จักตัวแปรของ shell** ต้องพิมพ์ชื่อจริงลงไปเอง

---

## สารบัญอาการ

| # | เห็นอะไรจาก `kubectl` | เปิด Grafana ไปดูอะไร |
|---|---|---|
| [1](#1--pod-crashloopbackoff) | `CrashLoopBackOff` | log ของ container รอบก่อน ๆ ที่ `--previous` ไปไม่ถึงแล้ว |
| [2](#2--pod-หายไปแล้ว--rollout-ทับไปแล้ว) | pod หาย / rollout ทับ | log ของ pod ที่ไม่มีอยู่บน cluster อีกแล้ว |
| [3](#3--pod-ถูกฆ่าเพราะ-oom-exit-137) | `Exit 137` / restart เงียบ ๆ | log ที่ขาดกลางประโยค + กราฟ memory ในหน้าเดียวกัน |
| [4](#4--pod-running-แต่-client-ได้-5xx) | `Running` แต่ client ได้ 5xx | log ของ Envoy Gateway เทียบกับ log ของ app |
| [5](#5--readinessprobe-ไม่ผ่าน--endpoints-ว่าง) | `0/1 Running` · endpoints ว่าง | app เริ่มถึงไหนแล้ว ก่อนไปโทษ probe |
| [6](#6--pod-ทำงานอยู่-แต่ค้น-log-ไม่เจอสักบรรทัด) | pod ปกติดี แต่ Grafana ว่างเปล่า | แยก 5 สาเหตุ — ตัวไหนกิน log ไป |
| [7](#7--พังพร้อมกันหลาย-pod--สงสัยว่าเป็นที่-node) | หลาย pod พังพร้อมกัน | ใช้ label `node` ตัดว่าเป็นที่เครื่องหรือที่ app |
| [8](#8--จาก-alert-ที่ดัง-ไปถึง-log-ใน-3-คลิก) | ได้ alert เข้ามา | เส้นทางจาก alert → log ที่เกี่ยวข้อง |

---

## 1 · pod `CrashLoopBackOff`

**นี่คือเคสที่ Grafana ชนะ `kubectl` ชัดที่สุด** — `kubectl logs --previous` ให้ดูได้แค่
**รอบก่อนหน้า 1 รอบ** เท่านั้น pod ที่วน crash มา 40 รอบตั้งแต่เมื่อคืน รอบที่ 1
ซึ่งเป็นรอบที่บอกสาเหตุจริงหายไปตั้งนานแล้ว **แต่ Loki เก็บไว้ครบทุกรอบ**

**เริ่มจากดูภาพรวมก่อนว่ามีกี่รอบ และแต่ละรอบพูดอะไร:**
```logql
{namespace="myhr-prod", app="zeeme-ads"}
```
ตั้งช่วงเวลาให้คร่อมตั้งแต่ก่อน deploy รอบนั้น แล้วสลับเป็น **Oldest first**

**ควรเห็น:** ท่อน log ซ้ำ ๆ เป็นชุด ๆ แต่ละชุดคือ container หนึ่งรอบชีวิต
มองหา**ชุดแรกสุด** — บรรทัดสุดท้ายของชุดนั้นคือสาเหตุจริง ที่เหลือคือมันวนตายซ้ำ

**ถ้า log ยาวเกินจนหาไม่เจอ ให้ตัดเหลือเฉพาะบรรทัดที่มีน้ำหนัก:**
```logql
{namespace="myhr-prod", app="zeeme-ads"} |~ "(?i)(error|exception|fatal|caused by|refused|timeout)"
```

**ถ้าอยากรู้ว่ามัน crash เป็นจังหวะยังไง ให้ทำเป็นกราฟ** — เปลี่ยนไปแท็บ metric
ของ Explore แล้วใช้:
```logql
sum by (pod) (count_over_time({namespace="myhr-prod", app="zeeme-ads"}[1m]))
```
**ควรเห็น:** ฟันปลาเป็นจังหวะ — ยอดแต่ละซี่คือ container start หนึ่งรอบ
ระยะห่างที่ถ่างขึ้นเรื่อย ๆ คือ backoff ของ kubelet (10s → 20s → 40s → ... → 5m)

> 🔴 **ข้อจำกัดที่ต้องรู้: container ที่ตายภายใน 1-2 วินาที Loki อาจไม่ได้ครบทุกบรรทัด**
> Alloy ดึง log ผ่าน Kubernetes API (ดู `loki.source.kubernetes` ใน `alloy-values.yaml`)
> ซึ่งต้องเปิด stream ตามให้ทัน — container ที่พังทันทีที่สตาร์ทอาจจบก่อนที่ stream จะติด
>
> **เพราะฉะนั้นกฎคือ: Grafana ก่อนเพื่อดูภาพรวมทุกรอบ แล้วถ้าท่อนสำคัญขาด ให้กลับไป**
> ```bash
> kubectl -n "$NS" logs "$POD" --previous --timestamps | tail -50
> ```
> **สองอย่างนี้ใช้คู่กัน ไม่ใช่แทนกัน**

**สาเหตุที่พบบ่อยที่สุดของ cluster ชุดนี้** (Spring Boot ไม่มี `startupProbe` แล้วโดน
`livenessProbe` ฆ่าก่อนเริ่มเสร็จ) จะเห็นเป็นรูปแบบชัดมากใน Grafana:
**log ทุกชุดขาดที่จุดเดียวกัน กลางการ start ไม่เคยมีชุดไหนไปถึงบรรทัด "Started ... in N seconds"**
→ ไปแก้ตาม [บทที่ 13 ข้อ 4](13-troubleshooting.md#4-pod-crashloopbackoff)

---

## 2 · pod หายไปแล้ว / rollout ทับไปแล้ว

**อาการ:** dev บอกว่า "เมื่อเช้ามันพัง แต่ตอนนี้ deploy ทับไปแล้ว" — `kubectl logs`
ไม่มีของให้ดู เพราะ pod ตัวนั้นไม่มีอยู่บน cluster อีกต่อไป

**🔴 กับดัก: อย่าค้นด้วย label `pod`** — ชื่อ pod เปลี่ยนทุกครั้งที่ rollout
(`zeeme-ads-7d4f9c8b6-x9k2m` → `zeeme-ads-5b8c7d9f4-p3n7q`) query ที่ปักชื่อ pod ไว้
จะว่างเปล่าทันทีที่ deploy ใหม่ **ให้ค้นด้วย `app` ซึ่งอยู่ข้ามรุ่น**

```logql
{namespace="myhr-prod", app="zeeme-ads"}
```

**อยากรู้ว่าในช่วงนั้นมี pod ตัวไหนอยู่บ้าง:**
```logql
sum by (pod) (count_over_time({namespace="myhr-prod", app="zeeme-ads"}[1h]))
```
**ควรเห็น:** ชื่อ pod ทั้งรุ่นเก่าและรุ่นใหม่ พร้อมจำนวนบรรทัด — จุดที่รุ่นเก่าเงียบลง
และรุ่นใหม่เริ่มพูด คือเวลาที่ rollout เกิดขึ้นจริง (แม่นกว่าดูจาก `kubectl rollout history`
ซึ่งบอกแค่ลำดับ ไม่บอกเวลา)

**แล้วเจาะเฉพาะ pod รุ่นที่พัง** — ก็อปชื่อจากผลด้านบนมาใส่:
```logql
{namespace="myhr-prod", pod="zeeme-ads-7d4f9c8b6-x9k2m"}
```

> `app` มาจาก label `app.kubernetes.io/name` ของ pod (แปลงชื่อให้ใน `alloy-values.yaml`)
> **ถ้า manifest ของ service ไหนไม่ได้ใส่ label นี้ ตัวนั้นจะไม่มี `app` ให้ค้น**
> เหลือแค่ `namespace` + `pod` ซึ่งใช้ไม่ได้ข้าม rollout — แม่แบบในบทที่ 11 ใส่ให้แล้ว
> ของเก่าที่ย้ายเข้ามาต้องไล่เติมเอง

---

## 3 · pod ถูกฆ่าเพราะ OOM (`Exit 137`)

**อาการที่ชวนหลงทาง:** log **ไม่มี error อะไรเลย** มันแค่หยุดกลางประโยค
เพราะ kernel ฆ่า process ทิ้งทันที app ไม่มีโอกาสเขียนอะไรออกมาก่อนตาย

**ขั้นที่ 1 — ยืนยันว่าเป็น OOM จริง ไม่ใช่ app จบเอง** (Explore → data source **Prometheus**):
```promql
kube_pod_container_status_last_terminated_reason{namespace="myhr-prod", reason="OOMKilled"}
```
**ควรเห็น:** ค่า `1` พร้อมชื่อ pod และ container ที่โดน — ถ้าไม่มีผลลัพธ์ แปลว่าไม่ใช่ OOM
ให้กลับไปดู exit code ตาม [บทที่ 13 ข้อ 4](13-troubleshooting.md#4-pod-crashloopbackoff)

**ขั้นที่ 2 — ดู log กับกราฟ memory พร้อมกันในหน้าเดียว**

นี่คือฟีเจอร์ที่คุ้มที่สุดของ Explore: กดปุ่ม **Split** (มุมขวาบน) จะได้สองช่อง
ตั้งช่องซ้ายเป็น Loki ช่องขวาเป็น Prometheus **แล้วกดไอคอนโซ่ให้สองช่องใช้ช่วงเวลาเดียวกัน**

ช่องซ้าย (Loki):
```logql
{namespace="myhr-prod", app="zeeme-ads"}
```

ช่องขวา (Prometheus):
```promql
container_memory_working_set_bytes{namespace="myhr-prod", container="zeeme-ads"}
```

**ควรเห็น:** เส้น memory ไต่ขึ้นชนเพดานพอดีกับวินาทีที่ log หยุดพูด — **นั่นคือหลักฐาน**
ถ้าเส้น memory ราบเรียบแต่ log หยุด แปลว่าไม่ใช่ OOM ให้ไปหาเหตุอื่น

**ขั้นที่ 3 — ดูว่าโตแบบไหน** เพราะวิธีแก้ต่างกันคนละเรื่อง:

| รูปกราฟ | แปลว่า | ทำอะไร |
|---|---|---|
| ไต่ขึ้นช้า ๆ ไม่เคยลง | memory leak | ให้ dev แก้ — เพิ่ม limit แค่ยืดเวลาตาย |
| พุ่งเป็นยอดแหลมตอนมี traffic | limit ตั้งต่ำไปจริง | เพิ่ม `limits.memory` แต่**ต้องเช็คเพดาน N+1 (32 vCPU / 96 GB) ก่อน** |
| พุ่งทันทีที่สตาร์ท | JVM heap ตั้งใหญ่กว่า limit ของ container | ตั้ง `-XX:MaxRAMPercentage` ไม่ใช่ `-Xmx` ตายตัว |

---

## 4 · pod `Running` แต่ client ได้ 5xx

**หัวใจของเคสนี้: มี log สองฝั่ง และต้องดูให้ครบทั้งคู่**
เพราะคำถามแรกคือ "request วิ่งไปถึง pod หรือเปล่า" ไม่ใช่ "app ทำงานถูกไหม"

**ฝั่งทางเข้า — Envoy Gateway:**
```logql
{namespace="envoy-gateway-system"} |~ "(?i)(50[0-9]|40[0-9])"
```

**ฝั่ง app:**
```logql
{namespace="myhr-prod", app="zeeme-ads"} |~ "(?i)(error|exception)"
```

> **ถ้าฝั่ง Envoy ว่างเปล่าทั้งที่รู้ว่ามี traffic** — Envoy Gateway เขียน access log ออก
> stdout ให้เป็นค่าเริ่มต้น การไม่มีเลยจึงผิดปกติ ยืนยันที่ต้นทางก่อนว่ามันเขียนจริงไหม:
> ```bash
> kubectl -n envoy-gateway-system get pods
> ```
> แล้วเอาชื่อ pod ที่ขึ้นต้นด้วย `envoy-` ไปดู log ตรง ๆ:
> ```bash
> kubectl -n envoy-gateway-system logs <ชื่อ-pod-ของ-envoy> --tail=20
> ```
> มีที่ต้นทางแต่ไม่มีใน Grafana = ปัญหาอยู่ที่ท่อเก็บ log → [ข้อ 6](#6--pod-ทำงานอยู่-แต่ค้น-log-ไม่เจอสักบรรทัด)

**อ่านผลแบบนี้:**

| Envoy | app | แปลว่า | ไปต่อที่ |
|---|---|---|---|
| มี 503 | **เงียบสนิท** | request ไปไม่ถึง pod — endpoints ว่าง หรือ NetworkPolicy ตัด | [บทที่ 13 ข้อ 11](13-troubleshooting.md#11-pod-running-แต่เรียกไม่ได้) |
| มี 500 | มี exception เวลาตรงกัน | app พังจริง | ส่ง stack trace ให้ dev |
| มี 504 | app เริ่มรับ request แล้วเงียบ | app ช้าเกิน `timeouts.request: 60s` ของ HTTPRoute | ดู dependency ของ app (DB นอก cluster) |
| **ไม่มีอะไรเลยทั้งคู่** | | request ไปไม่ถึง Gateway ด้วยซ้ำ | [บทที่ 13 ข้อ 7](13-troubleshooting.md#7-loadbalancer-ip-ขึ้นแต่เข้าไม่ได้) — เรื่อง L2/ARP ไม่ใช่เรื่อง app |

> 🔴 **แถวสุดท้ายคือเคสที่เสียเวลามากที่สุดถ้าไม่รู้** — คนมักไล่ log ของ app อยู่นาน
> ทั้งที่ packet ไม่เคยออกจากเครื่องตัวเองด้วยซ้ำ **ถ้า Envoy ไม่มี log ของ request นั้น
> แปลว่าไม่ใช่ปัญหาของ pod** ให้เลิกดู log ของ app ทันที

**ถ้า log ของ app เป็น JSON ตามกฎข้อ 2 ของบทที่ 09 จะเจาะได้ตรงกว่านี้มาก:**
```logql
{namespace="myhr-prod", app="zeeme-ads"} | json | status >= 500
```

**และทำเป็นกราฟดูว่าเริ่มพังตอนไหน:**
```logql
sum by (app) (rate({namespace="myhr-prod"} |~ "(?i)(error|exception)" [5m]))
```
**ควรเห็น:** จุดที่เส้นเริ่มยกตัว — เอาเวลานั้นไปเทียบกับเวลา deploy ล่าสุด
ถ้าตรงกัน สาเหตุคือ rollout รอบนั้น จบเรื่อง ไม่ต้องหาต่อ

---

## 5 · `readinessProbe` ไม่ผ่าน / endpoints ว่าง

**ระวังตรงนี้: ข้อความ `Readiness probe failed: HTTP probe failed with statuscode: 503`
เป็น Kubernetes Event ไม่ใช่ log ของ container — มันไม่อยู่ใน Loki**

```bash
kubectl -n "$NS" describe pod "$POD" | grep -A3 Events
```

**สิ่งที่ Grafana ตอบได้และ `describe` ตอบไม่ได้คือ "app เริ่มไปถึงไหนแล้ว":**
```logql
{namespace="myhr-prod", app="zeeme-ads"}
```
ดูบรรทัดท้ายสุด แล้วเทียบกับ 3 แบบนี้:

| บรรทัดสุดท้ายบอกว่า | แปลว่า |
|---|---|
| ยังอยู่กลางการ start (โหลด bean / ต่อ DB) | **app ยังไม่พร้อมจริง ๆ — probe ไม่ได้ผิด** ต้องเพิ่ม `startupProbe` |
| `Started ... in 45 seconds` แล้วเงียบ | app พร้อมแล้วแต่ probe ยังไม่ผ่าน → path/port ของ probe ผิด |
| ค้างที่การต่อ DB / external service | ปัญหาอยู่นอก cluster หรือ NetworkPolicy ตัดขาออก → [บทที่ 13 ข้อ 6.2](13-troubleshooting.md#62-networkpolicy-บล็อก--พบบ่อยที่สุดหลังทำบทที่-10) |

> ⚠️ **ถ้า probe ยิงที่ `/healthz` แล้วสำเร็จ log ของมันจะไม่อยู่ใน Loki**
> `stage.drop` ใน `alloy-values.yaml` ทิ้งบรรทัด healthcheck ที่ตอบ 200/204 ทิ้งตั้งแต่ต้นทาง
> **การไม่เห็น access log ของ `/healthz` จึงเป็นเรื่องปกติ ไม่ใช่อาการพัง**
> ส่วน healthcheck ที่**ล้มเหลว** (ตอบ 503) ไม่เข้าเงื่อนไข drop → ยังเห็นได้ตามปกติ

---

## 6 · pod ทำงานอยู่ แต่ค้น log ไม่เจอสักบรรทัด

ไล่ตามลำดับนี้ **ห้ามข้าม** เพราะมันไล่จาก "ปัญหาของคนค้น" ไปหา "ปัญหาของระบบ"

**6.1 · ช่วงเวลาผิด** — สาเหตุอันดับ 1 ตลอดกาล
กว้างช่วงเวลาเป็น **Last 24 hours** แล้วลองใหม่ ถ้าเจอ แปลว่าจบแล้ว

**6.2 · label สะกดผิด หรือ service นั้นไม่มี label `app`**
อย่าเดาชื่อ — ให้ Grafana บอกว่ามีอะไรบ้าง:
```logql
{namespace="myhr-prod"}
```
ถ้าอันนี้มีของออกมา แปลว่า Loki ปกติ ปัญหาอยู่ที่ label ที่เติมเข้าไปทีหลัง
กดที่บรรทัดใดบรรทัดหนึ่งเพื่อกาง label ที่มีจริงออกมาดู

**6.3 · app เขียน log ลงไฟล์ ไม่ได้เขียน stdout** — ผิดกฎข้อ 1 ของบทที่ 09
ตรวจจากต้นทางเลยว่ามีอะไรออกมาไหม:
```bash
kubectl -n "$NS" logs "$POD" --tail=20
```
**ถ้าคำสั่งนี้ก็ว่างเปล่าเหมือนกัน แปลว่าไม่ใช่ปัญหาของ Loki** — app ไม่ได้เขียน stdout
ให้ไปคุยกับ dev พร้อมกฎ 3 ข้อในบทที่ 09
**ถ้าคำสั่งนี้มีของ แต่ Grafana ไม่มี** ให้ไปต่อข้อ 6.4

**6.4 · Alloy ไม่ได้อยู่บน node ที่ pod นั้นรัน**
```bash
kubectl -n monitoring get ds alloy
kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}'; echo
```
**ควรเห็น:** `6/6` — ถ้าน้อยกว่านั้น pod ที่อยู่บน node ที่ไม่มี Alloy จะเงียบสนิท
และควรมี alert `AlloyDaemonSetIncomplete` ดังอยู่แล้ว

**6.5 · log ถูก drop เพราะชนเพดาน** — app นี้ (หรือ app อื่นในวงเดียวกัน) log รัวเกินโควตา
```logql
sum by (namespace, app) (rate({namespace=~"myhr-.+"}[5m]))
```
**ควรเห็น:** ตัวที่ยอดสูงผิดปกติคือตัวที่กินโควตาของคนอื่น เพดานคือ 10 MB/s ทั้ง cluster
และ 3 MB/s ต่อ stream (ตั้งใน `loki-values.yaml`) — เวลามันทำงานจะดังผ่าน `LokiDiscardingLogs`

**และตรวจว่า `stage.drop` ไม่ได้กินของดีไปด้วย:**
```bash
kubectl -n monitoring port-forward ds/alloy 12345:12345 &
sleep 3
curl -s http://localhost:12345/metrics | grep loki_process_dropped_lines_total
kill %%
```
ตัวเลข `reason="healthcheck_noise"` ต้องโตช้า ๆ สม่ำเสมอ ถ้าพุ่งแปลว่า regex กว้างเกินไป

---

## 7 · พังพร้อมกันหลาย pod — สงสัยว่าเป็นที่ node

**คำถามที่ต้องตอบให้ได้ก่อนอย่างอื่น: "พังทุกตัว หรือพังเฉพาะตัวที่อยู่เครื่องนั้น"**
คำตอบเปลี่ยนทิศทางการไล่ทั้งหมด — ถ้าเป็นที่ node การไปนั่งอ่าน code ของ app คือเสียเวลาเปล่า

**นี่คือเหตุผลที่ `alloy-values.yaml` แปะ label `node` ให้ทุกบรรทัด ใช้มันให้เป็น:**
```logql
sum by (node) (rate({namespace="myhr-prod"} |~ "(?i)(error|timeout|refused)" [5m]))
```

**ควรเห็น:** ถ้าเส้นของ node เดียวโดดขึ้นเส้นเดียว ในขณะที่อีก 5 เส้นราบ —
**ปัญหาอยู่ที่เครื่องนั้น ไม่ใช่ที่ app** ไปต่อที่ [บทที่ 13 ข้อ 2](13-troubleshooting.md#2-node-notready)
และ [ข้อ 5](13-troubleshooting.md#5-pod-ข้าม-node-ไม่ได้) (firewalld / MTU / kernel module หลัง reboot)

ถ้าทุกเส้นขึ้นพร้อมกัน — เป็นเรื่องที่ระดับ cluster หรือ dependency ร่วม
(DB นอก cluster, DNS, registry) ให้ดู CoreDNS ควบคู่:
```logql
{namespace="kube-system", app="coredns"} |~ "(?i)(error|timeout|SERVFAIL)"
```

---

## 8 · จาก alert ที่ดัง ไปถึง log ใน 3 คลิก

alert 11 ข้อในบทที่ 09 บอกว่า "มีอะไรผิด" แต่ไม่ได้บอกว่า "ทำไม" — เส้นทางไปหาคำตอบ:

1. Grafana → **Alerting → Alert rules** → กดข้อที่กำลังดัง อ่าน label `namespace` / `pod` / `node` ที่ติดมากับมัน
2. เปิด **Explore** → Loki → ใส่ label ที่ได้มาลงไปตรง ๆ
3. **ตั้งช่วงเวลาให้เริ่ม*ก่อน*เวลาที่ alert ดังอย่างน้อย 15 นาที** — เพราะทุก alert มี `for:`
   ของมัน กว่าจะดังคือของพังไปสักพักแล้ว **เหตุอยู่ก่อนเสียงเสมอ**

| alert ที่ดัง | เปิดดู |
|---|---|
| `KubePodCrashLooping` | [ข้อ 1](#1--pod-crashloopbackoff) |
| `KubePodNotReady` | [ข้อ 5](#5--readinessprobe-ไม่ผ่าน--endpoints-ว่าง) — และเช็คก่อนว่า container สตาร์ทหรือยัง |
| `KubeContainerOOMKilled` / restart ถี่ | [ข้อ 3](#3--pod-ถูกฆ่าเพราะ-oom-exit-137) |
| `LokiDiscardingLogs` | [ข้อ 6.5](#6--pod-ทำงานอยู่-แต่ค้น-log-ไม่เจอสักบรรทัด) — **และ log ช่วงนั้นหายไปจริง อย่าเชื่อว่าเงียบ = ไม่มีปัญหา** |
| `LokiNotReceivingLogs` / `AlloyDaemonSetIncomplete` | **หยุดใช้ Grafana หา log ก่อน** — ท่อเก็บ log พังอยู่ ไปแก้ตัวนั้นก่อน ไม่งั้นจะสรุปผิดจากของที่ไม่ครบ |

> 🔴 **แถวสุดท้ายสำคัญกว่าที่คิด** — ตอนท่อ log พัง Grafana จะแสดงหน้าว่างเปล่า
> ซึ่งหน้าตาเหมือนกับ "ระบบปกติ ไม่มี error" ทุกประการ **การไม่เห็น error ไม่ใช่หลักฐานว่าไม่มี error**
> ให้เช็ค `AlloyDaemonSetIncomplete` กับ `LokiNotReceivingLogs` ก่อนสรุปว่าทุกอย่างเรียบร้อย

---

## 9 · เทคนิคที่ประหยัดเวลาที่สุด 4 ข้อ

**1 · `Show context` — ดูบรรทัดรอบ ๆ ที่ query ไม่ได้ match**
กดที่ไอคอนข้างบรรทัด log แล้วเลือก **Show context** จะได้บรรทัดก่อนหน้าและถัดไป
**จำเป็นมากกับ stack trace** เพราะ containerd แยก log เป็นรายบรรทัด stack trace 30 บรรทัด
จึงเป็น 30 entry แยกกัน — `|~ "Exception"` จะ match แค่บรรทัดแรก ส่วน `Caused by:`
ที่บอกสาเหตุจริงอยู่บรรทัดที่ 25 ซึ่งไม่โผล่ออกมาถ้าไม่กางดู

**2 · `Live` — ตาม log สด ๆ ตอนกำลังจะ deploy**
ปุ่ม **Live** มุมขวาบนของ Explore เปิดทิ้งไว้ก่อนกด `kubectl apply` แล้วดูของใหม่ไหลเข้ามา
ได้เห็นบรรทัดแรกที่พังโดยไม่ต้องมาไล่ย้อนหลัง

**3 · `stern` สำหรับตอนที่อยู่บน terminal อยู่แล้ว**
```bash
stern -n myhr-prod zeeme-ads --since 10m
```
เร็วกว่าเปิดเบราว์เซอร์ **แต่ตามได้เฉพาะ pod ที่ยังมีชีวิตอยู่** ของที่ตายไปแล้วต้องใช้ Grafana

**4 · ทำ dashboard ให้ dev ใช้เอง — คุ้มกว่าสอน LogQL ทั้งทีม**
ใช้เวลาราว 30 นาที ทำครั้งเดียวใช้ได้ตลอด:

| ทำอะไร | ค่าที่ใส่ |
|---|---|
| สร้าง dashboard ใหม่ → Settings → Variables → เพิ่มตัวแปร `ns` | Type `Query` · data source Loki · Query `label_values(namespace)` |
| เพิ่มตัวแปร `app` | Query `label_values({namespace="$ns"}, app)` |
| เพิ่ม panel แบบ **Logs** | `{namespace="$ns", app="$app"}` |
| เพิ่ม panel แบบ **Time series** วางไว้ข้างบน | `sum(rate({namespace="$ns", app="$app"} \|~ "(?i)error" [5m]))` |
| เพิ่มช่องค้นหาเป็นตัวแปร `q` | Type `Textbox` · แล้วแก้ query ของ panel Logs เป็น `{namespace="$ns", app="$app"} \|~ "(?i)$q"` |

ได้หน้าที่ dev เลือก dropdown สองอัน พิมพ์คำที่อยากหา แล้วเห็นทั้งกราฟ error
และ log จริงในหน้าเดียว — **ไม่ต้องรู้จัก LogQL เลย**

---

## 📋 ตารางสรุป — เปิดหน้านี้ตอนของพัง

| อยากได้ | พิมพ์ |
|---|---|
| log ทั้ง app ข้ามทุก rollout | `{namespace="myhr-prod", app="zeeme-ads"}` |
| เฉพาะบรรทัดที่มีน้ำหนัก | `{namespace="myhr-prod", app="zeeme-ads"} \|~ "(?i)(error\|exception\|fatal\|caused by)"` |
| ตัดของที่ไม่อยากเห็นออก | `{namespace="myhr-prod"} != "healthz"` |
| มี pod ตัวไหนพูดบ้างในช่วงนี้ | `sum by (pod) (count_over_time({namespace="myhr-prod", app="zeeme-ads"}[1h]))` |
| จังหวะการ crash | `sum by (pod) (count_over_time({namespace="myhr-prod", app="zeeme-ads"}[1m]))` |
| error ต่อ app | `sum by (app) (rate({namespace="myhr-prod"} \|~ "(?i)error" [5m]))` |
| แยกว่าเป็นที่ node ไหม | `sum by (node) (rate({namespace="myhr-prod"} \|~ "(?i)error" [5m]))` |
| ใครกินโควตา log | `topk(5, sum by (namespace, app) (rate({namespace=~"myhr-.+"}[5m])))` |
| log ของทางเข้า | `{namespace="envoy-gateway-system"} \|~ "(?i)(50[0-9]\|40[0-9])"` |
| เจาะ JSON | `{namespace="myhr-prod", app="zeeme-ads"} \| json \| status >= 500` |
| ยืนยัน OOM (Prometheus) | `kube_pod_container_status_last_terminated_reason{namespace="myhr-prod", reason="OOMKilled"}` |
| memory เทียบกับ log (Prometheus) | `container_memory_working_set_bytes{namespace="myhr-prod", container="zeeme-ads"}` |

---

## ✅ เกณฑ์ผ่านของบทนี้

ทำจริงทีละข้อ **ตอนที่ยังไม่มีอะไรพัง** — ไม่ใช่ตอนกำลังมี incident

- [ ] เปิด Explore เลือก Loki แล้ว `{namespace="myhr-prod"}` มีของออกมา
- [ ] เปลี่ยนช่วงเวลาเป็น 24 ชั่วโมง แล้วยังเห็น log ของเมื่อวาน (พิสูจน์ว่าเก็บย้อนหลังได้จริง)
- [ ] `sum by (pod) (count_over_time(...))` แล้วเห็นชื่อ pod มากกว่าหนึ่งรุ่น
- [ ] 🔴 **จงใจ deploy pod ที่พัง** (เช่น image ที่ไม่มีอยู่จริง หรือ command ที่ exit 1)
      แล้วหา log ของมันใน Grafana ให้เจอ — **ถ้าหาไม่เจอตอนซ้อม จะหาไม่เจอตอนของจริง**
- [ ] ลบ pod นั้นทิ้ง แล้วยังหา log ของมันเจอใน Grafana (ข้อนี้คือเหตุผลทั้งหมดของบทนี้)
- [ ] กด **Split** ดู Loki กับ Prometheus พร้อมกันโดยช่วงเวลาผูกกันได้
- [ ] ทำ dashboard สำหรับ dev เสร็จแล้ว และมีคนในทีม dev เปิดใช้ได้จริง
- [ ] ทีม dev รู้ว่าเปิดหน้าไหน โดยไม่ต้องถาม ops

**➡️ กลับไปที่ [บทที่ 13 — Troubleshooting](13-troubleshooting.md) เมื่อ log บอกแล้วว่าปัญหาอยู่ตรงไหน**
