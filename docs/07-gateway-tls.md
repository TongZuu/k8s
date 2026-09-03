# บทที่ 07 — Envoy Gateway และ TLS

> **รันที่: 👑 master01**
> **เวลาที่ใช้:** ~40 นาที (ทาง A) · ~60 นาที (ทาง B)
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

## ⚖️ ตัดสินใจก่อนเริ่ม — cert จะมาจากไหน

บทนี้มีทางแยกอยู่ที่ **ขั้นที่ 3** เลือกทางเดียว แล้วเดินต่อเหมือนกันทั้งบท

| | **ทาง A — public cert ที่มีอยู่แล้ว** | **ทาง B — ออก internal CA เอง** |
|---|---|---|
| เหมาะเมื่อ | องค์กรซื้อ cert ของ `myhr.co.th` ไว้อยู่แล้ว | ไม่มี public cert หรือใช้ชื่อที่จดโดเมนไม่ได้ |
| ต้องลง cert-manager | **ไม่ต้อง** | ต้อง |
| ต้องเอา root CA ไปลงเครื่อง client | **ไม่ต้อง** — เครื่องทุกเครื่องเชื่อ public CA อยู่แล้ว | ต้อง ทำผ่าน GPO/MDM ทุกเครื่อง |
| ต่ออายุ | **ทำเอง** ปีละครั้ง (รันสคริปต์เดิมซ้ำ) | อัตโนมัติ |
| เวลาที่ใช้ในบทนี้ | ~40 นาที | ~60 นาที + งาน GPO ที่ตามมา |

> **ทาง A คือทางหลักของโครงการนี้** เพราะงานที่หนักที่สุดของทาง B ไม่ได้อยู่ในบทนี้
> แต่อยู่ที่การไล่ลง root CA ให้ครบทุกเครื่อง client ซึ่งกินเวลาเป็นสัปดาห์และพลาดง่าย
> เครื่องที่ตกหล่นจะเจอ cert warning แล้วคนจะเริ่มกด "ผ่าน ๆ ไป" ซึ่งอันตรายกว่าไม่มี TLS
>
> **สองทางอยู่ร่วมกันได้** — ทำทาง A ตอนนี้ แล้วเพิ่มทาง B ทีหลังเมื่อมี service
> ที่ใช้ชื่อภายในซึ่ง public cert ไม่ครอบ วิธีใส่ cert หลายใบใน listener เดียว
> อยู่ในคอมเมนต์ท้าย [`gateway.yaml`](../config/gateway/gateway.yaml)

> 🔎 **เวลามีปัญหาหลังบทนี้** (404 ทั้งที่ route เขียว, `no healthy upstream`, listener HTTPS ไม่ขึ้น,
> route ข้าม namespace) ให้เปิด [`../html/cilium-envoy-scenarios.html`](../html/cilium-envoy-scenarios.html)
> — ค้นด้วยข้อความ error ได้ตรง ๆ เรียงตามความถี่ที่เจอจริง
>
> 📐 **ก่อนสร้าง service ใหม่** หน้าเดียวกันมีฝั่ง "แบบแผนที่ควรทำ" — API service (P01),
> web app React/Angular (P02), หลาย service ใต้ host เดียว (P03), แบ่ง zone public/private (P06)

---

## 1 · ติดตั้ง Gateway API CRD

Envoy Gateway ต้องการ CRD ชุดนี้ก่อน — เป็นของกลางไม่ผูกกับ implementation ไหน

```bash
set -a && source /root/k8s/versions.env && set +a

kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"
kubectl get crd | grep gateway.networking.k8s.io
```

**ควรเห็น:** `gatewayclasses`, `gateways`, `httproutes`, `grpcroutes`, `referencegrants`

> ใช้ `standard-install.yaml` ไม่ใช่ `experimental` — `TCPRoute`/`UDPRoute` อยู่ใน experimental
> ถ้าวันหนึ่งต้องเปิด TCP ตรง ๆ ค่อยมาเปลี่ยน แต่ตอนนี้ยังไม่มีความจำเป็น

---

## 2 · ติดตั้ง Envoy Gateway

