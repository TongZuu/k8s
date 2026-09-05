# บทที่ 09 — Observability

> **รันที่: 👑 master01**
> **เวลาที่ใช้:** ~45 นาที
> **ต้องผ่านบทที่ 08** — PV ทั้ง 3 ตัวต้องเป็น `Available`

---

## ทำไมบทนี้จำเป็น ไม่ใช่ของฟุ่มเฟือย

cluster เดิมไม่มี metric ย้อนหลังเลย ทำให้ตอบคำถาม **"เมื่อคืนตอนตีสามเกิดอะไรขึ้น"**
ไม่ได้ และเมื่อตอบไม่ได้ก็แก้ที่ต้นเหตุไม่ได้ — วนกลับมาเจอปัญหาเดิมซ้ำ

**และสำหรับ cluster ชุดนี้มีเหตุผลเพิ่มอีกข้อ:** เราไม่มี Ksplice จึงต้อง drain node
ทุก 1-2 เดือน ถ้าไม่มี alert เตือนว่า Deployment ไหนไม่มี PDB หรือ capacity ใกล้เต็ม
วันที่ patch จริงจะกลายเป็นวันที่ service ล่ม

---

## 1 · metrics-server

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

ชุดนี้รวม Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics
มาให้ในครั้งเดียว

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --version "${KUBE_PROM_STACK_CHART}" \
  -f /root/k8s/config/monitoring/kube-prometheus-values.yaml

kubectl -n monitoring rollout status statefulset/prometheus-monitoring-kube-prometheus-prometheus --timeout=10m
```

**ตรวจ PV ผูกถูกตัว — ต้องดูคู่ ไม่ใช่ดูแค่คำว่า `Bound`:**
```bash
kubectl -n monitoring get pvc -o custom-columns=NAME:.metadata.name,VOL:.spec.volumeName,SIZE:.spec.resources.requests.storage
```
**ควรเห็น:** PVC ของ Prometheus ผูกกับ `prometheus-data` และของ Grafana ผูกกับ `grafana-data`

> 🔴 **ดูแค่ `Bound` ไม่พอ** — ก่อนที่ PV จะมี `claimRef` ทุกก้อน PVC สามารถขึ้น `Bound` ครบ
> ได้ทั้งที่**ผูกผิดก้อน** (Grafana ไปนอนบน PV 150Gi ของ Prometheus) จึงต้องดูคอลัมน์ `VOL` เสมอ
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
kill %1
```
**ควรเห็น:** ทุกบรรทัดเป็น `up`

**ถ้ามี `down` เอาสาเหตุจริงมาก่อน อย่าเดา:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq -r '.data.activeTargets[] | select(.health=="down") | "\(.labels.job)  \(.scrapeUrl)  \(.lastError)"' | sort -u
kill %1
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

pod ตายแล้ว log หายไปด้วยถ้าไม่มีที่รวม

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

# ⚠️ pin chart version ก่อน แล้วเขียนกลับลง versions.env
helm search repo grafana/loki --versions | head -3
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
แม้แต่บรรทัดเดียว** (จะดังผ่าน alert `LokiNotReceivingLogs` ในหัวข้อถัดไป)

**แล้วยืนยันด้วยตาที่ Grafana** — เลือก pod ที่ log น้อย ๆ แล้วดูว่าบรรทัดเดียวกัน
โผล่ซ้ำหรือไม่ ต้องเห็นครั้งเดียวต่อหนึ่ง event:
```
{namespace="kube-system", container="cilium-agent"}
```

---

## 4 · เข้า Grafana

