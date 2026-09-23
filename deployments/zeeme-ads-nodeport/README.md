# zeeme-ads แบบ NodePort — ทางเลือกแทน Gateway

> **ใช้ชุดนี้ หรือ [`../zeeme-ads/`](../zeeme-ads/) อย่างใดอย่างหนึ่ง — ห้าม apply ทั้งคู่**
> ชื่อ Deployment · Service · PDB ตรงกันทุกตัว apply ชุดไหนทีหลังก็ทับชุดก่อน

| | `zeeme-ads/` (Gateway) | `zeeme-ads-nodeport/` (ชุดนี้) |
|---|---|---|
| client เข้าทาง | `https://ads.myhr.co.th` → LB IP `192.168.50.200` | `http://<IP worker>:30100` |
| HTTPS | ✅ cert wildcard ที่ Gateway | ❌ HTTP ตรงเข้าแอป |
| worker ดับหรือถูก drain | Gateway ย้ายไป worker อื่นเอง | client ที่ชี้ IP เครื่องนั้นเข้าไม่ได้จนเครื่องกลับมา |
| NetworkPolicy | `allow-from-gateway` ของกลาง (บท 10) | `networkpolicy.yaml` ในโฟลเดอร์นี้ — เปิดเฉพาะวง IP ของ client |

| ไฟล์ | คือ |
|---|---|
| `deployment.yaml` | สำเนาของ `../zeeme-ads/deployment.yaml` (8 replica · กระจาย 3/3/2) **+ `envFrom` ConfigMap และรหัส DB จาก Secret** — แก้ image ต้องแก้ทั้งสองที่ |
| `configmap-prod.yaml` · `configmap-uat.yaml` | ค่า config ต่อ environment เป็น key-value (ชื่อ ConfigMap เดียวกัน `zeeme-ads-config` คนละ namespace) · ค่าในไฟล์เป็นตัวอย่าง |
| `pdb.yaml` | สำเนาของ `../zeeme-ads/pdb.yaml` — `minAvailable: 50%` |
| `service.yaml` | **NodePort `30100` → 8100** · `externalTrafficPolicy: Local` |
| `networkpolicy.yaml` | เปิดขาเข้าพอร์ต 8100 ให้วง IP ของ client · **มี `<CLIENT_CIDR>` ต้องแทนก่อน** |

---

## 1 · ส่งโฟลเดอร์ขึ้น master01

**ทำที่:** เครื่องคุณ (Git Bash) ที่ root ของ repo · **ต้องมีก่อน:** VPN ต่ออยู่

```bash
cd /d/workspace/k8s && tar cf - deployments/zeeme-ads-nodeport | ssh root@192.168.50.101 'tar xf - -C /root/k8s && ls /root/k8s/deployments/zeeme-ads-nodeport'
```
**ควรเห็น:** `README.md  configmap-prod.yaml  configmap-uat.yaml  deployment.yaml  networkpolicy.yaml  pdb.yaml  service.yaml`

## 2 · ตรวจของกลาง และตอบ 2 ค่า

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** บท 10 จบ (namespace `myhr-prod` · `regcred` · default-deny)

```bash
kubectl get ns myhr-prod && kubectl -n myhr-prod get secret regcred && kubectl -n myhr-prod get netpol
```
**ควรเห็น:** ns และ `regcred` มีอยู่ · netpol มี `default-deny-all` · `allow-dns-egress`

ค่า 2 ตัวที่ต้องรู้ก่อน apply:

| ค่า | อยู่ที่ | ถ้าไม่รู้ |
|---|---|---|
| **วง IP ของ client** ที่ต้องเรียก zeeme-ads | `networkpolicy.yaml` `<CLIENT_CIDR>` | ถามทีม network / เจ้าของระบบที่เรียก · ห้ามใส่ `0.0.0.0/0` |
| **เลข NodePort** | `service.yaml` `nodePort: 30100` | ถ้า client เดิมใช้เลขอื่น ดูบน cluster เก่า: `kubectl get svc zeeme-ads-service` คอลัมน์ `PORT(S)` เลขหลัง `:` |

**หา IP ของเครื่อง client ตามที่ cluster เห็นจริง** — รันจากเครื่อง client นั้น (ต้อง ssh เข้า node ได้):
```bash
ssh root@192.168.50.104 'echo $SSH_CLIENT' | cut -d' ' -f1
```
**ควรเห็น:** IP หนึ่งตัว — คือ IP ต้นทางที่ packet จากเครื่องนั้นมาถึง worker จริง (ผ่าน VPN/NAT แล้ว)
ซึ่งอาจ**ไม่ตรง**กับ `ipconfig` บนเครื่อง · ใช้เครื่องเดียว = ใส่ `<IP>/32` · หลายเครื่องใน VPN เดียวกัน =
ขอวง IP ที่ VPN แจก (VPN pool) จากทีม network แล้วใส่ทั้งวง