```bash
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version "v${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system --create-namespace

kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=5m
kubectl get gatewayclass
```

**ควรเห็น:** GatewayClass `eg` สถานะ `ACCEPTED=True`

> ขั้นนี้สร้าง namespace `envoy-gateway-system` ซึ่งขั้นที่ 3 ต้องใช้เก็บ Secret ของ cert
> จึงต้องทำก่อน ไม่ใช่หลัง

---

## 3 · เตรียม TLS cert

**ต้องมี Secret `myhr-wildcard-tls` ใน `envoy-gateway-system` ให้เสร็จก่อนสร้าง Gateway**
เพราะ listener HTTPS ที่อ้าง Secret ที่ยังไม่มี จะค้างที่ `Programmed=False`
แล้วขั้นที่ 4 จะตรวจไม่ผ่านโดยที่สาเหตุอยู่คนละที่กับที่กำลังมอง

เลือก **ทาง A หรือ ทาง B อย่างใดอย่างหนึ่ง** ตามตารางด้านบน

---

### 🅰️ ทาง A — ใช้ public cert ที่มีอยู่แล้ว

**เตรียมไฟล์สองไฟล์** วางไว้ที่ `/root/certs/` บน master01

| ไฟล์ | คือ |
|---|---|
| `fullchain.pem` | cert ของเรา **ต่อด้วย** intermediate ทุกใบ — เรียง leaf ขึ้นก่อนเสมอ |
| `privkey.pem` | private key แบบ PEM **ไม่มี passphrase** |

**ถ้า CA ส่งมาเป็นไฟล์แยก** (`cert.pem` + `intermediate.pem` หรือ `ca-bundle.crt`):
```bash
mkdir -p /root/certs && chmod 700 /root/certs
cat cert.pem intermediate.pem > /root/certs/fullchain.pem
```

**ถ้า CA ส่งมาเป็น `.pfx` / `.p12`:**
```bash
mkdir -p /root/certs && chmod 700 /root/certs
openssl pkcs12 -in myhr.pfx -clcerts -nokeys        -out /tmp/leaf.pem
openssl pkcs12 -in myhr.pfx -cacerts -nokeys -chain -out /tmp/chain.pem
openssl pkcs12 -in myhr.pfx -nocerts -nodes         -out /root/certs/privkey.pem
cat /tmp/leaf.pem /tmp/chain.pem > /root/certs/fullchain.pem
rm -f /tmp/leaf.pem /tmp/chain.pem
chmod 600 /root/certs/privkey.pem
```

**ตรวจก่อน แล้วค่อยเขียนลง cluster:**
```bash
bash /root/k8s/config/gateway/import-public-cert.sh --dry-run \
     /root/certs/fullchain.pem /root/certs/privkey.pem
```

`--dry-run` ตรวจอย่างเดียว ไม่แตะ cluster — ต้องได้ `ok` ครบทั้ง 5 ข้อก่อนไปต่อ

> **ทำไมไม่ใช้ `kubectl create secret tls` ตรง ๆ** — คำสั่งนั้นรับไฟล์อะไรก็ได้ที่หน้าตาเป็น PEM
> แล้วตอบ `created` ทั้งที่ chain ขาด intermediate, key ไม่ใช่คู่ของ cert, key ยังมี passphrase
> หรือ cert ไม่ครอบชื่อที่จะใช้จริง ทั้งสี่อย่างนี้เงียบตอนสร้าง แล้วไปโผล่ทีหลัง
> ในรูป "บางเครื่องเข้าได้ บางเครื่องไม่ได้" ซึ่งหาสาเหตุยากมาก สคริปต์นี้ตรวจทั้งสี่ข้อให้ก่อน

**ถ้าใช้ cert รายชื่อ ไม่ใช่ wildcard** ให้ระบุชื่อที่จะใช้จริงต่อท้าย เพื่อให้ตรวจครบทุกชื่อ:
```bash
bash /root/k8s/config/gateway/import-public-cert.sh --dry-run \
     /root/certs/fullchain.pem /root/certs/privkey.pem \
     hr.myhr.co.th api.myhr.co.th grafana.myhr.co.th
```

