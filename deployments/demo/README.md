# demo — ผูก auth ไว้ที่ Gateway แทนที่จะเขียนใน app

> **รันที่: 👑 master01 หรือเครื่องที่มี kubeconfig**
> **ผู้อ่าน: dev ที่กำลังจะเอา service ขึ้น cluster ใหม่**
> **ทั้งสอง demo deploy จริงและทดสอบผ่านแล้วบน `myhr-uat`**

สอง service ในโฟลเดอร์นี้เป็น **web app ธรรมดาที่ตอบ 200** เหมือนกันเป๊ะ
ต่างกันที่วิธีตรวจ credential ที่ Gateway เท่านั้น

| | ตรวจด้วย | hostname | client ส่งอะไรมา |
|---|---|---|---|
| [`demo-jwt/`](demo-jwt/) | JWT | `demo-jwt.myhr.co.th` | `Authorization: Bearer <token>` |
| [`demo-apikey/`](demo-apikey/) | API key | `demo-apikey.myhr.co.th` | `X-API-Key: <key>` |

## 🔴 ประเด็นเดียวของ demo นี้

**ไม่มี code ตรวจ auth อยู่ใน app เลยสักบรรทัด** — ทั้งสองตัวเป็น nginx เปล่า ๆ ที่เสิร์ฟ
ไฟล์ HTML หน้าเดียว Envoy เป็นคนตรวจให้ก่อน request จะออกจาก Gateway
ตัวที่ไม่ผ่านถูกตอบ **401 ที่ Gateway** ไม่วิ่งมาถึง pod ด้วยซ้ำ

ต่างจาก `zeeme-ads` ที่ verify JWT เองในตัว app — ซึ่งใช้ได้เหมือนกัน แต่แปลว่า
ทุก service ต้องเขียน logic เดิมซ้ำ และคนละตัวอาจตรวจไม่เหมือนกันโดยไม่มีใครรู้

---

## ผลทดสอบจริง

ยิงจากเครื่องนอก cluster ผ่าน Gateway `192.168.50.200` — **ผ่านครบทั้ง 7 เคส**

| ยิงอะไร | ได้ |
|---|---|
| `demo-jwt` ไม่ส่ง token | **401** |
| `demo-jwt` token ถูกต้อง | **200** |
| `demo-jwt` token มั่ว | **401** |
| `demo-apikey` ไม่ส่ง key | **401** |
| `demo-apikey` key ของ `mobile-app` | **200** |
| `demo-apikey` key ของ `partner-a` | **200** |
| `demo-apikey` key ผิด | **401** |

---

## ไฟล์ในแต่ละ demo

| ไฟล์ | ทำอะไร | ต่างกันไหม |
|---|---|---|
| `deployment.yaml` | nginx-unprivileged 2 replica | เหมือนกัน |
| `service.yaml` | ClusterIP `80 → 8080` | เหมือนกัน |
| `pdb.yaml` | `minAvailable: 50%` | เหมือนกัน |
| `configmap.yaml` | หน้า HTML ที่เสิร์ฟ | เหมือนกัน |
| `networkpolicy.yaml` | เปิดทางจาก Envoy เข้า pod | เหมือนกัน |
| `httproute.yaml` | hostname ของแต่ละตัว | ต่างแค่ชื่อ host |
| **`securitypolicy.yaml`** | **ตัวที่ต่างกันจริง ๆ** | 🔑 |
| `apikeys.yaml` | Secret เก็บ API key | มีเฉพาะ `demo-apikey` |

---

## แบบที่ 1 · JWT

ไฟล์: [`demo-jwt/securitypolicy.yaml`](demo-jwt/securitypolicy.yaml)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: demo-jwt
  namespace: myhr-uat
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute            # ผูกกับ route นี้ route เดียว
      name: demo-jwt
  jwt:
    providers:
      - name: demo
        localJWKS:
          type: Inline
          inline: '{"keys":[{"kty":"oct","alg":"HS256","kid":"demo-key","k":"..."}]}'
        issuer: myhr-demo-issuer
        audiences: [demo-jwt]
        extractFrom:
          headers:
            - name: Authorization
              valuePrefix: "Bearer "
        claimToHeaders:
          - { claim: sub,  header: x-jwt-sub }
          - { claim: name, header: x-jwt-name }