> คำถามเรื่อง actuator และชื่อ Service เดิม (`zeeme-ads-service`) ใน
> [`../zeeme-ads/README.md` ข้อ A2](../zeeme-ads/README.md) ใช้กับชุดนี้ด้วยเหมือนกัน — ตอบก่อน apply

## 3 · ใส่วง IP ของ client · สร้าง Secret รหัส DB · แล้ว apply

**ทำที่:** 👑 master01

```bash
cd /root/k8s/deployments/zeeme-ads-nodeport
read -rp 'วง IP ของ client (เช่น 10.212.0.0/16): ' C; [ -n "$C" ] && sed -i "s|<CLIENT_CIDR>|$C|" networkpolicy.yaml
grep -c '<CLIENT_CIDR>' networkpolicy.yaml; grep -n 'cidr:' networkpolicy.yaml
```
**ควรเห็น:** `0` แล้ว `cidr: <วงที่พิมพ์>` · ได้ `1` = ยังไม่ได้แทน ห้าม apply (apiserver จะปฏิเสธไฟล์ทั้งไฟล์)

**สร้าง Secret รหัสฐานข้อมูล** — ต้องมีก่อน apply ไม่งั้น pod ค้าง `CreateContainerConfigError`
(รหัสไม่อยู่ในไฟล์ใด ๆ ใน repo · พิมพ์ทางแป้นพิมพ์):
```bash
read -rsp 'รหัส DB ของ zeeme-ads: ' P; echo " (รับมา ${#P} ตัว)"
kubectl -n myhr-prod create secret generic zeeme-ads-db --from-literal=password="$P" --dry-run=client -o yaml | kubectl apply -f -; unset P
```
**ควรเห็น:** `(รับมา N ตัว)` ที่ N ไม่เป็น 0 · แล้ว `secret/zeeme-ads-db created`

**แก้ `configmap-prod.yaml` ให้เป็นค่าจริงของ zeeme-ads** (ค่าที่ให้มาเป็นตัวอย่าง — ดูหัวข้อ "ConfigMap" ข้างล่าง) แล้ว:

```bash
kubectl apply -f configmap-prod.yaml -f deployment.yaml -f pdb.yaml -f service.yaml -f networkpolicy.yaml \n  && kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
kubectl -n myhr-prod get svc zeeme-ads
kubectl -n myhr-prod get pod -l app.kubernetes.io/name=zeeme-ads -o wide | awk 'NR>1{print $7}' | sort | uniq -c
```
**ควรเห็น:** `successfully rolled out` · Service `TYPE=NodePort` `PORT(S)=80:30100/TCP` ·
แล้วจำนวน pod ต่อ worker `3 / 3 / 2` (ครบทั้ง 3 worker — ถ้า worker ไหนไม่มี pod เครื่องนั้นจะไม่ตอบ NodePort)

## ConfigMap — ค่า config แยก uat / prod

**ทำงานยังไง** — `deployment.yaml` ใช้ `envFrom` ดึง**ทุก key** ใน ConfigMap `zeeme-ads-config` เป็น environment
variable แล้ว Spring Boot อ่าน env ทับค่าใน `application.properties` ของ jar ให้เอง (relaxed binding):

```
jar: application.properties     spring.datasource.url=jdbc:...dev    app.ads.page-size=10
configmap-prod.yaml             SPRING_DATASOURCE_URL: jdbc:...prod  APP_ADS_PAGESIZE: "20"
แอปเห็น                          spring.datasource.url=jdbc:...prod   app.ads.page-size=20
```
key ที่ไม่อยู่ใน ConfigMap ใช้ค่าใน jar เหมือนเดิม — **ใส่เฉพาะค่าที่ต่างกันต่อ environment**

**ตั้งชื่อ key** — เอาชื่อ property มาทำตัวใหญ่ · `.` เป็น `_` · ตัด `-` ทิ้ง:

| ใน `application.properties` | key ใน ConfigMap |
|---|---|
| `spring.datasource.url` | `SPRING_DATASOURCE_URL` |
| `server.port` | `SERVER_PORT` |
| `app.ads.page-size` | `APP_ADS_PAGESIZE` |

ค่าทุกตัวต้องเป็นข้อความในเครื่องหมายคำพูด (`"20"` ไม่ใช่ `20`) — ตัวเลขไม่ครอบ apply จะไม่ผ่าน

**uat กับ prod** — สองไฟล์ใช้ชื่อ ConfigMap เดียวกัน (`zeeme-ads-config`) แต่อยู่คนละ namespace
(`myhr-uat` / `myhr-prod`) Deployment ใน namespace ไหนก็อ่านตัวที่อยู่ namespace นั้นเอง · **key ต้องชุดเดียวกัน**
ต่างกันแค่ค่า — key ที่มีใน uat แต่ลืมใส่ใน prod จะตกไปใช้ค่าใน jar เงียบ ๆ

