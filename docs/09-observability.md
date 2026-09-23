# บทที่ 09 — Observability

> **รันที่: 👑 master01 เกือบทั้งบท** · ยกเว้นที่บอกไว้: ค่าลับ (รหัส Grafana ข้อ 2 · รหัส SMTP ข้อ 5.1 พิมพ์ทางแป้นพิมพ์)
> อยู่ใน `secrets.env` บน**เครื่องคุณ** ส่งขึ้นทีละค่า · เปิด Grafana ในเบราว์เซอร์ (ข้อ 4) ทำบน**เครื่องคุณ**
> · ข้อ 7 มี `ssh` ไป worker03
> **ลำดับ: 1 → 8 ตามลำดับ** — ข้อ 5 (ปลายทาง alert) ต้องเสร็จและยิงทดสอบผ่านก่อนข้อ 6 (rule) เสมอ
> **เวลาที่ใช้:** ~45 นาที · เตรียมรหัส SMTP ของ `myhr-notification` กับที่อยู่ผู้รับ alert ไว้ก่อนเริ่มบท
> **ต้องผ่านบทที่ 08** — PV ทั้ง 3 ตัวต้องเป็น `Available` · และ[บท 07](07-gateway-tls.md) — ข้อ 4 ใช้ Gateway เปิด Grafana

---

## ทำไมบทนี้จำเป็น ไม่ใช่ของฟุ่มเฟือย

cluster เดิมไม่มี metric ย้อนหลังเลย ทำให้ตอบคำถาม **"เมื่อคืนตอนตีสามเกิดอะไรขึ้น"**
ไม่ได้ และเมื่อตอบไม่ได้ก็แก้ที่ต้นเหตุไม่ได้ — วนกลับมาเจอปัญหาเดิมซ้ำ

**และสำหรับ cluster ชุดนี้มีเหตุผลเพิ่มอีกข้อ:** เราไม่มี Ksplice จึงต้อง drain node
ทุก 1-2 เดือน ถ้าไม่มี alert เตือนว่า Deployment ไหนไม่มี PDB หรือ capacity ใกล้เต็ม
วันที่ patch จริงจะกลายเป็นวันที่ service ล่ม

---

## 1 · metrics-server

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** `helm` ใช้ได้ · เครื่องออก `github.io` ได้ · ไม่ต้องใช้ PV

ตัวนี้ไม่เก็บข้อมูลย้อนหลัง แค่ป้อนตัวเลขปัจจุบันให้ `kubectl top` และ HPA
**ไม่ต้องใช้ storage**

```bash
set -a && source /root/k8s/versions.env && set +a

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version "${METRICS_SERVER_CHART}" \
  --set replicas=2 \
  --set 'args={--kubelet-preferred-address-types=InternalIP,--kubelet-insecure-tls}'

kubectl -n kube-system rollout status deploy/metrics-server --timeout=3m
```

**ตรวจ — รอ ~60 วินาทีให้เก็บ metric รอบแรกก่อน:**
```bash
kubectl top nodes
kubectl top pods -A | head
```
**ควรเห็น:** ตัวเลข CPU/MEM ของทั้ง 6 node ไม่มี `<unknown>`

> 🔴 **`--kubelet-insecure-tls` ห้ามตัดออก** — ยืนยันบน cluster จริง 4 ก.ย. 2026
> ลงโดยไม่มี flag นี้แล้วได้ `metrics-server 0/1 Running` ค้างถาวร และ `kubectl top`
> ตอบ `error: Metrics API not available` โดย log ขึ้นเหมือนกันครบทั้ง 6 เครื่อง:
> `x509: cannot validate certificate for 192.168.50.105 because it doesn't contain any IP SANs`
>
> สาเหตุคือ kubelet ที่ไม่ได้ถูกบอกว่าให้ใช้ cert ใบไหน จะเซ็นใบให้ตัวเองโดยใส่แค่ชื่อ node
> ไม่ใส่ IP — **เป็นพฤติกรรมเริ่มต้นของ kubeadm ไม่ใช่ความผิดของค่าใน repo นี้**
>
> ราคาที่จ่าย: metrics-server ไม่ตรวจ cert ของ kubelet เลย กระทบแค่ `kubectl top` กับ HPA
> เป็นหนี้ที่ตั้งใจก่อ บันทึกพร้อมทางปลดไว้ที่ [CHECKLIST หัวข้อ C2](CHECKLIST.md) แล้ว

---

## 2 · kube-prometheus-stack

**ทำที่:** 👑 master01 · ยกเว้น "ทางที่ 2" ของการแทนรหัสซึ่งรันจาก**เครื่องคุณ** (PowerShell ที่ root ของ repo)
· **ต้องมีก่อน:** ข้อ 1 · PV `prometheus-data` และ `grafana-data` เป็น `Available` ([บท 08](08-storage.md))
· **โฟลเดอร์ `/var/lib/monitoring/{prometheus,loki,grafana}` มีอยู่บน worker03 จริง** ([บท 08 ข้อ 1](08-storage.md) —
PV `Available` ไม่ได้พิสูจน์ข้อนี้)
· `secrets.env` บนเครื่องคุณมี `GRAFANA_ADMIN_PASSWORD` · firewalld เปิด `9100` ทุกเครื่องและ `2381` บน master
([บท 01 ข้อ 8](01-prepare-os.md) — ไม่งั้น target จะ `down`)

ชุดนี้รวม Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics
มาให้ในครั้งเดียว

**🔴 แทนค่า `<GRAFANA_ADMIN_PASSWORD>` ก่อน ไม่งั้นรหัส admin จะเป็นข้อความนั้นตรงตัว**

รหัสจริง 24 ตัวอยู่ที่ **`secrets.env` บนเครื่องของคุณ** คีย์ `GRAFANA_ADMIN_PASSWORD`
(และในที่เก็บ secret ขององค์กรตาม [CHECKLIST ข้อ B](CHECKLIST.md))

> **`secrets.env` ไม่เคยถูก `scp` ขึ้น cluster และห้ามส่งขึ้นไป** — ในไฟล์เดียวกันนั้นมี
> `ENCRYPTION_KEY_BASE64` ซึ่งหลุดเมื่อไรเท่ากับ etcd backup ทุกก้อนถูกถอดได้ตลอดกาล
> ค่าที่ต้องใช้บน master01 จึงส่งเป็นราย ๆ ไป ไม่ใช่ส่งทั้งไฟล์ — เหมือนบท 03 และ 10

**ทางที่ 1 · พิมพ์มือบน master01** — พิมพ์แล้วกด Enter บรรทัดที่เหลือรันต่อเอง
```bash
read -rsp 'Grafana admin password: ' GFPW && echo "รับมา ${#GFPW} ตัวอักษร"

if [ -z "$GFPW" ]; then
    echo "❌ ไม่ได้พิมพ์อะไรเลย — ไม่แตะไฟล์ ให้รันบล็อกนี้ใหม่"
else
    sed -i "s|<GRAFANA_ADMIN_PASSWORD>|${GFPW}|" /root/k8s/config/monitoring/kube-prometheus-values.yaml
fi
unset GFPW
```
**ควรเห็น:** `รับมา 24 ตัวอักษร` — ถ้าได้ `0` ให้รันบล็อกใหม่ ไฟล์ยังไม่ถูกแตะ

**ทางที่ 2 · ส่งจากเครื่องของคุณ ไม่ต้องพิมพ์** — รันที่ root ของ repo **บนเครื่องของคุณ**
(PowerShell · ไม่ใช่บน master01) รหัสไปทาง stdin จึงไม่โผล่ใน `ps` และไม่ตกค้างใน history ของ master01
```bash
$pw = (Select-String -Path secrets.env -Pattern '^GRAFANA_ADMIN_PASSWORD=').Line -replace '^GRAFANA_ADMIN_PASSWORD=',''
$pw | ssh root@192.168.50.101 'read -r P; P=${P%$''\r''}; if [ -z "$P" ]; then echo "❌ ไม่ได้ค่ามา ไม่แตะไฟล์"; exit 1; fi; sed -i "s|<GRAFANA_ADMIN_PASSWORD>|${P}|" /root/k8s/config/monitoring/kube-prometheus-values.yaml; echo "แทนค่าแล้ว ${#P} ตัวอักษร"'
```
**ควรเห็น:** `แทนค่าแล้ว 24 ตัวอักษร`

> `P=${P%$'\r'}` ตัด CR ท้ายบรรทัดที่ Windows แถมมาให้ตอน pipe — ถ้าไม่ตัด รหัสจะยาว 25 ตัว
> โดยมีอักขระที่มองไม่เห็นต่อท้าย แล้วจะเข้า Grafana ไม่ได้ทั้งที่ตัวเลขความยาวดูเกือบถูก
> · ใช้ Git Bash แทนได้: `set -a; source secrets.env; set +a` แล้ว
> `printf '%s' "$GRAFANA_ADMIN_PASSWORD" | ssh ...` ท่อนหลังเหมือนกัน

**ตรวจค่าที่ลงไปจริง — ไม่ใช่แค่ดูว่า placeholder หายแล้ว** (บน master01 ทั้งสองทาง)
```bash
awk -F'"' '/adminPassword:/{print "adminPassword ยาว " length($2) " ตัว"}' /root/k8s/config/monitoring/kube-prometheus-values.yaml
```
**ควรเห็น:** `adminPassword ยาว 24 ตัว`

> ⚠️ **ห้ามเช็กด้วย `grep -c 'GRAFANA_ADMIN_PASSWORD'` อย่างเดียว** — ถ้ารหัสที่รับมาเป็นค่าว่าง
> `sed` จะเขียนค่าว่างทับ placeholder ผลคือ placeholder หายไปเหมือนตอนสำเร็จทุกประการ
> แต่ค่าที่ได้คือ `adminPassword: ""` ซึ่งเข้า Grafana ไม่ได้ และ**แก้ซ้ำไม่ได้เพราะไม่มี
> placeholder เหลือให้แทนแล้ว** ต้องเอาไฟล์ต้นฉบับมาทับก่อนแล้วทำข้อนี้ใหม่:
> `scp config/monitoring/kube-prometheus-values.yaml root@192.168.50.101:/root/k8s/config/monitoring/`
>
> ถ้ารหัสมีอักขระ `|` ให้แก้ด้วย editor แทน — `sed` ใช้ `|` เป็นตัวคั่นในคำสั่งข้างบน

> เปลี่ยนผ่านหน้าเว็บ Grafana ทีหลังไม่พอ — chart ส่งค่านี้เป็น `GF_SECURITY_ADMIN_PASSWORD`
> ซึ่ง**เขียนทับรหัสใน DB ทุกครั้งที่ pod start** ต้องแก้ที่ values เท่านั้นถึงจะอยู่ถาวร

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version "${KUBE_PROM_STACK_CHART}" \
  -f /root/k8s/config/monitoring/kube-prometheus-values.yaml
