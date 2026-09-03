# บทที่ 10 — Security Baseline

> **รันที่: 🎩 master ทั้ง 3 (สำหรับ etcd encryption) + 👑 master01 (ที่เหลือ)**
> **เวลาที่ใช้:** ~60 นาที
> **ต้องผ่านบทที่ 09** — ต้องมี monitoring ก่อน เพราะขั้นตอนบางอย่างอาจทำของพัง

---

## ทำไมบทนี้ไม่ใช่ทางเลือก

ระบบนี้เก็บ **ข้อมูลส่วนบุคคลของพนักงาน** ซึ่งทำให้เรื่องที่หลายที่ถือเป็น "ทำก็ดี"
กลายเป็นข้อกำหนดจริง โดยเฉพาะ NetworkPolicy แบบ default-deny และ encryption at rest

**และมีหนี้เก่าที่ต้องจ่ายด้วย:** คู่มือชุดเดิมมี root password, VPN password,
registry password, cluster-admin token และ client key **ฝังอยู่ในไฟล์แบบ plaintext**
ทั้งหมดนั้น**ต้องถูกหมุนใหม่** ไม่ใช่แค่ลบไฟล์ทิ้ง

> 📐 **ก่อนลงมือกับ NetworkPolicy** ให้อ่านแบบแผน P04 · P05 · P13 ใน
> [`../html/cilium-envoy-scenarios.html`](../html/cilium-envoy-scenarios.html) —
> ลำดับ rollout ที่ไม่ทำระบบดับ, การกัน namespace เรียกหากัน และ egress ออกนอก cluster
> ที่แคบกว่าไฟล์ตั้งต้น · ฝั่ง P07 อธิบายว่าต้องเตรียมอะไรถึงจะตอบคำถาม audit ย้อนหลังได้

---

## 1 · 🔴 etcd encryption at rest

โดยค่าเริ่มต้น Kubernetes เก็บ Secret ใน etcd เป็น **base64 ธรรมดา ไม่ได้เข้ารหัส**
ใครที่อ่านไฟล์ etcd ได้ (หรือได้ backup ไป) จะเห็น secret ทั้งหมด

### 1.1 สร้าง encryption key

**👑 บน master01:**
```bash
head -c 32 /dev/urandom | base64
```
**เก็บค่านี้ไว้ให้ดี** — ถ้าหายจะถอดรหัส etcd backup เก่าไม่ได้เลย
เอาไปใส่ที่เก็บ secret ขององค์กรทันที **ห้ามใส่ใน git**

### 1.2 วางไฟล์ config — 🎩 ทำเหมือนกันทั้ง 3 master

```bash
mkdir -p /etc/kubernetes/enc
\cp -f /root/k8s/config/security/encryption-config.yaml /etc/kubernetes/enc/encryption-config.yaml

read -rsp 'encryption key (base64): ' ENC_KEY && echo "รับมา ${#ENC_KEY} ตัวอักษร"

if [ -z "$ENC_KEY" ]; then
    echo "❌ ไม่ได้พิมพ์อะไรเลย — ไม่แตะไฟล์ ให้รันบล็อกนี้ใหม่"
else
    sed -i "s|<ENCRYPTION_KEY_BASE64>|${ENC_KEY}|" /etc/kubernetes/enc/encryption-config.yaml
    chmod 600 /etc/kubernetes/enc/encryption-config.yaml
fi
unset ENC_KEY
```
**ควรเห็น:** `รับมา 44 ตัวอักษร` — key ที่ได้จาก `head -c 32 /dev/urandom | base64` ยาว 44 เสมอ

**ตรวจว่าไฟล์ลงจริงและ key มีค่าจริง:**
```bash
grep -c 'kind: EncryptionConfiguration' /etc/kubernetes/enc/encryption-config.yaml
awk '$1=="secret:"{print "secret ยาว " length($2) " ตัว"}' /etc/kubernetes/enc/encryption-config.yaml
```
**ควรเห็น:** `1` แล้วตามด้วย `secret ยาว 44 ตัว`

> ⚠️ อย่าเช็กด้วย `grep -c '<ENCRYPTION_KEY_BASE64>'` อย่างเดียว — ถ้า `read` ได้ค่าว่าง
> `sed` จะเขียนค่าว่างทับ placeholder ผลคือ placeholder หายไปเหมือนตอนสำเร็จทุกประการ
> แต่ apiserver จะ **start ไม่ขึ้น** และคุณจะไล่หาสาเหตุไม่เจอเพราะด่านตรวจบอกว่าผ่าน

