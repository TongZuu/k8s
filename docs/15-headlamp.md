# บทที่ 15 — Headlamp (เว็บ UI ที่กด scale / แก้ config ได้)

> **รันที่: 👑 master01**
> **เวลาที่ใช้:** ~25 นาที
> **ต้องผ่านบทที่ 09 ข้อ 1** — ต้องมี metrics-server ไม่งั้นตัวเลข CPU/RAM ในหน้าเว็บจะว่าง
> **ต้องผ่านบทที่ 07** เฉพาะกรณีจะเปิดผ่าน `dashboard.myhr.co.th` (ข้อ 5 · เป็นทางเลือก)

---

## ทำไมถึงไม่เคยเห็นมันเลยจนถึงบทนี้

**เพราะบทที่ 01–14 ไม่เคยติดตั้ง web UI ตัวไหนเลย** — ไม่ได้พัง ไม่ได้ซ่อนอยู่ที่ไหน มันไม่เคยมี

Kubernetes **ไม่ได้แถม** web UI มาให้ตั้งแต่แรก ต่างจาก cluster เดิมที่คนก่อนหน้า
ลง Kubernetes Dashboard เอาไว้จนทุกคนเคยชินว่ามันมาคู่กัน ของที่บทที่ 09 ลงไปคือ
**Grafana** ซึ่งเป็นคนละตัว คนละงาน และแทนกันไม่ได้

| อยากทำอะไร | ใช้ตัวไหน |
|---|---|
| **กด scale เป็น 3 replica เดี๋ยวนี้** · แก้ ConfigMap · restart Deployment · อ่าน Secret | **Headlamp (บทนี้)** |
| ตอนนี้ pod ไหนกิน CPU เท่าไร (ค่าปัจจุบัน) | Headlamp · หรือ `kubectl top` |
| **เมื่อคืนตอนตีสามเกิดอะไรขึ้น** · กราฟย้อนหลัง 30 วัน · alert | [Grafana (บทที่ 09)](09-observability.md) |
| ตามหา log ของ pod ที่ตายไปแล้ว | [Grafana (บทที่ 14)](14-grafana-logs.md) |
| ไล่ปัญหาเป็นขั้นตอน | [`kubectl` (บทที่ 13)](13-troubleshooting.md) |

> **Headlamp ไม่เก็บข้อมูลย้อนหลังเลยสักวินาที** ตัวเลขที่เห็นคือค่า ณ ตอนนั้น
> ที่อ่านต่อจาก metrics-server · **ห้ามใช้ตัวนี้ตอบคำถามย้อนหลัง** นั่นคืองานของ Prometheus

### ทำไม Headlamp ไม่ใช่ Kubernetes Dashboard