```
**ควรเห็น:** `STATUS: deployed` · `DESCRIPTION: Install complete` (NOTES ยาว ๆ ข้างล่างไม่ต้องทำตาม — คู่มือนี้ครอบแล้ว)

**รอ Prometheus ขึ้น** — Operator เป็นคนสร้าง StatefulSet ให้**หลัง** helm จบไม่กี่วินาที
ถ้า `rollout status` ทันทีจะได้ `NotFound` ทั้งที่ไม่มีอะไรพัง (เจอจริง 19 ก.ย. 2026) บล็อกนี้รอให้มันโผล่ก่อน:
```bash
STS=prometheus-monitoring-kube-prometheus-prometheus
until kubectl -n monitoring get sts "$STS" >/dev/null 2>&1; do echo "รอ Operator สร้าง $STS ..."; sleep 5; done
kubectl -n monitoring rollout status statefulset/"$STS" --timeout=10m
```
**ควรเห็น:** `statefulset rolling update complete 1 pods at revision ...` (ครั้งแรก 2-5 นาที ดึง image)

**ตรวจ PV ผูกถูกตัว — ต้องดูคู่ ไม่ใช่ดูแค่คำว่า `Bound`:**
```bash
kubectl -n monitoring get pvc -o custom-columns=NAME:.metadata.name,VOL:.spec.volumeName,SIZE:.spec.resources.requests.storage
```
**ควรเห็น:** PVC ของ Prometheus ผูกกับ `prometheus-data` และของ Grafana ผูกกับ `grafana-data`

> 🔴 **ดูแค่ `Bound` ไม่พอ** — ก่อนที่ PV จะมี `claimRef` ทุกก้อน PVC สามารถขึ้น `Bound` ครบ
> ได้ทั้งที่**ผูกผิดก้อน** (Grafana ไปนอนบน PV 150Gi ของ Prometheus) จึงต้องดูคอลัมน์ `VOL` เสมอ
>
> ถ้า pod `grafana` / `prometheus-...-0` ค้าง **`Init:0/1`** เกิน 5 นาทีทั้งที่ PVC `Bound` ถูกก้อน:
> `kubectl -n monitoring describe pod prometheus-monitoring-kube-prometheus-prometheus-0 | tail -5`
> เห็น `FailedMount ... path "/var/lib/monitoring/prometheus" does not exist` = โฟลเดอร์บน worker03 ยังไม่ได้สร้าง
> (เจอจริง 20 ก.ย. 2026) → ทำ[บท 08 ข้อ 1](08-storage.md) แล้วรอ — kubelet ลอง mount ใหม่เองทุก ~2 นาที ไม่ต้องลบ pod
>
> ถ้า PVC ค้าง `Pending` ให้ดู `kubectl -n monitoring describe pvc <ชื่อ>` —
> เมื่อมี `claimRef` แล้ว สาเหตุที่เหลืออยู่คือ**ชื่อ PVC ไม่ตรงกับที่จองไว้** ใน
> `config/storage/monitoring-pv.yaml` ให้เอาชื่อจริงจากคำสั่งข้างบนไปแก้ในไฟล์นั้น

**ตรวจว่า Alertmanager แยกเครื่องกันจริง:**
```bash
kubectl -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o wide
```
**ควรเห็น:** 2 pod อยู่**คนละ node** — ถ้าอยู่เครื่องเดียวกันแปลว่า `podAntiAffinity` ไม่ทำงาน
และ drain เครื่องเดียวจะดับ Alertmanager ทั้งคู่

> **Alertmanager ไม่มี PV โดยตั้งใจ** มันเก็บแค่ silence กับสถานะการส่ง และ replica
> คุยกันผ่าน gossip อยู่แล้ว ตัวที่ restart จะ sync กลับจาก peer เอง — ถ้าให้มันใช้
> local PV จะถูกตรึงไว้ที่ worker03 ทั้งคู่ ซึ่งทำลายเหตุผลที่ตั้ง `replicas: 2` ตั้งแต่แรก

```bash
kubectl -n monitoring get pods
```
**ควรเห็น:** ทุก pod `Running` · `node-exporter` ต้องมี **6 ตัว** (ครบทุก node)

**ตรวจว่า Prometheus scrape ได้จริง:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | "\(.health)  \(.labels.job)"' | sort | uniq -c
kill %%
```
**ควรเห็น:** ทุกบรรทัดเป็น `up`

**ถ้ามี `down` เอาสาเหตุจริงมาก่อน อย่าเดา:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.health=="down") | "\(.labels.job)  \(.scrapeUrl)  \(.lastError)"' | sort -u
kill %%
```

> 🔴 **`lastError` แยกสองสาเหตุออกจากกันได้ทันที**
> · `no route to host` = **firewalld ปิดพอร์ตอยู่** — เปิดตาม [บทที่ 01 ข้อ 8](01-prepare-os.md)
>   (`9100` node-exporter ทุกเครื่อง · `2381` etcd metrics บน master)
> · `connection refused` = ถึงเครื่องแล้วแต่ component **bind อยู่ที่ `127.0.0.1`**
>
> `kubeadm-config.yaml` ตั้ง `bind-address: 0.0.0.0` และ `listen-metrics-urls` ไว้ให้แล้ว
> ถ้ายังเจอ แปลว่า cluster นี้สร้างก่อนที่ไฟล์นั้นจะมีค่าดังกล่าว ต้องแก้
> `/etc/kubernetes/manifests/` บน master เอง **ทีละเครื่อง รอ `Running` ก่อนไปเครื่องถัดไป**
> เพราะการแก้ `etcd.yaml` ทำให้ etcd ของเครื่องนั้น restart — พร้อมกัน 3 เครื่องคือเสีย quorum

---

## 3 · Loki + Alloy (รวม log)

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 2 (namespace `monitoring` และ Grafana มีแล้ว — Loki จะถูกเพิ่มเป็น
data source ให้เอง) · PV `loki-data` เป็น `Available`

pod ตายแล้ว log หายไปด้วยถ้าไม่มีที่รวม

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update
```

```bash
helm install loki grafana/loki \
  --namespace monitoring \
  --version "${LOKI_CHART}" \
  -f /root/k8s/config/monitoring/loki-values.yaml

helm install alloy grafana/alloy \
  --namespace monitoring \
  --version "${ALLOY_CHART}" \
  -f /root/k8s/config/monitoring/alloy-values.yaml

kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
kubectl -n monitoring get ds -l app.kubernetes.io/name=alloy
```
**ควรเห็น:** Loki `Running` และ Alloy DaemonSet `6/6`

### 🔴 ตรวจว่า Alloy ไม่ได้เก็บ log ซ้ำ — ห้ามข้ามข้อนี้

Alloy รันเป็น DaemonSet 6 ตัว ถ้า `discovery.kubernetes` ไม่กรอง node **ทุกตัวจะเก็บ log
ของ pod ทั้ง cluster เหมือนกันหมด** ผลคือทุกบรรทัดเข้า Loki 6 ครั้ง — PV หมดเร็วกว่าที่
คำนวณไว้ 6 เท่า ชนเพดาน ingestion เร็วกว่า 6 เท่า และหน้าจอ log อ่านไม่รู้เรื่อง

`config/monitoring/alloy-values.yaml` กรองไว้แล้วด้วย `selectors` ที่อ่านค่าจาก `NODE_NAME`
แต่ต้องยืนยันว่ามันถูกส่งเข้าไปจริง:

```bash
kubectl -n monitoring get ds alloy -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NODE_NAME")]}'; echo
```
**ควรเห็น:** JSON ที่มี `fieldPath: spec.nodeName` — ถ้าได้ค่าว่าง แปลว่า `extraEnv` ไม่ได้ถูก
apply แล้ว `selectors` จะกลายเป็น `spec.nodeName=` ซึ่งไม่ match อะไรเลย → **ไม่มี log เข้า Loki
แม้แต่บรรทัดเดียว** (จะดังผ่าน alert `LokiNotReceivingLogs` ในข้อ 6)

**แล้วยืนยันจากข้อมูลที่เข้า Loki จริง** — ขั้นเข้า Grafana อยู่ข้อ 4 ซึ่งยังมาไม่ถึง
จึงถาม Loki ตรง ๆ ว่ามีบรรทัดไหนซ้ำไหม (`auth_enabled: false` จึงไม่ต้องใส่ header):

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100 >/dev/null 2>&1 &
sleep 3
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="kube-system", container="cilium-agent"}' \
  --data-urlencode 'limit=200' \
  | jq -r '.data.result[].values[] | @tsv' | sort | uniq -c \
  | awk '{n++} $1>1{d++} END{print "บรรทัดทั้งหมด " n+0 " · ซ้ำ " d+0}'
kill %%
```
**ควรเห็น:** `บรรทัดทั้งหมด 200 · ซ้ำ 0` (เลขแรกอาจน้อยกว่า 200 ถ้า cluster เพิ่งขึ้น — ขอแค่ไม่เป็น 0)

| ได้ | แปลว่า |
|---|---|
| `ซ้ำ` ไม่เป็น 0 (มักเป็นทุกบรรทัด × 6) | Alloy ทั้ง 6 ตัวเก็บ log ชุดเดียวกัน → กลับไปดู `NODE_NAME` ข้างบน |
| `บรรทัดทั้งหมด 0` | ยังไม่มี log เข้า Loki เลย — คนละปัญหา · รอ 1-2 นาทีแล้วรันซ้ำ ยัง 0 → `kubectl -n monitoring logs ds/alloy --tail=20` |

> คำสั่งเดิมพิมพ์เฉพาะบรรทัดที่ซ้ำ ผลว่างจึงแปลได้ทั้ง "ผ่าน" และ "ไม่มี log" — นับให้เห็นทั้งสองค่าแทน (19 ก.ย. 2026)

---

## 4 · เข้า Grafana

**ทำที่:** ดึงรหัส · apply route · `curl` ตรวจ บน 👑 master01 — **เปิดเบราว์เซอร์ทำบนเครื่องคุณ** (หัวข้อย่อยข้างล่าง)
· **ต้องมีก่อน:** ข้อ 2-3 ทุก pod `Running` · [บท 07](07-gateway-tls.md) จบ — Gateway `myhr-gateway` มี `ADDRESS`
และ cert ครอบ `grafana.myhr.co.th` (wildcard ครอบ)

**รหัส admin** — ตัวที่ใส่ไว้ตั้งแต่ข้อ 2:
```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

> 🔴 **ถ้าได้ `<GRAFANA_ADMIN_PASSWORD>` ออกมาตรง ๆ** แปลว่าข้ามขั้นแทนค่าในข้อ 2 ไป
> **รหัส admin ของ Grafana คือข้อความนั้นจริง ๆ** ย้อนไปทำแล้ว `helm upgrade`
>
> **ถ้าได้บรรทัดว่าง** แปลว่าตอนแทนค่าในข้อ 2 รับค่าว่างมา (`adminPassword: ""`)
> ต้อง `scp` ไฟล์ values ต้นฉบับมาทับ ทำข้อ 2 ใหม่ แล้ว `helm upgrade` — วิธีเดียวกัน
> เปลี่ยนผ่านหน้าเว็บอย่างเดียวไม่พอ — chart ส่งค่านี้เป็น `GF_SECURITY_ADMIN_PASSWORD`
> ซึ่งเขียนทับรหัสใน DB ทุกครั้งที่ pod start

**เปิด route:**
```bash
kubectl apply -f /root/k8s/config/monitoring/grafana-route.yaml
```

