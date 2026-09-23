# `deployments/` — คู่มือสำหรับคนที่มารับช่วงต่อ

โฟลเดอร์นี้เก็บ manifest ของ **application** ที่รันบน cluster หนึ่งโฟลเดอร์ต่อหนึ่ง service

เอกสารนี้ตอบคำถามเดียว: **"ผมอยากเพิ่มของ ต้องไปแตะตรงไหนบ้าง"**
เพราะของบางอย่างเพิ่มได้จบในโฟลเดอร์ service แต่บางอย่างต้องไปแตะของกลางที่คนอื่นใช้ร่วมกันอยู่
และสองอย่างนี้คนละความเสี่ยงกันคนละเรื่อง

---

## แผนที่ — ของกลาง กับ ของ service

```
k8s/
├── config/                          ← ของกลาง · ตั้งครั้งเดียว ทุก service ใช้ร่วมกัน
│   ├── security/namespaces.yaml         Namespace + PSA + ResourceQuota      (บท 10)
│   ├── security/default-deny.yaml       NetworkPolicy ระดับทั้ง namespace     (บท 10)
│   ├── security/allow-dns.yaml          ให้ทุก pod resolve DNS ได้            (บท 10)
│   ├── gateway/                         Gateway + listener 443 + cert         (บท 07)
│   ├── app/deployment-template.yaml     แม่แบบของ service ใหม่                (บท 11)
│   ├── app/validate-manifests.sh        ตัวตรวจก่อน merge — แทน GitOps        (บท 11)
│   └── (Secret ไม่มีไฟล์ที่นี่ — มีรหัสจริง สร้างด้วยคำสั่ง)
│
└── deployments/                     ← ของ service · เพิ่มได้เรื่อย ๆ
    ├── zeeme-ads/                       deployment · service · pdb · httproute  (เข้าผ่าน Gateway)
    ├── zeeme-ads-nodeport/              ทางเลือกแทนชุดบน — NodePort 30100 · ใช้ชุดใดชุดหนึ่ง
    └── zeeme-hr/                        service ตัวถัดไป หน้าตาเดียวกัน
```

**เกณฑ์ตัดสินข้อเดียว** — *"ถ้าพรุ่งนี้มี service ใหม่ ไฟล์นี้ต้องถูกแก้หรือต้องมีสำเนาอีกอันไหม"*
ต้อง = ของกลาง อยู่ `config/` · ไม่ต้อง = ของ service อยู่ `deployments/ชื่อ/`

---

## ตารางรวม — อยากเพิ่มอะไร แตะตรงไหน

| อยากทำ | ต้องแตะ | ใครทำได้ |
|---|---|---|
| **A** เพิ่ม service ใหม่ใน namespace ที่มีอยู่ | `deployments/ชื่อ/` อย่างเดียว | dev |
| **B** เพิ่ม namespace / environment ใหม่ | 🔴 ของกลาง 4 จุด | ทีมที่ดูแล cluster |
| **C** เพิ่ม hostname ให้ service เดิม | `httproute.yaml` + DNS · (cert ถ้าอยู่นอก wildcard) | dev · (cert = ทีม cluster) |
| **D** เปิดเส้นทางเน็ตใหม่ (DB, ข้าม namespace, scrape) | ขึ้นกับว่าเจาะจง service เดียวหรือทั้ง namespace | ดูในหัวข้อ |
| **E** Secret ของแอปเอง (รหัส DB, API key) | ไม่มีไฟล์ใน git — สร้างด้วยคำสั่ง แล้วจดว่าต้องมีอะไรบ้าง | dev + ops |
| **F** ขอ storage / PVC | 🔴 ยังทำไม่ได้ ต้องคุยก่อน | — |
| **G** เพิ่ม replica หรือ resources | `deployment.yaml` แต่กินโควตากลาง | dev + ตรวจ capacity |

---

## A · เพิ่ม service ใหม่ใน namespace เดิม

**เคสที่พบบ่อยที่สุด และเป็นเคสเดียวที่ไม่ต้องแตะ `config/` เลย**

```bash
mkdir -p deployments/NEWAPP
```

```bash
cp config/app/deployment-template.yaml deployments/NEWAPP/all.yaml
```

แม่แบบเป็นไฟล์เดียวที่มีครบ 4 ชิ้น จะแยกเป็น 4 ไฟล์แบบ `zeeme-ads/` ก็ได้ แล้วแทน `APPNAME`

```bash
sed -i 's/APPNAME/NEWAPP/g' deployments/NEWAPP/all.yaml
```