> **key ต้องเหมือนกันทั้ง 3 เครื่อง** ไม่งั้น apiserver ตัวหนึ่งจะอ่านของที่อีกตัวเขียนไม่ออก

### 1.3 เปิดใช้ — ทำทีละเครื่อง

**🎩 บนแต่ละ master ทีละตัว** แก้ `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```bash
\cp -f /etc/kubernetes/manifests/kube-apiserver.yaml /root/k8s/kube-apiserver.yaml.bak
```

เพิ่มใน `spec.containers[0].command`:
```yaml
    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml
```

เพิ่มใน `volumeMounts`:
```yaml
    - name: enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
```

เพิ่มใน `volumes`:
```yaml
  - name: enc
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

kubelet จะเห็นไฟล์เปลี่ยนแล้ว restart apiserver ให้เอง — **รอให้ขึ้นก่อนไปเครื่องถัดไป:**
```bash
crictl ps | grep kube-apiserver
kubectl get --raw='/healthz'
```
**ควรเห็น:** `ok`

> ⚠️ **ห้ามทำพร้อมกันทั้ง 3 เครื่อง** ถ้า apiserver ล้มพร้อมกันหมด cluster จะเข้าไม่ได้เลย
> ทำทีละตัวแล้วรอ `/healthz` ผ่านก่อนเสมอ

### 1.4 เข้ารหัส Secret ที่มีอยู่แล้ว

การเปิด encryption มีผลเฉพาะกับของที่เขียน**หลังจากนี้** ของเก่ายังเป็น plaintext
ต้องเขียนทับทั้งหมดหนึ่งรอบ:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

**ตรวจว่าเข้ารหัสจริง — อ่านตรงจาก etcd:**
```bash
kubectl -n default create secret generic enc-test --from-literal=key=supersecret

kubectl -n kube-system exec -it etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | hexdump -C | head -5
```
**ควรเห็น:** `k8s:enc:aescbc:v1:key1:` แล้วตามด้วยข้อมูลที่อ่านไม่ออก
**ต้องไม่เห็นคำว่า `supersecret`** — ถ้าเห็นแปลว่ายังไม่ได้เข้ารหัส

```bash
kubectl -n default delete secret enc-test
```

---

## 2 · Pod Security Admission

PSA เป็นของที่มีอยู่ใน Kubernetes อยู่แล้ว ไม่ต้องลงอะไรเพิ่ม แค่ติด label ที่ namespace

```bash
kubectl apply -f /root/k8s/config/security/namespaces.yaml
kubectl get ns -L pod-security.kubernetes.io/enforce
```

**ควรเห็น:** namespace ของ application เป็น `restricted`

| ระดับ | ใช้กับ |
|---|---|
| `restricted` | namespace ของ application ทั้งหมด — เข้มที่สุด |
| `baseline` | namespace ที่มี workload พิเศษที่ `restricted` ไม่ผ่าน |
| `privileged` | `kube-system` เท่านั้น |

> ⚠️ **`restricted` จะทำให้ manifest เดิมของ `zeeme-*` deploy ไม่ผ่าน**
> เพราะของเดิมใช้ `runAsUser: 0` — นี่คือเจตนา ดูวิธีแก้ที่บทที่ 11
>
> ตั้ง `warn` และ `audit` ไว้ด้วยเสมอ จะได้เห็นว่าอะไรจะพังก่อนที่จะบังคับจริง

---

## 3 · 🔴 NetworkPolicy default-deny

นี่คือเหตุผลหลักที่เลือก Cilium แทน Flannel — Flannel ทำข้อนี้ไม่ได้เลย

**หลักการ: ปิดทุกอย่างก่อน แล้วค่อยเปิดทีละเส้นที่จำเป็น**

```bash
kubectl apply -f /root/k8s/config/security/default-deny.yaml
kubectl apply -f /root/k8s/config/security/allow-dns.yaml
```

**ตรวจว่า default-deny ทำงาน:**
```bash
kubectl -n myhr-prod run nptest --rm -it --restart=Never --image=curlimages/curl -- \
  curl -m 5 -s https://www.google.com
```
**ควรเห็น:** timeout ← **ถูกต้องแล้ว**

