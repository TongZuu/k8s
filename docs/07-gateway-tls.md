# บทที่ 07 — Envoy Gateway และ TLS

> **รันที่: 👑 master01 เกือบทั้งบท** · ยกเว้น 2 จุดที่บอกไว้: ไฟล์ cert ในข้อ 3 ต้อง `scp` ขึ้นมาจาก**เครื่องคุณ**
> · `curl` ทดสอบในข้อ 5-6 ต้องยิงจาก**เครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node** (เครื่องเดียวกับบท 05 ข้อ 7)
> **ลำดับ: 0 → 6 ตามลำดับ ทำพร้อมกันไม่ได้** — ข้อ 3 (cert) ต้องเสร็จก่อนข้อ 4 (Gateway) เสมอ
> **เวลาที่ใช้:** ~40 นาที (ไม่รวมเวลาขอไฟล์ cert)
> **ต้องผ่านบทที่ 05-06** — โดยเฉพาะการ curl เข้า LoadBalancer IP จากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node ได้

---

## ทำไมเป็น Gateway API ไม่ใช่ Ingress

`ingress-nginx` **ปิดโปรเจกต์ไปแล้วเมื่อ มี.ค. 2026** ไม่มี security patch อีกและตัวที่ตั้งใจให้มาแทนก็ถูกยกเลิก
ในเมื่อรอบนี้เขียนคู่มือใหม่หมดอยู่แล้ว การเริ่มที่ Gateway API เลยแทบไม่มีต้นทุนเพิ่ม
และตัดปัญหาต้องย้ายสองรอบ

**ภาพรวมที่จะได้ — 1 IP รองรับทุก service:**

```
ads.myhr.co.th ─┐
hr.myhr.co.th  ─┼─→ 192.168.50.200 ─→ Envoy Gateway ─┬─→ zeeme-ads  (ClusterIP)
api.myhr.co.th ─┘      LB IP เดียว    (แยกด้วย host)  ├─→ zeeme-hr   (ClusterIP)
                                                     └─→ zeeme-api  (ClusterIP)
```

microservice ทุกตัวเป็น `ClusterIP` ธรรมดา **ไม่กิน IP ของ LAN เลย**

---

## บันทึกการตัดสินใจ — cert ของโครงการนี้

**ใช้ public cert wildcard ที่องค์กรมีอยู่แล้ว** (ตรวจแล้ว 4 ก.ย. 2026)

| | |
|---|---|
| ชนิด | `*.myhr.co.th` + apex `myhr.co.th` |
| ผู้ออก | GlobalSign GCC R46 AlphaSSL CA 2025 |
| หมดอายุ | **11 มี.ค. 2027** — ตั้งเตือน 9 ก.พ. 2027 ([บท 12 หัวข้อ 3.1](12-day2-operations.md)) |

เพราะ wildcard ครอบทุกชื่อที่จะเปิด บทนี้จึง **ไม่ต้องลง cert-manager · ไม่ต้องออก internal CA
· ไม่ต้องไล่ลง root CA ที่เครื่อง client** ซึ่งเป็นงานที่หนักที่สุดของทางเลือกอีกทาง

> ถ้าวันหนึ่ง public cert ครอบชื่อที่ต้องการไม่ครบ (เช่นเปิด service ที่ใช้ชื่อภายใน
> ซึ่งจดโดเมนไม่ได้) ทางเลือกที่ใช้ internal CA อยู่ใน **ภาคผนวก ข** ท้ายบท
> ทำเพิ่มทีหลังได้โดยไม่ต้องรื้อของเดิม

> 🔎 **เวลามีปัญหาหลังบทนี้** (404 ทั้งที่ route เขียว, `no healthy upstream`, listener HTTPS ไม่ขึ้น,
> route ข้าม namespace) ให้เปิด [`../html/cilium-envoy-scenarios.html`](../html/cilium-envoy-scenarios.html)
> — ค้นด้วยข้อความ error ได้ตรง ๆ เรียงตามความถี่ที่เจอจริง
>
> 📐 **ก่อนสร้าง service ใหม่** หน้าเดียวกันมีฝั่ง "แบบแผนที่ควรทำ" — API service (P01),
> web app React/Angular (P02), หลาย service ใต้ host เดียว (P03), แบ่ง zone public/private (P06)

---

## 0 · ตรวจว่าไฟล์ของบทนี้อยู่บนเครื่องแล้ว

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** [บท 06](06-verify.md) ผ่านเช็กลิสต์ · `/root/k8s/` sync จาก[บท 00](00-overview.md)

บทนี้อ้างไฟล์ในrepo 10 ไฟล์ ถ้า `/root/k8s/` บนเครื่องยังเป็นชุดเก่า จะเจอ
`does not exist` กระจายทีละขั้น และคำสั่งตรวจที่ตามมาจะตอบอะไรที่ดูเหมือนคำตอบแต่ไม่ใช่

```bash
for f in config/gateway/envoyproxy.yaml \
         config/gateway/gatewayclass.yaml \
         config/gateway/gateway.yaml \
         config/gateway/httproute-example.yaml \
         config/gateway/https-redirect.yaml \
         config/gateway/import-public-cert.sh \
         config/gateway/check-cert-overlap.sh \
         config/cert-manager/internal-ca.yaml \
         config/cert-manager/internal-cert.yaml \
         config/cert-manager/pdb.yaml; do
  [ -f "/root/k8s/$f" ] && echo "  ok   $f" || echo "  ขาด  $f"
done
```

**ต้องได้ `ok` ครบ 10 บรรทัด**

ถ้ามี `ขาด` แปลว่า `/root/k8s/` บนเครื่องยังเป็นชุดเก่า ต้อง sync ใหม่ —
**คำสั่งนี้รันบนเครื่องที่มีrepo ไม่ใช่บน node** โดยยืนอยู่ในโฟลเดอร์rootของrepo:

```bash
scp -r docs/versions.env config/ root@192.168.50.101:/root/k8s/
```

แล้วกลับมารันบล็อกตรวจข้างบนซ้ำจนได้ `ok` ครบ

> ขั้นตอน sync เต็ม (ทั้ง 6 เครื่อง) อยู่ที่ [บทที่ 00 — ก่อนเริ่ม](00-overview.md)
>
> ทำทีเดียวตอนเริ่มบท ดีกว่าไปเจอทีละไฟล์กลางทาง — เพราะคำสั่งที่ตามหลัง `apply`
> ที่ล้มมักตอบกลับมาเป็นข้อความที่ดูปกติ (`No resources found`) แทนที่จะเป็น error

---

## 1 · ตรวจว่าเครื่องสะอาดก่อนเริ่ม

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 0 `ok` ครบ · ข้อนี้อ่านอย่างเดียว