**แล้วแก้ 5 ค่าที่แม่แบบเดาแทนไม่ได้:**

| ค่า | หาได้จาก |
|---|---|
| `image` | registry — pin ด้วย digest ถ้าทำได้ |
| `containerPort` | พอร์ตจริงของ service (`zeeme-ads` คือ 8100 ไม่ใช่ 8080 ในแม่แบบ) |
| path ของ probe | ยิงของจริงดูก่อนว่า `/actuator/health/*` มีจริงไหม |
| `resources` | ของเดิมกินเท่าไร — ถ้าไม่รู้ ใส่ค่าตั้งต้นแล้ววัดใน 24 ชม.แรก |
| `hostnames` ใน HTTPRoute | ต้องอยู่ใต้ `*.myhr.co.th` ไม่งั้นดูข้อ C |

**ก่อน merge:**

```bash
config/app/validate-manifests.sh deployments/NEWAPP/
```

ต้องได้ exit 0 · แล้วลง uat ก่อน prod เสมอ ([บทที่ 11](../docs/11-deploy-app.md))

> ✅ **ครบเมื่อมี 4 ชิ้น: Deployment · Service · PDB · HTTPRoute**
> ขาด PDB คือข้อที่ลืมบ่อยที่สุด และเป็นข้อที่ทำให้ `kubectl drain` ทุก 1-2 เดือน
> ทำ service ดับจริง (cluster นี้ไม่มี Ksplice — [บทที่ 12](../docs/12-day2-operations.md))

### ลำดับ apply — เรียงตามนี้

**0 · ตรวจของกลางว่ามีครบ (ไม่ต้องสร้าง)**

```bash
kubectl get ns myhr-prod && kubectl -n myhr-prod get secret regcred && kubectl -n myhr-prod get netpol && kubectl -n envoy-gateway-system get gateway myhr-gateway
```

ขาดตัวไหน = ยังไม่ถึงคิวของ service ให้ไปทำข้อ B ก่อน

**1 · Secret ของแอป — ถ้ามี**

```bash
kubectl -n myhr-prod create secret generic NEWAPP-config --from-literal=DB_PASSWORD=CHANGEME
```

ต้องมาก่อน Deployment ไม่งั้น pod จะขึ้นมาเป็น `CreateContainerConfigError` แล้ว retry วนอยู่พักหนึ่ง

**2 · Service**

```bash
kubectl apply -f deployments/NEWAPP/service.yaml
```

มาก่อน Deployment เพราะ EndpointSlice จะได้พร้อมรับ pod ตัวแรกที่ ready ทันที
และแอปที่ยังอ่าน service env var แบบเก่า (`NEWAPP_SERVICE_HOST`) ต้องมี Service อยู่ก่อน pod เกิด

**3 · PDB**

```bash
kubectl apply -f deployments/NEWAPP/pdb.yaml
```

วางไว้ก่อน Deployment เพื่อไม่ให้มีช่วงที่ pod รันอยู่โดยไม่มีเพดานการไล่ออก
ถ้ามีใคร drain node ระหว่างที่ deploy ยังไม่เสร็จ ก็ยังมีตัวคุม

**4 · Deployment แล้วรอจนขึ้นจริง**

```bash
kubectl apply -f deployments/NEWAPP/deployment.yaml
```

```bash
kubectl -n myhr-prod rollout status deploy/NEWAPP --timeout=5m
```

```bash
kubectl -n myhr-prod get endpointslice -l kubernetes.io/service-name=NEWAPP
```

**ต้องเห็น endpoint ก่อนไปข้อ 5** — ว่างเปล่าแปลว่าไม่มี pod ไหนผ่าน readinessProbe

**5 · HTTPRoute — เปิดทางเข้าเป็นอย่างสุดท้าย**

```bash
kubectl apply -f deployments/NEWAPP/httproute.yaml
```

```bash
kubectl -n myhr-prod get httproute NEWAPP -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
```

ต้องได้ `Accepted=True` และ `ResolvedRefs=True` · เปิดก่อนที่ backend จะมี endpoint
คนที่หลงเข้ามาจะเจอ 503 จาก Envoy โดยที่สถานะ route ยังขึ้นเขียวทุกอย่าง

**6 · ยิงทดสอบด้วย `--resolve` ก่อนแตะ DNS**

```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
```

```bash
curl -I --resolve "NEWAPP.myhr.co.th:443:${GW_IP}" https://NEWAPP.myhr.co.th
```

**7 · เพิ่ม DNS record ชี้มาที่ Gateway IP**