```

**4 ช่องที่ต้องแก้เวลาเอาไปใช้จริง:**

| ช่อง | ใส่อะไร | ถ้าไม่ตรงจะเป็นยังไง |
|---|---|---|
| `localJWKS` / `remoteJWKS` | ที่มาของกุญแจสำหรับตรวจลายเซ็น | ลายเซ็นตรวจไม่ผ่าน → **401** |
| `issuer` | ต้องตรงกับ claim `iss` ใน token เป๊ะ | **401** |
| `audiences` | ต้องมีตัวใดตัวหนึ่งตรงกับ claim `aud` | **401** |
| `extractFrom` | บอกว่า token อยู่ที่ header ไหน | Envoy หา token ไม่เจอ → **401** |

`exp` ไม่ต้องตั้งอะไร Envoy ตรวจให้เองเสมอ

### `claimToHeaders` — ของดีที่คนมักไม่รู้ว่ามี

Envoy แกะ claim ออกมาเป็น HTTP header ให้ app เลย app จึงอ่าน `x-jwt-sub`
เหมือน header ธรรมดา **ไม่ต้องมี library ถอด JWT ในทุก service**

> ⚠️ ถ้าใช้ท่านี้ **ต้องมั่นใจว่า app เข้าถึงได้จาก Gateway ทางเดียวเท่านั้น**
> ไม่งั้นใครก็ปลอม header `x-jwt-sub` ยิงตรงเข้า Service ได้
> `networkpolicy.yaml` ในแต่ละ demo คือตัวที่ปิดทางนั้น — **ห้ามลบ**

### 🔴 `localJWKS` แบบ Inline ห้ามใช้กับของจริง

demo นี้ใช้ **HS256** ซึ่งเป็น *กุญแจลับร่วมกัน* — JWKS ที่อยู่ในไฟล์จึงมีกุญแจลับอยู่ข้างใน
**ใครอ่านไฟล์นี้ได้ก็ปลอม token ได้ทันที** และตอนนี้มันอยู่ใน git แล้ว

ของจริงเลือกอย่างใดอย่างหนึ่ง:

```yaml
# ทางที่ควรใช้ — IdP เป็นคนถือกุญแจ ตัวที่อยู่ใน JWKS เป็น public key
remoteJWKS:
  uri: https://<idp>/.well-known/jwks.json
```

```yaml
# ถ้ายังต้องใช้ HS256 อย่างน้อยย้ายออกจากไฟล์ manifest
localJWKS:
  type: ValueRef
  valueRef: { group: "", kind: ConfigMap, name: demo-jwks }
```

> `remoteJWKS` ต้องเปิดทาง egress ให้ Envoy ออกไปหา IdP ได้ด้วย
> ถ้า IdP อยู่นอก cluster ให้ตรวจ NetworkPolicy ของ `envoy-gateway-system` ก่อน

---

## แบบที่ 2 · API key

ไฟล์: [`demo-apikey/securitypolicy.yaml`](demo-apikey/securitypolicy.yaml)

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: demo-apikey
  apiKeyAuth:
    credentialRefs:
      - name: demo-apikey-keys     # Secret ต้องอยู่ namespace เดียวกัน
    extractFrom:
      - headers: [X-API-Key]
    forwardClientIDHeader: x-client-id
    sanitize: true
```

**โครงสร้าง Secret — จุดที่คนงงที่สุด:**

```yaml
stringData:
  mobile-app: "demo-key-mobile-9f2a4c7e15b3"   # ชื่อ key = client id
  partner-a:  "demo-key-partner-3d81ba60ff42"  # ค่า = API key ที่ client ส่งมา
```

**1 บรรทัด = 1 client** — เพิ่ม client ใหม่ = เพิ่มบรรทัด