**ตรวจจาก master01 ว่า Gateway ทำงาน** — ขั้นนี้คือ*การตรวจ* ไม่ใช่วิธีเข้าใช้งาน:
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
curl -I --resolve "grafana.myhr.co.th:443:${GW_IP}" https://grafana.myhr.co.th
```
**ควรเห็น:** `HTTP/2 302` และ `location: /login`

> `--resolve` บอกคู่ชื่อ→IP ให้ curl รู้เฉพาะครั้งนั้นครั้งเดียว **เบราว์เซอร์ไม่รู้เรื่องด้วย**
> ผ่านตรงนี้จึงแปลว่า Gateway + route + cert ถูกต้อง ยังไม่ได้แปลว่าผู้ใช้เปิดได้
>
> ถ้า cert มาจาก internal CA (บทที่ 07 ทาง B) เพิ่ม `--cacert /root/k8s/myhr-root-ca.crt`

---

### เปิดจริงในเบราว์เซอร์ — ทำบนเครื่องของคุณ ไม่ใช่ master01

**1 · ให้ชื่อแปลงเป็น IP ได้** — ให้ DNS ขององค์กรชี้ `grafana.myhr.co.th` ไปที่ `GW_IP`
หรือใส่ hosts เองก่อนระหว่างทดสอบ (Windows: เปิด Notepad แบบ **Run as administrator**
แล้วแก้ `C:\Windows\System32\drivers\etc\hosts`)
```
192.168.50.200  grafana.myhr.co.th
```

**2 · เครื่องต้องวิ่งถึง IP นั้นได้จริง:**
```bash
Test-NetConnection 192.168.50.200 -Port 443
```
**ควรเห็น:** `TcpTestSucceeded : True` — แล้วเปิด `https://grafana.myhr.co.th` ได้เลย user `admin`

> 🔴 **ถ้าได้ `False`** ให้ไปดู [บทที่ 01 — เปิดให้ forward เข้าวง pod](01-prepare-os.md) ก่อนอย่างอื่น
> เป็นสาเหตุอันดับหนึ่ง และเป็นข้อที่ทุกอย่างฝั่งคลัสเตอร์จะขึ้นเขียวหมดทั้งที่เข้าไม่ได้
> · `PingSucceeded: False` อย่างเดียวไม่ได้แปลว่าพัง ICMP อาจถูกปิดไว้ ให้ดู `TcpTestSucceeded`

**ทางสำรอง — ใช้ได้เสมอ ไม่ต้องพึ่ง Gateway, DNS หรือ firewall** รันบนเครื่องของคุณ:
```bash
ssh -L 3000:127.0.0.1:3000 root@192.168.50.101 'kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80'
```
ค้างหน้าต่างนั้นไว้ แล้วเปิด `http://localhost:3000`

---

**ตรวจ dashboard ที่ควรใช้ได้เลย:**
- `Kubernetes / Compute Resources / Cluster`
- `Kubernetes / Compute Resources / Namespace (Pods)`
- `Node Exporter / Nodes`

**เพิ่ม Loki เป็น data source** (chart ตั้งให้อัตโนมัติถ้าใช้ values ที่ให้มา)
แล้วลองค้น log:
```
{namespace="kube-system"} |= "error"
```

---

## 5 · 🔴 ตั้งปลายทางของ alert — ทำก่อนเขียน rule

**ทำที่:** 5.0 จาก**เครื่องคุณ** · 5.1 → 5.4 บน 👑 master01 ตามลำดับ · **ต้องมีก่อน:** ข้อ 2 (Alertmanager มาพร้อม chart)
· user/รหัส SMTP ของบัญชี `myhr-notification@myhr.in.th` (อยู่ใน `secrets.env` หรือที่เก็บ secret ขององค์กร)
· ที่อยู่ผู้รับ alert ทั่วไป และผู้รับ critical (ใช้ที่อยู่เดียวกันก็ได้ถ้ายังไม่มีกลุ่ม on-call)

**alert ที่ไม่มีใครเห็น = ไม่มี alert** — ข้อนี้ต้องจบ**ก่อน**ข้อ 6 เพราะ rule ที่ไม่มีปลายทางก็ดังลงที่ว่าง

**เส้นทางที่ใช้ — ชุดเดียวกับที่ใช้ได้จริงรอบก่อน:**

```
Alertmanager ──webhook──▶ alert-mail-relay (pod ใน monitoring) ──SMTP AUTH พอร์ต 25──▶ mail.myhr.in.th ──▶ กล่องเมล
```

ส่งตรงจาก Alertmanager ไม่ได้ เพราะ relay ขององค์กรบังคับล็อกอินและพอร์ต 25 ไม่มี STARTTLS —
Alertmanager ไม่ยอมส่งรหัสบนช่องไม่เข้ารหัส · `alert-mail-relay` (Python `smtplib`) ส่งแทน
ค่า relay กับผู้ส่งตั้งไว้ในrepoแล้ว ([`alert-mail-relay.yaml`](../deployments/alert-mail-relay/alert-mail-relay.yaml))
ส่วน `alertmanager-config.yaml` ชี้ webhook มาที่ตัวกลางไว้แล้ว · เหลือแค่รหัสกับผู้รับ

> วันที่ได้พอร์ตที่มี STARTTLS และจะเลิกใช้ตัวกลาง → **ภาคผนวก · ส่งเมลตรงจาก Alertmanager** ท้ายบท

### 5.0 ส่งไฟล์ของตัวกลางขึ้น master01 — จากเครื่องคุณ

`deployments/` **ไม่ได้อยู่ในชุดที่ sync ตอน[บท 00](00-overview.md)** (ชุดนั้นมีแค่ `versions.env` กับ `config/`)
จึงต้องส่งเองก่อน 5.2 · ส่ง `alertmanager-config.yaml` ไปพร้อมกันด้วย เผื่อบนเครื่องยังเป็นชุดเก่า

**จากเครื่องคุณ** ที่ root ของ repo (Git Bash — WSL ใช้ `/mnt/d/...`):
```bash
cd /d/workspace/k8s
ssh root@192.168.50.101 'mkdir -p /root/k8s/deployments /root/k8s/config/monitoring'
scp -r deployments/alert-mail-relay root@192.168.50.101:/root/k8s/deployments/
scp config/monitoring/alertmanager-config.yaml root@192.168.50.101:/root/k8s/config/monitoring/
ssh root@192.168.50.101 'grep -E "smtp_host|mail_from" /root/k8s/deployments/alert-mail-relay/alert-mail-relay.yaml; grep -c alert-mail-relay /root/k8s/config/monitoring/alertmanager-config.yaml'
```
**ควรเห็น:** `smtp_host = mail.myhr.in.th` · `mail_from = myhr-notification@myhr.in.th` · แล้วเลขไม่เป็น `0`
(= config ชี้ webhook มาที่ตัวกลาง) · ได้ `mail.example.co.th` หรือ `<ALERT_FROM>` = ไฟล์บนเครื่องคุณยังเก่า `git pull` ก่อน

> 🔴 ส่งซ้ำ**หลัง** 5.2 จะทับผู้รับที่กรอกไว้บน master01 กลับเป็น `<ALERT_TO>` — ต้องทำ 5.2 ใหม่

### 5.1 เก็บ user/รหัส SMTP ลง Secret

รหัสอยู่ใน Secret เท่านั้น — ไม่อยู่ในไฟล์ในrepo และไม่ผ่าน helm values:
```bash
read -rp 'SMTP user: ' SU; read -rsp 'SMTP password: ' SP; echo " (รับมา ${#SP} ตัว)"
kubectl -n monitoring create secret generic alert-mail \
  --from-literal=SMTP_USER="$SU" --from-literal=SMTP_PASS="$SP" \
  --dry-run=client -o yaml | kubectl apply -f -
unset SU SP
```
**ควรเห็น:** `(รับมา N ตัว)` ที่ N ไม่เป็น 0 · แล้ว `secret/alert-mail created`

### 5.2 ใส่ผู้รับ แล้ว deploy ตัวกลาง

```bash
cd /root/k8s/deployments/alert-mail-relay
read -rp 'ผู้รับ alert ทั่วไป (คั่นด้วย , ได้): ' TO; read -rp 'ผู้รับ critical [เหมือนข้างบน]: ' TOC; TOC=${TOC:-$TO}
sed -i "s|<ALERT_TO>|$TO|; s|<ALERT_TO_CRITICAL>|$TOC|" alert-mail-relay.yaml
grep -nE 'smtp_host|smtp_port|mail_from|to_default|to_critical' alert-mail-relay.yaml
kubectl apply -f alert-mail-relay.yaml && kubectl -n monitoring rollout status deploy/alert-mail-relay --timeout=180s
```
**ควรเห็น:** `smtp_host = mail.myhr.in.th` · `smtp_port = 25` · `mail_from = myhr-notification@myhr.in.th`
· `to_default` / `to_critical` เป็นที่อยู่ที่พิมพ์ (ไม่มี `<...>` เหลือ) · ปิดท้าย `successfully rolled out`
(ครั้งแรกรอดึง image `python:3.12-alpine`)

> ต้องแก้ผู้รับทีหลัง: แก้ `to_*` ในไฟล์นี้แล้ว `kubectl apply` ซ้ำ — ตัวกลางอ่านค่าใหม่ทุก alert
> ไม่ต้อง restart (kubelet sync ไฟล์ราว 1 นาที)

### 5.3 ชี้ Alertmanager มาที่ตัวกลาง

🔴 **นับจากนี้ `helm upgrade` ของ `monitoring` ต้องมี `-f` สองไฟล์และ `--version` ทุกครั้ง** —
ลืมไฟล์ที่สอง ปลายทาง alert หายเงียบ ๆ · ลืม `--version` = อัป chart ทั้งชุดโดยไม่ตั้งใจ
```bash
set -a && source /root/k8s/versions.env && set +a
helm upgrade monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --version "${KUBE_PROM_STACK_CHART}" \
  -f /root/k8s/config/monitoring/kube-prometheus-values.yaml \
  -f /root/k8s/config/monitoring/alertmanager-config.yaml
```
**ควรเห็น:** `STATUS: deployed` และ `REVISION` เพิ่มขึ้น 1

**ตรวจว่า Alertmanager รับ config ใหม่จริง** — ต้องรอ ~45 วินาทีให้ secret sync เข้า pod ก่อน:
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 >/dev/null 2>&1 &
sleep 45
curl -s localhost:9093/api/v2/receivers | jq -r '.[].name'
kill %%
```
**ควรเห็น:** `null` · `myhr-default` · `myhr-critical` — ได้ `null` ตัวเดียว = ยังใช้ config ตั้งต้นของ chart
→ ตาราง "ถ้าไม่ผ่าน" ท้ายข้อ

### 5.4 ยิง alert ปลอม — ห้ามข้าม

มีคนเปิดกล่องเมลผู้รับรอดูอยู่ — ผลของข้อนี้อยู่ในกล่องเมล ไม่ใช่บนจอ:
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 >/dev/null 2>&1 &
sleep 3
for SEV in warning critical; do
  curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
    -d "[{\"labels\":{\"alertname\":\"TestAlert\",\"severity\":\"$SEV\"},\"annotations\":{\"summary\":\"ทดสอบเส้นทาง $SEV\"}}]"
done
kill %%
sleep 40; kubectl -n monitoring logs deploy/alert-mail-relay --tail=10
```
**ควรเห็น:** log ของตัวกลางมี `ส่งแล้ว: [k8s FIRING ...] -> to=default` และ `-> to=critical`
· **แล้วเมลเข้ากล่องทั้งสองฉบับ** (ดู junk ด้วย) · ของปลอมหายเองใน ~5 นาที ไม่ต้องลบ

**ห้ามไปข้อ 6 ก่อนเมลถึงมือคน**

---

### ถ้าข้อ 5 ไม่ผ่าน

