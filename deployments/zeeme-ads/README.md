# zeeme-ads — manifest ของจริงที่ deploy ลง `myhr-prod`

> **รันที่: 👑 master01 หรือเครื่องที่มี kubeconfig ของ cluster ใหม่**
> **ผู้อ่าน: dev เจ้าของ service + ops**
> **ที่นี่ตอบว่า "apply อะไร ยังไง" · [บทที่ 11](../../docs/11-deploy-app.md) ตอบว่า "ทำไมต้องเป็นแบบนี้"**

4 ไฟล์ในโฟลเดอร์นี้คือของที่**เป็นของ service ตัวนี้ตัวเดียว**
แปลงมาจาก [`old/`](old/) ตามแม่แบบ [`../../config/app/deployment-template.yaml`](../../config/app/deployment-template.yaml)

**ของกลางไม่ได้อยู่ที่นี่** — Namespace, Secret `regcred`, NetworkPolicy ระดับ namespace
และ Gateway อยู่ใน `config/` และมีคนอื่นดูแล เส้นแบ่งอยู่ที่หัวข้อสุดท้าย

| ไฟล์ | คือ | ต้องแก้ตอน deploy version ใหม่ไหม |
|---|---|---|
| `deployment.yaml` | 8 replica · uid 10001 · rootfs read-only · probe 3 ตัว · กระจายข้าม node | ✅ **แก้บรรทัด `image:` บรรทัดเดียว** |
| `service.yaml` | ClusterIP `80 → 8100` — ไม่ใช่ NodePort แล้ว | ❌ |
| `pdb.yaml` | `minAvailable: 50%` — ตัวที่กัน `kubectl drain` ทำ service ดับ | ❌ |
| `httproute.yaml` | ทางเข้าจาก `ads.myhr.co.th` ผ่าน `myhr-gateway` | ❌ |
| `old/` | manifest เดิมของ cluster เก่า **อ้างอิงอย่างเดียว ห้าม apply** | ❌ |

**ทุกคำสั่งในไฟล์นี้ยืนอยู่ที่โฟลเดอร์นี้** — `cd` ก่อนแล้วค่อยเริ่ม:

```bash
cd /root/k8s/deployments/zeeme-ads
```

**สถานะตอนนี้**

| | |
|---|---|
| แปลงตามแม่แบบครบ | ✅ ครบทุกข้อในตารางบทที่ 11 หัวข้อ 2 |
| ตรวจแล้วแค่ไหน | ⚠️ **YAML parse ผ่านอย่างเดียว** — ยังไม่ได้รัน `validate-manifests.sh` |
| apply จริง | ⬜ **ยังไม่เคย** — ตัวเลข resources กับ path ของ probe ยังไม่มีอะไรยืนยัน |

> 📘 **จะเพิ่ม service ใหม่ · เพิ่ม namespace · เปิดพอร์ต · เพิ่ม hostname · ขอ storage**
> อ่าน [`../README.md`](../README.md) — คู่มือว่าของแต่ละแบบต้องไปแตะตรงไหน และใครมีสิทธิ์ทำ

---

## เลือกทางก่อน — A หรือ B

**อย่าไล่ทั้งไฟล์** ทางซ้ายทำครั้งเดียวตลอดชีพของ service ทางขวาทำซ้ำทุกรอบที่มีของใหม่

| สถานการณ์ | ไปที่ |
|---|---|
| service นี้ยังไม่เคยขึ้น cluster ใหม่เลย | **A1 → A9** ข้างล่าง — ทำเรียงลำดับ ห้ามข้าม |
| ขึ้นแล้ว · จะเปลี่ยน version ของ image | **B1 → B5** |
| ขึ้นแล้ว · จะแก้ replica / resources / probe / hostname | **B1 → B5** เหมือนกัน (ข้าม B1 ไปแก้ไฟล์ที่ต้องแก้แทน) |
| ของใหม่ขึ้นไปแล้วแต่พัง ต้องถอย | **B6** |
| จะเพิ่ม service ตัวใหม่ทั้งตัว | [`../README.md`](../README.md) ไม่ใช่ไฟล์นี้ |

**สิ่งที่ต่างกันจริง ๆ:**