```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**เปิดผ่าน Gateway** (แนะนำ — จะได้ไม่ต้อง port-forward ทุกครั้ง):
```bash
kubectl apply -f /root/k8s/config/monitoring/grafana-route.yaml
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
curl -I --resolve "grafana.myhr.co.th:443:${GW_IP}" https://grafana.myhr.co.th
```

> ถ้าชื่อนี้ใช้ cert จาก **internal CA** (บทที่ 07 ภาคผนวก ข) ให้เพิ่ม
> `--cacert /root/k8s/myhr-root-ca.crt` ในคำสั่ง curl ข้างบน
> ถ้าใช้ **public cert** ไม่ต้อง เพราะเครื่องเชื่อ CA นั้นอยู่แล้ว

**เปลี่ยนรหัส admin ทันทีหลังเข้าครั้งแรก** และเก็บลงที่เก็บ secret ไม่ใช่ในไฟล์นี้

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

## 5 · 🔴 Alert ขั้นต่ำที่ต้องมี

chart มาพร้อม alert ของ Kubernetes พื้นฐานแล้ว แต่ **ขาดอีก 10 ข้อที่เฉพาะกับ cluster ชุดนี้**
ซึ่งมาจากข้อจำกัดที่เราเลือกไว้เอง

```bash
kubectl apply -f /root/k8s/config/monitoring/myhr-alerts.yaml
kubectl -n monitoring get prometheusrule
```

| Alert | ทำไมต้องมี |
|---|---|
| **`DeploymentWithoutPDB`** | ไม่มี GitOps มาบังคับมาตรฐาน · Deployment ที่ไม่มี PDB จะทำ drain ล่ม |
| **`DeploymentSingleReplica`** | PDB ช่วยไม่ได้ถ้ามี replica เดียว |
| **`ClusterCapacityNearNPlusOneLimit`** | requests รวมเกิน 90% ของ 32 vCPU / 96 GB → patch kernel ไม่ได้ |
| **`NodeKernelVersionMismatch`** | node บูตคนละ kernel = บั๊ก network ที่หาสาเหตุยากที่สุด |
| **`KubeCertificateExpiringSoon`** | cert หมดอายุคือสาเหตุที่ cluster เดิมเดินต่อไม่ได้ |
| **`CiliumAgentDown`** | Cilium ทำทั้ง CNI + kube-proxy + LB-IPAM และไม่มีตัวสำรอง |
| **`MonitoringDiskFillingUp`** | `/var/lib/monitoring` อยู่บน root ของ worker03 · เต็ม = node ตายทั้งเครื่อง |
| 🔴 **`LokiDiscardingLogs`** | เพดาน ingestion ทำงานแล้ว log จะหาย**เงียบ ๆ** ถ้าไม่มีข้อนี้ไม่มีใครรู้ |
| 🔴 **`LokiNotReceivingLogs`** | ระบบเก็บ log ตายจะดู "เงียบสงบ" เหมือนไม่มีอะไรผิด |
| 🔴 **`AlloyDaemonSetIncomplete`** | node ที่ไม่มี Alloy = log ของเครื่องนั้นหายโดย Loki ยังดูปกติ |

> **3 ข้อล่างมาจากธรรมชาติของระบบ log:** ความผิดพลาดของมันไม่ทำให้อะไรพัง
> มันแค่ทำให้ข้อมูล**หายไปเฉย ๆ** ซึ่งจะรู้ตัวก็ตอนที่ต้องใช้ — คือตอน incident พอดี

พร้อมของมาตรฐานที่ต้องเปิดด้วย: `KubeNodeNotReady`, `KubePodCrashLooping`,
`etcdInsufficientMembers`, `NodeFilesystemAlmostOutOfSpace`, `CiliumAgentDown`

**ตรวจว่า rule โหลดแล้ว:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/rules' | jq -r '.data.groups[].name' | sort -u
kill %1
```

---

## 6 · ตั้งปลายทางของ alert

**alert ที่ไม่มีใครเห็น = ไม่มี alert** — ข้อนี้ห้ามข้าม

```bash
kubectl -n monitoring edit secret alertmanager-monitoring-kube-prometheus-alertmanager
```
หรือแก้ที่ `config/monitoring/alertmanager-config.yaml` แล้ว apply
ตั้งปลายทางเป็น email / Line Notify / Teams ตามที่ทีมใช้จริง

**ทดสอบว่าส่งถึงจริง:**
```bash
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 &
sleep 3
curl -s -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels": {"alertname":"TestAlert","severity":"warning"},
  "annotations": {"summary":"ทดสอบว่า alert ส่งถึงจริง"}
}]'
kill %1
```
**ต้องเห็นข้อความจริงเข้ามาที่ปลายทาง** ถ้าไม่เข้าให้แก้จนกว่าจะเข้า

---

## 7 · กันไม่ให้ monitoring กิน disk จนเต็ม

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

### ตรวจว่าตัวกรอง noise ไม่ได้ตัดของดีทิ้ง

`alloy-values.yaml` มี `stage.drop` ที่ทิ้ง log ของ healthcheck ที่สำเร็จ — **ของที่ทิ้งแล้ว
หายถาวร ไม่มีทางกู้** จึงต้องดูเป็นระยะว่ามันทิ้งเยอะผิดปกติหรือเปล่า

```bash
kubectl -n monitoring port-forward ds/alloy 12345:12345 &
sleep 3
curl -s http://localhost:12345/metrics | grep loki_process_dropped_lines_total
kill %1
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
- [ ] PrometheusRule ของ MyHR โหลดแล้วครบ 10 ข้อ
- [ ] **ประกาศกฎ log 3 ข้อให้ทีม dev รู้แล้ว** (stdout เท่านั้น · JSON บรรทัดเดียว · มีเพดาน)
- [ ] 🔴 **ยิง test alert แล้วมีข้อความเข้าปลายทางจริง**
- [ ] จด disk usage เริ่มต้นไว้เป็น baseline

**➡️ ต่อที่ [บทที่ 10 — Security Baseline](10-security.md)**