| เห็นอะไร | แปลว่า / แก้ |
|---|---|
| 5.2 `grep` ยังเห็น `<ALERT_TO>` | `sed` ไม่ได้แทน (ค่าที่พิมพ์ว่าง) — รันบล็อก 5.2 ซ้ำ |
| 5.3 ได้ `null` ตัวเดียว | `helm -n monitoring get values monitoring \| grep -c myhr-default` — `0` = ไม่ได้ใส่ `-f` ไฟล์ที่สอง upgrade ใหม่ · ไม่เป็น 0 = config ถูกปฏิเสธ ดู `kubectl -n monitoring logs deploy/monitoring-kube-prometheus-operator --tail=80 \| grep -iE 'alertmanager\|error'` |
| 5.4 log ตัวกลางว่าง ไม่มี `ส่งแล้ว` เลย | Alertmanager ยังไม่เรียกมา — ยังใช้ config ตั้งต้น กลับไปตรวจ 5.3 |
| `ส่งไม่ผ่าน: SMTPAuthenticationError` | user/รหัสใน Secret ผิด — ทำ 5.1 ซ้ำ (apply ทับได้) แล้วยิง 5.4 ใหม่ |
| `ส่งไม่ผ่าน: TimeoutError` / `ConnectionRefused` | pod ต่อ `mail.myhr.in.th:25` ไม่ได้ — ภาคผนวกท้ายบท หัวข้อ "ต่อพอร์ตไม่ได้" |
| `ไม่มีผู้รับสำหรับ to=...` | `to_default` ว่าง — ทำ 5.2 ซ้ำ |
| log ขึ้น `ส่งแล้ว` แต่เมลไม่เข้า | relay รับแล้วแต่ปลายทางกรองทิ้ง (junk / นโยบายเมล) — ตามที่ทีม mail ไม่ใช่ที่ cluster |
| `helm upgrade` ล้มด้วย `no such host` | ดาวน์โหลด chart ไม่ได้ (DNS สะดุด) ไม่เกี่ยวกับ config — ลองซ้ำ หรือใช้ chart ที่ `helm pull` เก็บไว้ (ดูหมายเหตุข้างล่าง) |

> 🔴 **`--version` ต้องมีทุกครั้ง** — `helm upgrade` ที่ไม่ระบุเวอร์ชันจะคว้า chart
> **รุ่นล่าสุดใน repo** มาใช้ กลายเป็นอัป chart ทั้งชุดพ่วงไปกับการแก้ค่าเล็ก ๆ
> โดยที่คำสั่งหน้าตาเหมือนเดิมทุกประการ · ตรวจว่ารุ่นที่ใช้อยู่ตรงกับที่ตรึงไว้ไหม
> ด้วย `helm -n monitoring list` เทียบกับ `grep KUBE_PROM_STACK /root/k8s/versions.env`
> — namespace นี้มีหลาย release (loki · alloy · monitoring) เวลา parse json ต้องเลือกด้วยชื่อ
> ไม่ใช่ `.[0]` ไม่งั้นจะได้เวอร์ชันของ chart ตัวอื่นมาแล้ว helm จะฟ้องว่า `improper constraint`

> **`helm upgrade` ดาวน์โหลด chart ใหม่ทุกครั้ง** ไม่ได้ใช้ของที่ติดตั้งไปแล้ว จึงล้มได้
> เพราะเน็ตหรือ DNS สะดุด — อาการที่เจอจริงคือ
> `Error: Get "https://release-assets.githubusercontent.com/...": no such host`
> ซึ่ง **ไม่เกี่ยวกับ config ที่กำลังจะ apply เลย** ลองใหม่อีกรอบก่อน
> ถ้ายังไม่ได้ ให้ดึง chart เก็บไว้ตอนเน็ตดี:
> ```bash
> helm pull prometheus-community/kube-prometheus-stack --version "${KUBE_PROM_STACK_CHART}" -d /root/k8s/dl
> ```
> แล้วชี้ helm ไปที่ไฟล์นั้นแทน repo:
> ```bash
> helm upgrade monitoring /root/k8s/dl/kube-prometheus-stack-${KUBE_PROM_STACK_CHART}.tgz -n monitoring -f /root/k8s/config/monitoring/kube-prometheus-values.yaml -f /root/k8s/config/monitoring/alertmanager-config.yaml
> ```

> **ทำไมไม่ `kubectl edit secret` ของ Alertmanager ตรง ๆ** — มีผลทันทีจริง แต่ `helm upgrade` รอบถัดไป
> เขียนทับทั้งก้อน ปลายทางที่แก้ไว้จะหายโดยไม่มีใครรู้ · ใช้ได้เฉพาะฉุกเฉิน แล้วย้ายกลับมาใส่ไฟล์ให้เสร็จ

---

## 6 · 🔴 Alert ขั้นต่ำที่ต้องมี

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 5 — test alert ถึงกล่องเมลจริงทั้ง warning และ critical

chart มาพร้อม alert ของ Kubernetes พื้นฐานแล้ว แต่ **ขาดอีก 11 ข้อที่เฉพาะกับ cluster ชุดนี้**
ซึ่งมาจากข้อจำกัดที่เราเลือกไว้เอง

> **ต้องผ่านข้อ 5 มาก่อน** — rule 11 ข้อนี้มีค่าเท่ากับปลายทางที่มันไปถึง
> ถ้าปลายทางยังไม่ทำงาน สิ่งที่ได้จากข้อนี้คือแถบสีแดงในหน้าเว็บที่ไม่มีใครเปิดดู

```bash
kubectl apply -f /root/k8s/config/monitoring/myhr-alerts.yaml
kubectl -n monitoring get prometheusrule
```

| Alert | severity · `for` | ทำไมต้องมี |
|---|---|---|
| 🔴 **`NodeCountBelowExpected`** | critical · 10m | node ที่ถูก**ถอนออกจากทะเบียน** ไม่มี alert มาตรฐานตัวไหนจับได้เลย |
| **`DeploymentWithoutPDB`** | warning · 30m | ไม่มี GitOps มาบังคับมาตรฐาน · Deployment ที่ไม่มี PDB จะทำ drain ล่ม |
| **`DeploymentSingleReplica`** | warning · 1h | PDB ช่วยไม่ได้ถ้ามี replica เดียว |
| **`ClusterCapacityNearNPlusOneLimit`** | critical · 15m | requests รวมเกิน 90% ของ 32 vCPU / 96 GB → patch kernel ไม่ได้ |
| **`NodeKernelVersionMismatch`** | critical · 10m | node บูตคนละ kernel = บั๊ก network ที่หาสาเหตุยากที่สุด |
| **`KubeCertificateExpiringSoon`** | critical · 1h | cert หมดอายุคือสาเหตุที่ cluster เดิมเดินต่อไม่ได้ |
| **`CiliumAgentDown`** | critical · 5m | Cilium ทำทั้ง CNI + kube-proxy + LB-IPAM และไม่มีตัวสำรอง |
| **`MonitoringDiskFillingUp`** | critical · 30m | `/var/lib/monitoring` อยู่บน root ของ worker03 · เต็ม = node ตายทั้งเครื่อง |
| 🔴 **`LokiDiscardingLogs`** | warning · 15m | เพดาน ingestion ทำงานแล้ว log จะหาย**เงียบ ๆ** ถ้าไม่มีข้อนี้ไม่มีใครรู้ |
| 🔴 **`LokiNotReceivingLogs`** | critical · 20m | ระบบเก็บ log ตายจะดู "เงียบสงบ" เหมือนไม่มีอะไรผิด |
| 🔴 **`AlloyDaemonSetIncomplete`** | warning · 15m | node ที่ไม่มี Alloy = log ของเครื่องนั้นหายโดย Loki ยังดูปกติ |

> **3 ข้อล่างมาจากธรรมชาติของระบบ log:** ความผิดพลาดของมันไม่ทำให้อะไรพัง
> มันแค่ทำให้ข้อมูล**หายไปเฉย ๆ** ซึ่งจะรู้ตัวก็ตอนที่ต้องใช้ — คือตอน incident พอดี

### อธิบายทีละข้อ — ดังแล้วต้องทำอะไร

**🔴 `NodeCountBelowExpected`** — critical · `for: 10m`

- **จับอะไร** `count(kube_node_info) < 6` — นับจำนวน node ที่ยังอยู่ในทะเบียนของ cluster
  เทียบกับ 6 เครื่องใน `ansible/inventory.ini` (master 3 + worker 3)
  และมี arm ที่สอง `absent(kube_node_info)` ไว้ดักตอน **นับไม่ได้เลย**
- **ทำไมต้องมี** alert มาตรฐานทุกตัวจับได้แค่ "node ที่ยังอยู่แต่ป่วย" ถ้า node object
  หายไปจริง ๆ (`kubectl delete node`, ถอนเครื่องหลัง drain แล้วลืมใส่คืน, VM ถูกลบที่ vCenter)
  series ของเครื่องนั้นหายทั้งชุด → `KubeNodeNotReady` ไม่เหลืออะไรให้ประเมินจึง**หยุดดัง**
  และ `desired` ของ DaemonSet ลดลงตามจำนวน node ที่เหลือ →
  `CiliumAgentDown` กับ `AlloyDaemonSetIncomplete` ก็เงียบตาม
  ผลคือ cluster เล็กลงหนึ่งเครื่องโดยที่ทุกหน้าจอเขียวหมด
- **ดังแล้วทำอะไร** `kubectl get nodes` เทียบกับ inventory ว่าเครื่องไหนหาย → ถ้าไม่มีใครถอนออก
  ดูที่ vCenter ว่า VM ยังอยู่ไหม แล้วค่อยไล่ kubelet บนเครื่องนั้น
- **ดังหลอกเมื่อ** เพิ่มหรือถอน node ถาวรแล้วลืมแก้เลข `6` ในไฟล์ · หรือ kube-state-metrics
  ไม่ถูก scrape (กรณีนี้ `kubectl get nodes` จะครบ 6 — ให้ไปตรวจ target ที่ Prometheus ก่อน)

**`DeploymentWithoutPDB`** — warning · `for: 30m`

- **จับอะไร** Deployment ใน namespace ของแอป (ตัด `kube-system` / `monitoring` / `cert-manager` /
  `envoy-gateway-system` ออก) ที่ไม่มี PodDisruptionBudget อยู่ใน namespace เดียวกัน
- **ทำไมต้องมี** cluster นี้ไม่มี Ksplice จึงต้อง drain ทุกเครื่องทุก 1-2 เดือน
  และไม่มี GitOps คอยบังคับว่า manifest ต้องมี PDB — ของที่ขาดจึงหลุดเข้ามาได้เรื่อย ๆ
- **ดังแล้วทำอะไร** เพิ่ม PDB `minAvailable: 1` และตั้ง replica ≥ 2 ให้ Deployment นั้น
  **ก่อน**ถึงรอบ patch ถัดไป
- **ดังหลอกเมื่อ** ตั้งใจให้เป็นงาน batch ที่ดับได้ — ถ้าใช่ ให้ silence ไว้ อย่าลบ rule ทิ้ง

**`DeploymentSingleReplica`** — warning · `for: 1h`

- **จับอะไร** `kube_deployment_spec_replicas == 1` ใน namespace ของแอป
- **ทำไมต้องมี** PDB ไม่ช่วยอะไรถ้ามี pod เดียว — `minAvailable: 1` กับ replica 1
  ทำให้ drain **ค้าง**แทนที่จะทำให้ service รอด กลายเป็นปัญหาคนละแบบที่แย่พอกัน
- **ดังแล้วทำอะไร** ขยายเป็น 2 replica ถ้าแอป stateless · ถ้าเป็น singleton จริง ๆ
  (เช่นตัวรัน migration) ให้ย้ายไปเป็น Job แทน Deployment