| | A · ครั้งแรก | B · version ใหม่ |
|---|---|---|
| ตรวจของกลาง (ns · regcred · gateway · netpol) | ✅ ต้องตรวจ | ❌ ตรวจไปแล้วตั้งแต่ A1 |
| ตอบ 3 คำถามเรื่อง actuator · ชื่อเดิม · พอร์ต scrape | ✅ ครั้งเดียวพอ | ❌ |
| ลง uat ก่อน | ✅ | ✅ **ยังต้องทำทุกครั้ง** |
| ย้าย DNS · ตัดของเดิมบน cluster เก่า | ✅ | ❌ ทำไปแล้ว |
| ถอยกลับด้วย `rollout undo` | ❌ ไม่ต้อง — ของเดิมยังรับ traffic อยู่ | ✅ **นี่คือทางถอยทางเดียวที่มี** |

---

## 🅰 ทาง A · ครั้งแรก

ทำครั้งเดียวตลอดชีพของ service นี้ ทำจบแล้วไม่ต้องกลับมาอีก
**A1 → A9 ทำเรียงลำดับ ห้ามข้าม**

## A1 · ตรวจว่าของกลางพร้อม

**ตรวจอย่างเดียว ไม่ต้องสร้าง** ขาดตัวไหนให้ไปทำที่บทของมัน
ถ้าข้ามข้อนี้ pod จะขึ้นได้แต่เรียกไม่ถึง และอาการจะดูเหมือน app พัง

**ก่อนอื่น — ยืนยันว่า context ชี้ cluster ใหม่จริง:**

```bash
kubectl config current-context
```

```bash
kubectl get ns myhr-prod
```

```bash
kubectl -n myhr-prod get secret regcred
```

```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway
```

```bash
kubectl -n myhr-prod get netpol
```

**ควรเห็น:** ns มี label `pod-security.kubernetes.io/enforce=restricted` ·
มี secret `regcred` ชนิด `kubernetes.io/dockerconfigjson` ·
Gateway `PROGRAMMED=True` และมี address `192.168.50.200` ·
netpol ครบทั้ง `default-deny-all` · `allow-from-gateway` · `allow-dns-egress`

| ขาดตัวไหน | ไปทำที่ |
|---|---|
| Namespace · NetworkPolicy | [บทที่ 10](../../docs/10-security.md) |
| Secret `regcred` | [บทที่ 10 หัวข้อ 7](../../docs/10-security.md) · `NAMESPACES='myhr-prod' bash config/registry/create-regcred.sh` |
| Gateway | [บทที่ 07](../../docs/07-gateway-tls.md) |

---

## A2 · ตอบ 3 คำถามที่ยังไม่มีใครรู้คำตอบ

ทั้งสามข้อคือของที่ manifest เดิมไม่เคยมี จึงไม่เคยมีใครต้องตอบ
**ตอบให้ครบก่อน apply** ไม่งั้นจะไปรู้ตอน pod พังบน prod

### 1 · actuator เปิดอยู่จริงไหม

probe ทั้ง 3 ตัวยิงไปที่ `/actuator/health/*`
🔴 **ถ้า path นี้ไม่มีจริง `livenessProbe` จะฆ่า pod เป็น CrashLoop ตลอดกาล**

ถามจากของที่รันอยู่ตอนนี้ ซึ่งอยู่บน **cluster เดิม** (`kubectl config get-contexts` ดูชื่อ):

```bash
kubectl --context=CLUSTER_เดิม exec deploy/zeeme-ads-deployment -- wget -qO- localhost:8100/actuator/health/readiness
```

**ควรเห็น:** `{"status":"UP"}`
ถ้าได้ 404 หรือ connection refused ให้เปลี่ยนทั้ง 3 probe เป็น `tcpSocket` ก่อน
(ท่าเต็มอยู่ในคอมเมนต์ของ `deployment.yaml`)

### 2 · ใครเรียก `zeeme-ads-service` อยู่บ้าง

ชื่อ Service ของใหม่คือ `zeeme-ads` ตัวที่เรียกชื่อเดิมจะ resolve ไม่เจอ

```bash
kubectl --context=CLUSTER_เดิม get cm -A -o yaml | grep -n 'zeeme-ads-service'
```

แล้ว `grep -rn 'zeeme-ads-service'` ใน repo ของ service ที่เรียกใช้ด้วย
ตัวที่ย้ายตามมาทีหลังให้เรียกชื่อใหม่ ส่วนตัวที่ยังอยู่ cluster เดิมยังเรียกของเดิมต่อไปได้

### 3 · พอร์ต scrape ของ NetworkPolicy

[`allow-prometheus-scrape`](../../config/security/default-deny.yaml) เปิดไว้ที่ **8080**
แต่ service นี้ฟังที่ **8100** — ถ้าจะให้ Prometheus เก็บ metric ได้ ต้องเปิดพอร์ต 8100 ให้ก่อน