**เขียน Secret จริง** (คำสั่งเดิม เอา `--dry-run` ออก):
```bash
bash /root/k8s/config/gateway/import-public-cert.sh \
     /root/certs/fullchain.pem /root/certs/privkey.pem

kubectl -n envoy-gateway-system get secret myhr-wildcard-tls
```
**ควรเห็น:** `TYPE = kubernetes.io/tls` และ `DATA = 2`

> 🔐 **อย่า commit `privkey.pem` ลงrepo** — `config/` ถูก track ใน git อยู่
> เก็บไฟล์ไว้ที่ `/root/certs/` (chmod 700) หรือใน password manager ขององค์กรเท่านั้น
>
> 📅 **ต่ออายุปีหน้า:** เอา `fullchain.pem`/`privkey.pem` ชุดใหม่มาวางทับ แล้วรันคำสั่งเดิมซ้ำ
> สคริปต์ใช้ `apply` จึงเขียนทับได้เลยไม่ต้องลบก่อน และ Envoy Gateway โหลด cert ใหม่ให้เอง
> ภายในไม่กี่วินาที **ไม่ต้อง restart อะไร** — ใส่วันหมดอายุ (`openssl x509 -noout -enddate`)
> ลงปฏิทินทีมไว้ล่วงหน้า 30 วัน

**ทาง A จบแค่นี้ — ข้ามไปขั้นที่ 4**

---

### 🅱️ ทาง B — ออก internal CA เอง

**ติดตั้ง cert-manager:**
```bash
set -a && source /root/k8s/versions.env && set +a

helm repo add jetstack https://charts.jetstack.io && helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "v${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set replicaCount=2 \
  --set webhook.replicaCount=2 \
  --set cainjector.replicaCount=2

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=3m
kubectl -n cert-manager get pods
```

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

**ออก cert ให้ Gateway:**
```bash
kubectl apply -f /root/k8s/config/cert-manager/wildcard-cert.yaml

kubectl -n envoy-gateway-system get certificate myhr-wildcard-tls
kubectl -n envoy-gateway-system get secret myhr-wildcard-tls
```
**ควรเห็น:** Certificate `READY=True` และมี Secret `TYPE = kubernetes.io/tls`

**ถ้า `READY` ค้างที่ `False` เกินหนึ่งนาที:**
```bash
kubectl -n envoy-gateway-system describe certificate myhr-wildcard-tls | tail -20
```

> **ทำไมเขียนเป็นไฟล์ Certificate แทนที่จะติด annotation ไว้ที่ Gateway** — cert-manager
> อ่าน annotation `cert-manager.io/cluster-issuer` บน Gateway ได้ก็ต่อเมื่อติดตั้งด้วย
> `--set config.enableGatewayAPI=true` เท่านั้น ถ้าลืมเปิด: apply Gateway ผ่าน ไม่มี error
> ไม่มี event ไม่มี Certificate แล้ว listener HTTPS ค้างโดยไม่มีอะไรชี้สาเหตุ
> เขียนเป็น Certificate แยก แลกด้วยไฟล์เพิ่มหนึ่งไฟล์ แต่ตรวจได้ตั้งแต่ก่อนสร้าง Gateway

**ดึง root CA ออกมาแจกให้เครื่อง client:**
```bash
kubectl -n cert-manager get secret myhr-internal-ca-key-pair \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /root/k8s/myhr-root-ca.crt

openssl x509 -in /root/k8s/myhr-root-ca.crt -noout -subject -dates
```
**ควรเห็น:** subject เป็น `CN=MyHR Internal CA` และหมดอายุอีก ~10 ปี

> 📋 **งานที่ต้องทำต่อ (ไม่ใช่งานของ cluster):** เอา `myhr-root-ca.crt` ไปลงเป็น trusted root
> บนเครื่อง client ทุกเครื่องที่จะเรียก service ผ่าน HTTPS — ทำผ่าน GPO หรือ MDM ที่องค์กรใช้อยู่
> ถ้าข้ามข้อนี้ ทุกคนจะเจอ cert warning และจะเริ่มกด "ผ่าน ๆ ไป" ซึ่งอันตรายกว่าไม่มี TLS