- **ดังหลอกเมื่อ** ช่วง scale ลงชั่วคราวตอนทดสอบ — `for: 1h` เผื่อไว้ให้แล้ว

**`ClusterCapacityNearNPlusOneLimit`** — critical · `for: 15m`

- **จับอะไร** ผลรวม `requests` ของ pod บน worker เกิน 90% ของ **32 vCPU / 96 GB**
  ซึ่งคือ capacity ตอนเหลือ worker 2 เครื่อง ไม่ใช่ 48 vCPU / 144 GB ที่มีอยู่จริง
- **ทำไมต้องมี** เพดานที่ใช้วางแผนคือเพดาน**ตอน drain** ถ้าคิดจากของที่มีทั้งหมด
  วันที่ patch kernel จะเพิ่งรู้ว่า pod ลงไม่หมด แล้ว drain ค้างกลางคัน
- **ดังแล้วทำอะไร** ลด requests ที่ตั้งเผื่อไว้เกินจริง หรือขอ worker เพิ่ม
  **ก่อน**รอบ patch ถัดไป — ห้ามปล่อยไปเจอตอนกลางดึก
- **ดังหลอกเมื่อ** ไม่ค่อยหลอก แต่ถ้าเพิ่ม worker ต้องกลับมาแก้เลข 32 / 96 ในไฟล์ด้วย

**`NodeKernelVersionMismatch`** — critical · `for: 10m`

- **จับอะไร** `count(count by (release) (node_uname_info)) > 1` — มี kernel มากกว่าหนึ่งเวอร์ชันในวง
- **ทำไมต้องมี** Oracle Linux ให้ kernel มาสองตัว (UEK และ RHCK) ถ้า node บูตคนละตัว
  จะได้พฤติกรรม network ที่ต่างกันเป็นราย node ซึ่งเป็นบั๊กที่หาต้นเหตุยากที่สุดชนิดหนึ่ง
- **ดังแล้วทำอะไร** `uname -r` ทุกเครื่อง แล้วยืนยันว่า `dnf versionlock` ยังอยู่
- **ดังหลอกเมื่อ** ระหว่าง rolling reboot จะดังเป็นเรื่องปกติ — ดังค้าง**หลังจบรอบ**ถึงจะผิด

**`KubeCertificateExpiringSoon`** — critical · `for: 1h`

- **จับอะไร** cert ที่ apiserver เห็น เหลืออายุน้อยกว่า **60 วัน**
- **ทำไมต้องมี** นี่คือสาเหตุที่ cluster เดิมเดินต่อไม่ได้ · cert ของ kubeadm อายุ 1 ปี
  และไม่มีอะไรเตือนล่วงหน้าถ้าไม่ตั้งเอง
- **ดังแล้วทำอะไร** `kubeadm certs check-expiration` บน master ทั้ง 3 →
  ต่ออายุด้วย `kubeadm certs renew all` (ขั้นตอนเต็มอยู่ในบทที่ 12)
- **ดังหลอกเมื่อ** metric นี้เป็น histogram ของ **client cert** ที่วิ่งเข้ามา
  ถ้ามี client ถือ cert ใกล้หมดอายุก็ดังได้ — ยืนยันด้วย `check-expiration` เสมอก่อนสรุป

**`CiliumAgentDown`** — critical · `for: 5m`

- **จับอะไร** DaemonSet `cilium` มี `number_ready` น้อยกว่า `desired_number_scheduled`
- **ทำไมต้องมี** Cilium ทำทั้ง CNI + kube-proxy replacement + LB-IPAM
  node ที่ไม่มี agent จะไม่มี pod network และ Service ใช้ไม่ได้
  และ**ไม่มี kube-proxy ให้ถอยกลับ** เพราะไม่ได้ติดตั้งไว้ตั้งแต่แรก
- **ดังแล้วทำอะไร** `kubectl -n kube-system get pod -l k8s-app=cilium -o wide` หาว่าเครื่องไหนขาด
  แล้วดู `cilium status` บนเครื่องนั้น
- **ดังหลอกเมื่อ** node reboot ตามแผน · `for: 5m` สั้นที่สุดในไฟล์นี้โดยตั้งใจ
  เพราะผลของมันรุนแรงกว่าความรำคาญจากการดังตอน reboot

**`MonitoringDiskFillingUp`** — critical · `for: 30m`

- **จับอะไร** root partition ของ **worker03** (`.106`) เหลือว่างน้อยกว่า 20%
- **ทำไมต้องมี** ไม่มี CSI จึงใช้ local PV ที่ผูกกับ worker03 และ `/var/lib/monitoring`
  อยู่บน root ร่วมกับ OS — เต็มเมื่อไรคือ node ตายทั้งเครื่อง ไม่ใช่แค่ Prometheus ตาย
- **ดังแล้วทำอะไร** ลด `retention` / `retentionSize` ของ Prometheus หรือเพดานของ Loki
  หรือย้าย `/var/lib/monitoring` ไป disk แยก
- **ดังหลอกเมื่อ** ไม่หลอก — เหลือ 20% บน partition ที่โตทางเดียวคือเรื่องจริงเสมอ

**🔴 `LokiDiscardingLogs`** — warning · `for: 15m`

- **จับอะไร** `rate(loki_discarded_samples_total) > 0` แยกตาม `reason`
- **ทำไมต้องมี** เพดาน ingestion (10 MB/s · per-stream 3 MB) จำเป็นต้องมี ไม่งั้นแอปที่ log รัว
  จะกิน root ของ worker03 จนเต็ม — แต่เวลาเพดานทำงาน Loki ตอบ 429 แล้ว Alloy retry จนยอมแพ้
  แล้วทิ้ง log แบบเงียบ ทีม dev จะเห็นแค่ "log บางช่วงหาย"
- **ดังแล้วทำอะไร** ดู `reason` ก่อน · ถ้าเป็น `rate_limited` / `per_stream_rate_limit`
  ให้หาตัวต้นเหตุด้วย `topk(5, sum by (namespace, app) (rate({namespace=~".+"}[5m])))`
  แล้วแก้ที่แอปก่อน ค่อยพิจารณาขยายเพดาน
- **ดังหลอกเมื่อ** ช่วง deploy ที่แอปพ่น stack trace รัวสั้น ๆ — ถ้าหายเองใน 15 นาทีถือว่าปกติ

**🔴 `LokiNotReceivingLogs`** — critical · `for: 20m`

- **จับอะไร** `rate(loki_distributor_lines_received_total) == 0` ตลอด 15 นาที
- **ทำไมต้องมี** Alloy พัง / `NODE_NAME` ไม่ถูกส่งเข้าไปจน selector ไม่ match อะไรเลย / Loki ไม่รับ
  — ทั้งสามอย่างให้ผลหน้าจอเหมือนกันคือ **ว่างเปล่า** ซึ่งดูเหมือนระบบเงียบสงบ
- **ดังแล้วทำอะไร** ไล่ตามลำดับ 1) `kubectl -n monitoring get ds alloy` ครบ 6/6 ไหม
  2) `kubectl -n monitoring logs ds/alloy` มี error เรื่อง `NODE_NAME` หรือ 429 ไหม
  3) Loki pod ขึ้นหรือเปล่า
- **ดังหลอกเมื่อ** worker03 กำลัง reboot (Loki อยู่เครื่องนั้น) — ถือว่าปกติ
  แต่ต้องหายเองหลัง node กลับมา ถ้าไม่หายคือของจริง

**🔴 `AlloyDaemonSetIncomplete`** — warning · `for: 15m`

- **จับอะไร** DaemonSet `alloy` มี `number_ready` น้อยกว่า `desired` (ต้องได้ครบ **6/6** รวม master)
- **ทำไมต้องมี** node ที่ไม่มี Alloy = log ของเครื่องนั้นหายไปทั้งเครื่อง โดยที่ Loki
  ยังตอบ query ปกติและกราฟยังเขียว — ความผิดพลาดชนิด "ไม่มีอะไรพัง แต่ข้อมูลหาย"
- **ดังแล้วทำอะไร** ถ้าขาดเฉพาะ master ให้ตรวจ `tolerations` ใน `alloy-values.yaml`
- **ดังหลอกเมื่อ** ระหว่าง rolling reboot — และ**สังเกตว่าข้อนี้จะเงียบ**ถ้า node
  ถูกถอนออกจากทะเบียนไปเลย เพราะ `desired` ลดตาม (นั่นคือหน้าที่ของ `NodeCountBelowExpected`)

### node หายไปหนึ่งเครื่อง — อะไรดังบ้าง เรียงตามเวลา

กรณี **เครื่องดับแต่ node object ยังอยู่** (ไฟดับ · NIC ตาย · kernel panic):

| หลัง node ดับ | alert | มาจาก |
|---|---|---|
| ~5 นาที | `CiliumAgentDown` | ไฟล์นี้ — **ตัวที่ดังเร็วที่สุด** |
| ~10 นาที | `TargetDown` (kubelet / node-exporter หาย 1 ใน 6 = 16%) | chart |
| ~15 นาที | `KubeNodeNotReady` · `KubeNodeUnreachable` · `KubeletDown` | chart |
| ~15 นาที | `AlloyDaemonSetIncomplete` | ไฟล์นี้ |

กรณี **node object ถูกลบออกจากทะเบียน** (`kubectl delete node` · ถอนเครื่องหลัง drain แล้วลืมใส่คืน):

| หลังถูกลบ | alert | มาจาก |
|---|---|---|
| ~10 นาที | `NodeCountBelowExpected` | ไฟล์นี้ — **ตัวเดียวที่ดัง** |

> ตารางที่สองคือเหตุผลทั้งหมดที่ `NodeCountBelowExpected` มีอยู่ — ของมาตรฐานทุกตัวประเมินจาก
> series ของ node ที่ยังอยู่ พอ node หายทั้งก้อน alert ก็หายตามไปด้วย

### ของมาตรฐานจาก chart ที่ต้องรู้ว่ามีอยู่แล้ว

`KubeNodeNotReady` · `KubeNodeUnreachable` · `KubeletDown` · `TargetDown` ·
`KubePodCrashLooping` · `etcdInsufficientMembers` · `NodeFilesystemAlmostOutOfSpace`

ของพวกนี้มากับ chart และ **เปิดอยู่แล้ว** เพราะ `kube-prometheus-values.yaml`
ไม่ได้ตั้ง `defaultRules.create: false` ไว้ — ไม่ต้อง apply อะไรเพิ่ม แต่ต้องรู้ว่ามันช้า
(`for: 15m` เกือบทั้งหมด) จึงต้องมีของในไฟล์นี้มาช่วยดักให้เร็วขึ้น

**ตรวจว่า rule โหลดแล้ว:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules' | jq -r '.data.groups[].name' | sort -u
kill %%
```

**ดูว่า alert เรื่อง node ตัวไหนโหลดอยู่จริง และตั้ง `for:` ไว้กี่วินาที:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules' \
  | jq -r '.data.groups[].rules[]? | select(.type=="alerting") | "\(.duration)s\t\(.name)"' \
  | grep -iE 'node|kubelet|target|cilium|alloy' | sort -n
kill %%
```

**ซ้อมของจริงหนึ่งรอบ ตอนที่ยังไม่มี workload:** ปิด worker01 ทิ้งไว้ ~20 นาที
แล้วดูว่า alert ดังตามตารางข้างบนจริงไหม ถ้ามีตัวไหนไม่ดังแปลว่า rule นั้นไม่ได้โหลด
— รู้ตอนนี้ดีกว่ารู้ตอนของจริง · ปลายทางพร้อมตั้งแต่ข้อ 5 แล้ว การซ้อมรอบนี้จึงวัดได้ทั้งเส้น
ตั้งแต่ node ดับจนถึงข้อความที่เข้ามือคน