Kubernetes Dashboard **ยังใช้ได้อยู่ ไม่ได้ถูกประกาศเลิก** — แต่ทีม Kubernetes เอง
เขียน[คู่มือย้ายจาก Dashboard ไป Headlamp](https://kubernetes.io/blog/2026/07/13/kubernetes-dashboard-to-headlamp/)
ไว้บนบล็อกทางการ (13 ก.ค. 2026) ซึ่งเป็นสัญญาณทิศทางที่ชัดพอ

และเฉพาะกับ cluster ชุดนี้ Headlamp ง่ายกว่ามากด้วยเหตุผลที่จับต้องได้:

| | Kubernetes Dashboard | Headlamp |
|---|---|---|
| pod ที่ต้องดูแล | ~5 (รวม **Kong** ที่ลากมาเป็น sub-chart) | **1** |
| sub-chart | Kong + metrics-server (ต้องจำปิด ไม่งั้นแย่ง `v1beta1.metrics.k8s.io` กับบทที่ 09) | **ไม่มีเลย** |
| ต่อ Gateway API | ต้องงัดเปิดพอร์ต 80 ของ Kong แล้วเขียน HTTPRoute แยกไฟล์ | **`httpRoute` อยู่ใน chart** เปลี่ยนค่าเดียว |
| PSA | ต้องยอมลดเป็น `baseline` เพราะคุม securityContext ของ Kong ไม่ได้ | ตั้ง **`restricted`** ได้ตรง ๆ |

> ⚠️ **สิ่งที่ต่างจนต้องบอกทีม dev ล่วงหน้า:** Headlamp **เน้นแก้ผ่าน YAML**
> ส่วน Dashboard ตัวเก่ามีปุ่ม Scale แยกให้กด — ให้ลองกดจริงในข้อ 4 แล้วบอกทีม
> ให้ตรงกับที่เห็น อย่าไปสัญญาว่า "เหมือนของเดิมทุกอย่าง"

---

## 0 · 🔴 ก่อนติดตั้ง — สองเรื่องที่ต้องเข้าใจก่อน

**เรื่องที่ 1 · ตัวนี้คือ `kubectl` ที่มีปุ่ม**

Headlamp ที่รันใน cluster **ไม่มี user/password ของตัวเอง** มันรับ **token ของ
ServiceAccount** แล้วยิงคำสั่งไป apiserver ในนามบัญชีนั้น → **สิทธิ์ที่คนเห็นบนหน้าเว็บ
เท่ากับสิทธิ์ของ token ที่เอามาใส่ เป๊ะ ๆ** ไม่มีชั้นสิทธิ์ของ "แอป Headlamp" คั่นอยู่เลย

ผลที่ตามมา: **คนที่ได้ token ของ `headlamp-admin` = ได้ `cluster-admin`** ไม่ว่าจะเข้า
ทางเว็บ หรือเอา token นั้นไปยิง `curl` ตรง ๆ ก็ได้เท่ากัน และ **`kubectl auth can-i`
คือเครื่องมือตรวจของบทนี้** ไม่ใช่การไล่กดดูบนหน้าเว็บ

**เรื่องที่ 2 · 🔴 ค่าเริ่มต้นของ chart คือ `cluster-admin`**

`clusterRoleBinding.create` ของ chart เป็น **`true`** และ `clusterRoleName` เป็น
**`cluster-admin`** — ติดตั้งแบบไม่แตะอะไรเลยจะได้ **ServiceAccount ที่เป็น
cluster-admin นอนอยู่ใน cluster ตลอดเวลา**

ทำไมถึงอันตรายกว่าที่ฟังดู: SA ตัวนั้นคือ SA ของ pod ไม่ใช่ของคนล็อกอิน แปลว่า
**การล็อกอินจะไม่มีความหมาย** ใครก็ตามที่เปิดหน้าเว็บถึง หรือ exec เข้า pod ได้
หรือได้ token ของ SA นั้น = เป็นเจ้าของ cluster โดยไม่ต้องผ่านหน้า login สักขั้น

`config/headlamp/headlamp-values.yaml` **ปิดมันไว้แล้ว** (`create: false`) ข้อ 2
มีคำสั่งพิสูจน์ว่าปิดจริง — ห้ามข้ามข้อนั้น

---

## 1 · สร้าง namespace ก่อน — อย่าให้ helm สร้างให้

**ต้องติด label PSA เองตั้งแต่ต้น** ถ้าปล่อยให้ `helm --create-namespace` สร้าง
จะได้ namespace ที่ไม่มี label อะไรเลย ซึ่งแปลว่า **`privileged`** — สวนทางกับบทที่ 10
ทั้งบท และจะไม่มีใครสังเกตเพราะไม่มี error

```bash
kubectl create namespace headlamp

kubectl label namespace headlamp \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

**ตรวจ:**
```bash
kubectl get ns headlamp -L pod-security.kubernetes.io/enforce
```
**ควรเห็น:** คอลัมน์ `ENFORCE` เป็น `restricted` — **เท่ากับ namespace ของ application**
ไม่ต้องมีข้อยกเว้น ไม่ต้องก่อหนี้

> ตั้ง `restricted` ได้เพราะ chart นี้มี pod เดียวและเราคุม `securityContext`
> ของมันได้เองครบทั้ง 5 ข้อใน `headlamp-values.yaml`
> (`runAsNonRoot` · `runAsUser` · `allowPrivilegeEscalation: false` ·
> `capabilities.drop: [ALL]` · `seccompProfile: RuntimeDefault`)
>
> **ถ้าติดตั้งแล้ว pod ไม่ยอมขึ้น** ให้ดูสาเหตุจริงก่อนลดเป็น `baseline`:
> `kubectl -n headlamp describe rs | grep -A5 violates` — ข้อที่ตกจะบอกชื่อ field ตรง ๆ
> แล้วเติมลงใน values ได้เลย การลดเป็น `baseline` คือทางสุดท้าย ไม่ใช่ทางแรก

---

## 2 · ติดตั้ง

```bash
set -a && source /root/k8s/versions.env && set +a

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update

helm install headlamp headlamp/headlamp \
  --namespace headlamp \
  --version "${HEADLAMP_CHART}" \
  -f /root/k8s/config/headlamp/headlamp-values.yaml

kubectl -n headlamp rollout status deploy/headlamp --timeout=3m
```

**ตรวจ:**
```bash
kubectl -n headlamp get pods
```
**ควรเห็น:** pod เดียว `1/1 Running` — ถ้ามีมากกว่านั้นแปลว่า `pluginsManager` ถูกเปิดไว้

**🔴 พิสูจน์ว่า SA ของ Headlamp ไม่ได้เป็น cluster-admin — ข้อนี้ห้ามข้าม:**
```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:headlamp:headlamp 2>/dev/null | head -5
```
**ควรเห็น:** มีแต่ `selfsubjectreviews` / `selfsubjectaccessreviews` (สิทธิ์ที่ทุกคนมี)
**ห้ามเห็นบรรทัดที่เป็น `*.*` หรือ `*  []  []  [*]`** — ถ้าเห็นแปลว่า `clusterRoleBinding`
ยังเปิดอยู่ ให้แก้ values แล้ว `helm upgrade` ทันทีก่อนทำข้อต่อไป

**ดูอีกมุมหนึ่งเพื่อความแน่ใจ — ต้องไม่มีอะไรออกมาเลย:**
```bash
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | select(.subjects[]?.namespace=="headlamp") | .metadata.name + " -> " + .subjects[0].name' \
  | grep -v headlamp-admin
```
**ควรเห็น: ไม่มีอะไรออกมาเลย** — บรรทัดเดียวที่ยอมให้มีคือ `headlamp-admin -> headlamp-admin`
ซึ่งเป็นบัญชีที่คนถือ token เอง ไม่ใช่ SA ของ pod จึงถูกกรองออกไปแล้วด้วย `grep -v`

---

## 3 · สร้างบัญชี แล้วออก token

**สามระดับ เลือกให้ตรงกับคนใช้** — รายละเอียดอยู่ในหัวไฟล์:
```bash
kubectl apply -f /root/k8s/config/headlamp/headlamp-rbac.yaml
```

| บัญชี | ทำอะไรได้ | ให้ใคร |
|---|---|---|
| `headlamp-viewer` | อ่านอย่างเดียวทั้ง cluster · **ไม่เห็น Secret** | แจกกว้างได้ |
| `headlamp-operator` | **scale / แก้ config / restart** เฉพาะ `myhr-prod` + `myhr-uat` (เห็น Secret สอง ns นั้น) | ทีม dev · งานประจำวัน |
| `headlamp-admin` | ทุกอย่างทั้ง cluster รวม Secret ของ `kube-system` | ops เท่านั้น · เฉพาะตอนจำเป็น |

**ออก token — อายุ 8 ชั่วโมง แล้วหมดอายุไปเอง:**
```bash
kubectl -n headlamp create token headlamp-operator --duration=8h
```

**ตรวจว่าสิทธิ์เป็นอย่างที่ตั้งใจจริง — พิสูจน์ด้วยผลที่ต่างกัน ไม่ใช่ดูว่าคำสั่งไม่ error:**
```bash
SA=system:serviceaccount:headlamp:headlamp-operator
echo "scale ใน myhr-prod         : $(kubectl auth can-i update deployments/scale -n myhr-prod --as=$SA)"
echo "อ่าน secret ใน myhr-prod   : $(kubectl auth can-i get secrets -n myhr-prod --as=$SA)"
echo "อ่าน secret ใน kube-system : $(kubectl auth can-i get secrets -n kube-system --as=$SA)"
echo "ลบ node                    : $(kubectl auth can-i delete nodes --as=$SA)"
```
**ควรเห็น:** `yes` · `yes` · **`no`** · **`no`**

> ⚠️ **ห้ามสร้าง Secret ชนิด `kubernetes.io/service-account-token` เพื่อให้ได้ token ที่ไม่หมดอายุ**
> วิธีนั้นยังทำได้อยู่และเจอในบล็อกเก่าเต็มไปหมด แต่มันคือ credential ที่มีอายุตลอดชีพ
> นอนอยู่ใน etcd — ถอนคืนได้ทางเดียวคือลบ ServiceAccount ทิ้ง ถ้ารู้สึกว่า 8 ชั่วโมงสั้นไป
> ให้ขยาย `--duration` **แล้วขยาย `config.sessionTTL` ใน values ให้เท่ากันด้วย**
> ไม่งั้นสองค่านี้จะหมดอายุคนละเวลาแล้วอาการจะอ่านไม่ออก

---

## 4 · เข้าใช้งาน — ทางหลัก

**รันบนเครื่องของคุณ** (ไม่ใช่ master01) แล้วค้างหน้าต่างไว้:
```bash
ssh -L 8080:127.0.0.1:8080 root@192.168.50.101 'kubectl -n headlamp port-forward svc/headlamp 8080:80'
```
เปิด `http://localhost:8080` → เอา token จากข้อ 3 วางลงไป

**ทางนี้คือทางที่ควรใช้เป็นค่าเริ่มต้น** เพราะคนที่เปิดได้ต้องมี kubeconfig
บน master01 อยู่แล้ว = มีชั้นกันเพิ่มอีกชั้นก่อนถึงหน้าเว็บ

**ทดสอบให้ครบ อย่าดูแค่ว่าหน้าเว็บขึ้น** — ข้อนี้คือเหตุผลทั้งหมดที่ลงตัวนี้:

1. เลือก namespace `myhr-prod` → Workloads → Deployments → `zeeme-ads`
2. **ลอง scale เป็น 2 แล้วกลับเป็นค่าเดิม**
3. ยืนยันจากอีกฝั่งด้วย `kubectl` ไม่ใช่ดูแค่บนหน้าเว็บ:
```bash
kubectl -n myhr-prod get deploy zeeme-ads -w
```
**ควรเห็น:** คอลัมน์ `READY` ขยับตามที่กดบนหน้าเว็บภายในไม่กี่วินาที

> **จดไว้ตอนนี้เลยว่าการ scale ทำผ่านอะไร** — ปุ่มแยก หรือแก้ YAML แล้วกด Save
> เพราะนี่คือสิ่งที่ต้องบอกทีม dev และเป็นจุดที่ต่างจาก Dashboard ตัวเก่า

---

## 5 · เปิดผ่าน `dashboard.myhr.co.th` — ทางเลือก อ่านก่อนทำ

> 🔴 **ตัวนี้ต่างจาก Grafana ตรงระดับความเสียหาย**
> Grafana หลุด = คนนอกเห็น metric กับ log · **ตัวนี้หลุดพร้อม token ของ admin =
> คนนอกลบทั้ง cluster ได้** ข้ามข้อนี้ไปเลยก็ได้ ข้อ 4 ใช้งานได้ครบอยู่แล้ว

**ไม่ต้องมีไฟล์ route แยก** — แก้ค่าเดียวใน `config/headlamp/headlamp-values.yaml`:

```
httpRoute:
  enabled: true
```

แล้วสั่ง upgrade ด้วยไฟล์เดิม:
```bash
set -a && source /root/k8s/versions.env && set +a

helm upgrade headlamp headlamp/headlamp \
  --namespace headlamp \
  --version "${HEADLAMP_CHART}" \
  -f /root/k8s/config/headlamp/headlamp-values.yaml
```

**ตรวจว่า route ถูกยอมรับจริง — ไม่ใช่แค่ถูกสร้าง:**
```bash
kubectl -n headlamp get httproute headlamp \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
```
**ควรเห็น:** `True`

**ตรวจจาก master01 ว่า Gateway ทำงาน** — ขั้นนี้คือ*การตรวจ* ไม่ใช่วิธีเข้าใช้งาน:
```bash
GW_IP=$(kubectl -n envoy-gateway-system get gateway myhr-gateway -o jsonpath='{.status.addresses[0].value}')
curl -sk -o /dev/null -w '%{http_code}\n' --resolve "dashboard.myhr.co.th:443:${GW_IP}" https://dashboard.myhr.co.th
```
**ควรเห็น:** `200`

> **`--resolve` ต้องใส่ชื่อจริงเสมอ** ถ้าใส่ IP ตรง ๆ SNI จะไม่ตรง listener แล้วได้
> `000` ซึ่งเป็นผลหลอก ไม่ได้แปลว่า route พัง — กับดักเดียวกับบทที่ 07 และ 09

**แล้วบนเครื่องของคุณ** ต้องให้ `dashboard.myhr.co.th` ชี้ไปที่ `GW_IP` เหมือน Grafana
(DNS ขององค์กร หรือ `C:\Windows\System32\drivers\etc\hosts` ระหว่างทดสอบ)

> ถ้าวันหนึ่งเปลี่ยน `allowedRoutes` ของ Gateway จาก `from: All` เป็น `Selector`
> ตามหมายเหตุท้าย `config/gateway/gateway.yaml`
> **ต้องติด label `gateway-access: "true"` ที่ namespace นี้ด้วย** ไม่งั้น route
> จะถูกปฏิเสธเงียบ ๆ และหน้าเว็บจะกลายเป็น `404` โดยที่ HTTPRoute ยังดูปกติ

---

## 6 · ตรวจว่าตัวเลข metric ขึ้นจริง

นี่คือจุดที่ metrics-server จากบทที่ 09 ถูกใช้งานจริงเป็นครั้งแรก

**เทียบสองฝั่งด้วยตัวเลขชุดเดียวกัน — ถ้าฝั่ง `kubectl` ว่าง ฝั่งเว็บก็จะว่าง:**
```bash
kubectl top pods -n myhr-prod
```
**ควรเห็น:** ตัวเลข CPU/MEM ไม่มี `<unknown>`

แล้วเปิดหน้าเว็บ → Workloads → Pods ใน `myhr-prod` → **ควรเห็นตัวเลข CPU/Memory
ข้างชื่อ pod ตรงกับที่ `kubectl top` บอก**

> 🔴 **ถ้า `kubectl top` ได้ตัวเลข แต่หน้าเว็บว่าง** อย่าโทษ metrics-server
> ให้เช็กสิทธิ์ของ token ที่ใช้อยู่ก่อน:
> ```bash
> kubectl auth can-i list pods.metrics.k8s.io -n myhr-prod --as=system:serviceaccount:headlamp:headlamp-operator
> ```
> ต้องได้ `yes` — ถ้าได้ `no` แปลว่า `headlamp-navigation` ใน `headlamp-rbac.yaml`
> ยังไม่ได้ apply

---

## 7 · กับดักที่เจอบ่อย

| อาการ | สาเหตุจริง |
|---|---|
| ใส่ token แล้วเด้งกลับหน้า login ทันที | token หมดอายุแล้ว ออกใหม่ด้วย `create token` |
| ล็อกอินค้างอยู่ทั้งที่ token หมดอายุแล้ว แล้ว error อ่านไม่รู้เรื่อง | `config.sessionTTL` ยาวกว่า `--duration` ของ token — ตั้งให้เท่ากัน |
| ล็อกอินได้ แต่เมนูซ้ายขึ้น error เต็มไปหมด | บัญชีนั้นอ่าน `namespaces`/`nodes` ไม่ได้ → ต้องมี `headlamp-navigation` |
| เห็นทุกอย่างแต่แก้อะไรไม่ได้ | ใช้ token ของ `headlamp-viewer` อยู่ — ถูกแล้ว ให้เปลี่ยนเป็น `headlamp-operator` |
| กด scale แล้วขึ้น `forbidden` | namespace ที่กดอยู่ไม่ได้อยู่ใน RoleBinding (มีแค่ `myhr-prod`/`myhr-uat`) |
| **เข้าหน้าเว็บได้โดยไม่ต้องใส่ token เลย** | 🔴 `clusterRoleBinding.create` ยังเป็น `true` — กลับไปทำข้อ 2 ทันที |
| pod ไม่ขึ้นเลยสักตัว `get pods` เงียบสนิท | ถูก PSA ปฏิเสธที่ชั้น ReplicaSet · `kubectl -n headlamp describe rs \| grep -A5 violates` |

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] `kubectl get ns headlamp -L pod-security.kubernetes.io/enforce` ได้ `restricted`
- [ ] pod เดียวใน namespace `headlamp` ขึ้น `1/1 Running`
- [ ] 🔴 `kubectl auth can-i --list --as=system:serviceaccount:headlamp:headlamp` **ไม่มี** `*.*`
- [ ] `kubectl auth can-i` ของ `headlamp-operator` ได้ `yes yes no no` ตามข้อ 3
- [ ] เข้าหน้าเว็บทาง port-forward แล้ว **scale Deployment ได้จริง** และ `kubectl get deploy -w` เห็นเปลี่ยนตาม
- [ ] เห็นตัวเลข CPU/Memory ข้าง pod ตรงกับ `kubectl top` (พิสูจน์ว่าต่อถึง metrics-server จริง)
- [ ] **จดไว้แล้วว่า scale ทำผ่านปุ่มหรือผ่าน YAML** และบอกทีม dev ตรงกับที่เห็นจริง
- [ ] ทีมรู้ว่าใครควรได้ token ตัวไหน และรู้ว่า token หมดอายุกี่ชั่วโมง

**➡️ ใช้คู่กับ [บทที่ 13 — Troubleshooting](13-troubleshooting.md) และ [บทที่ 14 — ดู log ใน Grafana](14-grafana-logs.md) ตอนของพัง**