> 🔴 **เพิกถอนไม่ได้ด้วยการลบบรรทัดแล้ว `apply` ทับ** — ทดสอบแล้วไม่ได้ผลจริง
> ดูหัวข้อ [สร้าง · เพิ่ม · เพิกถอน](#สร้าง--เพิ่ม--เพิกถอน-api-key) ข้างล่าง

| ช่อง | ทำอะไร |
|---|---|
| `extractFrom` | เลือกได้อย่างเดียวต่อ entry: `headers` / `params` / `cookies` · ใส่หลาย entry ได้ Envoy ไล่ตามลำดับ |
| `forwardClientIDHeader` | ส่ง **ชื่อ key** (`mobile-app`) ต่อให้ app ไม่ใช่ตัว API key — app จึงรู้ว่าใครเรียกโดยไม่เห็นความลับ |
| `sanitize: true` | ลบ header `X-API-Key` ทิ้งก่อนส่งต่อ **ควรเปิดไว้เสมอ** ไม่งั้นกุญแจไหลไปโผล่ใน log ของ app |

> ⚠️ **อย่าใช้ `params`** ถ้าเลี่ยงได้ — query string โผล่ใน access log ของ Envoy
> และใน history ของ browser

### 🔴 `apikeys.yaml` ไม่ควรอยู่ใน git

ในโฟลเดอร์นี้มีไว้ให้ demo อ่านง่ายเท่านั้น ของจริงสร้างด้วยคำสั่งแทน:

```bash
kubectl -n myhr-uat create secret generic demo-apikey-keys --from-literal='mobile-app=<api key จริง>'
```

---

## สร้าง · เพิ่ม · เพิกถอน API key

**สร้างกุญแจ** — เป็นแค่สตริงสุ่ม ไม่มีโครงสร้างอะไรพิเศษ

```bash
openssl rand -hex 24
```

**เพิ่ม client ใหม่** — แก้ [`demo-apikey/apikeys.yaml`](demo-apikey/apikeys.yaml) เพิ่มบรรทัด แล้ว apply
Envoy เห็นของใหม่ภายในไม่กี่วินาที ไม่ต้อง restart อะไร

**🔴 เพิกถอน — ตรงนี้คือกับดัก**

ลบบรรทัดออกจากไฟล์แล้ว `kubectl apply` **ไม่ได้ลบกุญแจออกจาก cluster** เพราะไฟล์ใช้
`stringData` ซึ่งเป็นช่องเขียนอย่างเดียว ตัวที่เก็บจริงคือ `data` — `apply` จึงมองไม่เห็น
ว่ามีกุญแจส่วนเกินค้างอยู่ ขึ้นว่า `configured` เฉย ๆ แล้วกุญแจที่ตั้งใจเพิกถอน**ยังใช้ได้ต่อ**

ทดสอบมาแล้วจริง: หลัง `apply` ทับ กุญแจที่ลบออกจากไฟล์ยังยิงได้ `200`

ต้องสั่งลบตรง ๆ ที่ `data`:

```bash
kubectl -n myhr-uat patch secret demo-apikey-keys --type json -p '[{"op":"remove","path":"/data/<client id>"}]'
```

**ควรเห็น:** ยิงด้วยกุญแจนั้นได้ `401` ทันที

> **บน PowerShell 5.1 ใช้ `-p` ไม่ได้** — มันกลืน quote ของ JSON แล้ว kubectl จะฟ้อง
> `error decoding patch` ให้เขียน JSON ลงไฟล์แล้วใช้ `--patch-file <ไฟล์>` แทน

---

## สร้าง JWT

มีสคริปต์ [`mint-jwt.py`](mint-jwt.py) ในโฟลเดอร์นี้ — ออก **token กับ JWKS ที่คู่กัน**
ให้พร้อมกัน ใช้แค่ `python` กับ `openssl` ไม่ต้องลง library เพิ่ม

### HS256 — กุญแจลับร่วมกัน (แบบที่ demo ใช้)

```bash
python mint-jwt.py hs256 --secret "$(openssl rand -base64 32)" --iss myhr-demo-issuer --aud demo-jwt --sub user-1
```

เอา JWKS ที่ได้ไปวางใน `localJWKS.inline` และเอา token ไปทดสอบ

🔴 **ห้ามใช้กับของจริง** — JWKS ของ HS256 มีกุญแจลับอยู่ข้างใน ใครอ่านได้ก็ปลอม token ได้

### RS256 — กุญแจส่วนตัว/สาธารณะ (ท่าที่ควรใช้)

```bash
openssl genrsa -out jwt-private.pem 2048
```

```bash
python mint-jwt.py rs256 --key jwt-private.pem --iss myhr --aud demo-jwt --sub user-1
```

JWKS ที่ได้มีแต่ **public key** (`n` กับ `e`) เอาไปวางในไฟล์ได้โดยไม่รั่วอะไร
ส่วน `jwt-private.pem` เก็บไว้ที่คนออก token เท่านั้น **ห้ามเข้า git**

> ตรวจว่า JWKS ถูกต้อง: ค่า `"e"` ต้องเป็น **`"AQAB"`** (คือ 65537)
> ถ้าได้ค่าอื่นแปลว่าอ่าน exponent ผิดฐาน แล้วจะ verify ไม่ผ่านทั้งที่ token ถูก

### ของจริงควรมี IdP เป็นคนออก

ทั้งสองท่าข้างบนคือ "เราออก token เอง" ซึ่งเหมาะกับทดสอบ
ของจริงให้ IdP ออกให้ แล้ว SecurityPolicy ชี้ไปที่ JWKS ของมัน — ไม่ต้องถือกุญแจเองเลย

```yaml
remoteJWKS:
  uri: https://<idp>/.well-known/jwks.json
```

---

## verify กันยังไง

ทั้งสองแบบตรวจที่ Envoy **ก่อน** request จะออกจาก Gateway — pod ไม่เคยเห็น request ที่ไม่ผ่าน

### demo-jwt ตรวจ 4 ชั้น

ยิงจริงด้วย token ที่จงใจทำผิดทีละอย่าง ผลที่ได้:

| token เป็นยังไง | ได้ | Envoy จับที่ |
|---|---|---|
| ทุกอย่างถูก | **200** | — |
| เซ็นด้วยกุญแจอื่น | **401** | ลายเซ็น — คำนวณ HMAC/RSA ใหม่แล้วเทียบ |
| `iss` ไม่ตรง | **401** | claim `iss` เทียบกับ `issuer` ในนโยบาย |
| หมดอายุแล้ว | **401** | claim `exp` เทียบกับนาฬิกาของ Envoy |
| `aud` ไม่ตรง | **403** | claim `aud` เทียบกับ `audiences` |

> 🔴 **`aud` ผิดได้ 403 ไม่ใช่ 401** — ต่างจากอีก 3 ข้อ
> เพราะลายเซ็นผ่านแล้ว Envoy ถือว่า "รู้แล้วว่าเป็นใคร" (authentication ผ่าน)
> แต่ token ใบนี้ไม่ได้ออกมาให้ service นี้ใช้ (authorization ไม่ผ่าน)
> **เห็น 403 แปลว่า token ถูกต้องแต่ผิดปลายทาง — อย่าไปไล่หาว่ากุญแจผิด**

`kid` ในหัว token ใช้เลือกว่าจะหยิบกุญแจใบไหนใน JWKS มาตรวจ
ถ้าใน JWKS มีใบเดียว Envoy ก็ใช้ใบนั้น — แต่พอมีหลายใบตอนหมุนกุญแจ `kid` จะสำคัญทันที

### demo-apikey เทียบตรงตัว

ไม่มีลายเซ็น ไม่มีวันหมดอายุ — Envoy เอาค่าที่ client ส่งมาเทียบกับค่าใน Secret ตรง ๆ

| ส่งอะไรมา | ได้ |
|---|---|
| `demo-key-mobile-9f2a4c7e15b3` | **200** |
| `DEMO-KEY-MOBILE-9F2A4C7E15B3` | **401** — เทียบแบบ case-sensitive |
| `demo-key-mobile-9f2a4c7e15b3 ` (มีเว้นวรรคท้าย) | **200** — HTTP ตัดช่องว่างท้าย header ให้เองตามมาตรฐาน |
| `mobile-app` (ชื่อ client ไม่ใช่กุญแจ) | **401** — เทียบที่ *ค่า* ไม่ใช่ชื่อ key |

**ผลของการเทียบตรงตัวคือ API key ไม่มีทางบอกอะไรได้นอกจาก "ตรง/ไม่ตรง"** —
ไม่มี claim ไม่มีวันหมดอายุ ไม่มีข้อมูลผู้ใช้ สิ่งเดียวที่ backend ได้คือ
ชื่อ client ที่ Envoy ใส่มาให้ใน header `x-client-id`

---

## JWT กับ API key เลือกอันไหน

| | JWT | API key |
|---|---|---|
| หมดอายุเองได้ | ✅ `exp` | ❌ อยู่จนกว่าจะลบ |
| บอกได้ว่าใครเป็นคนเรียก | ✅ claim ครบ | ✅ แต่ได้แค่ client id |
| ต้องมี IdP | ✅ ต้องมีคนออก token | ❌ |
| เพิกถอนทีละราย | ยาก — ต้องรอ `exp` หรือทำ blacklist | ง่าย — ลบบรรทัดใน Secret |
| เหมาะกับ | ผู้ใช้คน · mobile app ที่ล็อกอิน | service-to-service · partner |

---

## ลองเอง

```bash
kubectl apply -f demo-jwt/
```

```bash
kubectl apply -f demo-apikey/
```

```bash
kubectl -n myhr-uat get pods,securitypolicy,httproute
```

**ควรเห็น:** pod `1/1 Running` อย่างละ 2 ตัว · SecurityPolicy `Accepted=True` ·
HTTPRoute `Accepted=True ResolvedRefs=True`

ยิงทดสอบจากเครื่องในวง `192.168.50.0/24`:

```bash
curl -s -o /dev/null -w "%{http_code}\n" --resolve "demo-jwt.myhr.co.th:443:192.168.50.200" https://demo-jwt.myhr.co.th/
```
**ควรเห็น:** `401` — ไม่ส่ง token

```bash
curl -s -o /dev/null -w "%{http_code}\n" --resolve "demo-apikey.myhr.co.th:443:192.168.50.200" -H "X-API-Key: demo-key-mobile-9f2a4c7e15b3" https://demo-apikey.myhr.co.th/
```
**ควรเห็น:** `200`

> token ของ demo-jwt ยาวเกินจะพิมพ์มือ — อยู่ในคอมเมนต์หัวไฟล์
> [`demo-jwt/securitypolicy.yaml`](demo-jwt/securitypolicy.yaml) และหมดอายุปี 2036

---

## 🔴 สองกับดักที่เจอจริงตอนสร้าง demo นี้

ทั้งคู่ทำให้ **pod ดูปกติแต่ใช้งานไม่ได้** และไม่มี error ตรงหน้าให้เห็น

### 1 · `myhr-uat` ไม่มี LimitRange แต่ quota บังคับ `limits.cpu`

`myhr-prod` มี LimitRange ชื่อ `myhr-prod-limits` คอยเติม `limits.cpu: 500m` ให้เอง
**`myhr-uat` ไม่มี** — manifest ที่ไม่ประกาศ `limits.cpu` จะถูกปฏิเสธตั้งแต่สร้าง pod

อาการคือ Deployment ค้าง `0/2` โดย **ไม่มี pod ให้ `describe` ด้วยซ้ำ** ต้องดูที่ ReplicaSet:

```bash
kubectl -n myhr-uat describe rs -l app.kubernetes.io/name=demo-jwt
```
**จะเห็น:** `failed quota: myhr-uat-quota: must specify limits.cpu`

> ผลข้างเคียงที่ควรรู้: `zeeme-ads` เขียนคอมเมนต์ว่า "ตั้งใจไม่ใส่ `limits.cpu`"
> แต่ pod จริงที่รันอยู่มี `limits.cpu: 500m` เพราะ LimitRange เติมให้ — เจตนาในไฟล์
> กับของที่รันจริงไม่ตรงกัน ตรวจด้วย `kubectl -n myhr-prod get pod <ชื่อ> -o jsonpath='{.spec.containers[0].resources}'`

### 2 · `myhr-uat` ไม่มี `allow-from-gateway`

`myhr-prod` มี NetworkPolicy `allow-from-gateway` ที่ `podSelector: {}` เปิดให้ทุก pod
**`myhr-uat` มีแค่ `default-deny-all` กับ `allow-dns-egress`**

ถ้าไม่มี `networkpolicy.yaml` ในแต่ละ demo pod จะขึ้น `1/1 Running` สวยงาม
แต่ยิงจากข้างนอกจะไม่มีวันถึง **และ NetworkPolicy ไม่เขียน log ตอนปฏิเสธ**

ไฟล์ที่ให้มาใช้ `podSelector` เจาะจงแต่ละ demo ไม่ใช่ `{}` จึงเป็นของ service ตัวนั้นตัวเดียว
ลบ demo ทิ้งเมื่อไหร่ policy หายตามไปด้วย ไม่ค้างเป็นรูโหว่

---

## เอา demo ออก

```bash
kubectl delete -f demo-jwt/ -f demo-apikey/
```

Namespace `myhr-uat` · Gateway · NetworkPolicy ระดับ namespace เป็นของกลาง ไม่ถูกลบไปด้วย