> 📖 **แหล่งอ้างอิงของขั้นที่ 1-2:** [Install with Helm — Envoy Gateway](https://gateway.envoyproxy.io/docs/install/install-helm/)
> **ถ้าคำสั่งในบทนี้ขัดกับเอกสารทางการ ให้เชื่อเอกสาร** แล้วมาแก้บทนี้ตาม
> สิ่งที่บทนี้เพิ่มให้คือ *ค่าที่ต้องใช้ของโครงการนี้* · *คำสั่งตรวจว่าสำเร็จจริง* · *กับดักที่วัดได้บนเครื่องนี้*

**🔴 อย่าลง Gateway API CRD เอง** — `helm install` ที่ขั้นที่ 2 ลงให้ทั้งชุดอยู่แล้ว
(ค่าเริ่มต้น `crds.enabled=true` ลงทั้ง Gateway API CRDs และ Envoy Gateway CRDs)

```bash
set -a && source /root/k8s/versions.env && set +a
kubectl get crd | grep gateway.networking.k8s.io
```

**ไม่มีอะไรออกมาเลย = สะอาด → ข้ามไปขั้นที่ 2 ได้เลย**

---

**เฉพาะกรณีที่บรรทัดบนมี CRD โผล่มา** ให้เช็กก่อนว่าไม่มีใครใช้อยู่:
```bash
kubectl get gateways,httproutes,grpcroutes,referencegrants -A
```

| ที่ได้ | แปลว่า |
|---|---|
| `Error from server (NotFound): ... could not find the requested resource` | **CRD ไม่มีอยู่จริง = สะอาด** ไปขั้นที่ 2 ได้ (เจอตอนเผลอรันบรรทัดนี้บนเครื่องสะอาด) |
| `No resources found` | CRD มีอยู่ แต่ยังไม่มีใครใช้ → ถอนได้ปลอดภัย |
| มี object โผล่มา | **หยุด** มีของใช้งานจริงอยู่ |

> 🔴 **สองข้อความแรกไม่เหมือนกัน** — `NotFound` คือ "ไม่มี CRD ตัวนี้ในระบบ"
> ส่วน `No resources found` คือ "มี CRD แต่ยังไม่มี object" อ่านสลับกันแล้วจะสรุปผิดทั้งสองทาง
> และ `NotFound` ที่หน้าตาเหมือน error นั้น **คือผลลัพธ์ที่ถูกต้อง**สำหรับเครื่องที่ยังไม่เคยลงอะไร

ถ้าต้องถอน ให้ทำตาม **ภาคผนวก — เริ่มบทนี้ใหม่** ท้ายบท
การลบ CRD ลบ object ทั้งหมดใต้มันไปด้วยโดยไม่ถามซ้ำ

> 🔴 **CRD ที่ลงเองค้างไว้จะไม่ถูกทับ และไม่มี error ให้เห็น**
> helm ลง CRD จากโฟลเดอร์พิเศษ `crds/` ไม่ใช่จาก template ซึ่งกลไกนั้น
> **ข้ามของที่มีอยู่แล้วเงียบ ๆ** (ตรวจบน cluster จริง: `helm get manifest` ยาว 613 บรรทัด
> แต่ไม่มี `kind: CustomResourceDefinition` เลย และ CRD บนเครื่องไม่มี
> annotation `meta.helm.sh/release-name`)
>
> ผลคือ cluster ค้างอยู่กับ CRD ชุดเก่าตลอดไป โดยที่ `helm install` รายงานว่าสำเร็จ
> ขั้นที่ 2 จึงมีคำสั่งตรวจว่าได้ CRD ชุดที่ chart ตั้งใจจริงหรือเปล่า

## 2 · ติดตั้ง Envoy Gateway

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 1 สะอาด · `helm` ใช้ได้ ([บท 05 ข้อ 1](05-cilium.md))
· เครื่องออก `docker.io` ได้ (chart เป็น OCI) · ทำตามลำดับในข้อนี้: chart → install → ตรวจ → EnvoyProxy → GatewayClass

### ค่าที่โครงการนี้ใช้ — ต่างจากตัวอย่างในเอกสาร

| | เอกสารทางการ | **โครงการนี้** | ทำไม |
|---|---|---|---|
| ชื่อ release | `eg` | **`envoy-gateway`** | อ่านออกตอนไล่ปัญหา · คำสั่งอื่นในบทนี้อ้างชื่อนี้ |
| namespace | `envoy-gateway-system` | เหมือนกัน | Secret ของ cert ที่ขั้นที่ 3 ต้องอยู่ namespace นี้ |
| เวอร์ชัน | เลขล่าสุดในหน้าเอกสาร | **`v${ENVOY_GATEWAY_VERSION}`** จาก `versions.env` | ตรึงไว้ทั้งโครงการ ห้ามอัปเดตกลางคัน |
| GatewayClass | อยู่ใน `quickstart.yaml` | **ไฟล์แยกของเรา** | `quickstart.yaml` มี Gateway + HTTPRoute ของ demo ติดมาด้วย ซึ่งจะกิน LB IP จาก pool ไปหนึ่งตัว |

**ตรวจก่อนว่าดึง chart ได้จริง** — ยังไม่แตะ cluster:
```bash
set -a && source /root/k8s/versions.env && set +a
helm show chart oci://docker.io/envoyproxy/gateway-helm --version "v${ENVOY_GATEWAY_VERSION}"
```
**ควรเห็น:** `name: gateway-helm` และ `version:` ตรงกับที่ขอ

ข้อนี้แยก "ดึงของไม่ได้" ออกจาก "ลงแล้วพัง" ให้จบในคำสั่งเดียว
ถ้าเจอ `i/o timeout` / `no such host` แปลว่าเครื่องออก docker.io ไม่ได้ ซึ่งกระทบบทที่ 09 ด้วย

> 🔴 **ถ้าเจอ `dial tcp [2600:...]:443: connect: network is unreachable`**
> ตัวเลขในวงเล็บเหลี่ยมคือที่อยู่ IPv6 — เครื่องมี IPv6 address แต่ไม่มี route ออกข้างนอก
>
> **เกิดเป็นครั้งคราว ไม่ใช่ทุกครั้ง** — เจอจริงบนเครื่องเดียวกัน install รอบหนึ่งผ่าน อีกรอบล้ม
> ขึ้นกับว่ารอบนั้นหยิบ address ตัวไหน ทำให้ลองใหม่แล้วอาจผ่านไปเฉย ๆ ซึ่งอันตรายกว่าล้มทุกครั้ง
> เพราะจะไปโผล่อีกทีตอน worker ดึง image ในบทหลัง
>
> ลองใหม่ได้ก่อน แต่ควรไปปิด IPv6 ตาม [บทที่ 01 ข้อ 1.2](01-prepare-os.md) **ให้ครบทุกเครื่อง**

**ติดตั้ง:**
```bash
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version "v${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system --create-namespace
```
**ควรเห็น:** `NAME: envoy-gateway` · `STATUS: deployed` · `REVISION: 1` (ใช้เวลา ~1 นาที ดึง image)

**ตรวจด้วยคำสั่งของเอกสารทางการ:**
```bash
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```
**ควรเห็น:** `deployment.apps/envoy-gateway condition met` — ถ้าหมดเวลา ดู `kubectl -n envoy-gateway-system get pods`

**แล้วตรวจซ้ำด้วยตัวชี้ขาดจริง:**
```bash
helm status envoy-gateway -n envoy-gateway-system | head -6
```
**ควรเห็น:** `STATUS: deployed` และ `DESCRIPTION: Install complete`

> 🔴 **สถานะของ deployment ไม่ได้บอกว่า helm สำเร็จ** — เจอมาแล้วบนเครื่องจริง
> จอเดียวกันขึ้นทั้ง `Error: INSTALLATION FAILED` และ
> `deployment "envoy-gateway" successfully rolled out` พร้อมกัน
> เพราะ deployment มาจาก install รอบก่อนที่สำเร็จไปแล้ว ส่วนรอบใหม่ตายตอนดึง chart
>
> **`helm status` เท่านั้นที่ตอบตรงคำถาม** — และอย่าใช้ `helm list -a` หรือ `--all`
> **helm 4 ตัด flag นี้ออกทั้งคู่** ใช้แล้วได้ `unknown flag`
>
> ถ้าได้ `failed` ให้ล้างก่อนลงใหม่ ตาม **ภาคผนวก** ท้ายบท

**ตรวจว่า CRD มาครบทั้งสองชุด และได้ช่องที่ตั้งใจ:**
```bash
echo -n "Gateway API      : "; kubectl get crd -o name | grep -c gateway.networking.k8s.io
echo -n "Envoy Gateway    : "; kubectl get crd -o name | grep -c gateway.envoyproxy.io
echo -n "channel          : "; kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/channel}{"\n"}'
echo -n "bundle-version   : "; kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

**ควรเห็น:** สองบรรทัดแรกมากกว่า `0` · `channel` เป็น **`experimental`**

`experimental` คือค่าที่ chart ลงมาให้ ไม่ใช่ตัวเลือก — **ถ้าได้ `standard` แปลว่ามี CRD ค้าง
จากรอบก่อนแล้ว helm ข้ามไป** ต้องล้างตามภาคผนวกท้ายบทแล้วลงใหม่

> `experimental` เป็น superset ของ `standard` — `Gateway`, `HTTPRoute`, `GRPCRoute`,
> `GatewayClass`, `ReferenceGrant` ที่บทนี้ใช้ทั้งหมดอยู่ในทั้งสองช่องเหมือนกัน
> **ผลลัพธ์จึงไม่ต่างกันเลย** ส่วนที่เกินมาคือ `TCPRoute`/`UDPRoute`/`TLSRoute` และ field
> ที่ยังทดลองอยู่ ซึ่งเราไม่ได้ใช้ — นอนอยู่เฉย ๆ ไม่กระทบอะไร
>
> ถ้าองค์กรมีนโยบายห้าม CRD ช่อง experimental บน production เป็นเรื่องที่ต้องเคาะ
> **ครั้งเดียวก่อนขึ้น production** ไม่ใช่ทุกครั้งที่ติดตั้ง — บันทึกไว้ที่
> [CHECKLIST หัวข้อ C2](CHECKLIST.md) แล้ว วิธีบังคับใช้ `standard` อยู่ในเอกสารทางการ
> หัวข้อ *Install CRDs separately*

**เอา `bundle-version` ที่ได้ไปแก้ `GATEWAY_API_VERSION` ใน `docs/versions.env`** ให้ตรงกับของจริง

---

### 🔴 ให้ Envoy รันทุก worker ก่อน — ไม่ใช่ pod เดียว

ค่าเริ่มต้นของ Envoy Gateway คือ **Envoy 1 pod** คู่กับ Service แบบ
**`externalTrafficPolicy: Local`** ซึ่งแปลว่า *node ที่รับ traffic ต้องมี pod ปลายทาง
อยู่บนเครื่องตัวเอง ห้ามส่งข้ามเครื่อง*

แต่ Cilium เลือก node ที่จะตอบ ARP ให้ LB IP จาก `nodeSelector` ใน
[l2-announcement-policy.yaml](../config/cilium/l2-announcement-policy.yaml) **เท่านั้น**
มันไม่ได้ดูว่า node นั้นมี Envoy อยู่หรือเปล่า — พอสองอย่างนี้ไม่ตรงกัน
node ที่ตอบ ARP จะรับ packet มาแล้วทิ้งทุกใบ

**ยืนยันบน cluster จริง 5 ก.ย. 2026:** Envoy อยู่ `worker02` · lease ตอบ ARP อยู่ `worker03`
ผลคือ `ADDRESS` ขึ้นครบ · HTTPRoute `Accepted=True` · `curl` จาก master01 ได้ `302`
**แต่เครื่องนอก cluster เข้าไม่ได้เลย** และไม่มี error โผล่ที่ไหนสักที่

`envoyproxy.yaml` สั่งให้ Envoy เป็น **DaemonSet** — node ไหนได้สิทธิ์ตอบ ARP
ก็มี Envoy อยู่กับตัวเสมอ ปัญหาหายทั้งคลาส ไม่ใช่แค่รอบนี้

> ทางเลือกอีกทางคือเปลี่ยนเป็น `externalTrafficPolicy: Cluster` ซึ่งแก้บรรทัดเดียว
> แต่ Envoy จะเห็น source IP เป็น IP ของ node ที่รับ ไม่ใช่ของผู้ใช้จริง
> → log ระบุตัวคนไม่ได้ และ NetworkPolicy ที่กรองตาม source ในบทที่ 10 ใช้ไม่ได้ตามที่ตั้งใจ

---
### สร้าง GatewayClass

chart **ไม่สร้าง GatewayClass ให้** — ในเอกสารทางการมันอยู่ใน `quickstart.yaml`
ซึ่งเรารับมาทั้งไฟล์ไม่ได้เพราะมี Gateway กับ HTTPRoute ของ demo ติดมาด้วย

```bash
kubectl apply -f /root/k8s/config/gateway/envoyproxy.yaml
kubectl apply -f /root/k8s/config/gateway/gatewayclass.yaml   && kubectl get gatewayclass
```

> ต่อด้วย `&&` เพื่อไม่ให้ `kubectl get` รันตอน `apply` ล้ม

**ควรเห็น:** `envoyproxy.gateway.envoyproxy.io/myhr-proxy created` · `gatewayclass.gateway.networking.k8s.io/eg created`
· แล้วตาราง: `eg` · `CONTROLLER` เป็น `gateway.envoyproxy.io/gatewayclass-controller` · `ACCEPTED=True`
(`ACCEPTED` อาจว่าง 2-3 วินาทีแรก รันบรรทัด `get` ซ้ำ)

| ถ้าได้ข้อความนี้แทน | แปลว่า |
|---|---|
| `No resources found` | CRD ลงแล้ว แต่ `apply` ไม่ได้สร้าง GatewayClass — ดู error ของ `apply` |
| `the server doesn't have a resource type` | **CRD ยังไม่ได้ลง** — ย้อนกลับไปต้นขั้นที่ 2 |

**ถ้า `ACCEPTED` ยังว่างหรือเป็น `False` เกิน 30 วินาที** — GatewayClass เป็นแค่ป้ายที่เขียนว่า
"ให้ controller ชื่อนี้มาดูแล" คนที่มาอ่านป้ายแล้วประทับ `True` คือ pod `envoy-gateway` จากข้อ 2
ไม่ถูกประทับมีแค่ 2 สาเหตุ ตรวจตามลำดับ:

**ก. ไม่มีใครมาอ่านป้าย — controller ยังไม่ทำงาน:**
```bash
kubectl -n envoy-gateway-system get pods
```
**ควรเห็น:** pod `envoy-gateway-...` เป็น `Running` `1/1` · ถ้าเป็น `ImagePullBackOff`/`CrashLoopBackOff`
ปัญหาอยู่ที่ข้อ 2 ไม่ใช่ที่ไฟล์นี้ — ดู `kubectl -n envoy-gateway-system logs deploy/envoy-gateway | tail -20`

**ข. controller ทำงานอยู่ แต่ชื่อบนป้ายไม่ใช่ชื่อมัน** — เทียบสองบรรทัดนี้ต้องเท่ากันเป๊ะ:
```bash
echo -n "ในไฟล์   : "; kubectl get gatewayclass eg -o jsonpath='{.spec.controllerName}{"\n"}'
echo -n "ใน chart : "; helm get values envoy-gateway -n envoy-gateway-system -a | grep -i controllerName
```
**ควรเห็น:** ทั้งคู่เป็น `gateway.envoyproxy.io/gatewayclass-controller` · ไม่เท่ากัน = มีคนแก้ค่าใดค่าหนึ่ง
ให้แก้ `controllerName` ใน `gatewayclass.yaml` ให้ตรงกับของ chart แล้ว `apply` ใหม่ (chart เป็นฝ่ายกำหนดชื่อ)

ถ้าทั้ง ก. และ ข. ปกติแต่ยังไม่ `True`: `kubectl describe gatewayclass eg | tail -15` — บรรทัด `Message` บอกเหตุผลตรง ๆ

> ขั้นนี้สร้าง namespace `envoy-gateway-system` ซึ่งขั้นที่ 3 ต้องใช้เก็บ Secret ของ cert
> จึงต้องทำก่อน ไม่ใช่หลัง

---

## 3 · ใส่ public cert

**ทำที่:** 3.1 จาก**เครื่องคุณ** (`scp` ขึ้น master01) · 3.2 บน 👑 master01
· **ต้องมีก่อน:** ข้อ 2 จบ (namespace `envoy-gateway-system` มีแล้ว — Secret ต้องอยู่ที่นั่น)
· ได้ไฟล์ cert `*.myhr.co.th` + private key จากทีมที่ดูแลโดเมนแล้ว (ไม่มี = หยุดรอ ทำข้อ 4 ต่อไม่ได้)

**ต้องมี Secret `myhr-public-tls` ให้เสร็จก่อนสร้าง Gateway** เพราะ listener HTTPS ที่อ้าง
Secret ที่ยังไม่มี จะค้างที่ `Programmed=False` แล้วขั้นที่ 4 จะตรวจไม่ผ่าน
โดยที่สาเหตุอยู่คนละที่กับที่กำลังมอง

**ผลที่ข้อนี้ต้องได้** — สองไฟล์นี้ที่ `/root/certs/` บน master01 แล้วกลายเป็น Secret ใน 3.2:

| ไฟล์ | คือ |
|---|---|
| `fullchain.pem` | cert ของเรา **ต่อด้วย** intermediate ทุกใบ — เรียง leaf ขึ้นก่อนเสมอ |
| `privkey.pem` | private key แบบ PEM **ไม่มี passphrase** |

---

### 3.1 · เอาไฟล์ขึ้น master01

ไฟล์ที่องค์กรมี (ตรวจของจริงแล้ว 4 ก.ย. 2026) **ใช้ได้เลย ไม่ต้องแปลง** — แค่ส่งขึ้นไปเป็นชื่อที่ 3.2 ใช้:

| ไฟล์ที่มี | ส่งขึ้นเป็น |
|---|---|
| `IntermediateBundle-CrossR3-R46.crt` (chain ครบ 3 ใบ leaf อยู่บน) | `fullchain.pem` |
| `privatekey.key` (ไม่มี passphrase) | `privkey.pem` |

อยู่ในโฟลเดอร์ `IntermediateBundle-CrossR3-R46/` ข้าง repo บนเครื่องที่ใช้ทำ (ไม่อยู่ใน git)

**จากเครื่องคุณ** — Git Bash ใช้ path `/d/...` · WSL ใช้ `/mnt/d/...`:
```bash
cd /d/workspace/k8s/IntermediateBundle-CrossR3-R46
ssh root@192.168.50.101 'mkdir -p /root/certs && chmod 700 /root/certs'
scp IntermediateBundle-CrossR3-R46.crt root@192.168.50.101:/root/certs/fullchain.pem
scp privatekey.key               root@192.168.50.101:/root/certs/privkey.pem
ssh root@192.168.50.101 'chmod 600 /root/certs/privkey.pem && ls -l /root/certs'
```
**ควรเห็น:** `100%` สองบรรทัด · แล้ว `ls` มี 2 ไฟล์ `privkey.pem` ขึ้นต้น `-rw-------`

→ **ไป 3.2** — สคริปต์ที่นั่นตรวจข้างในไฟล์ให้ทั้งหมด (chain ครบ · key คู่กับ cert · ยังไม่หมดอายุ · ชื่อครอบ)

> ได้ไฟล์หน้าตาอื่นมา (รอบต่ออายุ CA อาจส่งคนละแบบ) → **ภาคผนวก ค** ท้ายบท

---

### 3.2 · ตรวจแล้วเขียนลง cluster

**ตรวจก่อน — ยังไม่แตะ cluster:**
```bash
bash /root/k8s/config/gateway/import-public-cert.sh --dry-run \
     /root/certs/fullchain.pem /root/certs/privkey.pem
```

**ควรเห็น:** หัวข้อ 1-5 มี `ok` ทุกข้อ ไม่มี `FAIL` และปิดท้าย `ตรวจผ่านหมด (--dry-run จึงไม่ได้เขียน secret)`
— มี `FAIL` ข้อไหน ข้อความใต้บรรทัดนั้นบอกวิธีแก้ · แก้แล้วรัน `--dry-run` ซ้ำจนผ่าน

> **ทำไมไม่ใช้ `kubectl create secret tls` ตรง ๆ** — คำสั่งนั้นรับไฟล์อะไรก็ได้ที่หน้าตาเป็น PEM
> แล้วตอบ `created` ทั้งที่ chain ขาด intermediate, key ไม่ใช่คู่ของ cert, key ยังมี passphrase
> หรือ cert ไม่ครอบชื่อที่จะใช้จริง ทั้งสี่อย่างนี้เงียบตอนสร้าง แล้วไปโผล่ทีหลัง
> ในรูป "บางเครื่องเข้าได้ บางเครื่องไม่ได้" ซึ่งหาสาเหตุยากมาก สคริปต์นี้ตรวจทั้งสี่ข้อให้ก่อน

**ถ้าใช้ cert รายชื่อ ไม่ใช่ wildcard** ให้ระบุชื่อที่จะใช้จริงต่อท้าย เพื่อให้ตรวจครบทุกชื่อ:
```bash
bash /root/k8s/config/gateway/import-public-cert.sh --dry-run \
     /root/certs/fullchain.pem /root/certs/privkey.pem \
     hr.myhr.co.th api.myhr.co.th ads.myhr.co.th
```

**เขียน Secret จริง** (คำสั่งเดิม เอา `--dry-run` ออก):
```bash
bash /root/k8s/config/gateway/import-public-cert.sh \
     /root/certs/fullchain.pem /root/certs/privkey.pem

kubectl -n envoy-gateway-system get secret myhr-public-tls
```
**ควรเห็น:** `secret/myhr-public-tls created` ตามด้วย `เรียบร้อย  ต่อที่ขั้นที่ 4` · แล้วตาราง `TYPE = kubernetes.io/tls` และ `DATA = 2`

> **มี public cert หลายใบแยกตามชื่อ service?** รันซ้ำได้ ใส่ `--secret <ชื่อ>` ให้แต่ละใบ
> แล้วเติมชื่อ Secret เข้าไปใน `certificateRefs` ตอนขั้นที่ 4.1:
> ```
> bash .../import-public-cert.sh --secret hr-myhr-tls hr-chain.pem hr.key hr.myhr.co.th
> ```

> 🔐 **อย่า commit `privkey.pem` ลงrepo** — `config/` ถูก track ใน git อยู่
> เก็บไฟล์ไว้ที่ `/root/certs/` (chmod 700) หรือใน password manager ขององค์กรเท่านั้น
>
> 📅 **ต่ออายุปีหน้า:** เอาไฟล์ชุดใหม่มาวางทับ แล้วรันคำสั่งเดิมซ้ำ สคริปต์ใช้ `apply`
> จึงเขียนทับได้เลยไม่ต้องลบก่อน และ Envoy Gateway โหลด cert ใหม่ให้เองในไม่กี่วินาที
> **ไม่ต้อง restart อะไร** — รายละเอียดรอบตรวจรายเดือนอยู่ที่ [บท 12 หัวข้อ 3.1](12-day2-operations.md)

---

## 4 · สร้าง Gateway

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 2 (GatewayClass `eg` ACCEPTED) · ข้อ 3 (Secret `myhr-public-tls` มีแล้ว)
· pool ของ[บท 05 ข้อ 6](05-cilium.md) มี IP ว่าง (`kubectl get ciliumloadbalancerippool` — `AVAILABLE` ไม่เป็น 0)

```bash
kubectl apply -f /root/k8s/config/gateway/gateway.yaml
```
**ควรเห็น:** `gateway.gateway.networking.k8s.io/myhr-gateway created`

listener HTTPS ในไฟล์ชี้ไปที่ Secret `myhr-public-tls` ที่สร้างไว้ตอนขั้นที่ 3

**รอให้พร้อมก่อน อย่าเพิ่งเช็ค** — `apply` เสร็จไม่ได้แปลว่าใช้งานได้:
```bash
kubectl -n envoy-gateway-system wait --for=condition=Programmed   gateway/myhr-gateway --timeout=5m
```
**ควรเห็น:** `gateway.gateway.networking.k8s.io/myhr-gateway condition met` (ครั้งแรก 1-3 นาที)

> 🔴 **`PROGRAMMED=False` ทันทีหลัง apply เป็นเรื่องปกติ ไม่ใช่ปัญหา**
> Envoy Gateway ต้องไปสร้าง Deployment ของ Envoy proxy กับ Service `type: LoadBalancer`
> ก่อน แล้วรอ pod พร้อม กว่าจะครบใช้เวลาหลายสิบวินาที **ครั้งแรกนานกว่านั้นมาก
> เพราะต้องดึง image ลง worker ด้วย**
>
> ถ้าไม่รอแล้วรีบ `get` จะเห็น `False` แล้วเข้าใจผิดว่าพัง ซึ่งเสียเวลาไล่ของที่ไม่ได้เสีย
> — `kubectl wait` คืนค่าเมื่อพร้อมจริง หรือ error ตอนครบ 5 นาที ซึ่งตอนนั้นค่อยไล่หาสาเหตุ

```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway
```

**ควรเห็น:** `PROGRAMMED=True` และคอลัมน์ `ADDRESS` เป็น IP จาก pool เช่น `192.168.50.200`

**ถ้า `kubectl wait` หมดเวลา 5 นาที** ค่อยไล่ตามนี้ — `describe` บอก `Reason` ตรง ๆ
ไม่ต้องเดาจากอาการ:
```bash
kubectl -n envoy-gateway-system describe gateway myhr-gateway | sed -n '/^Status:/,$p'
kubectl -n envoy-gateway-system get pods -o wide
```

| `Reason` ที่เห็น | มักแปลว่า |
|---|---|
| `AddressNotAssigned` | Service ยังไม่ได้ IP → Cilium LB-IPAM ([บท 05](05-cilium.md)) |
| `InvalidCertificateRef` / `NoValidListeners` | Secret `myhr-public-tls` ไม่มี ผิด namespace หรือไม่ใช่ `type: kubernetes.io/tls` |
| proxy pod ไม่ `Running` (`ImagePullBackOff`) | worker ดึง image ไม่ได้ — ปิด IPv6 ให้ครบทุกเครื่อง ([บท 01 ข้อ 1.2](01-prepare-os.md)) |
| GatewayClass ไม่ถูกรับ | `gatewayClassName: eg` ไม่ตรงกับ GatewayClass ที่มี — ย้อนไปท้ายขั้นที่ 2 |

**ตรวจ listener ทีละตัว** — คอลัมน์ `PROGRAMMED` ข้างบนเป็นสถานะรวม
listener ตัวเดียวพังแล้วอีกตัวยังใช้ได้ ซึ่งมองจากตารางไม่เห็น:
```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{":"}{range .conditions[*]}{" "}{.type}={.status}{end}{"\n"}{end}'
```
**ควรเห็น:** ทั้ง `http` และ `https` เป็น `Accepted=True Programmed=True ResolvedRefs=True`

ถ้า `https` ขึ้น `ResolvedRefs=False` แปลว่า Secret ที่อ้างถึงไม่มี ผิด namespace
หรือไม่ใช่ `type: kubernetes.io/tls` — กลับไปขั้นที่ 3

> Envoy Gateway จะสร้าง Service `type: LoadBalancer` ให้อัตโนมัติ
> ซึ่ง Cilium LB-IPAM จะจ่าย IP ให้ — **นี่คือ IP เดียวที่กินจาก pool ทั้ง 10 ตัว**

**ถ้า `ADDRESS` ว่าง — ไล่ตามลำดับนี้:**
```bash
kubectl get gatewayclass
kubectl -n envoy-gateway-system get svc
kubectl get ciliumloadbalancerippool default-pool -o yaml | grep -A5 status
```

| ที่เจอ | แปลว่า |
|---|---|
| ไม่มี GatewayClass `eg` | **ไม่มี controller ตัวไหนรับ Gateway ตัวนี้ไปทำ** — Gateway จะ apply ผ่านโดยไม่มี error แต่ `ADDRESS` ว่างตลอดไป ย้อนไปทำท้ายขั้นที่ 2 |
| มี GatewayClass แต่ไม่มี Service `type: LoadBalancer` | Envoy Gateway ยังไม่ได้ reconcile — ดู log ของ `deploy/envoy-gateway` |
| มี Service แต่ `EXTERNAL-IP` ค้าง `<pending>` | pool หมดหรือ LB-IPAM มีปัญหา — กลับไปดูบทที่ 05 |

**ตรวจว่า Envoy กระจายครบทุก worker** — ตรงนี้ Envoy ถึงจะถูกสร้างจริง:
```bash
kubectl -n envoy-gateway-system get ds,pod -o wide -l app.kubernetes.io/name=envoy
```
**ควรเห็น:** DaemonSet `DESIRED=3 READY=3` และ pod อยู่คนละ worker กันทั้งสามตัว

**ถ้าได้ Deployment แทน DaemonSet** แปลว่า `parametersRef` ใน `gatewayclass.yaml`
ไม่ได้ชี้มาที่ `EnvoyProxy` — ตรวจด้วย:
```bash
kubectl get gatewayclass eg -o jsonpath='{.spec.parametersRef}{"\n"}'
```
**ควรเห็น:** JSON ที่มี `"name":"myhr-proxy"` — ถ้าว่าง แปลว่า `EnvoyProxy` ถูกลงไว้เฉย ๆ
โดยไม่มีใครใช้ ซึ่ง**ไม่มี error ให้เห็น**

---

**จด IP ที่ได้ไว้** — ขั้นถัดไปต้องใช้บนเครื่องทดสอบซึ่งไม่มี kubectl:
```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway \
  -o jsonpath='{.status.addresses[0].value}{"\n"}'
```
**ควรเห็น:** IP บรรทัดเดียว เช่น `192.168.50.200` — ตัวนี้คือ `GW_IP` ของข้อ 5

---

## 5 · ทดสอบด้วย HTTPRoute จริง

**ทำที่:** ครึ่งแรก (สร้างของทดสอบ + ตรวจ route) บน 👑 master01 · ครึ่งหลัง (`curl`) บน**เครื่องทดสอบในวง LAN**
— มีเส้นแบ่งบอกไว้ · **ต้องมีก่อน:** ข้อ 4 `PROGRAMMED=True` และจด IP มาแล้ว

**บน master01 — สร้าง service ทดสอบ:**
```bash
kubectl create ns demo
kubectl -n demo create deployment echo --image=nginx:alpine --replicas=2
kubectl -n demo rollout status deploy/echo --timeout=2m
kubectl -n demo expose deployment echo --port=80

kubectl apply -f /root/k8s/config/gateway/httproute-example.yaml
```
**ควรเห็น:** `namespace/demo created` · `deployment "echo" successfully rolled out` · `service/echo exposed`
· `httproute.gateway.networking.k8s.io/echo-route created`

**ตรวจว่า route ผูกติดจริง:**
```bash
kubectl -n demo get httproute echo-route \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
```
**ควรเห็น:** `Accepted=True` และ `ResolvedRefs=True`

> `kubectl get httproute` เฉย ๆ ไม่มีคอลัมน์สถานะ — มีแค่ `HOSTNAMES` กับ `AGE`
> route ที่ผูกไม่ติดกับ Gateway หรือชี้ไป Service ที่พิมพ์ผิด จะหน้าตาเหมือนกันเป๊ะ
> `ResolvedRefs=False` คือตัวที่จับ backend ผิดชื่อได้ ซึ่งเป็นสาเหตุอันดับหนึ่งของ 404

---

### ⬇️ ตั้งแต่ตรงนี้ลงไป — ย้ายไปรันบนเครื่องทดสอบ

**ต้องเป็นเครื่องที่อยู่ในวง `192.168.50.0/24` และไม่ใช่ node ของ cluster**

| รันจาก | พิสูจน์อะไร |
|---|---|
| **เครื่องในวงเดียวกับ LB pool ที่ไม่ใช่ node** ✅ | **ทั้งเส้น** — ARP / L2 announcement · LB IP · Envoy · HTTPRoute · cert |
| node ของ cluster (เช่น master01) | route กับ cert เท่านั้น · **ข้าม ARP ทั้งหมด** |
| เครื่องที่อยู่วงอื่น | ไม่ได้ — timeout |

> 🔴 **ยิงจาก node แล้วผ่าน ไม่ได้แปลว่าผู้ใช้จริงเข้าได้** — Cilium จัดการ LB IP ให้ในเครื่องเอง
> traffic ไม่เคยออกไปที่สาย ถ้า switch เปิด Dynamic ARP Inspection ขวางอยู่ จะไม่รู้เลย
> จนกว่าจะมีคนนอกลองเปิด ซึ่งมักเป็นวันส่งมอบ
>
> เครื่องทดสอบตัวนี้เป็นข้อบังคับตั้งแต่ [บทที่ 00](00-overview.md) และใช้ยืนยัน
> L2 announcement มาแล้วที่ [บทที่ 05](05-cilium.md) — ถ้ายังไม่มี หยุดแล้วไปหาให้ได้ก่อน

**ตั้งค่า IP ที่จดมาจากขั้นที่ 4:**
```bash
GW_IP=192.168.50.200
```

**host ถูก ต้องได้ 200:**
```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
     --resolve "echo.myhr.co.th:443:${GW_IP}" https://echo.myhr.co.th
```

**host ที่ไม่มี route ต้องได้ 404:**
```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
     --resolve "nope.myhr.co.th:443:${GW_IP}" https://nope.myhr.co.th
```

> `echo.myhr.co.th` ต้องเป็นชื่อที่ **cert ใบใดใบหนึ่งครอบอยู่** ถ้าไม่ครอบจะตายที่ TLS
> ก่อนถึงเรื่อง routing — เปลี่ยนไปใช้ชื่อที่ครอบ หรือเติม `-k` ถ้าจะตรวจแค่ routing
>
> ถ้าใช้ cert จาก **internal CA** ต้องเพิ่ม `--cacert /root/k8s/myhr-root-ca.crt`
> (หรือลง root CA ที่เครื่องทดสอบก่อน) — cert จาก **public CA** ไม่ต้อง

**ดูว่า cert ที่เสิร์ฟออกมาเป็นใบที่ตั้งใจจริง** ไม่ใช่แค่ "เข้าได้":
```bash
curl -sS -v -o /dev/null --resolve "echo.myhr.co.th:443:${GW_IP}" \
     https://echo.myhr.co.th 2>&1 | grep -E 'subject:|issuer:|expire'
```
**ควรเห็น:** `issuer` เป็น `GlobalSign GCC R46 AlphaSSL CA 2025` และ `expire date` ตรงกับใบที่ใส่ไป

> `x509: certificate signed by unknown authority` → ยังไม่ได้ลง root CA ที่เครื่องนั้น
> `certificate is valid for ... not echo.myhr.co.th` → ชื่อใน cert ไม่ครอบ host ที่เรียก
> `connection refused` / timeout → ยังไม่ถึง Envoy เลย กลับไปดูเรื่อง ARP ที่บทที่ 05

---

## 6 · บังคับ HTTPS

**ทำที่:** `apply` และเก็บกวาดบน 👑 master01 · `curl` ตรวจบน**เครื่องทดสอบ**เครื่องเดิม (`GW_IP` ยังตั้งอยู่)
· **ต้องมีก่อน:** ข้อ 5 ได้ 200/404 ตามที่ควร

ตอนนี้ listener HTTP ยังไม่มี route ผูกอยู่เลย ทุก request ที่เข้าทาง port 80 จึงได้ 404
ขั้นนี้เปลี่ยนให้เป็น redirect แทน

```bash
kubectl apply -f /root/k8s/config/gateway/https-redirect.yaml
```
**ควรเห็น:** `httproute.gateway.networking.k8s.io/https-redirect created` · ทำครั้งเดียวใช้กับทุก hostname — ไม่ต้องทำซ้ำต่อ service

**ตรวจจากเครื่องทดสอบ:**
```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
     -H 'Host: echo.myhr.co.th' "http://${GW_IP}"
```
**ควรเห็น:** `301 https://echo.myhr.co.th/`

**เก็บกวาดบน master01** — ลบเฉพาะของทดสอบ Gateway และ redirect อยู่ต่อ:
```bash
kubectl delete ns demo
```
**ควรเห็น:** `namespace "demo" deleted` (รอ ~10 วินาที)

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] Gateway API CRD มาจาก chart — ช่อง `experimental` ไม่ใช่ `standard`
      ตรวจ: `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations}'`
