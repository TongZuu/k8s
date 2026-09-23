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
| `deployment.yaml` | สำเนาของ `../zeeme-ads/deployment.yaml` (8 replica · กระจาย 3/3/2) **+ mount ConfigMap และรหัส DB จาก Secret** — แก้ image ต้องแก้ทั้งสองที่ |
| `configmap.yaml` | **แทน `application.properties`** — ค่าที่ต่างกันต่อ environment · ค่าในไฟล์เป็นตัวอย่าง ต้องแก้เป็น key จริงก่อน |
| `pdb.yaml` | สำเนาของ `../zeeme-ads/pdb.yaml` — `minAvailable: 50%` |
| `service.yaml` | **NodePort `30100` → 8100** · `externalTrafficPolicy: Local` |
| `networkpolicy.yaml` | เปิดขาเข้าพอร์ต 8100 ให้วง IP ของ client · **มี `<CLIENT_CIDR>` ต้องแทนก่อน** |

---

## 1 · ส่งโฟลเดอร์ขึ้น master01

**ทำที่:** เครื่องคุณ (Git Bash) ที่ root ของ repo · **ต้องมีก่อน:** VPN ต่ออยู่

```bash
cd /d/workspace/k8s && tar cf - deployments/zeeme-ads-nodeport | ssh root@192.168.50.101 'tar xf - -C /root/k8s && ls /root/k8s/deployments/zeeme-ads-nodeport'
```
**ควรเห็น:** `README.md  configmap.yaml  deployment.yaml  networkpolicy.yaml  pdb.yaml  service.yaml`

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

**แก้ `configmap.yaml` ให้เป็นค่าจริงของ zeeme-ads** (ค่าที่ให้มาเป็นตัวอย่าง — ดูหัวข้อ "ConfigMap" ข้างล่าง) แล้ว:

```bash
kubectl apply -f . && kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
kubectl -n myhr-prod get svc zeeme-ads
kubectl -n myhr-prod get pod -l app.kubernetes.io/name=zeeme-ads -o wide | awk 'NR>1{print $7}' | sort | uniq -c
```
**ควรเห็น:** `successfully rolled out` · Service `TYPE=NodePort` `PORT(S)=80:30100/TCP` ·
แล้วจำนวน pod ต่อ worker `3 / 3 / 2` (ครบทั้ง 3 worker — ถ้า worker ไหนไม่มี pod เครื่องนั้นจะไม่ตอบ NodePort)

## ConfigMap — แทน `application.properties` ใน jar

**ทำงานยังไง** — `configmap.yaml` ถูก mount เป็นไฟล์ `/config/application.properties` ใน pod และ env
`SPRING_CONFIG_ADDITIONAL_LOCATION=file:/config/` บอก Spring Boot ให้อ่านไฟล์นั้นเพิ่ม **ทับ**ค่าใน jar:

```
jar: application.properties        server.port=8100   app.ads.page-size=10   spring.datasource.url=jdbc:...dev
ConfigMap: /config/application.properties         app.ads.page-size=20   spring.datasource.url=jdbc:...prod
ผลที่แอปเห็น:                       server.port=8100   app.ads.page-size=20   spring.datasource.url=jdbc:...prod
```
key ที่ไม่อยู่ใน ConfigMap ใช้ค่าใน jar เหมือนเดิม — **ใส่เฉพาะค่าที่ต่างกันต่อ environment** (DB · URL ของ service อื่น · ขนาด pool)

**รหัสผ่านห้ามอยู่ใน ConfigMap** — ไม่ได้เข้ารหัส และ dev role อ่าน configmap ได้ · เขียนเป็น `${DB_PASSWORD}`
ใน properties แล้วค่าจริงมาจาก Secret `zeeme-ads-db` ทาง env (Spring แทนค่า `${...}` จาก environment ให้เอง)
· รหัสตัวอื่นทำแบบเดียวกัน: เพิ่ม key ใน Secret + เพิ่ม env ใน `deployment.yaml` + อ้าง `${ชื่อ}` ใน properties

**แก้ค่าทีหลัง** — Spring อ่าน properties ตอนเริ่มเท่านั้น apply อย่างเดียว pod ไม่เห็นค่าใหม่:
```bash
cd /root/k8s/deployments/zeeme-ads-nodeport
kubectl apply -f configmap.yaml && kubectl -n myhr-prod rollout restart deploy/zeeme-ads && kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```
**ควรเห็น:** `configmap/zeeme-ads-config configured` → `restarted` → `successfully rolled out`
(restart ทีละตัวตาม `maxUnavailable: 0` — service ไม่ดับ)

**ดูว่า pod เห็นไฟล์อะไรจริง:**
```bash
kubectl -n myhr-prod exec deploy/zeeme-ads -- cat /config/application.properties
```
(บัญชีที่ใช้ต้องมีสิทธิ์ `exec` — dev role ไม่มี · ใช้บน master01 ด้วย admin)

| อาการ | แปลว่า |
|---|---|
| pod ค้าง `CreateContainerConfigError` | Secret `zeeme-ads-db` ยังไม่มี — สร้างตามข้อ 3 |
| log ของแอปขึ้น `Could not resolve placeholder 'DB_PASSWORD'` | env `DB_PASSWORD` ไม่ถึง container — ตรวจชื่อ Secret/key ใน `deployment.yaml` |
| แก้ ConfigMap แล้วค่าไม่เปลี่ยน | ยังไม่ได้ `rollout restart` |
| แอปไม่อ่านไฟล์เลย (ค่ายังเป็นของ jar) | แอปเป็น Spring Boot 1.x ซึ่งไม่รู้จัก `SPRING_CONFIG_ADDITIONAL_LOCATION` — ใช้ `SPRING_CONFIG_LOCATION=classpath:/,file:/config/` แทน |

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
ถ้าจะใช้ ConfigMap กับชุด Gateway ด้วย ให้ยกส่วน "ConfigMap" 3 จุดใน `deployment.yaml` นี้ไปใส่ที่นั่นก่อน