---

## 7 · กันไม่ให้ monitoring กิน disk จนเต็ม

**ทำที่:** 👑 master01 (บรรทัด `ssh` ไป worker03 รันจากที่ไหนก็ได้ที่มี key) · **ต้องมีก่อน:** ข้อ 2-3 รันมาแล้ว
— วันติดตั้งจดค่าเริ่มต้นไว้เป็น baseline · **กลับมาทำซ้ำหลังใช้ไป 1 สัปดาห์** จึงจะเห็นอัตราโต

`/var/lib/monitoring` อยู่บน **root partition** ร่วมกับ log และ OS
ถ้า Prometheus โตจนเต็ม node จะกลายเป็น `NotReady` ทั้งเครื่อง

ค่า retention ที่ตั้งไว้ใน values:

| | retention | ขนาดสูงสุด |
|---|---|---|
| Prometheus | 30 วัน | 120 GB (จาก PV 150 GB) |
| Loki | 14 วัน | 40 GB (จาก PV 50 GB) |

**ตรวจของจริงหลังใช้ไป 1 สัปดาห์:**
```bash
kubectl -n monitoring exec -it prometheus-monitoring-kube-prometheus-prometheus-0 -c prometheus -- df -h /prometheus
```

**และตรวจบน worker03 โดยตรง:**
```bash
ssh root@192.168.50.106 'du -sh /var/lib/monitoring/* && df -h /'
```

---

## 8 · log ของ application — ใช้ยังไง และต้องบอกทีม dev ว่าอะไร

**ทำที่:** อ่านและตัดสินใจ — ไม่มีคำสั่งที่เปลี่ยน cluster ยกเว้นบล็อกตรวจตัวกรอง noise (บน 👑 master01)
· **ต้องมีก่อน:** ข้อ 3 (Loki + Alloy ทำงาน) · **ผลลัพธ์ของข้อนี้คือประกาศกฎ 3 ข้อให้ทีม dev** ไม่ใช่ของบน cluster

### เส้นทางของ log

```
  app เขียน stdout/stderr
        ▼
  containerd เขียนไฟล์ /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log
        │   ← อยู่บน root partition ไม่ใช่ partition /var/lib/containerd ที่แยกไว้
        │   ← kubelet หมุนไฟล์ให้ 10Mi × 5 = 50Mi ต่อ container (ตั้งใน kubeadm-config.yaml)
        ▼
  Alloy (DaemonSet 6 ตัว · เก็บเฉพาะ pod บน node ตัวเอง)
        ▼
  Loki (worker03 · local PV 50Gi · เก็บ 14 วัน)
        ▼
  Grafana
```

### ดู log ที่ไหน

| เครื่องมือ | เหมาะกับ |
|---|---|
| **Grafana → Explore** | เทียบเท่า Discover ของ Kibana · มีอยู่แล้วไม่ต้องลงอะไร |
| **Grafana → Drilldown → Logs** | คลิกอย่างเดียวไม่ต้องพิมพ์ query — ใกล้ Kibana ที่สุด · ดูว่ามีในเมนูซ้ายหรือยัง |
| **`stern`** | ตาม log สด ๆ หลาย pod พร้อมกันบน terminal ตอน debug |

> 📖 **บทนี้บอกว่า log เดินทางยังไงและต้องตั้งค่าอะไร ส่วน "pod พังแบบนี้ ต้องพิมพ์ query ไหน"**
> อยู่ใน [บทที่ 14 — ดู log ใน Grafana ตามอาการของ pod](14-grafana-logs.md) แยกเป็นเคส ๆ ไป
> พร้อมกับดักที่ทำให้ค้นแล้วไม่เจอทั้งที่ log มีอยู่

### ตรวจว่าตัวกรอง noise ไม่ได้ตัดของดีทิ้ง

`alloy-values.yaml` มี `stage.drop` ที่ทิ้ง log ของ healthcheck ที่สำเร็จ — **ของที่ทิ้งแล้ว
หายถาวร ไม่มีทางกู้** จึงต้องดูเป็นระยะว่ามันทิ้งเยอะผิดปกติหรือเปล่า

```bash
kubectl -n monitoring port-forward ds/alloy 12345:12345 &
sleep 3
curl -s http://localhost:12345/metrics | grep loki_process_dropped_lines_total
kill %%
```
**ควรเห็น:** ตัวเลขของ `reason="healthcheck_noise"` โตช้า ๆ สม่ำเสมอ ถ้าโตพุ่งกว่าปริมาณ
healthcheck ที่ควรจะมี แปลว่า regex กว้างเกินไปและกำลังกิน log จริงอยู่

> regex ตัวนี้บังคับครบ 4 อย่าง: ต้องมี method · path ต้องมี `/` นำหน้า · status ต้องอยู่
> ติดหลัง request · และไม่รับคำว่า `OK` เป็นตัวชี้วัด ทั้งหมดนี้เพื่อกันไม่ให้บรรทัด error
> อย่าง `payment health degraded, retry in 200ms` โดนทิ้งไปโดยไม่มีใครรู้

### 🔴 Loki ไม่ใช่ Elasticsearch — ข้อนี้ต้องเข้าใจก่อนใช้

**Loki index เฉพาะ label ไม่ได้ index เนื้อหา** จึง**ค้นคำมั่ว ๆ ทั้งระบบไม่ได้**
ต้องระบุ label ก่อนเสมอ แล้วมันจะไปไล่อ่านเนื้อหาให้ทีหลัง

label ที่มีในระบบนี้: `namespace` `pod` `container` `app` `node`

| อยากทำแบบ Kibana | พิมพ์แบบนี้ |
|---|---|
| ดู log ทั้ง namespace | `{namespace="myhr-prod"}` |
| ค้นคำว่า error | `{namespace="myhr-prod"} \|= "error"` |
| ตัดคำที่ไม่อยากเห็น | `{namespace="myhr-prod"} != "healthz"` |
| หลายคำ / regex | `{namespace="myhr-prod"} \|~ "(?i)timeout\|refused"` |
| `status:500` (ต้อง log เป็น JSON) | `{namespace="myhr-prod"} \| json \| status=500` |
| กราฟจำนวน error ต่อ app | `sum by (app) (rate({namespace="myhr-prod"} \|= "error" [5m]))` |

> ⚠️ **ห้ามเพิ่ม label ที่มีค่าไม่ซ้ำ** (`trace_id`, `request_id`, `user_id`) ลงใน
> `alloy-values.yaml` เด็ดขาด — นั่นคือวิธีฆ่า Loki ที่เร็วที่สุด ค่าพวกนั้นให้อยู่ใน
> **เนื้อ log** แล้วค้นด้วย `|=` หรือ `| json` เอา

**ถ้าอยากให้ dev ไม่ต้องเรียน LogQL เลย** — ทำ dashboard 1 หน้าที่มี dropdown เลือก
`namespace` / `app` แล้วมี panel เดียวเป็น Logs ใช้เวลาราว 30 นาที และได้ผลกับทีม
มากกว่าการสอน LogQL ทั้งทีม

### 🔴 กฎ 3 ข้อที่ต้องประกาศให้ทีม dev รู้ตั้งแต่วันแรก

เหมือนเรื่อง "ไม่มี dynamic storage" ในบทที่ 08 — ต้องเป็นบทสนทนาที่วางแผนไว้
ไม่ใช่เซอร์ไพรส์ตอนใกล้ deadline

**1 · log ต้องออก `stdout`/`stderr` เท่านั้น ห้ามเขียนลงไฟล์ในคอนเทนเนอร์**
ถ้าเขียนลงไฟล์ Alloy จะมองไม่เห็น (dev นึกว่ามี log แต่ไม่มี) แถม**ไม่มีใครหมุนไฟล์ให้**
มันจะโตไปเรื่อย ๆ บน writable layer จนกิน `/var/lib/containerd` (partition 100 GB)
แล้วทั้ง node ดึง image ไม่ได้

**2 · log เป็น JSON บรรทัดเดียวต่อหนึ่ง event**
ไม่งั้น stack trace หลายบรรทัดจะกลายเป็นคนละ entry และใช้ `| json` ไม่ได้

**3 · มีเพดาน 10 MB/s ทั้ง cluster และ 3 MB/s ต่อ stream**
app ที่ log ทุก request จะกินโควตาของทีมอื่นจนหมด แล้ว **log ของทุกคนจะเริ่มหาย**
เพดานนี้อยู่ใน `loki-values.yaml` และเวลามันทำงานจะดังผ่าน `LokiDiscardingLogs`

### ทางเลือก: เปลี่ยนไปเก็บ log แบบอ่านไฟล์

ตอนนี้ใช้ `loki.source.kubernetes` ซึ่งดึง log **ผ่าน Kubernetes API** — ตั้งค่าง่ายและ
พอสำหรับขนาดนี้ แต่ทุก stream วิ่งผ่าน apiserver

ถ้าวันหนึ่ง pod เยอะขึ้นมากจน apiserver เริ่มหนัก ให้เปลี่ยนไปเป็น `local.file_match` +
`loki.source.file` อ่านไฟล์ใน `/var/log/pods` ตรง ๆ (ซึ่ง mount ไว้ให้แล้วใน values)
พร้อมใส่ `stage.cri` มาแกะ format — ไม่กวน apiserver เลย
**อย่าเปลี่ยนบน production โดยไม่ทดสอบก่อน** เพราะถ้า path pattern ผิด log จะหายเงียบ ๆ

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl top nodes` ขึ้นตัวเลขครบ 6 เครื่อง
- [ ] PV `prometheus-data`, `grafana-data`, `loki-data` เป็น **`Bound`**
- [ ] 🔴 **ตรวจคอลัมน์ `VOL` แล้วว่า PVC แต่ละตัวผูก PV ถูกก้อน** ไม่ใช่ดูแค่คำว่า `Bound`
- [ ] Alertmanager 2 pod อยู่ **คนละ node** (`-o wide`)
- [ ] `node-exporter` ครบ 6 ตัว · Prometheus target ทุกตัว `up`
- [ ] Alloy DaemonSet `6/6` และค้น log ใน Grafana เจอ
- [ ] 🔴 **log ไม่ซ้ำ** — บรรทัดเดียวกันโผล่ครั้งเดียว ไม่ใช่ 6 ครั้ง
- [ ] เข้า Grafana ผ่าน `https://grafana.myhr.co.th` ได้และ**เปลี่ยนรหัส admin แล้ว**
- [ ] 🔴 **ยิง test alert แล้วมีข้อความเข้าปลายทางจริง** (ทั้ง warning และ critical)
- [ ] `curl .../api/v2/receivers` เห็น `myhr-default` กับ `myhr-critical` ไม่ใช่แค่ `null`
- [ ] 🔴 **จำได้ว่า `helm upgrade` ต้องใส่ `-f` ทั้งสองไฟล์ และ `--version` ทุกครั้ง**
      ลืม `-f` = ปลายทางหาย · ลืม `--version` = อัป chart โดยไม่รู้ตัว