policy ตัวนั้นใช้ `podSelector: {}` คือมีผลกับ **ทุก pod ใน `myhr-prod`**
การไปเปลี่ยนเลขพอร์ตในนั้นจึงกระทบ service อื่นด้วย มี 2 ทาง เลือกทางที่ 2 ถ้าเลือกได้:

| ทาง | ทำอะไร | ข้อเสีย |
|---|---|---|
| 1 · แก้ของกลาง | เปลี่ยน 8080 เป็น 8100 ใน `config/security/default-deny.yaml` | เปิดพอร์ต 8100 ให้ **ทุก pod** ใน namespace และต้องให้ทีมที่ดูแล cluster ทำให้ |
| 2 · เขียน policy เจาะจง service นี้ | policy ใหม่ `podSelector` = label ของ `zeeme-ads` เปิด ingress จาก `monitoring` ที่ 8100 วางไว้**ในโฟลเดอร์นี้** | ต้องเขียนเพิ่มหนึ่งไฟล์ |

NetworkPolicy หลายตัวรวมกันแบบ "บวกกัน" — เพิ่ม policy อนุญาตเส้นใหม่ได้โดยไม่ต้องแก้ของเดิม
ทางที่ 2 จึงไม่แตะของใคร และถูกลบตามไปเองตอนลบ service ([`../README.md` ข้อ D](../README.md))

---

## A3 · ตรวจ manifest — สิ่งที่มาแทน GitOps

```bash
../../config/app/validate-manifests.sh .
```

ต้องได้ `ผ่านทั้งหมด` และ exit 0 ก่อนเสมอ · บรรทัดเตือนเรื่อง digest สีเหลืองยังปล่อยผ่านได้ในรอบแรก

> ต้องมี `kubeconform` กับ `yq` บนเครื่องที่รัน ถ้าไม่มี สคริปต์จะหยุดตั้งแต่ข้อ 0

---

## A4 · ลง uat ก่อนเสมอ

บทที่ 11 หัวข้อ 6 — ห้ามลง prod เป็นที่แรก

ทุกไฟล์ปัก `namespace: myhr-prod` ไว้ในตัวแล้ว และ `--namespace` **ทับค่าที่เขียนในไฟล์ไม่ได้**
(`kubectl` จะฟ้อง namespace ไม่ตรงแล้วหยุด) และ **hostname ต้องเปลี่ยนด้วย**
ไม่งั้น route ของ uat จะชนกับของ prod บน listener เดียวกัน ตัวที่มาทีหลังจะได้ `Accepted=False` เงียบ ๆ:

```bash
sed -e 's/namespace: myhr-prod/namespace: myhr-uat/' -e 's/ads[.]myhr[.]co[.]th/ads-uat.myhr.co.th/' *.yaml | kubectl apply -f -
```

```bash
kubectl -n myhr-uat rollout status deploy/zeeme-ads --timeout=5m
```

```bash
kubectl -n myhr-uat get deploy,svc,pdb,httproute -l app.kubernetes.io/name=zeeme-ads
```

> นี่เป็นท่าชั่วคราวให้ผ่าน uat ไปก่อน ถ้าต้องแยกสอง environment ระยะยาว
> ให้ทำเป็น kustomize overlay แล้วเลิกใช้ `sed` — ของที่ต่างกันจะได้เห็นชัดใน git

---

## A5 · ลง prod

### `-f .` คืออะไร — apply ทั้งโฟลเดอร์จริงไหม

จริง `.` คือโฟลเดอร์ที่ยืนอยู่ และ `kubectl` จะ apply **ทุกไฟล์ YAML ในนั้นพร้อมกัน**
ที่นี่คือ 4 ไฟล์: `deployment.yaml` · `service.yaml` · `pdb.yaml` · `httproute.yaml`

**2 อย่างในโฟลเดอร์นี้ที่มันไม่แตะ:**

| ของในโฟลเดอร์ | โดน apply ไหม | เพราะ |
|---|---|---|
| `README.md` | ❌ | `kubectl` รับเฉพาะ `.yaml` · `.yml` · `.json` |
| `old/` — manifest ของ cluster เก่า | ❌ | **`-f .` ไม่ลงโฟลเดอร์ย่อย** ต้องเติม `-R` ถึงจะลง |

> 🔴 **อย่าเติม `-R` เด็ดขาด** — มันจะลากของใน `old/` (ซึ่งรันเป็น root และไม่มี PDB)
> ขึ้น prod ไปด้วย ของใน `old/` มีไว้อ่านเทียบอย่างเดียว

