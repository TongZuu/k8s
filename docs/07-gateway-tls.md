# บทที่ 07 — Envoy Gateway และ TLS

> **รันที่: 👑 master01**
> **เวลาที่ใช้:** ~40 นาที
> **ต้องผ่านบทที่ 05-06** — โดยเฉพาะการ curl เข้า LoadBalancer IP จากนอก cluster ได้

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

## 2 · ติดตั้ง cert-manager

```bash
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

---

## 3 · สร้าง internal CA

ระบบภายในไม่ต้องใช้ cert จาก public CA — ออก CA เองแล้วกระจาย root ไปเครื่อง client
ดีกว่า self-signed รายตัวมาก เพราะไม่ต้องกด "ยอมรับความเสี่ยง" ทุกครั้ง และ cert ต่ออายุเองอัตโนมัติ

```bash
kubectl apply -f /root/k8s/config/cert-manager/internal-ca.yaml

kubectl -n cert-manager get certificate myhr-internal-ca
kubectl get clusterissuer myhr-internal-ca-issuer
```
**ควรเห็น:** Certificate `READY=True` และ ClusterIssuer `READY=True`

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

## 4 · ติดตั้ง Envoy Gateway

```bash
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version "v${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system --create-namespace

kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=5m
kubectl get gatewayclass
```

**ควรเห็น:** GatewayClass `eg` สถานะ `ACCEPTED=True`

---

## 5 · สร้าง Gateway

```bash
kubectl apply -f /root/k8s/config/gateway/gateway.yaml
kubectl -n envoy-gateway-system get gateway myhr-gateway
```

**ควรเห็น:** `PROGRAMMED=True` และคอลัมน์ `ADDRESS` เป็น IP จาก pool เช่น `192.168.50.200`

> Envoy Gateway จะสร้าง Service `type: LoadBalancer` ให้อัตโนมัติ
> ซึ่ง Cilium LB-IPAM จะจ่าย IP ให้ — **นี่คือ IP เดียวที่กินจาก pool ทั้ง 10 ตัว**

**ถ้า `ADDRESS` ว่าง:**
```bash
kubectl -n envoy-gateway-system get svc
kubectl get ciliumloadbalancerippool default-pool -o yaml | grep -A5 status
```
แปลว่า pool หมดหรือ LB-IPAM มีปัญหา — กลับไปดูบทที่ 05

**ตรวจจากเครื่องนอก cluster:**
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
echo "Gateway IP = $GW_IP"
curl -I "http://${GW_IP}"
```
**ควรเห็น:** `404 Not Found` จาก Envoy ← **ถูกต้องแล้ว** เพราะยังไม่มี HTTPRoute
ถ้า `connection refused` หรือ timeout ให้กลับไปดูเรื่อง ARP ที่บทที่ 05

---

## 6 · ทดสอบด้วย HTTPRoute จริง

```bash
kubectl create ns demo
kubectl -n demo create deployment echo --image=nginx:alpine --replicas=2
kubectl -n demo expose deployment echo --port=80

kubectl apply -f /root/k8s/config/gateway/httproute-example.yaml
kubectl -n demo get httproute echo-route
```
**ควรเห็น:** `PARENTS` ผูกกับ `myhr-gateway` และ `ACCEPTED=True`

**ทดสอบ hostname routing จากเครื่องนอก cluster:**
```bash
curl -I -H 'Host: echo.myhr.co.th' "http://${GW_IP}"          # ต้องได้ 200
curl -I -H 'Host: ไม่มีจริง.myhr.co.th' "http://${GW_IP}"      # ต้องได้ 404
```

**ทดสอบ HTTPS:**
```bash
curl -I --cacert /root/k8s/myhr-root-ca.crt \
     --resolve "echo.myhr.co.th:443:${GW_IP}" \
     https://echo.myhr.co.th
```
**ควรเห็น:** `HTTP/2 200` **ไม่มี** cert warning

> ถ้าเจอ `x509: certificate signed by unknown authority` แปลว่า root CA ไม่ถูกต้อง
> ถ้าเจอ `certificate is valid for ... not echo.myhr.co.th` แปลว่า `hostname` ใน Gateway
> ไม่ตรงกับที่ curl เรียก

**เก็บกวาด:**
```bash
kubectl delete ns demo
```

---

## 7 · บังคับ HTTPS

```bash
kubectl apply -f /root/k8s/config/gateway/https-redirect.yaml
```
ทำให้ทุก request ที่เข้ามาทาง HTTP ถูก redirect เป็น HTTPS อัตโนมัติ

**ตรวจ:**
```bash
curl -I -H 'Host: echo.myhr.co.th' "http://${GW_IP}"
```
**ควรเห็น:** `301 Moved Permanently` และ header `location: https://...`

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] Gateway API CRD ครบ (`standard-install`)
- [ ] cert-manager 3 deployment × 2 replica + PDB
- [ ] ClusterIssuer `myhr-internal-ca-issuer` **READY=True**
- [ ] Gateway `myhr-gateway` **PROGRAMMED=True** และมี `ADDRESS`
- [ ] curl HTTP เข้า Gateway IP จากนอก cluster ได้ (404 ถือว่าผ่าน)
- [ ] HTTPRoute ทดสอบทำงาน — host ถูกได้ 200 · host ผิดได้ 404
- [ ] HTTPS ผ่านโดยไม่มี cert warning (ด้วย `--cacert`)
- [ ] HTTP redirect ไป HTTPS
- [ ] **เอา root CA ไปลงเครื่อง client แล้ว** (หรือมี ticket ค้างอยู่)
- [ ] ลบ namespace `demo` แล้ว

> **จด IP ที่ Gateway ได้ไปลง DNS** — ต้องให้ทีม network ทำ record ชี้
> `*.myhr.co.th` (หรือรายตัว) มาที่ IP นี้ ไม่งั้นต้องใช้ `--resolve` ตลอดไป

**➡️ ต่อที่ [บทที่ 08 — Storage](08-storage.md)**