- [ ] `alert-mail-relay` 2 pod อยู่คนละ node และ log ขึ้น `ส่งแล้ว` ทั้ง `to=default` และ `to=critical`
- [ ] จดไว้ว่าตัวกลางนี้ต้องถอดออกวันที่ได้พอร์ตที่มี STARTTLS (ขั้นตอนอยู่ที่ภาคผนวกท้ายบท ข.3)
- [ ] PrometheusRule ของ MyHR โหลดแล้วครบ 11 ข้อ
- [ ] `NodeCountBelowExpected` มีตัวเลข node ตรงกับจำนวนเครื่องจริง (ตอนนี้ 6)
- [ ] **ประกาศกฎ log 3 ข้อให้ทีม dev รู้แล้ว** (stdout เท่านั้น · JSON บรรทัดเดียว · มีเพดาน)
- [ ] จด disk usage เริ่มต้นไว้เป็น baseline

**➡️ ต่อที่ [บทที่ 10 — Security Baseline](10-security.md)**

> เก็บ [บทที่ 14](14-grafana-logs.md) ไว้เปิดตอนของพัง — เป็นบทที่ใช้ตอนมี incident ไม่ใช่ตอนติดตั้ง

---

## ภาคผนวก · ส่งเมลตรงจาก Alertmanager — วันที่ได้พอร์ตที่มี STARTTLS

ข้อ 5 ใช้ตัวกลาง `alert-mail-relay` เพราะ relay ขององค์กรบังคับ AUTH บนพอร์ต 25 ที่ไม่มี STARTTLS
ภาคผนวกนี้เก็บวิธีตรวจ relay และวิธีสลับไปส่งตรง สำหรับวันที่สภาพนั้นเปลี่ยน (ได้ 587 · ได้ allow-list)
หรือสำหรับ cluster อื่นที่ relay ไม่เหมือนกัน · **ติดตั้งปกติไม่ต้องอ่าน**

ทุกคำสั่งทำบน 👑 master01 · ตั้งค่า relay ที่จะตรวจก่อน (ใช้ต่อทุกบล็อกข้างล่าง):
```bash
H=mail.myhr.in.th; P=587
```

### ก · ทดสอบส่งด้วย user/รหัสจริงผ่านพอร์ตใดพอร์ตหนึ่ง

ส่งเมลจริงหนึ่งฉบับจาก master01 ด้วย `smtplib` — พิสูจน์ user/รหัส และเส้นทางไป relay ในทีเดียว
```bash
cat > /root/smtp25-test.py <<'EOF'
import os, smtplib
host, port = os.environ["SMTP_HOST"], int(os.environ.get("SMTP_PORT", "25"))
user, pw, to = os.environ["SMTP_USER"], os.environ["SMTP_PASS"], os.environ["SMTP_TO"]
s = smtplib.SMTP(host, port, timeout=15)
s.ehlo(); s.login(user, pw)
msg = (f"From: {user}\r\nTo: {to}\r\nSubject: k8s smtp port25 test\r\n"
       "Content-Type: text/plain; charset=utf-8\r\n\r\ntest send via port 25\r\n")
s.sendmail(user, [to], msg.encode("utf-8")); s.quit()
print("=== SENT OK")
EOF
read -rp 'SMTP user: ' SU; read -rsp 'SMTP password: ' SP; echo; read -rp 'send to: ' TO
SMTP_HOST="$H" SMTP_USER="$SU" SMTP_PASS="$SP" SMTP_TO="$TO" python3 /root/smtp25-test.py
unset SU SP TO; rm -f /root/smtp25-test.py
```

> 🔴 **อย่าใส่ `s.set_debuglevel(1)`** ถ้าไม่จำเป็น — มันพิมพ์บรรทัด `AUTH LOGIN` ซึ่งมี
> user กับรหัสผ่านเป็น base64 ออกมาบนจอ · base64 ไม่ใช่การเข้ารหัส ถอดได้ทันที
> ถ้าเผลอเปิดไปแล้วให้ถือว่ารหัสรั่ว (ค้างใน scrollback / ภาพหน้าจอ) แล้วเปลี่ยนรหัส
>
> และใช้ env แทน `input()` เพราะ `input()` ถอดรหัส stdin ตาม locale ของ session
> ถ้า locale ไม่ใช่ UTF-8 จะได้ `UnicodeDecodeError` ทั้งที่ไม่เกี่ยวกับ SMTP เลย

### ข · ตั้งค่าให้ Alertmanager ส่งตรง

#### ข.1 แทนค่าในไฟล์ปลายทาง

**ทำที่:** 👑 master01 (ไฟล์ `/root/k8s/config/monitoring/alertmanager-config.yaml`) · ค่าที่ต้องใช้ดูตารางข้างล่าง

ค่าที่ต้องเตรียมก่อน — ถามทีม infra/mail ไว้ล่วงหน้า ไม่ใช่มานั่งหาตอนทำ:

| ค่าที่ต้องแทน | คืออะไร |
|---|---|
| `<SMTP_HOST>` · `<SMTP_PORT>` | mail relay ภายในองค์กร · พอร์ต 25 มักไม่ต้องล็อกอิน · 587 เกือบทุกครั้งต้อง |
| `<ALERT_FROM>` | ที่อยู่ผู้ส่ง เช่น `k8s-alert@บริษัท` — ต้องเป็นที่อยู่ที่ relay ยอมให้ส่ง |
| `<ALERT_TO>` | ปลายทางของ alert ทั่วไป — ควรเป็น distribution list ไม่ใช่เมลคนเดียว |
| `<ALERT_TO_CRITICAL>` | ปลายทางของ critical · ถ้ายังไม่มีกลุ่ม on-call ใส่ค่าเดียวกับข้างบนไปก่อน |
| `<SMTP_USER>` · `<SMTP_PASSWORD>` | **เฉพาะเมื่อ relay ต้องล็อกอิน** — ตัดสินใจที่ขั้น A ข้างล่าง |

**ขั้น A — ตัดสินก่อนว่า relay ต้องล็อกอินไหม** ไม่แน่ใจให้ถามทีม mail
หรือดูว่า relay ประกาศ `AUTH` ไว้หรือเปล่า (ประกาศ ≠ บังคับ แต่ถ้าไม่ประกาศเลยแปลว่าไม่ต้องแน่ ๆ):
**ใส่ชื่อ relay จริงที่ได้จากทีม mail ก่อน** (ไม่ใช่ `mail.example.co.th` — นั่นคือตัวอย่าง) · ค่า `H` กับ `P`
ใช้ต่อในทุกคำสั่งทดสอบของภาคผนวกนี้ ถ้าเปิด shell ใหม่ต้องรันบรรทัดนี้ซ้ำ:
```bash
read -rp 'SMTP relay host (จากทีม mail): ' H; read -rp 'port [25]: ' P; P=${P:-25}; getent hosts "$H" || echo "❌ resolve $H ไม่ได้ — ชื่อผิดหรือ DNS ไม่รู้จัก"
```
**ควรเห็น:** IP ของ relay หนึ่งบรรทัด · ได้ `❌` = ชื่อผิด ถามทีม mail ใหม่ (ห้ามไปต่อ)

แล้วถาม relay ว่าประกาศอะไร — ยิงจาก pod เพราะเป็นเส้นทางเดียวกับที่ Alertmanager ใช้:
```bash
kubectl -n monitoring run smtp-test --rm --attach --restart=Never --image=busybox:1.36 -- \
  sh -c '(printf "EHLO myhr\r\n"; sleep 4; printf "QUIT\r\n"; sleep 1) | nc -w 10 "$0" "$1"' "$H" "$P" | grep -iE '^2|AUTH|STARTTLS'
```
**ควรเห็น:** บรรทัด `220 ...` ตามด้วย `250-...` หลายบรรทัด · มี `AUTH` = relay รับล็อกอิน · ไม่มีเลย = ไม่ต้องล็อกอิน (A-ก)
· ไม่มีอะไรออกมาเลย = ต่อไม่ติด → ข.2.3

**A-ก · relay ไม่ต้องล็อกอิน** — ปิดสองบรรทัด auth ทิ้งไปเลย
```bash
cd /root/k8s/config/monitoring
sed -i -E 's|^([[:space:]]*)(smtp_auth_)|\1# \2|' alertmanager-config.yaml
grep -cE '^[[:space:]]*smtp_auth_' alertmanager-config.yaml
```
**ควรเห็น:** `0`

> 🔴 **ห้ามปล่อยสองบรรทัดนั้นเปิดไว้ทั้งที่ยังเป็น `<SMTP_USER>`** — Alertmanager จะโหลด
> config ไม่ผ่าน แล้ว**ถอยไปใช้ config เดิมของ chart** ผลคือหน้า `/api/v2/receivers`
> ตอบ `null` มาตัวเดียว ทั้งที่ `helm upgrade` สำเร็จและ pod ยัง `Running` ทุกตัว

**A-ข · relay ต้องล็อกอิน** — เปิด auth แล้วบังคับ TLS กับพอร์ตให้ถูกในทีเดียว
```bash
cd /root/k8s/config/monitoring
read -rp 'พอร์ตที่ใช้กับ auth [587]: ' SPORT; SPORT=${SPORT:-587}
sed -i -E "s|^([[:space:]]*)#[[:space:]]*(smtp_auth_)|\1\2|" alertmanager-config.yaml
sed -i -E -e "s|(smtp_smarthost: \"[^\"]*):[0-9]+\"|\1:${SPORT}\"|" \
          -e 's|smtp_require_tls: false|smtp_require_tls: true|' alertmanager-config.yaml
grep -E 'smtp_(smarthost|require_tls)' alertmanager-config.yaml
```
**ควรเห็น:** พอร์ตเป็นเลขที่กรอก และ `smtp_require_tls: true`

> 🔴 **เปิด auth แล้วต้องเปิด TLS เสมอ** — ไลบรารีที่ Alertmanager ใช้ปฏิเสธการส่งรหัสผ่าน
> บนช่องที่ไม่เข้ารหัส ถ้าทิ้ง `smtp_require_tls: false` ไว้จะได้ error ทำนอง
> `unencrypted connection` แล้วเมลไม่ออกเลย
>
> **แต่ TLS ไม่ได้ผูกกับพอร์ต 587** — `require_tls` คือ STARTTLS ซึ่ง relay หลายเจ้าก็ให้บน 25
> ตัวตัดสินคือ relay ประกาศ `STARTTLS` บนพอร์ตนั้นหรือเปล่า ไม่ใช่เลขพอร์ต
> ถ้าองค์กรบล็อก 587 ขาออก (เจอบ่อยเมื่อ relay อยู่นอกวง) ให้ลอง 25 ที่มี STARTTLS ก่อน

**ขั้น B — แทนค่าทุกช่องที่เหลือ** บล็อกนี้ **รันซ้ำได้ไม่จำกัด** ถามเฉพาะช่องที่ยังว่างจริง
ช่องที่เต็มแล้วจะขึ้น `✓ ... ไม่ถาม` และไม่แตะไฟล์ (ถ้าเลือก A-ก มันจะไม่ถาม user/password ให้เอง)
```bash
cd /root/k8s/config/monitoring
for V in SMTP_HOST SMTP_PORT ALERT_FROM ALERT_TO ALERT_TO_CRITICAL SMTP_USER SMTP_PASSWORD; do
    if grep -v '^[[:space:]]*#' alertmanager-config.yaml | grep -q "<${V}>"; then
        if [ "$V" = SMTP_PASSWORD ]; then
            read -rsp "ค่าของ ${V}: " NEW; echo " (รับมา ${#NEW} ตัว)"
        else
            read -rp "ค่าของ ${V}: " NEW
        fi
        if [ -n "$NEW" ]; then
            sed -i "s|<${V}>|${NEW}|" alertmanager-config.yaml; echo "  ✓ แทน ${V} แล้ว"
        else
            echo "  ⚠ ข้าม ${V} — ค่าว่าง ยังต้องกลับมาทำ"
        fi
    else
        echo "✓ ${V} แทนไปแล้ว ไม่ถาม"
    fi
done
unset NEW
chmod 600 alertmanager-config.yaml
```

