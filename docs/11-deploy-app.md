# บทที่ 11 — Deploy Application

> **รันที่: 👑 master01 หรือเครื่อง admin ที่มี kubeconfig**
> **ผู้อ่าน: dev + ops**
> **ต้องผ่านบทที่ 10** — PSA `restricted` และ NetworkPolicy ต้องทำงานแล้ว

---

## 🔴 อ่านตรงนี้ก่อน — เราไม่มี GitOps

D9 เลือก `kubectl apply` มือ ซึ่งเป็นการตัดสินใจที่สมเหตุสมผลในรอบนี้
(ของใหม่เยอะพออยู่แล้ว) แต่แลกมาด้วยว่า **ไม่มีอะไรบังคับให้ manifest ผ่านมาตรฐาน**

และมันไปชนกับข้อเท็จจริงจากบทที่ 12 พอดี:
> เราไม่มี Ksplice จึงต้อง drain ทุก node ทุก 1-2 เดือน
> **ถ้ามี Deployment สักตัวที่ไม่มี PDB หรือมี replica เดียว rolling reboot จะทำ service ล่มจริง**

จึงต้องมี 3 อย่างนี้มาแทนตัวบังคับที่หายไป:

| | ทำอะไร |
|---|---|
| **1. apply จาก git เท่านั้น** | ห้าม `kubectl edit` บน cluster ตรง ๆ เด็ดขาด |
| **2. policy check ที่ CI** | ตกทันทีถ้า manifest ไม่ครบมาตรฐาน |
| **3. alert จับ Deployment ที่ไม่มี PDB** | ตั้งไว้แล้วในบทที่ 09 |

---

## 1 · โครงสร้าง repo ของ manifest

```
myhr-k8s-manifests/
├── prod/
│   ├── zeeme-ads/{deployment.yaml, service.yaml, pdb.yaml, httproute.yaml}
│   ├── zeeme-hr/...
│   └── kustomization.yaml
├── uat/
│   └── ...
└── .gitlab-ci.yml          หรือ .github/workflows/validate.yaml
```

**กติกา:** ทุกอย่างที่อยู่บน cluster ต้องมีต้นฉบับในนี้
ถ้าของบน cluster ไม่ตรงกับ git ให้ถือว่า **git ถูก** แล้ว apply ทับ

---

## 2 · แม่แบบ manifest

```bash
\cp -f /root/k8s/config/app/deployment-template.yaml ./zeeme-ads.yaml
sed -i 's/APPNAME/zeeme-ads/g' ./zeeme-ads.yaml
```
แล้วแก้ image digest, พอร์ต และ resources ให้ตรงกับ service จริง

### สิ่งที่เปลี่ยนจาก `zeeme-ads/deployment.yml` เดิม

| รายการ | ของเดิม | แม่แบบใหม่ | ทำไม |
|---|---|---|---|
| ผู้ใช้ที่รัน | `runAsUser: 0` | `runAsNonRoot` + uid 10001 | PSA `restricted` บล็อก root |
| filesystem | เขียนได้ทั้งหมด | `readOnlyRootFilesystem` + emptyDir ที่ `/tmp` | ลดผลกระทบถ้าถูกเจาะ |
| capabilities | ครบตาม default | `drop: ["ALL"]` | ไม่มี container ไหนต้องใช้ |
| `resources` | **ไม่มี** | มีครบ requests + limits.memory | ไม่มี = scheduler มั่ว + quota บล็อกทั้ง namespace |
| `probes` | **ไม่มี** | ครบ 3 ตัว | Spring Boot เริ่มช้า ต้องมี `startupProbe` |
| **`PodDisruptionBudget`** | **ไม่มี** | `minAvailable: 1` | **drain node แล้วดับถ้าไม่มี** |
| `replicas` | 1 | **≥ 2** | PDB ช่วยไม่ได้ถ้ามีตัวเดียว |
| anti-affinity | **ไม่มี** | `topologySpreadConstraints` | replica 2 ตัวบน node เดียว = ไร้ความหมาย |
| image tag | `:0.0.5` | `:1.0.0@sha256:...` | tag เขียนทับได้ digest ไม่ได้ |
| Service type | NodePort | **ClusterIP** | เข้าผ่าน Gateway ตัวเดียว |

> ⚠️ **`limits.cpu` ตั้งใจไม่ใส่** — CPU throttling ทำให้ latency แย่ลงโดยไม่ช่วยอะไร
> ถ้าคุม `requests` ดีแล้ว ส่วน `limits.memory` **ต้องมี** เพราะ memory ไม่มี throttling
> มีแต่ OOM kill

---

## 3 · Deploy

```bash
kubectl apply -f zeeme-ads.yaml
kubectl -n myhr-prod rollout status deploy/zeeme-ads --timeout=5m
```

**ตรวจครบ 5 ข้อ:**
```bash
kubectl -n myhr-prod get deploy,svc,pdb,httproute -l app.kubernetes.io/name=zeeme-ads
kubectl -n myhr-prod get pods -l app.kubernetes.io/name=zeeme-ads -o wide
```
**ควรเห็น:** pod **กระจายคนละ node** · PDB มี `ALLOWED DISRUPTIONS = 1` · HTTPRoute `ACCEPTED=True`