**ที่ apply ทั้ง 4 ไฟล์ทีเดียวเพราะมันเป็นชุดเดียวกัน** แยกทีละไฟล์จะได้สภาพครึ่ง ๆ กลาง ๆ
ที่ไล่ยาก — Deployment ขึ้นแล้วแต่ยังไม่มี PDB (มีคน drain ตอนนั้นคือดับ) หรือ
Service ขึ้นแล้วแต่ยังไม่มี HTTPRoute (เรียกจากนอกไม่ได้ แต่ดูเผิน ๆ ทุกอย่างเขียว)

### ดูรายชื่อของที่จะขึ้นก่อน

```bash
kubectl apply -f . --dry-run=client -o name
```

**ควรเห็น 4 บรรทัด** — `deployment.apps/zeeme-ads` · `service/zeeme-ads` ·
`poddisruptionbudget.policy/zeeme-ads` · `httproute.gateway.networking.k8s.io/zeeme-ads`
ถ้าเห็น 6 บรรทัดแปลว่าเผลอลาก `old/` มาด้วย **หยุดทันที**

### ดูว่าจะเปลี่ยนอะไรบ้าง แล้วค่อยยิง

```bash
kubectl diff -f .
```

```bash
kubectl apply -f .
```

**ควรเห็น:** ครั้งแรกขึ้น `created` ทั้ง 4 ตัว

```bash
kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```