> **ทำไมต้องเป็น loop ไม่ใช่ `read` เรียงกันแล้ว `sed` ทีเดียว** — แบบเรียงกันจะถามครบทุกช่อง
> ทุกครั้งที่รัน แล้ว `sed` ไปไม่เจอ placeholder ที่รอบก่อนกินไปแล้ว
> กลายเป็น "พิมพ์แล้วไม่มีอะไรเปลี่ยน" ซึ่งชวนให้เข้าใจว่าคำสั่งพัง
> ขั้นตอนที่คนต้องรันซ้ำตอนตีสอง ต้องรันซ้ำได้จริง

**ตรวจผลก่อน `helm upgrade` (ข้อ 5.3):**
```bash
cd /root/k8s/config/monitoring
grep -v '^[[:space:]]*#' alertmanager-config.yaml | grep -c '<[A-Z_]*>'
grep -E '^[[:space:]]*smtp_(smarthost|from|require_tls|auth_username)' alertmanager-config.yaml
awk -F'"' '/^[[:space:]]*smtp_auth_password:/{print "smtp_auth_password ยาว " length($2) " ตัว"}' alertmanager-config.yaml
```

**ควรเห็น:** บรรทัดแรกเป็น `0` · ค่าที่ตั้งไว้ตรงกับที่ทีม mail ให้มา ·
ถ้าเลือก A-ข ต้องเห็น `smtp_require_tls: true` และ `smtp_auth_password ยาว N ตัว` (N ตรงกับที่พิมพ์)
· ถ้าเลือก A-ก สองบรรทัดสุดท้ายต้องไม่มีอะไรออกมาเลย

> ที่ต้องตัดบรรทัดคอมเมนต์ออกก่อนนับ `<...>` เพราะในไฟล์ยังมี `<TEAMS_WEBHOOK_URL>`
> ค้างอยู่ในคอมเมนต์ของทางเลือก Teams ที่ยังไม่ได้เปิดใช้ — ปกติ ไม่ต้องแทน
>
> **รหัส SMTP จะไปอยู่ในไฟล์บน master01 และใน secret ของ helm release** — ห้ามแทนค่าลงไฟล์
> ชุดที่อยู่ใน repo บนเครื่องคุณ เพราะไฟล์นั้นถูก commit · จดไว้ที่ `secrets.env`
> คีย์ `SMTP_PASSWORD` ด้วย จะได้ไม่ต้องไปขอใหม่ตอนสร้าง cluster รอบหน้า

#### ข.2 ตรวจ relay ด้วยคำสั่งใน pod

##### ข.2.1 ถ้า log บอกว่า relay ไม่ประกาศ STARTTLS

ดูว่า relay ประกาศอะไรบ้างบนพอร์ตที่ต่อได้จริง — **รันจาก pod** เพราะนั่นคือเส้นทางที่
Alertmanager ใช้ และ **ห้ามใส่ `-it`** เพราะ TTY จะกลืน output ของ pipe จนเห็นแต่บรรทัด `220`:
```bash
kubectl -n monitoring run smtp-test --rm --attach --restart=Never --image=busybox:1.36 -- \
  sh -c '(printf "EHLO myhr\r\n"; sleep 4; printf "QUIT\r\n"; sleep 1) | nc -w 10 "$0" "$1"' "$H" "$P"
```

| relay ประกาศ | แปลว่า | ทางแก้ |
|---|---|---|
| มี `STARTTLS` | ใช้พอร์ตนั้นได้เลย | ตั้ง `smtp_smarthost` เป็นพอร์ตนั้น + `require_tls: true` |
| ไม่มีทั้ง `STARTTLS` และ `AUTH` | relay รับจาก IP ที่อนุญาตโดยไม่ต้องล็อกอิน | ปิด auth ตามคำสั่งข้างล่าง แล้ว `helm upgrade` ซ้ำ |
| มี `AUTH` แต่ไม่มี `STARTTLS` | **ยังไม่สรุป** — ประกาศ AUTH ไม่ได้แปลว่าบังคับ | ทดสอบต่อด้วยบล็อกถัดไปก่อนไปขอใคร |

**ทดสอบว่า relay บังคับ auth จริงไหม** — คุยถึงขั้น `RCPT TO` แต่ไม่ส่ง `DATA`
จึงไม่มีเมลออกไปจริงสักฉบับ (แทน `<...>` ด้วยที่อยู่จริงก่อนรัน):
```bash
kubectl -n monitoring run smtp-test --rm --attach --restart=Never --image=busybox:1.36 -- \
  sh -c '(printf "EHLO myhr\r\n"; sleep 2; printf "MAIL FROM:<ผู้ส่ง>\r\n"; sleep 2; printf "RCPT TO:<ปลายทาง>\r\n"; sleep 3; printf "QUIT\r\n"; sleep 1) | nc -w 15 "$0" "$1"' "$H" "$P"
```

| บรรทัดหลัง `RCPT TO` | แปลว่า | ทางแก้ |
|---|---|---|
| `250 ... Ok` | ไม่บังคับ auth | ปิด auth ตามคำสั่งข้างล่าง แล้ว `helm upgrade` ซ้ำ — จบ |
| `530 SMTP authentication is required` | บังคับ auth และไม่มี STARTTLS บนพอร์ตนี้ | ส่งตรงไม่ได้ → ไปที่ ข.2.2 |
| `554` · `relay access denied` | relay ไม่ยอมส่งต่อออกนอกโดเมนให้ IP นี้ | ขอทีม mail ใส่ IP ขาออกของ cluster ใน allow-list |

**ปิด auth ทั้งชุด** (สำหรับสองแถวที่บอกว่าไม่ต้องล็อกอิน):
```bash
cd /root/k8s/config/monitoring
sed -i -E -e 's|^([[:space:]]*)(smtp_auth_)|\1# \2|' \
          -e 's|smtp_require_tls: true|smtp_require_tls: false|' alertmanager-config.yaml
grep -E '^[[:space:]]*smtp_' alertmanager-config.yaml
```
**ควรเห็น:** เหลือแค่ `smtp_smarthost` · `smtp_from` · `smtp_require_tls: false`
แล้วกลับไปรัน `helm upgrade` ในข้อ 5.3 ซ้ำ · เมลที่ค้างคิว retry อยู่จะถูกส่งเองไม่ต้องยิงใหม่

##### ข.2.2 relay บังคับ auth แต่พอร์ตที่ออกได้ไม่มี STARTTLS

Alertmanager ส่งตรงไม่ได้แน่นอนในสภาพนี้ — มันปฏิเสธการส่งรหัสผ่านบนช่องที่ไม่เข้ารหัส
แบบฮาร์ดโค้ด และนั่นถูกต้องแล้ว **มีสามทางออก เลือกได้ทันทีตามว่าอันไหนเป็นไปได้ก่อน**

| ทางออก | ต้องพึ่งใคร | ได้เมื่อไร |
|---|---|---|
| ขอเปิดพอร์ตที่มี STARTTLS (มัก 587) | ทีม network **และ** relay ต้องเปิด 587 จริง | ต้องรอ |
| ขอ allow-list ให้ส่งจาก IP ของ cluster โดยไม่ต้อง auth | ทีม mail | ต้องรอ |
| **ตัวกลางในคลัสเตอร์ที่ยอมทำ auth บนพอร์ต 25 แทน** | ไม่ต้องพึ่งใคร | ทำเองได้วันนี้ → ข้อ 5 (ทางหลักของ cluster นี้) |

**พอได้ 587 มาแล้ว อย่าเพิ่งเชื่อว่ามี STARTTLS** ตรวจก่อนหนึ่งครั้ง:
```bash
kubectl -n monitoring run smtp-test --rm --attach --restart=Never --image=busybox:1.36 -- \
  sh -c '(printf "EHLO myhr\r\n"; sleep 4; printf "QUIT\r\n"; sleep 1) | nc -w 10 "$0" 587' "$H"
```
เห็น `250-STARTTLS` แล้วค่อยกลับไปทำ ข.1 ขั้น A-ข ด้วยพอร์ต 587

##### ข.2.3 ต่อพอร์ตไม่ได้ — แยกก่อนว่าใครดรอป

`timeout` แปลว่า "ไม่มีใครตอบ" เท่านั้น **ไม่ได้แปลว่าไฟร์วอลล์ขององค์กรบล็อก** —
ตัว relay เองไม่ได้เปิดพอร์ตนั้นแล้วดรอปทิ้งก็ให้อาการเดียวกันเป๊ะ ชนิดของ error
ต่างหากที่บอกได้ และ **ห้ามใช้ `/dev/tcp` ของ bash ทดสอบ** — บนเครื่องที่ปิดฟีเจอร์นี้
มันจะรายงานว่าทุกพอร์ตตัน รวมพอร์ตที่เปิดอยู่จริง (เจอมาแล้วกับ cluster ชุดนี้)

**จาก node:**
```bash
python3 - <<'EOF'
import socket
for p in (25, 465, 587, 2525):
    try:
        s = socket.create_connection(('<IP ของ relay>', p), 5); print(p, 'เปิด'); s.close()
    except Exception as e:
        print(p, 'ไม่ได้ —', type(e).__name__, e)
EOF
```

**จากเครื่องของคุณ** (คนละต้นทาง คนละกฎ — PowerShell):
```bash
foreach ($p in 25,465,587,2525) { $r = Test-NetConnection <IP ของ relay> -Port $p -WarningAction SilentlyContinue; "$p : $($r.TcpTestSucceeded)" }
```

| ที่เจอ | สรุปได้ว่า |
|---|---|
| `ConnectionRefusedError` (RST) | server ไม่ได้เปิดพอร์ตนั้น — ไม่เกี่ยวกับ network ขององค์กร ต้องคุยกับทีม mail |
| `TimeoutError` ทั้งจาก cluster และจากเครื่องคุณ | ผลเหมือนกันสองต้นทาง → น่าจะเป็นฝั่ง relay/ผู้ให้บริการ ไม่ใช่กฎเฉพาะ cluster |
| cluster timeout แต่เครื่องคุณต่อได้ | ตรงนี้ถึงจะเป็นกฎฝั่ง network จริง และมีหลักฐานให้ไปคุย |

#### ข.3 ถอดตัวกลางออก

1. เปิด `email_configs` และ `smtp_*` ที่คอมเมนต์ไว้ใน `alertmanager-config.yaml` กลับ
   แล้วลบ `webhook_configs` ออก
2. `helm upgrade` ตามข้อ 5.3 · ยิงของปลอมตามข้อ 5.4 · **ยืนยันว่าเมลเข้าจริง**
3. เมื่อยืนยันแล้วเท่านั้นค่อยลบตัวกลาง:
```bash
kubectl delete -f /root/k8s/deployments/alert-mail-relay/alert-mail-relay.yaml
kubectl -n monitoring delete secret alert-mail
```

**ลำดับสำคัญ** — อย่าลบตัวกลางก่อนพิสูจน์ว่าทางตรงส่งได้จริง ไม่งั้นจะเหลือช่วงที่
ไม่มีใครได้รับ alert เลยโดยไม่มีอะไรฟ้อง