- [ ] GatewayClass `eg` **ACCEPTED=True**
- [ ] Gateway `myhr-gateway` **PROGRAMMED=True** และมี `ADDRESS`
- [ ] listener ทั้ง `http` และ `https` เป็น `Programmed=True ResolvedRefs=True`
- [ ] HTTPRoute ทดสอบขึ้น `Accepted=True ResolvedRefs=True`
- [ ] host ถูกได้ 200 · host ที่ไม่มี route ได้ 404 (ยิงจากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node)
- [ ] HTTPS ผ่านโดยไม่มี cert warning และ `issuer` เป็น GlobalSign ตามใบที่ใส่ไป
- [ ] HTTP redirect ไป HTTPS (301)
- [ ] ลบ namespace `demo` แล้ว

- [ ] Secret `myhr-public-tls` เป็น `type: kubernetes.io/tls`
- [ ] `privkey.pem` **ไม่ได้อยู่ในrepo** และไฟล์ที่ `/root/certs/` เป็น chmod 600
- [ ] **จดวันหมดอายุ `11 มี.ค. 2027` ลงปฏิทินทีมแล้ว** ตั้งเตือน 9 ก.พ. 2027
      — ใบนี้ไม่ต่ออายุเอง ลืมแล้วทุก service ล่มพร้อมกันโดยที่ pod ยังเขียวหมด