**ทดสอบจากนอก cluster:**
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
curl -I --cacert /root/k8s/myhr-root-ca.crt \
     --resolve "zeeme-ads.myhr.co.th:443:${GW_IP}" https://zeeme-ads.myhr.co.th
```

---

## 4 · ถ้า deploy ไม่ผ่าน — 3 สาเหตุที่พบบ่อยที่สุด

### `violates PodSecurity "restricted"`
manifest ยังใช้ `runAsUser: 0` หรือขาด `securityContext` — เทียบกับแม่แบบ
```bash
kubectl -n myhr-prod get events --sort-by=.lastTimestamp | tail -10
```

### pod ค้าง `Pending`
```bash
kubectl -n myhr-prod describe pod <ชื่อ> | tail -20
```
- `Insufficient cpu/memory` → ชน ResourceQuota หรือ cluster เต็ม
- `didn't match pod topology spread constraints` → replica มากกว่าจำนวน node
- `persistentvolumeclaim not found` → **cluster นี้ไม่มี dynamic storage (D8)**

### pod `Running` แต่เรียกไม่ได้
เกือบทุกครั้งเป็น NetworkPolicy — ดูของจริงอย่าเดา:
```bash
kubectl -n kube-system exec -it ds/cilium -- \
  hubble observe --namespace myhr-prod --verdict DROPPED --last 50
```
แล้วเปิดเฉพาะเส้นที่ถูก drop จริง

---

## 5 · 🔴 Policy check ที่ CI

**นี่คือสิ่งที่มาแทน GitOps** ถ้าข้ามข้อนี้ ข้อ 1-4 จะไร้ความหมายภายในไม่กี่เดือน

```bash
\cp -f /root/k8s/config/app/validate-manifests.sh ./scripts/
```

ตัวสคริปต์ตรวจ 6 ข้อและ **exit 1 ถ้าไม่ผ่าน**:

1. schema ถูกต้องตาม Kubernetes 1.36 (`kubeconform`)
2. ทุก Deployment มี **PDB คู่กัน**
3. `replicas >= 2`
4. มี `resources.requests` ครบทุก container
5. มี `readinessProbe` และ `livenessProbe`
6. ไม่มี `runAsUser: 0` และไม่มี image ที่เป็น `:latest`

```yaml
# .gitlab-ci.yml
validate:
  stage: test
  image: alpine:3.20
  before_script:
    - apk add --no-cache bash curl yq
    - curl -sSL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz | tar xz -C /usr/local/bin
  script:
    - ./scripts/validate-manifests.sh prod/
```

> **ถูกกว่า Argo CD มากและได้ประโยชน์หลักไปแล้ว**
> ถ้าภายหลังอยากได้ Argo CD ให้ทำหลัง Phase 5 ตอน manifest ทุกตัวอยู่ใน git เรียบร้อยแล้ว
> ตอนนั้นจะเหลือแค่ชี้ Argo ไปที่ repo ที่มีอยู่ ไม่ใช่โครงการใหญ่

---

## 6 · ย้าย workload จาก cluster เดิม — ทีละตัว

**อย่าย้ายทีเดียวหมด** ลำดับที่ปลอดภัย:

1. เลือก service ที่**ไม่มีใครพึ่ง**ก่อน (leaf service)
2. แปลง manifest ตามแม่แบบ แล้ว deploy ลง `myhr-uat` ก่อน
3. ทดสอบจน uat ผ่าน
4. deploy ลง `myhr-prod` แต่**ยังไม่ตัด DNS**
5. ทดสอบ prod ผ่าน `--resolve` ให้แน่ใจก่อน
6. **ค่อยย้าย DNS record** มาที่ Gateway IP
7. เฝ้า Grafana 24 ชั่วโมง แล้วค่อยไป service ถัดไป

**ก่อนย้ายทุกตัว ตรวจ capacity:**
```bash
kubectl get pods -A -o json | jq -r '
  [.items[] | select(.spec.nodeName | test("worker"))
   | .spec.containers[].resources.requests.cpu // "0"]
  | map(sub("m$";"") | tonumber / (if test("m") then 1 else 0.001 end))
  | add / 1000' 2>/dev/null || kubectl describe nodes | grep -A5 'Allocated resources'
```
**ผลรวมต้องไม่เกิน 32 vCPU / 96 GB** — นั่นคือเพดาน N+1 ไม่ใช่ 48/144

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] repo ของ manifest สร้างแล้วและมีทุกอย่างที่อยู่บน cluster
- [ ] service แรก deploy ผ่านและเรียกได้จากนอก cluster ผ่าน HTTPS
- [ ] pod **กระจายคนละ node** จริง
- [ ] ทุก Deployment มี PDB · `replicas >= 2` · resources · probes ครบ
- [ ] 🔴 **CI policy check ทำงานและ block PR ที่ manifest ไม่ผ่านได้จริง**
- [ ] alert `DeploymentWithoutPDB` ไม่ดัง
- [ ] ทีมรู้กติกา **"ห้าม `kubectl edit` บน cluster"** แล้ว
- [ ] ผลรวม requests ยังไม่เกินเพดาน N+1

**➡️ ต่อที่ [บทที่ 12 — Day-2 Operations](12-day2-operations.md)** ← **บทที่สำคัญที่สุด**