ทำท้ายสุดเสมอ นี่คือสวิตช์จริงที่ทำให้คนนอกเข้าถึงได้ · แล้วเฝ้า Grafana 24 ชม.
([บทที่ 14](../docs/14-grafana-logs.md)) ก่อนถือว่าจบ

---

**ถ้าอยากใช้คำสั่งเดียวจบ** `kubectl apply -f deployments/NEWAPP/` ก็ใช้ได้ตอน**สร้างใหม่**
เพราะทุก controller จะไล่ปรับสภาพให้ตรงกันเองภายในไม่กี่วินาที

รู้ไว้ 2 อย่าง: `kubectl` เรียง**ตามชื่อไฟล์** (deployment → httproute → pdb → service)
ซึ่งกลับด้านกับลำดับข้างบน · และช่วงสั้น ๆ ที่ route ขึ้นก่อน endpoint จะตอบ 503

**ลำดับข้างบนสำคัญจริงตอนแก้ของที่มีคนใช้อยู่แล้ว** ตอนสร้างใหม่ที่ยังไม่มี DNS ชี้มา ไม่มีใครเห็น

### ถอนออก — ย้อนลำดับกลับ

```bash
kubectl -n myhr-prod delete httproute NEWAPP
```

ตัดทางเข้าก่อนเสมอ แล้วค่อยลบ Deployment · PDB · Service · Secret ตามหลัง
(ลบ DNS record ก่อนหน้านั้นถ้าเคยชี้ไว้แล้ว)

---

## B · เพิ่ม namespace หรือ environment ใหม่

🔴 **นี่คือของกลาง ไม่ใช่งานที่ทำจบในโฟลเดอร์ service** ทำ 4 อย่างนี้ก่อน ไม่งั้น service
ที่ลงไปจะขึ้นได้แต่เรียกไม่ถึง หรือ pull image ไม่ได้ โดยอาการดูเหมือน app พัง

| ลำดับ | ทำอะไร | ที่ไหน |
|---|---|---|
| 1 | Namespace + PSA label `restricted` + ResourceQuota + LimitRange | `config/security/namespaces.yaml` |
| 2 | `default-deny-all` + `allow-from-gateway` + `allow-dns-egress` ของ namespace นั้น | `config/security/default-deny.yaml` · `allow-dns.yaml` |
| 3 | Secret `regcred` ของ namespace นั้น | `NAMESPACES='ชื่อ-ns' bash config/registry/create-regcred.sh` · [บทที่ 10 หัวข้อ 7](../docs/10-security.md) |
| 4 | หักโควตาจากเพดานที่เหลือ | ดูย่อหน้าถัดไป |

> **NetworkPolicy กับ Secret ไม่ข้าม namespace** — สองข้อนี้คือที่คนพลาดบ่อยที่สุด
> คู่มือชุดเดิมสร้าง `regcred` แค่ใน `default` แล้วงงว่าทำไม namespace อื่น pull ไม่ได้
> ส่วน namespace ที่ไม่มี `allow-dns-egress` จะ resolve DNS ไม่ได้ทั้ง namespace

**โควตาต้องหักจากของที่เหลือ ไม่ใช่เพิ่มใหม่ลอย ๆ** — เพดานที่วางแผนได้คือ
**32 vCPU / 96 GB** (ค่า N+1 ตอน drain เหลือ worker 2 เครื่อง) ตอนนี้แจกไปแล้ว
prod 60% · uat 25% · เหลือให้ระบบ 15% การเพิ่ม namespace ใหม่แปลว่าต้องลดของเดิมลง

```bash
kubectl get resourcequota -A
```

---

## C · เพิ่ม hostname ให้ service เดิม

**ถ้าชื่อใหม่อยู่ใต้ `*.myhr.co.th`** (เช่น `ads2.myhr.co.th`) — จบในโฟลเดอร์ service

1. เพิ่มชื่อใน `hostnames:` ของ `httproute.yaml`
2. `kubectl apply -f .`
3. เพิ่ม DNS record ชี้มาที่ Gateway IP

**ถ้าอยู่นอก wildcard** (เช่น `ads.mycompany.com` หรือชื่อลึกสองชั้น `a.b.myhr.co.th`) —
เป็นของกลาง ต้องเพิ่มชื่อลงใน cert ก่อนแล้ว import ใหม่ ([บทที่ 07](../docs/07-gateway-tls.md) ภาคผนวก)
ถ้าข้ามขั้นนี้จะตายที่ TLS ตั้งแต่ยังไม่ถึง app