**ตรวจว่า DNS ยังใช้ได้ (ไม่งั้นทุกอย่างพัง):**
```bash
kubectl -n myhr-prod run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```
**ควรเห็น:** ตอบกลับปกติ

> **ลำดับสำคัญมาก** — ถ้า apply `default-deny` โดยไม่ apply `allow-dns` พร้อมกัน
> ทุก pod ใน namespace จะ resolve DNS ไม่ได้ทันที และอาการจะดูเหมือน application พัง

**ดู flow จริงด้วย Hubble เพื่อรู้ว่าต้องเปิดเส้นไหนบ้าง:**
```bash
kubectl -n kube-system exec -it ds/cilium -- hubble observe --namespace myhr-prod --verdict DROPPED --last 50
```
นี่คือวิธีที่ถูกต้องในการเขียน policy — **ดูของจริงว่าอะไรถูก drop แล้วเปิดเฉพาะเส้นนั้น**
ไม่ใช่เดาเอาจากเอกสาร

---

## 4 · RBAC ตามหน้าที่

`cluster-admin` ควรมีคนถือน้อยที่สุด และต้องรู้ว่าใครถือบ้าง

```bash
kubectl apply -f /root/k8s/config/security/rbac.yaml
```

| Role | ทำอะไรได้ | ให้ใคร |
|---|---|---|
| `myhr:developer` | อ่าน pod/log/service ใน namespace ตัวเอง · `exec` ไม่ได้ | ทีม dev |
| `myhr:deployer` | apply manifest ใน namespace ที่กำหนด | คนที่ deploy |
| `myhr:operator` | จัดการ node, drain, ดู resource ทั้ง cluster | ทีม ops |
| `cluster-admin` | ทุกอย่าง | **2 คนเท่านั้น** |

**ตรวจว่าใครเป็น cluster-admin อยู่บ้าง:**
```bash
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name as $n
           | (.subjects // [])[] | "\($n)\t\(.kind)/\(.name)"'
```
**ทบทวนรายชื่อนี้ทุกไตรมาส** และลบคนที่ไม่ได้อยู่แล้วออก

**ทดสอบว่า RBAC ทำงานจริง:**
```bash
kubectl auth can-i delete nodes --as=system:serviceaccount:myhr-prod:developer
kubectl auth can-i get pods --as=system:serviceaccount:myhr-prod:developer -n myhr-prod
```
**ควรเห็น:** `no` และ `yes` ตามลำดับ

---

### 4.1 ออก kubeconfig ให้คนใหม่

ตอนนี้ยังไม่มี OIDC — ตัวตนของคนมาจาก **client certificate** ที่เซ็นด้วย CA ของ cluster
โดย `CN` กลายเป็นชื่อ user และ `O` กลายเป็น group ที่ [`rbac.yaml`](../config/security/rbac.yaml) ผูกสิทธิ์ไว้

```
/CN=somchai/O=myhr:developers
     │              └── group → ได้สิทธิ์ myhr:developer
     └── user → ชื่อที่โผล่ใน audit log
```

**👑 ทำบน master01:**
```bash
USER_NAME=somchai
GROUP=myhr:developers          # หรือ myhr:operators

# 1. สร้าง key + CSR
openssl genrsa -out ${USER_NAME}.key 2048
openssl req -new -key ${USER_NAME}.key -out ${USER_NAME}.csr \
  -subj "/CN=${USER_NAME}/O=${GROUP}"

# 2. ส่งให้ cluster เซ็น — อายุ 90 วัน
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER_NAME}
spec:
  request: $(base64 -w0 < ${USER_NAME}.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 7776000
  usages: ["client auth"]
EOF

kubectl certificate approve ${USER_NAME}
kubectl get csr ${USER_NAME} -o jsonpath='{.status.certificate}' | base64 -d > ${USER_NAME}.crt
```
**ควรเห็น:** `certificatesigningrequest.certificates.k8s.io/somchai approved`

**3. ประกอบเป็น kubeconfig** (`--embed-certs` เพื่อให้ได้ไฟล์เดียวจบ):
```bash
KCFG=${USER_NAME}.kubeconfig
kubectl config set-cluster myhr \
  --server="https://${VIP}:${VIP_PORT}" \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true --kubeconfig="$KCFG"
kubectl config set-credentials "${USER_NAME}" \
  --client-certificate="${USER_NAME}.crt" --client-key="${USER_NAME}.key" \
  --embed-certs=true --kubeconfig="$KCFG"
kubectl config set-context "${USER_NAME}" \
  --cluster=myhr --user="${USER_NAME}" \
  --namespace=myhr-prod --kubeconfig="$KCFG"
kubectl config use-context "${USER_NAME}" --kubeconfig="$KCFG"
```