> **จด IP ที่ Gateway ได้ไปลง DNS** — ต้องให้ทีม network ทำ record ชี้
> `*.myhr.co.th` (หรือรายตัว) มาที่ IP นี้ ไม่งั้นต้องใช้ `--resolve` ตลอดไป
> public cert ใช้กับ IP วงในได้ปกติ เพราะ TLS ตรวจที่ชื่อ ไม่ใช่ที่ IP



---

## ภาคผนวก ก · เริ่มบทนี้ใหม่ทั้งบท

ใช้เมื่อ install ค้างสถานะ `failed` · CRD ได้ช่องผิด · หรือจะรื้อทำใหม่ให้สะอาด

**ไม่แตะของจากบท 01-06 เลย** — Cilium, LB IP pool, L2 announcement policy, node,
etcd, control plane, `/etc/hosts`, resolver option ทั้งหมดอยู่ครบ

### 1 · ดูก่อนว่าจะลบอะไร (ยังไม่ลบ)

```bash
echo "=== helm release ==="
helm list -A | grep -Ei 'envoy|gateway|cert-manager' || echo "  ไม่มี"

echo "=== namespace ==="
for n in envoy-gateway-system cert-manager demo; do
  kubectl get ns "$n" >/dev/null 2>&1 && echo "  มี $n" || echo "  ไม่มี $n"
done

echo "=== CRD ==="
kubectl get crd -o name | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io|cert-manager\.io' || echo "  ไม่มี"

echo "=== object ที่จะหายไปด้วย (ต้องว่าง) ==="
kubectl get gatewayclass 2>/dev/null
kubectl get gateways,httproutes,grpcroutes -A 2>/dev/null
kubectl get clusterissuer,certificate -A 2>/dev/null
```