> ⚠️ **hostname + path ห้ามซ้ำกับ route ที่มีอยู่** บน listener เดียวกัน
> ตัวที่มาทีหลังจะได้ `Accepted=False` แบบไม่มีใครสังเกต — `kubectl get httproute`
> ไม่มีคอลัมน์สถานะ ต้องดูด้วย jsonpath (วิธีดูอยู่ใน [`zeeme-ads/README.md`](zeeme-ads/README.md))

---

## D · เปิดเส้นทางเน็ตใหม่

**ดูของจริงก่อนเสมอ อย่าเดาว่าเส้นไหนโดนปิด:**

```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --namespace myhr-prod --verdict DROPPED --last 50
done
```

แล้วเปิดเฉพาะเส้นที่ถูก drop จริง · **จะเขียนไว้ที่ไหนขึ้นกับว่า policy กว้างแค่ไหน:**

| policy แบบ | เป็นของ | เก็บไว้ที่ |
|---|---|---|
| `podSelector: {}` — มีผลกับทุก pod ใน namespace | ของกลาง | `config/security/default-deny.yaml` |
| `podSelector` เจาะจง label ของ service เดียว | ของ service นั้น | `deployments/ชื่อ/networkpolicy.yaml` |

เส้นที่มีอยู่ตอนนี้เป็นแบบแรกทั้งหมด เช่น `allow-prometheus-scrape` ที่เปิดไว้ที่พอร์ต 8080 —
**การไปแก้เลขพอร์ตในนั้นกระทบทุก service ใน namespace** ถ้าต้องการเปิดพอร์ตให้ service ตัวเดียว
เขียน policy ใหม่แบบเจาะจง label แล้ววางในโฟลเดอร์ service จะปลอดภัยกว่า และถูกลบตามตอนลบ service

---

## E · Secret ของแอปเอง (รหัส DB, API key)

Secret แบบนี้ **เป็นของ service ตัวนั้นจริง** (ไม่เหมือน `regcred` ที่เป็นของกลาง —
ตัวนั้นสร้างด้วย [`config/registry/create-regcred.sh`](../config/registry/create-regcred.sh)
ดู [บทที่ 10 หัวข้อ 7](../docs/10-security.md))
แต่ **ยังห้ามอยู่ใน git** เพราะมีค่าจริงอยู่ข้างใน

ท่าที่ใช้ตอนนี้ — สร้างด้วยคำสั่ง แล้ว **จดว่าต้องมีคีย์อะไรบ้าง (ไม่จดค่า)** ไว้ใน README ของ service:

```bash
kubectl -n myhr-prod create secret generic NEWAPP-config --from-literal=DB_PASSWORD=CHANGEME
```

> ที่ต้องจดไว้เพราะไม่มี GitOps — ถ้าไม่มีใครจด วันที่ต้องสร้าง cluster ใหม่หรือ namespace ใหม่
> จะไม่มีใครรู้ว่า service ต้องการ secret อะไรบ้าง จนกว่า pod จะพังแล้วต้องไล่อ่าน log
>
> ถ้าอยากเก็บ secret ใน git จริง ๆ ต้องลง SealedSecret หรือ SOPS ก่อน
> **cluster นี้ยังไม่มี** — เป็นเรื่องที่ต้องตัดสินใจ ไม่ใช่แค่เพิ่มไฟล์

---

## F · ขอ storage / PVC

🔴 **ยังทำไม่ได้ และแก้ที่ ResourceQuota อย่างเดียวไม่พอ**

cluster นี้ไม่มี dynamic storage (การตัดสินใจ D8) โควตาจึงตั้ง `persistentvolumeclaims: 0` ไว้ตรง ๆ
ถ้าเปิดโควตาแล้ว apply PVC เข้าไปเฉย ๆ pod จะค้าง `Pending` ตลอดไปเพราะไม่มีใคร provision ให้

ต้องเลือกทางก่อน (ลง CSI driver · NFS · หรือใช้ของนอก cluster) แล้วบันทึกการตัดสินใจไว้
ก่อนจะมี service ตัวไหนพึ่ง storage ได้ — [บทที่ 08](../docs/08-storage.md)

---

## G · เพิ่ม replica หรือ resources

แก้ในไฟล์ของ service ได้เลย **แต่ตัวเลขไปกินโควตากลาง** ตรวจ 2 อย่างก่อน:

```bash
kubectl -n myhr-prod describe resourcequota
```

```bash
kubectl top nodes
```