> `apply` เป็น idempotent — รันซ้ำได้ตลอด ตัวที่ไม่เปลี่ยนจะขึ้น `unchanged` เฉย ๆ
> ตอน [B4](#b4--apply-แล้วเฝ้า-rollout) ที่แก้แค่ `image:` ก็ใช้คำสั่งเดียวกันนี้
> แล้วจะเห็น 3 ตัวขึ้น `unchanged` มีแค่ deployment ตัวเดียวที่ `configured`

> ของเดิมบน cluster เก่ายังรับ traffic ต่อไปตราบใดที่ยังไม่ย้าย DNS
> **อย่าเพิ่งลบ** จนกว่าจะผ่าน A7 แล้วเฝ้าครบ 24 ชั่วโมง

---

## A6 · ตรวจ 4 อย่างหลัง apply

```bash
kubectl -n myhr-prod get deploy,svc,pdb,httproute -l app.kubernetes.io/name=zeeme-ads
```
**ควรเห็น:** deploy `8/8` · svc เป็น `ClusterIP` · pdb `ALLOWED DISRUPTIONS = 4`

```bash
kubectl -n myhr-prod get pods -l app.kubernetes.io/name=zeeme-ads -o wide
```
**ควรเห็น:** pod กระจาย **3/3/2 คนละ worker** — ถ้ากองเครื่องเดียว topology spread ไม่ทำงาน

```bash
kubectl -n myhr-prod get httproute zeeme-ads -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
```
**ควรเห็น:** `Accepted=True` และ `ResolvedRefs=True`
`kubectl get httproute` เปล่า ๆ **ไม่มีคอลัมน์สถานะ** route ที่ผูกไม่ติดหน้าตาเหมือน route ที่ดีเป๊ะ ·
`ResolvedRefs=False` คือพิมพ์ชื่อ Service ผิด

```bash
kubectl -n myhr-prod get endpointslice -l kubernetes.io/service-name=zeeme-ads
```
**ควรเห็น:** endpoint 8 ตัว — ว่างเปล่าแปลว่าไม่มี pod ไหนผ่าน readinessProbe เลย

---

## A7 · ยิงของจริงจากนอก cluster

รันจากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node

```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
```

```bash
curl -I --resolve "ads.myhr.co.th:443:${GW_IP}" https://ads.myhr.co.th
```

**ควรเห็น:** `HTTP/2 200` — cert เป็น wildcard `*.myhr.co.th` ขององค์กร จึงไม่ต้องใส่ `--cacert`

---

## A8 · ย้าย DNS แล้วเฝ้า 24 ชั่วโมง

ผ่าน A7 แล้วค่อย **ย้าย DNS record ของ `ads.myhr.co.th` มาที่ Gateway IP**

แล้วเฝ้า Grafana 24 ชั่วโมง ([บทที่ 14](../../docs/14-grafana-logs.md)) ก่อนไป A9
ระหว่างนี้เก็บตัวเลขจริงไว้ปรับ `resources` ด้วย — ค่าที่อยู่ในไฟล์ตอนนี้เป็นค่าเดา:

```bash
kubectl -n myhr-prod top pod -l app.kubernetes.io/name=zeeme-ads
```

---

## A9 · ตัดของเดิมทิ้ง

**สำรองจาก cluster ก่อน** ไฟล์ใน `old/` เป็นสำเนาที่คนเขียนไว้ ไม่ใช่ของที่รันอยู่จริง
(อาจมีคน `kubectl edit` ทับไปแล้วโดยไม่มีใครรู้)

```bash
kubectl --context=CLUSTER_เดิม get deploy zeeme-ads-deployment -o yaml > ~/zeeme-ads-old-deploy.yaml
```

```bash
kubectl --context=CLUSTER_เดิม get svc zeeme-ads-service -o yaml > ~/zeeme-ads-old-svc.yaml
```

ลด replica ลงก่อน — ยังกลับได้ทันทีถ้าของใหม่มีปัญหา

```bash
kubectl --context=CLUSTER_เดิม scale deploy zeeme-ads-deployment --replicas=0
```

รอจนแน่ใจแล้วค่อยลบจริง

```bash
kubectl --context=CLUSTER_เดิม delete deploy/zeeme-ads-deployment svc/zeeme-ads-service
```

**ทำถึงตรงนี้แล้วทาง A จบ** ครั้งต่อ ๆ ไปใช้ทาง B อย่างเดียว

---

## 🅱 ทาง B · deploy version ใหม่

ทำซ้ำทุกครั้งที่มีของใหม่ · ปกติใช้เวลาไม่เกิน 10 นาที
ไม่ต้องกลับไปทำ A ซ้ำ **ยกเว้นตอนที่มีคนไปแตะของกลาง** (namespace · regcred · Gateway)

## B1 · แก้ image ให้ชี้ของใหม่

### 🔴 อ่านก่อน — tag เปล่า ๆ ทำให้ "deploy แล้ว" ทั้งที่ code ยังเป็นตัวเก่า

ตอนนี้ [`deployment.yaml`](deployment.yaml) ยังเขียนเป็น tag เปล่า คู่กับ `imagePullPolicy: IfNotPresent`
ถ้า build image ใหม่ทับ tag เดิม แล้ว `kubectl apply -f .` จะเจอ **2 ชั้นที่กันไม่ให้ของใหม่ขึ้น**:

| ชั้น | เกิดอะไร |
|---|---|
| 1 · Deployment spec ไม่เปลี่ยน | `apply` ได้ `unchanged` และ **ไม่เกิด rollout เลย** pod เดิมรันต่อไปเฉย ๆ |
| 2 · `IfNotPresent` | ต่อให้บังคับ rollout ได้ kubelet เห็นว่ามี tag นี้บน node แล้ว จึง **ไม่ pull ใหม่** |

จบด้วยสภาพที่ทุกคนคิดว่า deploy สำเร็จ แต่ยังรัน code เก่าอยู่ **และไม่มี error สักบรรทัด**

**ทางแก้คือ pin digest** — digest เปลี่ยนทุกครั้งที่ image เปลี่ยน spec จึงเปลี่ยนตามเสมอ

หา digest ของ image ที่จะขึ้น:

```bash
skopeo inspect docker://registry.myhr.co.th/zeeme-ads-service:1.0.0 | jq -r .Digest
```

> ไม่มี `skopeo` บนเครื่อง? ใช้ `crane digest registry.myhr.co.th/zeeme-ads-service:1.0.0`
> หรือขอค่าจาก CI ที่ push image ตัวนั้นขึ้นไป — **อย่าเดา**

แล้วแก้บรรทัด `image:` ใน [`deployment.yaml`](deployment.yaml) ให้เป็นรูปนี้:

```yaml
          image: registry.myhr.co.th/zeeme-ads-service:1.0.0@sha256:<digest>
```

**เก็บ tag ไว้ข้างหน้าด้วย** — Kubernetes ใช้ digest ตัดสิน ส่วน tag มีไว้ให้คนอ่านออกว่านี่คือ version ไหน

---

## B2 · commit ก่อน apply เสมอ

repo นี้ไม่มี GitOps จึงไม่มีอะไรบังคับ — กติกานี้บังคับด้วยคนอย่างเดียว

```bash
git add deployment.yaml && git commit -m "zeeme-ads: 0.0.9 -> 1.0.0" && git push
```

**ทำไมต้องก่อน ไม่ใช่หลัง:** ถ้า apply ไปแล้วยังไม่ commit แล้วมีคนอื่น `apply -f .`
จาก git ที่ยังเป็นของเก่า ของที่คุณเพิ่งขึ้นจะถูกถอยกลับเงียบ ๆ โดยไม่มีใครตั้งใจ

---

## B3 · ตรวจ + ดู diff

```bash
../../config/app/validate-manifests.sh .
```

```bash
kubectl diff -f .
```

**ควรเห็น:** มีบรรทัด `image:` เปลี่ยนอยู่ใน diff จริง ๆ
🔴 **ถ้า `kubectl diff` ไม่ขึ้นอะไรเลย แปลว่ายังไม่ได้แก้ image สำเร็จ — หยุดตรงนี้** อย่า apply ต่อ

---

## B4 · apply แล้วเฝ้า rollout

ลง uat ก่อน:

```bash
sed -e 's/namespace: myhr-prod/namespace: myhr-uat/' -e 's/ads[.]myhr[.]co[.]th/ads-uat.myhr.co.th/' *.yaml | kubectl apply -f -
```

```bash
kubectl -n myhr-uat rollout status deploy/zeeme-ads --timeout=5m
```

ผ่านแล้วลง prod:

```bash
kubectl apply -f .
```

```bash
kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```

**ควรเห็น:** `deployment "zeeme-ads" successfully rolled out`

`maxUnavailable: 0` แปลว่าระหว่าง rollout จะมี pod พร้อมใช้ครบ 8 ตัวตลอด
pod ใหม่ต้องผ่าน `readinessProbe` ก่อน ตัวเก่าถึงจะถูกลบทีละตัว — **ไม่มีช่วง downtime**

ถ้าคำสั่งค้างเกิน 5 นาที แปลว่า pod ใหม่ไม่ผ่าน readiness ดูว่าติดตรงไหน:

```bash
kubectl -n myhr-prod get pods -l app.kubernetes.io/name=zeeme-ads
```

```bash
kubectl -n myhr-prod logs -l app.kubernetes.io/name=zeeme-ads --tail=50
```

---

## B5 · ตรวจว่าของใหม่ขึ้นจริง

**อ่าน digest ที่รันอยู่จริง ไม่ใช่ดูแค่ว่า pod เขียว** — นี่คือข้อที่กันกับดักใน B1:

```bash
kubectl -n myhr-prod get pods -l app.kubernetes.io/name=zeeme-ads -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.containerStatuses[0].imageID}{"\n"}{end}'
```

**ควรเห็น:** ทุก pod ขึ้น digest ตัวใหม่ **เหมือนกันหมด** ไม่มีตัวไหนค้างของเก่า

```bash
curl -I --resolve "ads.myhr.co.th:443:$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')" https://ads.myhr.co.th
```

**ควรเห็น:** `HTTP/2 200`

---

## B6 · ถ้าพัง — ถอยกลับ

**หยุดเลือดก่อน** คำสั่งเดียว กลับไป revision ก่อนหน้าทันที:

```bash
kubectl -n myhr-prod rollout undo deploy/zeeme-ads
```

```bash
kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```

ดูว่ามี revision ไหนให้ถอยกลับบ้าง:

```bash
kubectl -n myhr-prod rollout history deploy/zeeme-ads
```

> 🔴 **`rollout undo` ทำให้ cluster ไม่ตรงกับ git ทันที**
> กติกาของ repo นี้คือ *git ถูกเสมอ* — คนถัดไปที่ `apply -f .` จะเอาของพังกลับขึ้นไปให้เอง
>
> **ถอยเสร็จแล้วต้อง revert ที่ git ทันทีในวันเดียวกัน** ไม่ใช่ค่อยทำทีหลัง:
> ```
> git revert <commit ของ B2>  &&  git push
> ```

---

## ถ้าไม่ผ่าน — ตารางอาการ

| อาการ | ดูตรงไหน |
|---|---|
| `ImagePullBackOff` · `ErrImagePull` | ถาม registry ก่อนว่าเป็นเรื่องรหัสจริงไหม — [บทที่ 10 หัวข้อ 7.1](../../docs/10-security.md) · ถ้า `regcred` หาย: `NAMESPACES='myhr-prod' bash config/registry/create-regcred.sh` |
| `apply` ขึ้น `unchanged` ทั้งที่เพิ่ง build ของใหม่ | tag เขียนทับ — [B1](#b1--แก้-image-ให้ชี้ของใหม่) |
| `violates PodSecurity "restricted"` | image ต้องรันด้วย uid 10001 ได้ — `kubectl -n myhr-prod get events --sort-by=.lastTimestamp \| tail -10` |
| pod ค้าง `Pending` | `kubectl -n myhr-prod describe pod ชื่อ` — `didn't match pod topology spread constraints` = replica ไม่ลงตัวกับจำนวน node ที่เหลือ |
| `CrashLoopBackOff` ทันทีที่ขึ้น | เกือบทุกครั้งคือ probe path ผิด ([A2 ข้อ 1](#a2--ตอบ-3-คำถามที่ยังไม่มีใครรู้คำตอบ)) หรือเขียน rootfs ไม่ได้ — `kubectl -n myhr-prod logs deploy/zeeme-ads --previous` |
| `Running` แต่เรียกไม่ได้ | NetworkPolicy — ดู flow ที่ถูกทิ้ง **ทุก agent** (`for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --namespace myhr-prod --verdict DROPPED --last 50; done`) — ถาม agent ตัวเดียวได้ผลว่างทั้งที่มีของถูก drop |
| curl ค้างหรือไม่ตอบ | เข้าไม่ถึง Gateway ไม่ใช่เรื่อง app — [บทที่ 13](../../docs/13-troubleshooting.md) |

รายละเอียดเต็มอยู่ที่ [บทที่ 11 หัวข้อ 4](../../docs/11-deploy-app.md) และ [บทที่ 13](../../docs/13-troubleshooting.md)

---

## อ้างอิง · ขอบเขต — ของกลาง กับ ของ service

ไม่ต้องอ่านตอนรัน — อ่านตอนสงสัยว่าไฟล์ใหม่ควรวางตรงไหน

```
k8s/
├── config/                          ← ของกลาง · ทำครั้งเดียวตอนตั้ง cluster
│   ├── security/namespaces.yaml         Namespace myhr-prod + PSA + Quota   (บท 10)
│   ├── security/default-deny.yaml       NetworkPolicy ของทั้ง namespace     (บท 10)
│   ├── security/allow-dns.yaml          ให้ทุก pod resolve DNS ได้          (บท 10)
│   ├── gateway/gateway.yaml             Gateway + listener 443 + cert       (บท 07)
│   └── (Secret regcred ไม่มีไฟล์ที่นี่ — มีรหัสจริง สร้างด้วยคำสั่งในบท 10)
│
└── deployments/
    ├── zeeme-ads/                   ← ที่นี่ · ของ zeeme-ads ตัวเดียว
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── pdb.yaml
    │   └── httproute.yaml
    └── zeeme-hr/                    ← service ตัวถัดไป ก็ 4 ไฟล์แบบเดียวกัน
```

**วิธีตัดสินว่าไฟล์ควรอยู่ตรงไหน ถามข้อเดียว:**

> *"พรุ่งนี้เพิ่ม `zeeme-hr` ต้องแก้ไฟล์นี้ หรือต้องมีสำเนาอีกอันไหม"*

| ตอบว่า | แปลว่า | ไปอยู่ |
|---|---|---|
| ต้องแก้ / ต้องมีสำเนา | ของกลาง | `config/` — ทำครั้งเดียว ทุก service ใช้ร่วมกัน |
| ไม่ต้องยุ่งเลย | ของ service | `deployments/ชื่อ-service/` |

Namespace · `regcred` · NetworkPolicy ระดับ namespace · Gateway ผ่านคำถามนี้ทั้งหมด (`zeeme-hr` ใช้ตัวเดียวกัน) → อยู่ `config/`
Deployment · Service · PDB · HTTPRoute ของ `zeeme-ads` ไม่มีใครใช้ต่อ → อยู่ที่นี่

`kubectl apply -f .` ตรงนี้จึงสร้างแค่ 4 อย่างนั้น **ไม่สร้าง Namespace · Secret · Gateway**
และไม่สร้าง NetworkPolicy ที่มีผลทั้ง namespace

> ข้อยกเว้นเดียวของ NetworkPolicy: policy ที่ `podSelector` เจาะจง label ของ `zeeme-ads`
> ตัวเดียว **วางไว้ที่นี่ได้และควรวางที่นี่** เพราะลบ service แล้วมันต้องถูกลบตามไปด้วย
> ส่วนที่ใช้ `podSelector: {}` (มีผลทุก pod) เป็นของกลางเสมอ — [`../README.md` ข้อ D](../README.md)

### อ้างถึงของกลางได้ แต่ไม่สร้างมัน

ในไฟล์มีสองบรรทัดที่พูดถึงของกลาง:

| บรรทัด | ความหมาย |
|---|---|
| `imagePullSecrets: regcred` | "ขอใช้ Secret ที่มีคนสร้างไว้แล้ว" |
| `parentRefs: myhr-gateway` | "ขอไปเกาะ Gateway ที่มีคนสร้างไว้แล้ว" |

ทั้งคู่คือการ **ขอใช้** ไม่ใช่การสร้าง ถ้าของนั้นยังไม่มี → ไปสร้างที่ต้นทางตามบทของมัน
**ไม่ใช่เพิ่มไฟล์ลงในโฟลเดอร์นี้**

เทียบง่าย ๆ: บรรทัด `namespace: myhr-prod` ก็เหมือนจ่าหน้าซองว่าส่งไปบ้านเลขที่ไหน
**ไม่ได้แปลว่าเป็นเจ้าของบ้าน**

ที่ต้องจ่าหน้าไว้เพราะ repo นี้ apply มือทั้งหมด ไม่มี GitOps — พลาด `-n` ตอน context
ชี้ผิดที่เกิดได้จริง ปักไว้แล้ว `kubectl` ฟ้องทันทีแทนที่จะลงผิดที่เงียบ ๆ
(ผลข้างเคียง: ลง uat ต้องแก้ค่านี้ก่อน — จึงต้องใช้ `sed` ใน [A4](#a4--ลง-uat-ก่อนเสมอ))

### ถ้าดื้อเอาของกลางมาไว้ที่นี่ จะเจออะไร

| เอามาไว้ที่นี่ | สิ่งที่เกิดขึ้นจริง |
|---|---|
| `namespaces.yaml` | วันที่ `zeeme-hr` apply ของตัวเอง ResourceQuota ของทั้ง namespace ถูกทับด้วยตัวเลขที่ `zeeme-hr` คิดไว้ **ไม่มี error ให้เห็น** |
| Secret `regcred` | รหัสจริงเข้า git history — ลบไฟล์ทีหลังไม่ได้ทำให้ปลอดภัยขึ้น |
| NetworkPolicy ระดับ namespace | policy พวกนี้ใช้ `podSelector: {}` = มีผลกับ **ทุก pod ใน namespace** แก้ให้ตัวเองแต่กระทบคนอื่นหมด |
| Namespace | `kubectl delete -f .` ที่ตั้งใจลบ service ตัวเดียว จะลบ **ทุก service ใน namespace** |
| Gateway | สอง service แก้ listener คนละทาง ทับกันไปมา |

และ RBAC ก็ไม่ให้อยู่แล้ว — dev สร้าง Namespace, Gateway, NetworkPolicy ไม่ได้ (บทที่ 10)
apply เข้าไปจะโดน `Forbidden` เฉพาะชิ้นที่เป็นของกลาง ส่วนที่เหลือขึ้นไปเรียบร้อย
จบด้วยสภาพ **ขึ้นไปครึ่งเดียว** ซึ่งไล่ยากกว่าพังทั้งก้อนมาก

### เส้นแบ่งของ HTTPRoute

อันนี้สับสนง่ายที่สุด เพราะมันพูดถึง Gateway ที่เป็นของกลาง แต่ตัวไฟล์อยู่ที่นี่:

| | ของใคร | อยู่ที่ |
|---|---|---|
| Gateway · listener 443 · cert wildcard | ของกลาง — ทุก service มาเกาะตัวเดียวกัน | `config/gateway/` |
| hostname `ads.myhr.co.th` + path ของ `zeeme-ads` | ของ service ตัวนี้ตัวเดียว | `httproute.yaml` ที่นี่ |

ตัวที่ยอมให้ route จาก namespace อื่นมาเกาะได้คือ `allowedRoutes.namespaces.from: All`
ที่ตั้งไว้**ฝั่ง Gateway** ไม่ใช่สิ่งที่ไฟล์นี้เปิดเอง

> ถ้าต้องแก้ listener หรือเพิ่มชื่อใน cert เพื่อ service นี้
> **แก้ที่ `config/gateway/` แล้วบันทึกในบทที่ 07** อย่าเอามาไว้ที่นี่

---

> **ถ้าคู่มือกับไฟล์ที่นี่ไม่ตรงกัน — [บทที่ 11](../../docs/11-deploy-app.md) ถูก** แล้วแก้ไฟล์ที่นี่ตาม
> **ถ้าของบน cluster ไม่ตรงกับที่นี่ — ที่นี่ถูก** แล้ว apply ทับ
> 🔴 ห้าม `kubectl edit` บน cluster ตรง ๆ เด็ดขาด