---

## 4 · สร้าง Gateway

```bash
kubectl apply -f /root/k8s/config/gateway/gateway.yaml
kubectl -n envoy-gateway-system get gateway myhr-gateway
```

**ควรเห็น:** `PROGRAMMED=True` และคอลัมน์ `ADDRESS` เป็น IP จาก pool เช่น `192.168.50.200`

**ตรวจ listener ทีละตัว** — คอลัมน์ `PROGRAMMED` ข้างบนเป็นสถานะรวม
listener ตัวเดียวพังแล้วอีกตัวยังใช้ได้ ซึ่งมองจากตารางไม่เห็น:
```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway \
  -o jsonpath='{range .status.listeners[*]}{.name}{":"}{range .conditions[*]}{" "}{.type}={.status}{end}{"\n"}{end}'
```
**ควรเห็น:** ทั้ง `http` และ `https` เป็น `Accepted=True Programmed=True ResolvedRefs=True`

ถ้า `https` ขึ้น `ResolvedRefs=False` แปลว่า Secret `myhr-wildcard-tls` ไม่มี ผิด namespace
หรือไม่ใช่ `type: kubernetes.io/tls` — กลับไปขั้นที่ 3

> Envoy Gateway จะสร้าง Service `type: LoadBalancer` ให้อัตโนมัติ
> ซึ่ง Cilium LB-IPAM จะจ่าย IP ให้ — **นี่คือ IP เดียวที่กินจาก pool ทั้ง 10 ตัว**

**ถ้า `ADDRESS` ว่าง:**
```bash
kubectl -n envoy-gateway-system get svc
kubectl get ciliumloadbalancerippool default-pool -o yaml | grep -A5 status
```
แปลว่า pool หมดหรือ LB-IPAM มีปัญหา — กลับไปดูบทที่ 05

**จด IP ที่ได้ไว้** — ขั้นถัดไปต้องใช้บนเครื่องทดสอบซึ่งไม่มี kubectl:
```bash
kubectl -n envoy-gateway-system get gateway myhr-gateway \
  -o jsonpath='{.status.addresses[0].value}{"\n"}'
```

---

## 5 · ทดสอบด้วย HTTPRoute จริง

**บน master01 — สร้าง service ทดสอบ:**
```bash
kubectl create ns demo
kubectl -n demo create deployment echo --image=nginx:alpine --replicas=2
kubectl -n demo rollout status deploy/echo --timeout=2m
kubectl -n demo expose deployment echo --port=80

kubectl apply -f /root/k8s/config/gateway/httproute-example.yaml
```

**ตรวจว่า route ผูกติดจริง:**
```bash
kubectl -n demo get httproute echo-route \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
```
**ควรเห็น:** `Accepted=True` และ `ResolvedRefs=True`

> `kubectl get httproute` เฉย ๆ ไม่มีคอลัมน์สถานะ — มีแค่ `HOSTNAMES` กับ `AGE`
> route ที่ผูกไม่ติดกับ Gateway หรือชี้ไป Service ที่พิมพ์ผิด จะหน้าตาเหมือนกันเป๊ะ
> `ResolvedRefs=False` คือตัวที่จับ backend ผิดชื่อได้ ซึ่งเป็นสาเหตุอันดับหนึ่งของ 404

**บนเครื่องทดสอบในวง `192.168.50.0/24` (ไม่ใช่ node) — ตั้งค่า IP ที่จดมาจากขั้นที่ 4:**
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

> ถ้าใช้ **ทาง B** ต้องเพิ่ม `--cacert /root/k8s/myhr-root-ca.crt` ในสองคำสั่งข้างบน
> (หรือลง root CA ที่เครื่องทดสอบก่อน) — **ทาง A ไม่ต้อง** เพราะเครื่องเชื่อ public CA อยู่แล้ว
>
> ถ้าใช้ cert **รายชื่อ** ไม่ใช่ wildcard คำสั่งที่สองจะตายที่ TLS ก่อนถึง 404
> ให้เติม `-k` เฉพาะคำสั่งที่สอง — ข้อนี้ตรวจการ routing ไม่ได้ตรวจ cert