**4. ตรวจว่าสิทธิ์ถูกต้องก่อนส่งมอบ:**
```bash
kubectl --kubeconfig="$KCFG" auth can-i get pods -n myhr-prod    # ต้องได้ yes
kubectl --kubeconfig="$KCFG" auth can-i delete nodes             # ต้องได้ no
kubectl --kubeconfig="$KCFG" auth can-i get secrets -n myhr-prod # ต้องได้ no
```

**5. ส่งไฟล์ให้เจ้าตัวผ่านช่องทางที่ปลอดภัย แล้วลบของกลางทิ้ง:**
```bash
shred -u ${USER_NAME}.key ${USER_NAME}.csr ${USER_NAME}.crt
```

> 🔴 **cert ที่ออกไปแล้ว "ถอนไม่ได้"** — Kubernetes ไม่รองรับ CRL
> ถ้าคนลาออกกลางคัน ทางเดียวที่ตัดได้ทันทีคือ **ลบ RoleBinding ของทั้ง group**
> (กระทบทุกคนใน group) หรือรื้อ CA ใหม่ทั้ง cluster ซึ่งไม่คุ้ม
> จึงตั้งอายุไว้แค่ 90 วัน — ทำใหม่ทุกไตรมาสพร้อมรอบทบทวนรายชื่อ `cluster-admin`
> **นี่คือราคาของการยังไม่ตั้ง OIDC** ยอมรับได้ตราบใดที่คนถือ kubeconfig ยังนับหัวได้

---

### 4.2 วันที่จะย้ายไปใช้ OIDC — ทำอะไรบ้าง

ยังไม่ต้องทำตอนนี้ บันทึกไว้เฉย ๆ ว่าเส้นทางเป็นยังไง
**สัญญาณว่าถึงเวลา:** คนถือ kubeconfig เกินราว 10 คน หรือมีคนเข้าออกบ่อยจนตามถอนไม่ไหว

Kubernetes ต่อ AD/LDAP ตรง ๆ **ไม่ได้** รับได้แค่ OIDC จึงต้องมีตัวกลาง:

```
AD ของบริษัท ──→ OIDC provider ──→ apiserver
                 Keycloak / Dex        (ถ้าใช้ Microsoft 365 อยู่แล้ว
                 ถ้า AD เป็น on-prem     ต่อ Entra ID ตรงได้ ไม่ต้องลงอะไรเพิ่ม)
```

4 ขั้น:

1. **ตั้ง OIDC provider** ให้อ่าน AD ได้ แล้ว**ตั้งให้มันส่ง group ชื่อ `myhr:developers`
   และ `myhr:operators` ออกมาตรง ๆ** — ชื่อเดียวกับที่ `rbac.yaml` ใช้อยู่ตอนนี้
2. **เพิ่ม flag ที่ apiserver** — ใส่ใน `kubeadm-config.yaml` ที่ `apiServer.extraArgs`
   แล้ว `kubeadm upgrade apply` หรือแก้ `/etc/kubernetes/manifests/kube-apiserver.yaml` ทีละ master:
   ```yaml
   oidc-issuer-url: "https://sso.myhr.co.th/realms/myhr"
   oidc-client-id: "kubernetes"
   oidc-username-claim: "preferred_username"
   oidc-groups-claim: "groups"
   ```
3. **ทดสอบด้วยคนเดียวก่อน** — `kubectl auth can-i` ผ่าน token ของ OIDC
   ระหว่างนี้ client cert เดิมยังใช้ได้ปกติ ทั้งสองทางอยู่ร่วมกันได้
4. **หยุดออก cert ใหม่** แล้วปล่อยของเก่าหมดอายุไปเองใน 90 วัน

**[`rbac.yaml`](../config/security/rbac.yaml) ไม่ต้องแก้เลยสักบรรทัด** เพราะผูกกับชื่อ group ไม่ได้ผูกกับวิธี login
— นั่นคือเหตุผลที่ตั้งชื่อ group ไว้แบบนี้ตั้งแต่ตอนที่ยังไม่มี OIDC

---

## 5 · Audit log