**เพดานที่วางแผนได้คือ 32 vCPU / 96 GB ไม่ใช่ 48/144 ที่เห็น** — ต้องเผื่อว่าตอน drain
จะเหลือ worker 2 เครื่อง ถ้าแจกจนเต็ม 48 วันที่ drain pod จะไม่มีที่ลง
alert `ClusterCapacityNearNPlusOneLimit` ([บทที่ 09](../docs/09-observability.md)) จับเรื่องนี้ไว้
แต่มันนับจาก `requests` เท่านั้น — pod ที่ไม่ประกาศ requests นับเป็น 0 ทั้งที่กิน RAM จริง

> 🔴 **`topologySpreadConstraints` ที่ `maxSkew: 1` ทำให้ pod ค้าง `Pending` ระหว่าง drain
> ไม่ว่าจะตั้ง replica เป็นเลขอะไร** — `nodeTaintsPolicy` ค่าเริ่มต้นคือ `Ignore`
> แปลว่า node ที่โดน cordon ยัง**ถูกนับเป็น domain ที่มี 0 pod** อยู่ ค่า skew ของ node
> ที่เหลือจึงเกิน 1 ทันที pod ที่ถูกไล่ออกเลยลงที่ไหนไม่ได้จนกว่า node เดิมจะกลับมา
>
> **ไม่ใช่เรื่องผิดพลาด แต่เป็นการแลก:** ยอมให้ capacity หายชั่วคราว แลกกับการไม่ให้ pod
> ไปกองรวมกันบน node เดียว · ตัวที่กันไม่ให้ service ดับระหว่างนั้นคือ **PDB**
> ถ้าไม่อยากให้ค้าง ใส่ `nodeTaintsPolicy: Honor` ในข้อจำกัดนั้น **แล้วต้องแก้
> `config/app/deployment-template.yaml` ด้วย** ไม่งั้น service ที่ทำทีหลังจะไม่เหมือนกัน

---

## กติกาที่ต้องไม่หายไปหลังส่งมอบ

repo นี้ **ไม่มี GitOps** (การตัดสินใจ D9) ไม่มีอะไรบังคับให้ของบน cluster ตรงกับ git
4 ข้อนี้คือสิ่งที่มาแทน ถ้าหายไปสักข้อ ของบน cluster จะค่อย ๆ ต่างจาก git โดยไม่มีใครรู้ตัว

1. **apply จาก git เท่านั้น** ห้าม `kubectl edit` บน cluster ตรง ๆ เด็ดขาด
   ถ้าของบน cluster ไม่ตรงกับ git ให้ถือว่า **git ถูก** แล้ว apply ทับ
2. **ทุกอย่างต้องผ่าน `config/app/validate-manifests.sh` ก่อน merge**
   6 ข้อ: schema · ทุก Deployment มี PDB · `replicas >= 2` · มี `requests` · มี probe · ไม่ root ไม่ `:latest`
3. **แตะ `config/` เมื่อไหร่ ต้องอัปเดตคู่มือด้วย** แก้ `docs/*.md` แล้ว build ใหม่:
   ```bash
   python tools/build-html.py
   ```
   คู่มือคือของที่คนต่อไปอ่าน ถ้า `config/` กับ `docs/` ไม่ตรงกัน คนอ่านจะเชื่อคู่มือ
4. **ของใหม่ทุกตัวต้องรอด `kubectl drain`** เพราะไม่มี Ksplice จึงต้อง drain ทุกเครื่องทุก 1-2 เดือน
   แปลว่า: มี PDB · replica ≥ 2 · กระจายข้าม node · ปิดงานค้างได้ทันใน `terminationGracePeriodSeconds`

---

## ใครทำอะไรได้

| | dev | ทีมที่ดูแล cluster |
|---|---|---|
| `deployments/ชื่อ/` ของ service ตัวเอง | ✅ | ✅ |
| Namespace · PSA · ResourceQuota | ❌ | ✅ |
| Secret `regcred` · NetworkPolicy ระดับ namespace | ❌ | ✅ |
| Gateway · listener · cert | ❌ | ✅ |

RBAC 3 ระดับตั้งไว้ตาม [บทที่ 10](../docs/10-security.md)

> **ถ้า `kubectl apply` แล้วได้ `Forbidden` — แปลว่ากำลังแตะของกลาง ไม่ใช่ manifest ของตัวเองพัง**
> ระวังตอน apply ทั้งโฟลเดอร์: ชิ้นที่เป็นของกลางโดนปฏิเสธ แต่ชิ้นที่เหลือขึ้นไปแล้ว
> จะเหลือของขึ้นครึ่งเดียว — อ่านผลลัพธ์ให้ครบทุกบรรทัดก่อนสรุปว่าล้มเหลวทั้งหมด
