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
  --set 'args={--kubelet-preferred-address-types=InternalIP}'

kubectl -n kube-system rollout status deploy/metrics-server --timeout=3m
```

**ตรวจ — รอ ~60 วินาทีให้เก็บ metric รอบแรกก่อน:**
```bash
kubectl top nodes
kubectl top pods -A | head
```
**ควรเห็น:** ตัวเลข CPU/MEM ของทั้ง 6 node ไม่มี `<unknown>`

> ถ้าเจอ `error: Metrics API not available` ให้รออีก 1 นาที ถ้ายังไม่ได้ให้ดู
> `kubectl -n kube-system logs deploy/metrics-server` — สาเหตุที่พบบ่อยคือ
> certificate ของ kubelet ไม่ผ่านการตรวจ ซึ่งแก้ด้วยการเติม `--kubelet-insecure-tls`
> **แต่ให้ดูสาเหตุจริงก่อน อย่าเติม flag นี้แบบไม่คิด**

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

**ตรวจ PV ผูกแล้ว:**
```bash
kubectl get pv
kubectl -n monitoring get pvc
```
**ควรเห็น:** `prometheus-data` และ `grafana-data` เปลี่ยนจาก `Available` เป็น **`Bound`**

> ถ้า PVC ค้าง `Pending` ให้ดู `kubectl -n monitoring describe pvc <ชื่อ>`
> สาเหตุที่พบบ่อยคือขนาดที่ขอไม่ตรงกับ PV หรือ `storageClassName` ไม่ตรง

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
**ควรเห็น:** ทุกบรรทัดเป็น `up` — ถ้ามี `down` ให้ไล่ดูทีละตัวก่อนไปต่อ

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
curl -I --cacert /root/k8s/myhr-root-ca.crt \
     --resolve "grafana.myhr.co.th:443:${GW_IP}" https://grafana.myhr.co.th
```

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

chart มาพร้อม alert ของ Kubernetes พื้นฐานแล้ว แต่ **ขาด 4 ข้อที่เฉพาะกับ cluster ชุดนี้**
ซึ่งมาจากข้อจำกัดที่เราเลือกไว้เอง

```bash
kubectl apply -f /root/k8s/config/monitoring/myhr-alerts.yaml
kubectl -n monitoring get prometheusrule
```

| Alert | ทำไมต้องมี |
|---|---|
| **`DeploymentWithoutPDB`** | ไม่มี GitOps มาบังคับมาตรฐาน · Deployment ที่ไม่มี PDB จะทำ drain ล่ม |
| **`ClusterCapacityNearNPlusOneLimit`** | requests รวมเกิน 90% ของ 32 vCPU / 96 GB → patch kernel ไม่ได้ |
| **`NodeKernelVersionMismatch`** | node บูตคนละ kernel = บั๊ก network ที่หาสาเหตุยากที่สุด |
| **`KubeCertificateExpiringSoon`** | cert หมดอายุคือสาเหตุที่ cluster เดิมเดินต่อไม่ได้ |

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

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl top nodes` ขึ้นตัวเลขครบ 6 เครื่อง
- [ ] PV `prometheus-data`, `grafana-data`, `loki-data` เป็น **`Bound`**
- [ ] `node-exporter` ครบ 6 ตัว · Prometheus target ทุกตัว `up`
- [ ] Alloy DaemonSet `6/6` และค้น log ใน Grafana เจอ
- [ ] เข้า Grafana ผ่าน `https://grafana.myhr.co.th` ได้และ**เปลี่ยนรหัส admin แล้ว**
- [ ] PrometheusRule ของ MyHR โหลดแล้วครบ 4 ข้อ
- [ ] 🔴 **ยิง test alert แล้วมีข้อความเข้าปลายทางจริง**
- [ ] จด disk usage เริ่มต้นไว้เป็น baseline

**➡️ ต่อที่ [บทที่ 10 — Security Baseline](10-security.md)**