**ถ้าท่อนสุดท้ายมี object ที่คุณไม่ได้สร้างเอง — หยุด** อย่าเพิ่งลบ

### 2 · ลบ — เรียงลำดับนี้เท่านั้น

```bash
for r in envoy-gateway eg; do
  helm uninstall "$r" -n envoy-gateway-system 2>/dev/null && echo "ถอน $r แล้ว"
done
helm uninstall cert-manager -n cert-manager 2>/dev/null && echo "ถอน cert-manager แล้ว"
```

```bash
kubectl delete gatewayclass eg --ignore-not-found
```

```bash
kubectl get crd -o name   | grep -E 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io|cert-manager\.io'   | xargs -r kubectl delete --ignore-not-found
```

```bash
kubectl delete ns envoy-gateway-system cert-manager demo --ignore-not-found --timeout=180s
```

> 🔴 **ลำดับสำคัญ — CRD ต้องมาก่อน namespace**
> ถ้าลบ namespace ก่อนทั้งที่ยังมี Certificate หรือ Gateway ค้างอยู่ข้างใน
> namespace จะติด `Terminating` ค้าง เพราะ webhook ของ cert-manager ถูกลบไปแล้ว
> แต่ finalizer ยังรอคำตอบจากมันอยู่ ลบ CRD ก่อนตัดปัญหานี้ทิ้งเลย