**ดูว่า cert ที่เสิร์ฟออกมาเป็นใบที่ตั้งใจจริงหรือเปล่า:**
```bash
curl -sS -v -o /dev/null \
     --resolve "echo.myhr.co.th:443:${GW_IP}" https://echo.myhr.co.th 2>&1 \
  | grep -E 'subject:|issuer:|expire'
```
**ควรเห็น:** `issuer` เป็น CA ที่คาดไว้ และ `expire date` ตรงกับใบที่เพิ่งใส่ไป

> `x509: certificate signed by unknown authority` → root CA ไม่ถูก (ทาง B: ยังไม่ได้ลง root CA ที่เครื่องทดสอบ)
> `certificate is valid for ... not echo.myhr.co.th` → ชื่อใน cert ไม่ครอบ host ที่เรียก
> `connection refused` / timeout → ยังไม่ถึง Envoy เลย กลับไปดูเรื่อง ARP ที่บทที่ 05

---

## 6 · บังคับ HTTPS

ตอนนี้ listener HTTP ยังไม่มี route ผูกอยู่เลย ทุก request ที่เข้าทาง port 80 จึงได้ 404
ขั้นนี้เปลี่ยนให้เป็น redirect แทน

```bash
kubectl apply -f /root/k8s/config/gateway/https-redirect.yaml
```
ทำครั้งเดียวใช้กับทุก hostname — ไม่ต้องทำซ้ำต่อ service

**ตรวจจากเครื่องทดสอบ:**
```bash
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
     -H 'Host: echo.myhr.co.th' "http://${GW_IP}"
```
**ควรเห็น:** `301 https://echo.myhr.co.th/`

**เก็บกวาดบน master01:**
```bash
kubectl delete ns demo
```

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] Gateway API CRD ครบ (`standard-install`)
- [ ] GatewayClass `eg` **ACCEPTED=True**
- [ ] Secret `myhr-wildcard-tls` มีอยู่ใน `envoy-gateway-system` เป็น `type: kubernetes.io/tls`
- [ ] Gateway `myhr-gateway` **PROGRAMMED=True** และมี `ADDRESS`
- [ ] listener ทั้ง `http` และ `https` เป็น `Programmed=True ResolvedRefs=True`
- [ ] HTTPRoute ทดสอบขึ้น `Accepted=True ResolvedRefs=True`
- [ ] host ถูกได้ 200 · host ที่ไม่มี route ได้ 404 (ยิงจากเครื่องในวง `192.168.50.0/24` ที่ไม่ใช่ node)
- [ ] HTTPS ผ่านโดยไม่มี cert warning และ `issuer` ตรงกับใบที่ตั้งใจ
- [ ] HTTP redirect ไป HTTPS (301)
- [ ] ลบ namespace `demo` แล้ว

**เฉพาะทาง A:**
- [ ] `privkey.pem` **ไม่ได้อยู่ในrepo** และไฟล์ที่ `/root/certs/` เป็น chmod 600
- [ ] **จดวันหมดอายุลงปฏิทินทีมแล้ว** พร้อมเตือนล่วงหน้า 30 วัน (ทางนี้ไม่ต่ออายุเอง)

**เฉพาะทาง B:**
- [ ] cert-manager 3 deployment × 2 replica + PDB
- [ ] ClusterIssuer `myhr-internal-ca-issuer` **READY=True**
- [ ] Certificate `myhr-wildcard-tls` **READY=True**
- [ ] **เอา root CA ไปลงเครื่อง client แล้ว** (หรือมี ticket ค้างอยู่)

> **จด IP ที่ Gateway ได้ไปลง DNS** — ต้องให้ทีม network ทำ record ชี้
> `*.myhr.co.th` (หรือรายตัว) มาที่ IP นี้ ไม่งั้นต้องใช้ `--resolve` ตลอดไป
> public cert ใช้กับ IP วงในได้ปกติ เพราะ TLS ตรวจที่ชื่อ ไม่ใช่ที่ IP

**➡️ ต่อที่ [บทที่ 08 — Storage](08-storage.md)**