เปิดไว้แล้วตั้งแต่ `kubeadm-config.yaml` (บทที่ 04) แต่ยังไม่มี policy
ซึ่งแปลว่า**ยังไม่ได้บันทึกอะไรเลย**

**🎩 ทำทั้ง 3 master ทีละตัว:**
```bash
\cp -f /root/k8s/config/security/audit-policy.yaml /etc/kubernetes/audit-policy.yaml
chmod 600 /etc/kubernetes/audit-policy.yaml

# ตรวจว่าไฟล์ลงจริง ไม่ใช่ค้างของเก่า
grep -c 'kind: Policy' /etc/kubernetes/audit-policy.yaml
```
**ควรเห็น:** `1` — ถ้าได้ `0` แปลว่า copy ไม่โดน apiserver จะ restart ไม่ขึ้นเพราะหา policy ไม่เจอ

เพิ่มใน `kube-apiserver.yaml`:
```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
```
พร้อม volumeMount ของ `/etc/kubernetes/audit-policy.yaml` และ `/var/log/kubernetes`

**ตรวจ:**
```bash
tail -3 /var/log/kubernetes/audit.log | jq -r '"\(.verb) \(.objectRef.resource) by \(.user.username)"'
```
**ควรเห็น:** บรรทัด JSON ของ event จริง

> **audit log กิน disk เร็วมาก** ถ้าเขียนทุก event — policy ที่ให้มาจึงบันทึกเฉพาะ
> สิ่งที่มีความหมายจริง (secret access, การเปลี่ยนแปลง RBAC, exec เข้า pod)
> และตั้ง rotate ไว้ที่ 100 MB × 10 ไฟล์

---

## 6 · หนี้เก่าที่ต้องจ่าย — หมุน credential

> 🔴 **ข้อนี้ไม่เกี่ยวกับ cluster ใหม่ แต่ห้ามข้าม**

credential ที่รั่วในคู่มือชุดเดิม **ต้องถือว่าถูกเปิดเผยไปแล้วทั้งหมด**
การลบไฟล์ออกจาก git ไม่ได้ทำให้มันปลอดภัยขึ้น เพราะยังอยู่ใน git history

| รายการ | สถานะ |
|---|---|
| root password ของทุก node เดิม | [ ] หมุนแล้ว |
| VPN password (FortiClient) | [ ] หมุนแล้ว |
| registry password | [ ] หมุนแล้ว + **แยก account pull อ่านอย่างเดียว** |
| cluster-admin token ของ cluster เดิม | [ ] เพิกถอนแล้ว |
| client key ใน `admin.conf` เดิม | [ ] เพิกถอนแล้ว |

**สำหรับ registry — สร้าง 2 account แยกกัน:**
```bash
# บน cluster ใหม่ ใช้ account ที่ pull ได้อย่างเดียว
kubectl -n myhr-prod create secret docker-registry regcred \
  --docker-server="${REGISTRY_HOST}" \
  --docker-username='<PULL_ONLY_USER>' \
  --docker-password='<PULL_ONLY_PASSWORD>'
```

> **secret ไม่ข้าม namespace** ต้องสร้างทุก namespace ที่ต้อง pull image
> คู่มือเดิมสร้างแค่ `default` แล้วงงว่าทำไม namespace อื่น pull ไม่ได้

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] 🔴 อ่าน Secret ตรงจาก etcd แล้ว **เห็นเป็นข้อมูลเข้ารหัส** ไม่ใช่ plaintext
- [ ] encryption key เก็บในที่เก็บ secret แล้ว **และไม่ได้อยู่ใน git**
- [ ] Secret เก่าถูกเขียนทับให้เข้ารหัสครบแล้ว
- [ ] namespace ของ application เป็น PSA `restricted`
- [ ] 🔴 NetworkPolicy default-deny ทำงาน — curl ออกนอกไม่ได้ แต่ DNS ยังใช้ได้
- [ ] RBAC role ครบ 3 ระดับ · `cluster-admin` ไม่เกิน 2 คน · จดรายชื่อไว้แล้ว
- [ ] audit log เขียนไฟล์จริงและอ่านได้
- [ ] 🔴 **credential ที่รั่วในเอกสารเดิม หมุนครบทุกตัวแล้ว**
- [ ] `regcred` เป็น account ที่ pull ได้อย่างเดียว ไม่ใช่รหัสเดียวกับ root

**➡️ ต่อที่ [บทที่ 11 — Deploy Application](11-deploy-app.md)**