### 3 · ยืนยันว่าสะอาด

```bash
echo -n "CRD ค้าง       : "; kubectl get crd -o name | grep -cE 'gateway\.networking\.k8s\.io|gateway\.envoyproxy\.io|cert-manager\.io'
echo -n "release ค้าง   : "; helm list -A | grep -ciE 'envoy|gateway|cert-manager'
echo -n "namespace ค้าง : "; kubectl get ns -o name | grep -cE 'envoy-gateway-system|cert-manager|demo'
```

**ต้องได้ `0` ทั้งสามบรรทัด** แล้วกลับไปเริ่มที่ขั้นที่ 1

> **ไฟล์ cert ที่ `/root/certs/` ไม่ถูกลบ** — ตั้งใจให้เป็นแบบนั้น จะได้ไม่ต้องไปขอจาก CA ใหม่
> ตอนทำขั้นที่ 3 รอบหน้า รันสคริปต์เดิมซ้ำได้เลย

---

## ภาคผนวก ข · ถ้าวันหนึ่งต้องใช้ internal CA

> **โครงการนี้ไม่ได้ใช้** — public cert wildcard ครอบทุกชื่ออยู่แล้ว
> ภาคผนวกนี้เก็บไว้เผื่อวันที่ต้องเปิด service ด้วยชื่อที่ public cert ไม่ครอบ
> เช่นชื่อภายในที่จดโดเมนจริงไม่ได้ · **ทำเพิ่มทีหลังได้ ไม่ต้องรื้อของเดิม**