**รหัสผ่านห้ามอยู่ใน ConfigMap** — ไม่ได้เข้ารหัส และ dev role อ่าน configmap ได้ · รหัส DB มาจาก Secret
`zeeme-ads-db` เข้า env `SPRING_DATASOURCE_PASSWORD` ตรง ๆ (ดู `env:` ใน `deployment.yaml`)
· รหัสตัวอื่นทำแบบเดียวกัน: เพิ่ม key ใน Secret + เพิ่ม env ใน `deployment.yaml`

**แก้ค่าทีหลัง** — env ถูกอ่านตอน container เริ่มเท่านั้น apply อย่างเดียว pod ไม่เห็นค่าใหม่:
```bash
cd /root/k8s/deployments/zeeme-ads-nodeport
kubectl apply -f configmap-prod.yaml && kubectl -n myhr-prod rollout restart deploy/zeeme-ads && kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```
**ควรเห็น:** `configmap/zeeme-ads-config configured` → `restarted` → `successfully rolled out`
(restart ทีละตัวตาม `maxUnavailable: 0` — service ไม่ดับ)

**ดูว่า pod ได้ค่าอะไรจริง:**
```bash
kubectl -n myhr-prod exec deploy/zeeme-ads -- env | grep -E '^(SPRING|APP|LOGGING)_' | grep -v PASSWORD
```
(ต้องมีสิทธิ์ `exec` — dev role ไม่มี · ใช้บน master01 ด้วย admin · `grep -v PASSWORD` กันรหัสขึ้นจอ)

| อาการ | แปลว่า |
|---|---|
| pod ค้าง `CreateContainerConfigError` | Secret `zeeme-ads-db` หรือ ConfigMap `zeeme-ads-config` ยังไม่มีใน namespace นั้น |
| แก้ ConfigMap แล้วค่าไม่เปลี่ยน | ยังไม่ได้ `rollout restart` |
| ค่าบางตัวยังเป็นของ jar | ชื่อ key ไม่ตรงกฎข้างบน (เช่นยังมี `-` หรือตัวเล็ก) — Spring หา property ไม่เจอเลยข้ามไป |

## 4 · ทดสอบจากเครื่อง client จริง

**ทำที่:** เครื่องที่อยู่ในวง `<CLIENT_CIDR>` — **ไม่ใช่ node ของ cluster** (ยิงจาก node ไม่ผ่าน policy ข้อนี้เลย)

```bash
for ip in 104 105 106; do curl -s -o /dev/null -m 5 -w "worker .$ip → %{http_code}\n" http://192.168.50.$ip:30100/actuator/health; done
```
**ควรเห็น:** `200` ครบทั้ง 3 worker

| ได้ | แปลว่า |
|---|---|
| `000` ทุกเครื่อง | policy ไม่เปิดให้วงนี้ (client ไม่ได้อยู่ใน `<CLIENT_CIDR>` ที่ใส่) · หรือเครื่อง client วิ่งไม่ถึงวง `192.168.50.0/24` |
| `000` บางเครื่อง | worker นั้นไม่มี pod ของ zeeme-ads (`externalTrafficPolicy: Local`) — ดูข้อ 3 บรรทัดนับ pod |
| `404` | ถึงแอปแล้ว แต่แอปไม่มี `/actuator/health` — เปลี่ยน path เป็น endpoint ที่มีจริง |

ดูว่า policy ทิ้งหรือเปล่า ([บท 10 ข้อ 3.4](../../docs/10-security.md)) — รันบน master01 ทันทีหลังยิง:
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --namespace myhr-prod --to-port 8100 --since 2m 2>/dev/null
done
```
`Policy denied DROPPED` + IP ต้นทางของ client = วงใน `<CLIENT_CIDR>` ไม่ครอบเครื่องนั้น

## 5 · ย้ายกลับไปใช้ Gateway

**ทำที่:** 👑 master01

```bash
kubectl -n myhr-prod delete netpol allow-zeeme-ads-nodeport
kubectl apply -f /root/k8s/deployments/zeeme-ads/
```
Service `zeeme-ads` จะถูกทับกลับเป็น ClusterIP — client ที่ยังยิง `:30100` จะเข้าไม่ได้ทันที แจ้งก่อนทำ

⚠️ `deployment.yaml` ของชุด Gateway **ยังไม่มี** ConfigMap/Secret — apply กลับแล้วแอปจะกลับไปใช้ค่าใน jar
ถ้าจะใช้ ConfigMap กับชุด Gateway ด้วย ให้ยก `envFrom` และ env `SPRING_DATASOURCE_PASSWORD` ใน `deployment.yaml` นี้ไปใส่ที่นั่นก่อน