ผลลัพธ์คือ Secret `myhr-internal-tls` ซึ่งเป็นคนละใบกับ `myhr-public-tls`
จึงอยู่ร่วมกันบน listener เดียวได้ — Envoy เลือกใบที่จะเสิร์ฟจาก SNI

> 🔴 **กติกาข้อเดียว: ชื่อในสองใบต้องไม่ทับกัน**
> ถ้ามีสองใบครอบชื่อเดียวกัน Envoy จะเลือกใบไหนก็ได้ อาการคือผู้ใช้บางคนบางเวลา
> เจอ cert warning แล้ว refresh ก็หาย ไม่ผูกกับเครื่อง ไม่ผูกกับเวลา ไม่มี error ที่ไหนเลย
> และ Gateway ยัง `Programmed=True` ครบ — มีตัวตรวจให้ที่ข้อ ข.3

---

### ข.1 · ออก cert จาก internal CA

> 📖 **แหล่งอ้างอิง:** [Installing with Helm — cert-manager](https://cert-manager.io/docs/installation/helm/)
> เอกสารเปลี่ยนมาใช้ OCI จาก `quay.io` เป็นทางหลักแล้ว ส่วน `helm repo add jetstack`
> ยังใช้ได้แต่ถูกจัดเป็น *legacy repository installation* บทนี้จึงใช้แบบ OCI

**ติดตั้ง cert-manager:**
```bash
set -a && source /root/k8s/versions.env && set +a

helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "v${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set replicaCount=2 \
  --set webhook.replicaCount=2 \
  --set cainjector.replicaCount=2

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=3m
helm status cert-manager -n cert-manager | head -6
kubectl -n cert-manager get pods
```

**ค่าที่เพิ่มจากตัวอย่างในเอกสาร:** `replicaCount` ทั้งสามตัว — เหตุผลอยู่ในกล่องข้างล่าง
ส่วน `--set crds.enabled=true` เป็นค่าที่เอกสารระบุไว้เอง (ไม่ใช่ `installCRDs` ซึ่งเป็นชื่อเก่า)

**ควรเห็น:** 3 deployment (`cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector`) `Running` อย่างละ 2 pod

> **`replicaCount=2` ไม่ใช่ของแถม** — เราต้อง drain node ทุก 1-2 เดือน
> ถ้า webhook เหลือ pod เดียวแล้ว node นั้นถูก drain การสร้าง Certificate ทุกอันจะค้าง

**เพิ่ม PDB:**
```bash
kubectl apply -f /root/k8s/config/cert-manager/pdb.yaml
kubectl -n cert-manager get pdb
```

**สร้าง internal CA:**
```bash
kubectl apply -f /root/k8s/config/cert-manager/internal-ca.yaml

kubectl -n cert-manager get certificate myhr-internal-ca
kubectl get clusterissuer myhr-internal-ca-issuer
```
**ควรเห็น:** Certificate `READY=True` และ ClusterIssuer `READY=True`

**⚠️ ก่อน apply ข้อถัดไป — ตรวจชื่อใน [`internal-cert.yaml`](../config/cert-manager/internal-cert.yaml) ก่อน**

ไฟล์นี้ตั้งค่าเริ่มต้นเป็น `*.ops.myhr.co.th` ซึ่งเป็นค่าที่ทับกับ public cert ไม่ได้ไม่ว่ากรณีไหน

- **ถ้าเลิกใช้ public cert ไปเลย** — เปลี่ยนเป็น `*.myhr.co.th` + `myhr.co.th` ได้
- **ถ้าใช้คู่กับ public cert** — ต้องเป็นชื่อที่ public cert **ไม่ครอบ** ซึ่ง cert ของเราเป็น wildcard
  `*.myhr.co.th` ก็ต้องอยู่คนละชั้นแบบค่าเริ่มต้น ถ้า public cert เป็นรายชื่อ จะใส่ชื่อ
  ฝั่ง ops ตรง ๆ ก็ได้ · **ถ้าย้ายชื่อ service ไปใต้ `.ops.` ต้องแก้ hostname ใน HTTPRoute
  ของ service นั้นด้วย** เช่น [`grafana-route.yaml`](../config/monitoring/grafana-route.yaml)

**ออก cert:**
```bash
kubectl apply -f /root/k8s/config/cert-manager/internal-cert.yaml

kubectl -n envoy-gateway-system get certificate myhr-internal-tls
kubectl -n envoy-gateway-system get secret myhr-internal-tls
```
**ควรเห็น:** Certificate `READY=True` และมี Secret `TYPE = kubernetes.io/tls`

**ถ้า `READY` ค้างที่ `False` เกินหนึ่งนาที:**
```bash
kubectl -n envoy-gateway-system describe certificate myhr-internal-tls | tail -20
```

> **ทำไมเขียนเป็นไฟล์ Certificate แทนที่จะติด annotation ไว้ที่ Gateway** — cert-manager
> อ่าน annotation `cert-manager.io/cluster-issuer` บน Gateway ได้ก็ต่อเมื่อติดตั้งด้วย
> `--set config.enableGatewayAPI=true` เท่านั้น ถ้าลืมเปิด: apply Gateway ผ่าน ไม่มี error
> ไม่มี event ไม่มี Certificate แล้ว listener HTTPS ค้างโดยไม่มีอะไรชี้สาเหตุ
> เขียนแยกเป็น Certificate ยังทำให้คุมชื่อ Secret ได้เอง จึงอยู่ร่วมกับ public cert ได้

**ดึง root CA ออกมาแจกให้เครื่อง client:**
```bash
kubectl -n cert-manager get secret myhr-internal-ca-key-pair \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /root/k8s/myhr-root-ca.crt

openssl x509 -in /root/k8s/myhr-root-ca.crt -noout -subject -dates
```
**ควรเห็น:** subject เป็น `CN=MyHR Internal CA` และหมดอายุอีก ~10 ปี

> 📋 **งานที่ต้องทำต่อ (ไม่ใช่งานของ cluster):** เอา `myhr-root-ca.crt` ไปลงเป็น trusted root
> บนเครื่อง client — ทำผ่าน GPO หรือ MDM ที่องค์กรใช้อยู่
> **ลงเฉพาะเครื่องที่จะเปิดชื่อฝั่งภายในก็พอ** ไม่ต้องไล่ทุกเครื่องในองค์กร
> เพราะชื่อที่ผู้ใช้ทั่วไปเปิดยังใช้ public cert เหมือนเดิม
> ถ้าข้ามข้อนี้ คนจะเจอ cert warning แล้วเริ่มกด "ผ่าน ๆ ไป" ซึ่งอันตรายกว่าไม่มี TLS

---


---

### ข.2 · ผูก cert เข้ากับ listener

**ถ้าเลิกใช้ public cert ไปเลย** — เปลี่ยนไปใช้ internal cert อย่างเดียว:
```bash
kubectl -n envoy-gateway-system patch gateway myhr-gateway --type=json -p='[
  {"op":"test","path":"/spec/listeners/1/name","value":"https"},
  {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs",
   "value":[{"kind":"Secret","name":"myhr-internal-tls"}]}
]'
```

**ถ้าใช้คู่กับ public cert** (กรณีปกติของภาคผนวกนี้) — ใส่ทั้งสองใบ:
```bash
kubectl -n envoy-gateway-system patch gateway myhr-gateway --type=json -p='[
  {"op":"test","path":"/spec/listeners/1/name","value":"https"},
  {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs",
   "value":[{"kind":"Secret","name":"myhr-public-tls"},
            {"kind":"Secret","name":"myhr-internal-tls"}]}
]'
```

> `{"op":"test"}` ข้างหน้าไม่ใช่ของประดับ — JSON Patch ทำงานแบบทั้งหมดหรือไม่ทำเลย
> ถ้าวันหนึ่งมีคนสลับลำดับ listener ใน `gateway.yaml` ข้อ `test` จะไม่ผ่าน
> แล้วทั้ง patch ถูกปฏิเสธพร้อมข้อความ แทนที่จะไปเขียนทับ cert ของ listener ผิดตัวเงียบ ๆ
>
> ทั้งสองคำสั่งใช้ `replace` จึงรันซ้ำได้ ไม่สะสมค่าเดิม

---

### ข.3 · ตรวจว่าชื่อใน cert ไม่ทับกัน

```bash
bash /root/k8s/config/gateway/check-cert-overlap.sh
```
**ควรเห็น:** `ผ่าน — ไม่มีชื่อไหนอยู่ในสองใบพร้อมกัน`

ถ้าไม่ผ่าน สคริปต์จะบอกว่าชื่อไหนซ้ำและซ้ำกับใบไหน — แก้ `dnsNames` ใน
`internal-cert.yaml` แล้ว `kubectl apply` ใหม่ cert-manager จะออกใบใหม่ให้เอง

> รันซ้ำทุกครั้งที่ **ต่ออายุ** หรือ **เพิ่มชื่อ** เข้าไปในใบใดใบหนึ่ง — cert ใบใหม่
> ที่ CA ใส่ SAN เพิ่มมาให้โดยไม่ได้ขอ ก็ทำให้ทับกันได้โดยไม่มีใครรู้

---


---

**➡️ ต่อที่ [บทที่ 08 — Storage](08-storage.md)**

---

## ภาคผนวก ค · ถ้ารอบต่ออายุได้ไฟล์ cert หน้าตาอื่น

ข้อ 3.1 ใช้กับไฟล์ชุดที่องค์กรมีอยู่ตอนนี้ · CA อาจส่งรอบหน้ามาคนละรูปแบบ (P7B · DER · PFX · key มี passphrase)
ภาคผนวกนี้แปลงให้เป็น `fullchain.pem` + `privkey.pem` แล้วกลับไปทำ 3.2 ต่อ

ทุกคำสั่งทำบน master01 ใน `/root/certs` (`cd /root/certs` ก่อน) · ชื่อไฟล์ในตัวอย่างเป็นชื่อสมมติ
เปลี่ยนเป็นชื่อที่ได้มาจริง

**ดูก่อนว่าได้อะไรมา** — นามสกุลไฟล์เชื่อไม่ได้ CA ตั้งชื่อกันคนละแบบ
`.crt` อาจเป็น fullchain ทั้งชุดอยู่แล้ว หรืออาจเป็น leaf ใบเดียว หรือเป็นไบนารีก็ได้:

```bash
for f in /root/certs/*; do
  printf '%-34s ' "$(basename "$f")"
  first=$(head -1 "$f" 2>/dev/null | tr -d '\0')   # tr กัน warning ตอนเจอไฟล์ไบนารี
  case "$first" in
    *"BEGIN CERTIFICATE"*) printf '%-36s cert %s ใบ
' "$first" "$(grep -c 'BEGIN CERTIFICATE' "$f")" ;;
    *"-----BEGIN"*)        printf '%s
' "$first" ;;
    *)                     echo "ไบนารี — น่าจะเป็น DER, PFX หรือ P7B แบบ DER" ;;
  esac
done
```

| ที่เห็นบรรทัดแรก | คือ | ไปที่ |
|---|---|---|
| `BEGIN CERTIFICATE` + **cert 2 ใบขึ้นไป** | fullchain พร้อมใช้แล้ว | **ไม่ต้องแปลง** เปลี่ยนชื่อเป็น `fullchain.pem` |
| `BEGIN CERTIFICATE` + **cert 1 ใบ** | leaf ล้วน ยังขาด intermediate | ก. ต่อ chain |
| `BEGIN PKCS7` | บันเดิลแบบ PKCS#7 | ข. แปลง P7B |
| `ไบนารี` | DER หรือ PFX | ค. / ง. |
| `BEGIN ENCRYPTED PRIVATE KEY` | key มี passphrase | จ. ถอด passphrase |
| `BEGIN RSA PRIVATE KEY` / `BEGIN EC PRIVATE KEY` | key แบบเก่า (PKCS#1) | ใช้ได้เลย · หรือ จ. เพื่อแปลงเป็น PKCS#8 |

---

**ก. CA ส่งมาเป็นไฟล์แยก** (`cert.pem` + `intermediate.pem` / `ca-bundle.crt`) — **leaf ขึ้นก่อนเสมอ**
```bash
cat cert.pem intermediate.pem > /root/certs/fullchain.pem
```

**ข. บันเดิล PKCS#7** (`.p7b` / `.p7c` / `.spc`)
```bash
openssl pkcs7 -print_certs -in bundle.p7b   | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /root/certs/fullchain.pem
```

**ถ้าไฟล์ p7b เป็นไบนารี** (บรรทัดแรกอ่านไม่ออก) ให้เติม `-inform DER`:
```bash
openssl pkcs7 -print_certs -inform DER -in bundle.p7b   | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > /root/certs/fullchain.pem
```
> `sed` ตัดบรรทัด `subject=` / `issuer=` ที่ `-print_certs` แถมมาออก เหลือเฉพาะ PEM
> · ตรวจผลด้วย `grep -c 'BEGIN CERTIFICATE' /root/certs/fullchain.pem` ต้องได้ 2 ขึ้นไป

**ค. cert เดี่ยวแบบ DER** (`.der` / `.cer` ที่เปิดแล้วเป็นไบนารี)
```bash
openssl x509 -inform DER -in cert.der -out /tmp/leaf.pem
```
แล้วต่อ chain ตามข้อ ก.

**ง. `.pfx` / `.p12`** — ได้ทั้ง cert และ key ในไฟล์เดียว (จะถาม password ที่ CA ให้มา)
```bash
openssl pkcs12 -in myhr.pfx -clcerts -nokeys        -out /tmp/leaf.pem
openssl pkcs12 -in myhr.pfx -cacerts -nokeys -chain -out /tmp/chain.pem
openssl pkcs12 -in myhr.pfx -nocerts -nodes         -out /root/certs/privkey.pem
cat /tmp/leaf.pem /tmp/chain.pem > /root/certs/fullchain.pem
rm -f /tmp/leaf.pem /tmp/chain.pem
```

**จ. key มี passphrase หรือเป็นรูปแบบเก่า** (จะถาม passphrase ถ้ามี)
```bash
openssl pkey -in privkey-เดิม.pem -out /root/certs/privkey.pem
```
> Envoy อ่าน key ที่มี passphrase ไม่ออก และ `kubectl create secret` ก็ไม่ฟ้อง —
> secret สร้างได้ปกติ แล้วไปตายตอน listener โหลด cert

**ปิดท้ายทุกทาง — ตั้งสิทธิ์ไฟล์ แล้วกลับไปข้อ 3.2:**
```bash
chmod 600 /root/certs/privkey.pem
ls -l /root/certs
```
**ควรเห็น:** มี `fullchain.pem` และ `privkey.pem` ทั้งคู่ขนาดไม่เป็น 0 · บรรทัด `privkey.pem` ขึ้นต้น `-rw-------`

> **chain เรียงผิดลำดับ?** (บาง CA ส่ง root ขึ้นก่อน) สคริปต์ตรวจข้างล่างจะจับได้ที่ข้อ 2
> เพราะมันถือว่าใบแรกคือ leaf แล้ว key จะไม่ตรงกัน · ดูลำดับจริงด้วย:
> ```
> openssl crl2pkcs7 -nocrl -certfile /root/certs/fullchain.pem | openssl pkcs7 -print_certs -noout
> ```
> ใบที่ `subject` เป็นชื่อโดเมนของเรา (ไม่ใช่ชื่อ CA) ต้องอยู่บนสุด — ถ้าไม่ใช่ ให้ `cat` เรียงใหม่
