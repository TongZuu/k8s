# บทที่ 10 — Security Baseline

> **รันที่: 👑 master01 เป็นหลัก** · ยกเว้น: ข้อ 0 จาก**เครื่องคุณ** · ข้อ 1.2-1.3 และข้อ 5 ต้อง ssh เข้า
> **🎩 master ทั้ง 3 ทีละเครื่อง** (แก้ apiserver ของแต่ละเครื่อง — ทำพร้อมกันไม่ได้ จะเสีย apiserver ทั้ง cluster)
> · ข้อ 6 ไม่ใช่งานบน cluster
> **ลำดับ: 0 → 8 ตามลำดับ** · ข้อ 2 (namespace) ต้องมาก่อน 3 · 4 · 7 ซึ่งอ้าง namespace เหล่านั้น
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

<figure class="fig">
<svg viewBox="0 0 900 360" role="img" aria-label="แผนผังเครื่องทั้งหมดใน cluster และวงเครือข่าย">
  <text class="t-dim" x="8" y="16">ทุกเครื่องอยู่วงเดียวกัน 192.168.50.0/24 · pod อยู่ในวงของตัวเองที่ 10.246.0.0/16 · service 10.247.0.0/16</text>

  <rect class="zone" x="8" y="26" width="884" height="256" rx="12"/>
  <text class="t-dim" x="20" y="44">Kubernetes cluster</text>

  <rect class="box"   x="330" y="52" width="240" height="42" rx="8"/>
  <text class="t-hd"  x="450" y="70" text-anchor="middle">VIP 192.168.50.100:8443</text>
  <text class="t-mono" x="450" y="87" text-anchor="middle">keepalived + HAProxy → apiserver</text>

  <rect class="box-p" x="20"  y="108" width="270" height="78" rx="9"/>
  <text class="t-hd"  x="155" y="130" text-anchor="middle">🎩 k8s-master01</text>
  <text class="t-mono" x="155" y="150" text-anchor="middle">192.168.50.101</text>
  <text class="t-sm"  x="155" y="171" text-anchor="middle">apiserver · etcd · controller</text>

  <rect class="box-p" x="315" y="108" width="270" height="78" rx="9"/>
  <text class="t-hd"  x="450" y="130" text-anchor="middle">🎩 k8s-master02</text>
  <text class="t-mono" x="450" y="150" text-anchor="middle">192.168.50.102</text>
  <text class="t-sm"  x="450" y="171" text-anchor="middle">apiserver · etcd · controller</text>

  <rect class="box-p" x="610" y="108" width="270" height="78" rx="9"/>
  <text class="t-hd"  x="745" y="130" text-anchor="middle">🎩 k8s-master03</text>
  <text class="t-mono" x="745" y="150" text-anchor="middle">192.168.50.103</text>
  <text class="t-sm"  x="745" y="171" text-anchor="middle">apiserver · etcd · controller</text>

  <rect class="box-ok" x="20"  y="196" width="270" height="72" rx="9"/>
  <text class="t-hd"  x="155" y="218" text-anchor="middle">🖥 k8s-worker01</text>
  <text class="t-mono" x="155" y="238" text-anchor="middle">192.168.50.104</text>
  <text class="t-sm"  x="155" y="258" text-anchor="middle">pod ของแอปรันที่นี่</text>

  <rect class="box-ok" x="315" y="196" width="270" height="72" rx="9"/>
  <text class="t-hd"  x="450" y="218" text-anchor="middle">🖥 k8s-worker02</text>
  <text class="t-mono" x="450" y="238" text-anchor="middle">192.168.50.105</text>
  <text class="t-sm"  x="450" y="258" text-anchor="middle">pod ของแอปรันที่นี่</text>

  <rect class="box-ok" x="610" y="196" width="270" height="72" rx="9"/>
  <text class="t-hd"  x="745" y="218" text-anchor="middle">🖥 k8s-worker03</text>
  <text class="t-mono" x="745" y="238" text-anchor="middle">192.168.50.106</text>
  <text class="t-sm"  x="745" y="258" text-anchor="middle">pod ของแอปรันที่นี่</text>

  <text class="t-dim" x="8" y="304">นอก cluster — คนละวง ต้องวิ่งผ่าน gateway ของเครือข่ายออกไป</text>
  <rect class="box-p" x="20"  y="312" width="270" height="38" rx="8"/>
  <text class="t-sm"  x="155" y="336" text-anchor="middle">ฐานข้อมูล · 192.168.30.0/24</text>
  <rect class="box-p" x="315" y="312" width="270" height="38" rx="8"/>
  <text class="t-sm"  x="450" y="336" text-anchor="middle">registry · 192.168.30.207</text>
  <rect class="box-p" x="610" y="312" width="270" height="38" rx="8"/>
  <text class="t-sm"  x="745" y="336" text-anchor="middle">อินเทอร์เน็ต</text>
</svg>
<figcaption>เครื่องทั้งหมดที่มี — master 3 ตัวรับคำสั่ง (apiserver) และเก็บสถานะ (etcd) ·
worker 3 ตัวเป็นที่ที่ pod รันจริง · ฐานข้อมูลกับ registry อยู่<b>นอก</b> cluster คนละวง IP</figcaption>
</figure>

## 0 · ตรวจว่า config บนเครื่องตรงกับrepo

**ทำที่:** เครื่องคุณ (ที่มีrepo · WSL/Git Bash) · **ต้องมีก่อน:** VPN ต่ออยู่ · key ssh ครบ 3 master
· ไฟล์ทั้งหมดอยู่ที่ `/root/k8s/config/security/` แล้วจาก
[บท 00](00-overview.md) — บทนี้ใช้ `encryption-config.yaml` กับ `audit-policy.yaml`
**ทั้ง 3 master** จึงต้องตรงกันทุกเครื่อง เทียบ md5 ก่อน:
```bash
md5sum config/security/*.yaml
for ip in 101 102 103; do echo "== .$ip"; ssh root@192.168.50.$ip 'md5sum /root/k8s/config/security/*.yaml'; done
```
**ควรเห็น:** ค่า md5 เหมือนกันทั้ง 4 ชุด ครบ 6 ไฟล์ (`allow-dns` · `audit-policy` ·
`default-deny` · `encryption-config` · `namespaces` · `rbac`)

ถ้าไม่ตรง แปลว่า `/root/k8s/` เป็นชุดเก่า — sync ใหม่ทั้ง 6 เครื่องตาม[บท 00](00-overview.md)
แล้วเทียบซ้ำ อย่า copy ทีละไฟล์

> ⚠️ การ copy รอบนี้ทับแค่ไฟล์ใน `/root/k8s/` — ของที่วางไว้ที่ `/etc/kubernetes/` แล้ว
> **ไม่โดน** ถ้าแก้ไฟล์ต้นทางหลังจากทำข้อ 1.2 หรือข้อ 5 ไปแล้ว ต้อง `\cp -f` ซ้ำ
> แล้วใส่ encryption key ใหม่ เพราะ placeholder กลับมาแล้ว

---

## 1 · 🔴 etcd encryption at rest

**ทำที่:** 1.1 👑 master01 · 1.2 🎩 ทั้ง 3 master (key **เดียวกัน** ทุกเครื่อง) · 1.3 🎩 ทีละเครื่อง รอ `/healthz` ก่อนเครื่องถัดไป
· 1.4 👑 master01 · **ต้องมีก่อน:** ข้อ 0 md5 ตรง · ที่เก็บ secret ขององค์กรพร้อมรับ key (1.1 ออก key แล้วต้องเก็บทันที)
· etcd snapshot ล่าสุดมี ([บท 06 ข้อ 7](06-verify.md)) — ข้อนี้แก้ apiserver ทั้ง 3 เครื่อง

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

**ทำที่:** 🎩 ssh เข้า master ทีละเครื่อง (master01 → 02 → 03) · **ต้องมีก่อน:** 1.2 เสร็จบนเครื่องนั้น
(`/etc/kubernetes/enc/encryption-config.yaml` มี key แล้ว — apiserver จะอ่านไฟล์นี้ตอนเริ่ม)

บล็อกเดียวจบ ไม่ต้องเปิดไฟล์แก้ — เติม flag 1 บรรทัด + mount + volume ลง manifest ของ apiserver
(สำรองไฟล์เดิมไว้ก่อน · รันซ้ำได้ ถ้าเติมไปแล้วจะไม่เติมซ้ำ):
```bash
M=/etc/kubernetes/manifests/kube-apiserver.yaml
if grep -q encryption-provider-config "$M"; then echo "เติมไว้แล้ว ไม่แก้ซ้ำ"; else
  \cp -f "$M" /root/k8s/kube-apiserver.yaml.bak
  sed -i -e '/^    - kube-apiserver$/a\    - --encryption-provider-config=/etc/kubernetes/enc/encryption-config.yaml' \
         -e '/^    volumeMounts:$/a\    - mountPath: /etc/kubernetes/enc\n      name: enc\n      readOnly: true' \
         -e '/^  volumes:$/a\  - hostPath:\n      path: /etc/kubernetes/enc\n      type: DirectoryOrCreate\n    name: enc' "$M"
fi
grep -c -e 'encryption-provider-config' -e 'path: /etc/kubernetes/enc' -e 'mountPath: /etc/kubernetes/enc' "$M"
```
**ควรเห็น:** `3` (flag · volume · mount ครบ) — ได้น้อยกว่านี้ให้เอาไฟล์สำรองคืน
`\cp -f /root/k8s/kube-apiserver.yaml.bak "$M"` แล้วส่งผล `grep -n 'kube-apiserver$\|volumeMounts:\|volumes:' "$M"` มาดู

kubelet เห็นไฟล์เปลี่ยนแล้ว restart apiserver ของเครื่องนี้ให้เอง — **รอให้ขึ้นก่อนไปเครื่องถัดไป**
(ถามที่ `127.0.0.1` ของเครื่องนี้ ไม่ใช่ผ่าน VIP ซึ่งอาจไปตอบจาก master เครื่องอื่น):
```bash
sleep 10; until curl -sk https://127.0.0.1:6443/healthz | grep -q ok; do sleep 3; done; echo "apiserver ของ $(hostname) ok"
```
**ควรเห็น:** `apiserver ของ k8s-masterXX ok` ภายใน ~1 นาที · ค้างเกิน 3 นาที = apiserver ไม่ขึ้น
ดู `crictl ps -a | grep kube-apiserver` และ `crictl logs $(crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -5`
— ส่วนใหญ่คือไฟล์ของ 1.2 ยังมี `<ENCRYPTION_KEY_BASE64>` หรือ key ไม่ใช่ 32 byte

> ⚠️ **ห้ามทำพร้อมกันทั้ง 3 เครื่อง** ถ้า apiserver ล้มพร้อมกันหมด cluster จะเข้าไม่ได้เลย
> ทำทีละตัวแล้วรอ `ok` ก่อนเสมอ

### 1.4 เข้ารหัส Secret ที่มีอยู่แล้ว

การเปิด encryption มีผลเฉพาะกับของที่เขียน**หลังจากนี้** ของเก่ายังเป็น plaintext
ต้องเขียนทับทั้งหมดหนึ่งรอบ:

```bash
kubectl get secrets -A -o json | kubectl replace -f -
```

**ตรวจว่าเข้ารหัสจริง — อ่านตรงจาก etcd:**
```bash
kubectl -n default create secret generic enc-test --from-literal=key=supersecret \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n kube-system exec -it etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | hexdump -C | head -5
```
**ควรเห็น:** `k8s:enc:aescbc:v1:key1:` แล้วตามด้วย byte ที่อ่านไม่ออก

> ใช้ `apply` แทน `create` เพราะถ้ารันบล็อกนี้ซ้ำ `create` จะขึ้น
> `error: ... "enc-test" already exists` — คำสั่ง etcdctl บรรทัดล่างยังรันต่อได้ปกติ
> เพราะเป็นคนละคำสั่ง แต่ error ที่ไม่มีความหมายทำให้อ่านผลยาก

**`head -5` เห็นแค่ 80 byte แรก** ยืนยันให้ขาดว่าไม่มี plaintext หลงเหลือท้ายไฟล์:
```bash
kubectl -n kube-system exec etcd-k8s-master01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/enc-test | strings | grep -c supersecret
```
**ควรเห็น:** `0` — ถ้าได้ `1` แปลว่ายังไม่ได้เข้ารหัส

**แล้วเช็กว่าทั้ง 3 master ถอดรหัสได้จริง** — ยิงตรงเข้าแต่ละ apiserver ข้าม VIP ไป
(ผ่าน VIP จะสุ่มเครื่อง เครื่องที่ key ผิดอาจไม่โดนเลย แล้วเข้าใจผิดว่าผ่าน):
```bash
for ip in 101 102 103; do
  printf "== .%s : " "$ip"
  kubectl --server=https://192.168.50.$ip:6443 --insecure-skip-tls-verify \
    -n default get secret enc-test -o jsonpath='{.data.key}' | base64 -d
  echo
done
```
**ควรเห็น:** `supersecret` ครบทั้ง 3 บรรทัด — เครื่องไหนขึ้น `no matching key`
แปลว่าเครื่องนั้น key ไม่ตรงหรือยังไม่ได้วางไฟล์ ให้กลับไปทำข้อ 1.2 ใหม่

```bash
kubectl -n default delete secret enc-test
```

---

## 2 · Pod Security Admission

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 1 จบ apiserver ทั้ง 3 `/healthz` = `ok` · ข้อนี้สร้าง namespace
`myhr-prod` / `myhr-uat` ที่ข้อ 3 · 4 · 7 ต้องใช้

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

**ทำที่:** 👑 master01 ทั้งข้อ (3.1 → 3.4 ตามลำดับ — 3.1 ต้องวัด**ก่อน** 3.2 ไม่งั้น 3.3 ไม่มีอะไรเทียบ)
· **ต้องมีก่อน:** ข้อ 2 (namespace `myhr-prod` มีแล้ว) · Hubble ทำงาน ([บท 05](05-cilium.md)) · pod ดึง image ทดสอบได้

นี่คือเหตุผลหลักที่เลือก Cilium แทน Flannel — Flannel ทำข้อนี้ไม่ได้เลย

**หลักการ: ปิดทุกอย่างก่อน แล้วค่อยเปิดทีละเส้นที่จำเป็น**

### 3.1 วัดค่าก่อน apply

สร้าง pod ชั่วคราวใน `myhr-prod` → ยิงออกไปข้างนอก → ดูผล → pod ลบตัวเองทิ้ง
รันชุดเดียวกัน **สองรอบ** ก่อนและหลัง apply แล้วเทียบกัน

**ผลที่ต้องได้คือ "เปลี่ยน" ไม่ใช่ "ตก"** — ปลายทางที่ต่อไม่ได้อยู่แล้วก็ตกทั้งสองรอบ
โดยไม่เกี่ยวกับ policy เลย

> **ถ้าเผลอ apply ไปแล้ว** ถอยกลับมาวัดได้ ลบด้วยไฟล์เดิมที่ใช้ apply:
> ```bash
> kubectl delete -f /root/k8s/config/security/default-deny.yaml --ignore-not-found
> kubectl delete -f /root/k8s/config/security/allow-dns.yaml --ignore-not-found
> ```
> ระหว่างนี้ namespace เปิดโล่ง ทำตอนที่ยังไม่มี traffic จริง แล้ว apply กลับให้ครบทั้งสองไฟล์

#### เลือกปลายทางที่จะใช้วัด

pod ที่นี่ออกอินเทอร์เน็ตได้หรือไม่ **ยังไม่มีใครพิสูจน์ อย่าเดา** — วัดก่อน:

```bash
PUB='{"spec":{"containers":[{"name":"pubtest","image":"curlimages/curl","command":["curl","-m","5","-sk","-o","/dev/null","-w","ip=%{http_code} exit=%{exitcode}\n","https://1.1.1.1"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":100,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'

kubectl -n myhr-prod run pubtest --rm -i --restart=Never \
  --image=curlimages/curl --overrides="$PUB"
```

| ผลที่ได้ | ใช้ปลายทางไหนต่อ |
|---|---|
| มีเลข HTTP · `exit=0` | ใช้ `https://1.1.1.1` — **เป็นด่านที่สำคัญที่สุดของบทนี้** เพราะระบบเก็บข้อมูลพนักงาน ช่องที่อันตรายคือ pod ส่งข้อมูลออกเน็ตได้ |
| `exit=28` | pod ออกเน็ตไม่ได้อยู่แล้ว ใช้เป็นด่านวัด policy ไม่ได้ — ใช้ apiserver `192.168.50.101:6443` แทน (ตอบ `403` แปลว่าต่อถึง) |

#### คำสั่งทดสอบ

<figure class="fig">
<svg viewBox="0 0 900 440" role="img" aria-label="เส้นทางของ packet ตอนทดสอบ จุดที่ NetworkPolicy ตัด และเส้นทางออกอินเทอร์เน็ต">
  <defs>
    <marker id="a10b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" fill="currentColor"/>
    </marker>
  </defs>

  <!-- ---------- worker01 ---------- -->
  <rect class="box-p" x="12" y="48" width="420" height="250" rx="10"/>
  <text class="t-hd"  x="28" y="70">🖥 k8s-worker01 · 192.168.50.104</text>

  <rect class="zone" x="30" y="86" width="252" height="140" rx="10"/>
  <text class="t-sm" x="156" y="106" text-anchor="middle">namespace myhr-prod</text>
  <rect class="box"  x="56" y="122" width="204" height="70" rx="8"/>
  <text class="t-hd"  x="158" y="150" text-anchor="middle">pod nptest</text>
  <text class="t-mono" x="158" y="172" text-anchor="middle">10.246.1.37</text>
  <circle class="box" cx="44" cy="122" r="14"/>
  <text class="t-hd" x="44" y="127" text-anchor="middle">1</text>

  <path class="wall" d="M306 86 V266"/>
  <circle class="box-bad" cx="306" cy="164" r="15"/>
  <text class="t-hd" x="306" y="169" text-anchor="middle">2</text>
  <text class="t-bad" x="306" y="288" text-anchor="middle">veth ของ pod · eBPF ของ Cilium — จุดที่ policy ตัด</text>

  <rect class="box-p" x="342" y="140" width="80" height="48" rx="8"/>
  <text class="t-sm"  x="382" y="160" text-anchor="middle">NIC</text>
  <text class="t-mono" x="382" y="178" text-anchor="middle">.104</text>

  <!-- ---------- เครือข่าย ---------- -->
  <rect class="box-p" x="452" y="48" width="40" height="330" rx="8"/>
  <circle class="box" cx="472" cy="164" r="14"/>
  <text class="t-hd" x="472" y="169" text-anchor="middle">3</text>
  <text class="t-dim" x="472" y="40" text-anchor="middle">วง 192.168.50.0/24</text>

  <path class="ln-a" d="M260 164 H288"/>
  <path class="ln-a" d="M324 164 H338" marker-end="url(#a10b)"/>
  <path class="ln-a" d="M422 164 H448" marker-end="url(#a10b)"/>
  <path class="ln"   d="M472 92 V341"/>

  <!-- ---------- ปลายทาง ---------- -->
  <path class="ln-a"  d="M492 92 H532" marker-end="url(#a10b)"/>
  <rect class="box"    x="548" y="60" width="340" height="64" rx="9"/>
  <text class="t-hd"   x="718" y="84"  text-anchor="middle">🎩 master01 · kube-apiserver</text>
  <text class="t-mono" x="718" y="105" text-anchor="middle">192.168.50.101:6443 ← ที่เราใช้ทดสอบ</text>
  <text class="t-bad"  x="538" y="98" text-anchor="middle">✗</text>

  <path class="ln-ok" d="M492 172 H532" marker-end="url(#a10b)"/>
  <rect class="box-ok" x="548" y="140" width="340" height="64" rx="9"/>
  <text class="t-hd"   x="718" y="164" text-anchor="middle">CoreDNS · kube-system</text>
  <text class="t-mono" x="718" y="185" text-anchor="middle">เปิดไว้ด้วย allow-dns-egress</text>
  <text class="t-ok"   x="538" y="178" text-anchor="middle">✓</text>

  <path class="ln-ok" d="M492 250 H532" marker-end="url(#a10b)"/>
  <rect class="box-ok" x="548" y="220" width="340" height="60" rx="9"/>
  <text class="t-hd"   x="718" y="243" text-anchor="middle">ฐานข้อมูล · นอก cluster</text>
  <text class="t-mono" x="718" y="264" text-anchor="middle">ผ่าน router → 192.168.30.0/24</text>
  <text class="t-ok"   x="538" y="256" text-anchor="middle">✓</text>

  <path class="ln-bad ln-d" d="M492 328 H532" marker-end="url(#a10b)"/>
  <rect class="box-bad" x="548" y="298" width="340" height="60" rx="9"/>
  <text class="t-hd"   x="718" y="321" text-anchor="middle">อินเทอร์เน็ต · นอก cluster</text>
  <text class="t-mono" x="718" y="342" text-anchor="middle">ผ่าน router → ออกเน็ต</text>
  <text class="t-bad"  x="538" y="334" text-anchor="middle">✗</text>

  <text class="t-ok"  x="12" y="396">ก่อน apply — วิ่งครบทาง 1 → 2 → 3 ทุกเส้น · ยิง :6443 ได้ http=403 exit=0</text>
  <text class="t-bad" x="12" y="418">หลัง apply — เส้น ✗ ถูกตัดที่ 2 ตั้งแต่ยังไม่ออกจาก worker01 ปลายทางไม่เคยเห็น request เลย · curl รอครบ 5 วิ ได้ exit=28</text>
</svg>
<figcaption>Cilium ตัดที่ <b>veth ของ pod บนเครื่องที่ pod นั้นรันอยู่</b> ไม่ใช่ที่ปลายทางและไม่ใช่ firewall ของเครือข่าย —
ทุกเส้นถูกตัดที่จุด 2 เหมือนกันหมด ไม่ว่าปลายทางจะอยู่ใน cluster หรือออกอินเทอร์เน็ต ·
เส้น ✓ คือปลายทางที่ <code>allow-*</code> เปิดไว้ตั้งใจ จึงผ่านจุด 2 ไปได้ตามเดิม</figcaption>
</figure>

```bash
NPPOD='{"spec":{"containers":[{"name":"nptest","image":"curlimages/curl","command":["curl","-m","5","-sk","-o","/dev/null","-w","http=%{http_code} exit=%{exitcode}\n","https://192.168.50.101:6443"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":100,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'

kubectl -n myhr-prod run nptest --rm -i --restart=Never \
  --image=curlimages/curl --overrides="$NPPOD"
```
**ควรเห็น (รอบแรก):** `http=403 exit=0` — หรือ `401` ก็ได้ ทั้งคู่แปลว่าต่อถึงแล้ว
**ถ้าได้ `http=000` ตั้งแต่รอบแรก อย่าเพิ่งไปต่อ** ปลายทางนี้ใช้วัดไม่ได้

| ผลที่ได้ | แปลว่า |
|---|---|
| `exit=0` + มีเลข HTTP | ✅ ต่อถึง — นี่คือค่าตั้งต้น |
| `exit=28` | timeout · packet ถูกทิ้งเงียบ ๆ = **NetworkPolicy ทำงาน** |
| `exit=7` | connection refused · **ไม่ใช่**ผลของ policy — มีคนตอบว่าไม่รับ |
| `exit=6` | resolve ชื่อไม่ได้ · เรายิงเป็น IP จึงไม่ควรเจอ |

> 🔴 **คำสั่ง `curl` ต้องอยู่ใน `command` ของ JSON ห้ามเขียนต่อท้ายหลัง `--`**
> `--overrides` ใช้ JSON merge patch ที่แทน `containers` ทั้ง array อะไรที่อยู่หลัง `--`
> จะหายไปทั้งชุด แล้วขึ้น `curl: try 'curl --help'` ซึ่งดูเหมือน curl พัง

> `securityContext` ทั้ง 5 ข้อในนั้นมีไว้ให้ผ่าน **PSA `restricted`** จากหัวข้อ 2 — ขาดข้อเดียว
> จะโดนปฏิเสธด้วย `violates PodSecurity` ตั้งแต่ยังไม่ได้สร้าง pod ซึ่ง**ไม่ใช่**ผลของ NetworkPolicy ·
> ส่วน `warning: couldn't attach ... falling back to streaming logs` และ `terminated (Error)`
> เป็นเรื่องปกติ ไม่ใช่ error

#### ทดสอบ DNS — คู่กันเสมอ

```bash
DNSPOD='{"spec":{"containers":[{"name":"dnstest","image":"busybox:1.36","command":["nslookup","kubernetes.default.svc.cluster.local"],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65534,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}}]}}'

kubectl -n myhr-prod run dnstest --rm -i --restart=Never \
  --image=busybox:1.36 --overrides="$DNSPOD"
```
**ควรเห็น:** ตอบกลับเป็น IP ปกติ — และต้องได้แบบนี้**ทั้งสองรอบ** ต่างจาก curl ที่ต้องเปลี่ยน
เพราะ `allow-dns.yaml` มีหน้าที่เปิดช่อง DNS ไว้ให้ ถ้ารอบสอง DNS ตาย แปลว่าลืม apply ไฟล์นั้น

### 3.2 apply

```bash
kubectl apply -f /root/k8s/config/security/default-deny.yaml
kubectl apply -f /root/k8s/config/security/allow-dns.yaml
```

> **ลำดับสำคัญมาก** — ถ้า apply `default-deny` โดยไม่ apply `allow-dns` พร้อมกัน
> ทุก pod ใน namespace จะ resolve DNS ไม่ได้ทันที และอาการจะดูเหมือน application พัง

รอให้ Cilium รับ policy ไปบังคับใช้ก่อนวัดซ้ำ (ปกติไม่ถึงวินาที แต่อย่ายิงทันที)
— ต้องถามที่ **worker** เพราะ policy ถูกโหลดเฉพาะเครื่องที่มี pod ของ namespace นั้นอยู่:
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  n=$(kubectl -n kube-system exec "$p" -c cilium-agent -- \
        cilium-dbg policy get 2>/dev/null | grep -c myhr-prod)
  echo "$p → $n"
done
```
**ควรเห็น:** มีอย่างน้อยหนึ่งบรรทัดที่ไม่ใช่ `0` (เครื่องที่ pod รันอยู่) · ถ้าเป็น `0` หมดทุกบรรทัด
แปลว่า Cilium ยังไม่รับ policy ไปบังคับใช้ อย่าเพิ่งไปวัดรอบสอง

### 3.3 วัดซ้ำด้วยคำสั่งเดิมเป๊ะ ๆ

รัน **สองบล็อกเดิมในข้อ 3.1 ซ้ำอีกรอบ** (คำสั่งเดียวกัน ปลายทางเดียวกัน) แล้วเทียบผล:

| ทดสอบ | ก่อน apply | หลัง apply | แปลว่า |
|---|---|---|---|
| curl ออกนอก namespace | `http=403 exit=0` | `http=000 exit=28` | 🔴 egress ถูกปิดจริง |
| DNS lookup | ตอบเป็น IP | ตอบเป็น IP **เหมือนเดิม** | `allow-dns` ทำงาน |

**ค่าที่ต้องได้คือ "เปลี่ยน"** ไม่ใช่แค่ "ตก" — ถ้าคอลัมน์ก่อนกับหลังเหมือนกันทั้งคู่
แปลว่าการทดสอบไม่ได้วัด policy ไม่ว่าผลจะออกมาหน้าตาดีแค่ไหน

- ทั้งสองช่องเป็น `000` → ปลายทางต่อไม่ถึงตั้งแต่แรก เลือกปลายทางใหม่
- ทั้งสองช่องมีเลข HTTP (`403`/`401`) → policy **ยังไม่ถูกบังคับใช้** ดูด้วยบล็อกวน agent ในข้อ 3.2
  และตรวจว่า apply ลง namespace ถูกตัวหรือไม่ (`kubectl -n myhr-prod get netpol`)
- DNS ตายหลัง apply → ลืม `allow-dns.yaml` ให้ apply ทันที

### 3.4 ดู flow จริงด้วย Hubble เพื่อรู้ว่าต้องเปิดเส้นไหนบ้าง

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** 3.3 ได้ `exit=28` (policy ทำงานแล้ว)

**ทำไมต้องดู** — 3.3 บอกแค่ว่า "ตก" · Hubble บอกว่า **ตกที่ไหน ไปหาใคร พอร์ตอะไร เพราะ policy**
ซึ่งเป็นข้อมูลเดียวกับที่ต้องใช้เขียน rule เปิดทาง เวลาแอปจริงโดนบล็อกก็ใช้วิธีนี้หาว่าต้องเปิดอะไร

**ยิงแล้วดูทันทีในบล็อกเดียว** — Hubble จำ flow ไว้ในหน่วยความจำของ agent เครื่องที่ pod รันอยู่
และถูกทับภายในไม่กี่นาที (ถ้ายิงไว้นานแล้วค่อยมาดู จะได้ผลว่างทุกเครื่อง):
```bash
kubectl -n myhr-prod run nptest --rm -i --restart=Never --image=curlimages/curl --overrides="$NPPOD"
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --namespace myhr-prod --verdict DROPPED --since 2m 2>/dev/null
done
```
(`$NPPOD` คือตัวแปรจากข้อ 3.1 — shell ใหม่ให้รันบรรทัด `NPPOD='...'` ก่อน)

**ควรเห็น:** `http=000 exit=28` ตามด้วยบรรทัด DROPPED 1-3 บรรทัด หน้าตาประมาณนี้:
```
Sep 24 10:15:02.341: myhr-prod/nptest:48212 (ID:31807) <> 192.168.50.101:6443 (kube-apiserver) Policy denied DROPPED (TCP Flags: SYN)
```

**อ่านยังไง** — แต่ละบรรทัดคือ packet หนึ่งตัวที่ถูกทิ้ง:

| ส่วน | ตัวอย่าง | บอกอะไร |
|---|---|---|
| ต้นทาง | `myhr-prod/nptest:48212` | pod ไหนเป็นคนส่ง (namespace/ชื่อ pod) |
| ปลายทาง | `192.168.50.101:6443 (kube-apiserver)` | ส่งไปหาใคร พอร์ตอะไร · ในวงเล็บคือ Cilium รู้จักว่าเป็นอะไร (`world` = อินเทอร์เน็ต) |
| เหตุผล | `Policy denied DROPPED` | ถูกทิ้งเพราะ NetworkPolicy — **ไม่ใช่** network เสีย |
| `TCP Flags: SYN` | | ตายตั้งแต่ขอเปิด connection ปลายทางไม่เคยได้รับ |

ใช้กับแอปจริง: ถ้าต้องให้ `myhr-prod` ต่อ `192.168.50.101:6443` ได้ ก็เขียน egress rule ไปที่ IP/พอร์ตนั้น
(ดูรูปแบบใน `allow-egress-to-registry` ของ [`allow-dns.yaml`](../config/security/allow-dns.yaml)) แล้วยิงซ้ำ
บรรทัดนั้นต้องหายไป · **สำหรับการติดตั้งตอนนี้ไม่ต้องเปิดอะไร** — บรรทัดนี้คือหลักฐานว่าปิดได้จริง

| ได้อะไร | แปลว่า |
|---|---|
| `exit=28` แต่ไม่มีบรรทัด DROPPED เลย | Hubble เครื่องนั้นไม่ทำงาน → เช็กข้างล่าง |
| บรรทัดขึ้น `... to-stack FORWARDED` / ไม่มี `Policy denied` | policy ยังไม่ถูกบังคับใช้ → กลับข้อ 3.2 |

#### policy บล็อก หรือ network เสีย — แยกด้วย Hubble

`exit=28` จาก curl มีได้สองสาเหตุที่หน้าตาเหมือนกันเป๊ะ — **policy ทิ้ง** กับ **ปลายทางไม่ตอบ**
ดู curl อย่างเดียวแยกไม่ออก ต้องดูว่า Hubble เห็นอะไร:

| สถานการณ์ | Hubble เห็นอะไร | curl ได้ |
|---|---|---|
| **policy บล็อก** | `Policy denied DROPPED` | `exit=28` |
| **ปลายทางไม่ตอบ** (เครื่องดับ · firewall ปลายทางทิ้ง · router ไม่ส่งต่อ) | ขาออก `FORWARDED` (SYN) ซ้ำหลายครั้ง **ไม่มีขากลับ** ไม่มีคำว่า DROPPED | `exit=28` |
| **ปลายทางปฏิเสธ** (พอร์ตไม่ได้เปิด) | ขาออก `FORWARDED` แล้วมีขากลับ `TCP Flags: RST` | `exit=7` |
| **Cilium ทิ้งด้วยเหตุอื่น** | `DROPPED` แต่เหตุผลไม่ใช่ `Policy denied` เช่น `No route to host` · `Stale or unroutable IP` · `Invalid source ip` | `exit=28` / `7` |
| **DNS พัง** | ไม่มี flow ไปปลายทางเลย — ไปไม่ถึงขั้นต่อ | `exit=6` |

- มี `Policy denied` = เรื่องของเรา → เขียน rule เปิดทาง
- `FORWARDED` แต่ไม่มีขากลับ = packet ออกจาก cluster ไปแล้ว → ปัญหาอยู่นอก cluster ไล่ที่ network/ปลายทาง **ไม่ต้องแตะ policy**

คำสั่งข้างบนกรอง `--verdict DROPPED` จึงไม่เห็นกรณี `FORWARDED` — ถ้าจะดูครบทุกกรณี
ถอด `--verdict` ออกแล้วระบุ IP ปลายทางด้วย `--ip` (จับทั้งสองทิศ — เห็นขาออก ขากลับ และตัวที่ถูกทิ้ง):
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- \
    hubble observe --namespace myhr-prod --ip 192.168.50.101 --since 2m 2>/dev/null
done
```
(เปลี่ยน `192.168.50.101` เป็น IP ปลายทางที่สงสัย · รันทันทีหลังยิงทดสอบ เหมือนบล็อกข้างบน)

**เช็กว่า Hubble ทำงานอยู่จริง:**
```bash
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  echo "== $p"
  kubectl -n kube-system exec "$p" -c cilium-agent -- cilium-dbg status | grep -i hubble
done
```
**ควรเห็น:** ทุกเครื่องขึ้น `Hubble: Ok` พร้อมตัวเลข `Current/Max Flows`

> เหตุผลเดียวกับกรอบข้างบน — ค่านี้เป็นของ agent แต่ละตัว เครื่องที่ยัง `Disabled`
> คือเครื่องที่จะไม่มี flow ให้ดูตอนของพัง และเป็นเครื่องที่ไล่ปัญหาไม่ได้

ถ้ามีเครื่องไหนขึ้น `Disabled` แปลว่า values ที่ deploy จริงไม่ตรงกับ
[`values.yaml`](../config/cilium/values.yaml) ในrepo หรือ agent เครื่องนั้นยังไม่ได้ restart

---

## 4 · RBAC ตามหน้าที่

**ทำที่:** 👑 master01 · 4.1 ต้องรันบน master01 เท่านั้น (ใช้ `/etc/kubernetes/pki/ca.key` เซ็น cert — ห้ามคัดลอก key ออก)
· ไฟล์ kubeconfig ที่ออกได้ส่งให้เจ้าตัวทางช่องทางลับขององค์กร · **ต้องมีก่อน:** ข้อ 2 (namespace) · รู้แล้วว่าใคร 2 คน
จะถือ `cluster-admin` · 4.2 อ่านอย่างเดียว ยังไม่ต้องทำ

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

**ทดสอบว่า RBAC ทำงานจริง**

`kubectl auth can-i` ถาม apiserver ว่า "คนนี้ทำสิ่งนี้ได้ไหม" **โดยไม่ได้ทำจริง** ·
`--as=tester --as-group=myhr:developers` คือให้ root **สวมรอย**เป็น user `tester` ในกลุ่ม `myhr:developers`
— ตัวตนเดียวกับที่คนจะได้จาก kubeconfig ในข้อ 4.1 (ช่อง `O=myhr:developers` ใน cert)
จึงทดสอบสิทธิ์ได้โดยไม่ต้องออก cert จริง

```bash
kubectl auth can-i get pods    --as=tester --as-group=myhr:developers -n myhr-prod
kubectl auth can-i get secrets --as=tester --as-group=myhr:developers -n myhr-prod
kubectl auth can-i create pods --subresource=exec \
                               --as=tester --as-group=myhr:developers -n myhr-prod
kubectl auth can-i get pods    --subresource=log \
                               --as=tester --as-group=myhr:developers -n myhr-prod
kubectl auth can-i get pods    --as=tester --as-group=myhr:developers -n myhr-uat
kubectl auth can-i delete nodes --as=tester --as-group=myhr:developers
```
**ควรเห็นเรียงลงมา:** `yes` `no` `no` `yes` `no` `no`

ทีละบรรทัด — สิทธิ์มาจาก ClusterRole `myhr:developer` ใน [`rbac.yaml`](../config/security/rbac.yaml)
ซึ่งผูกกับกลุ่มนี้ด้วย RoleBinding **ใน `myhr-prod` เท่านั้น**:

| # | ถามว่า | ได้ | ทำไม |
|---|---|---|---|
| 1 | ดู pod ใน prod | `yes` | role ให้ `get/list/watch` pods |
| 2 | อ่าน secret ใน prod | `no` | **ตั้งใจไม่ให้** — secret มีรหัสฐานข้อมูลของแอป dev ไม่ควรเห็น |
| 3 | `exec` เข้า pod ใน prod | `no` | **ตั้งใจไม่ให้** — exec เข้าไปแล้วอ่าน env หรือไฟล์ secret ที่ mount อยู่ได้ = อ่าน secret ทางอ้อม และ audit log จะไม่บันทึกว่าเป็นการอ่าน secret |
| 4 | ดู log ของ pod ใน prod | `yes` | role ให้ `pods/log` — dev ต้องใช้ไล่ปัญหาแอป |
| 5 | ดู pod ใน **uat** | `no` | RoleBinding ผูกไว้แค่ `myhr-prod` · role เดียวกันแต่ไม่ได้ผูกใน uat ก็ไม่มีสิทธิ์ที่นั่น |
| 6 | ลบ node | `no` | dev ไม่มีสิทธิ์ระดับ cluster เลย |

> `Warning: resource 'nodes' is not namespace scoped` ใต้บรรทัดสุดท้าย **ไม่ใช่ error** — node ไม่อยู่ใน
> namespace ไหน แต่ kubectl แนบ namespace `default` จาก kubeconfig มาให้เอง เลยเตือนว่าค่านั้นไม่มีผล
> · ผล `no` ยังถูกต้อง

> อยากให้ dev ดู uat ได้ด้วย (บรรทัด 5 เป็น `yes`) → เพิ่ม RoleBinding ตัวที่สองใน `myhr-uat`
> — ผูกได้ทีละ namespace เหมือน NetworkPolicy

**ถ้าผลไม่ตรง — กับดักสองข้อที่ทำให้ทดสอบผิดโดยไม่รู้ตัว:**

> 🔴 **ต้องสวมรอยเป็น group ไม่ใช่ ServiceAccount** — `rbac.yaml` ผูกสิทธิ์ไว้กับ Group
> `myhr:developers` / `myhr:operators` ไม่ได้ผูกกับ ServiceAccount ตัวไหนเลย · ถ้าทดสอบด้วย
> `--as=system:serviceaccount:myhr-prod:developer` จะได้ `no` **เสมอ** ไม่ว่า RBAC จะถูกหรือผิด
> แล้วจะแปลผลผิดว่า "ปิดแน่นดี" · `--as-group` ต้องมาคู่กับ `--as` เพราะ apiserver ต้องการชื่อ user ด้วย

> 🔴 **subresource ต้องใช้ `--subresource` ห้ามเขียน `pods/exec` ติดกัน** — kubectl ตีความ `pods/exec`
> เป็น "resource `pods` ที่ชื่อ `exec`" แล้วไปถามว่า "create pods ได้ไหม" ซึ่งเป็นคนละคำถาม
> และมักได้ `no` ออกมาพอดี ดูเหมือนผ่านทั้งที่ไม่ได้ทดสอบสิ่งที่ตั้งใจ

**ฝั่ง ops:**
```bash
kubectl auth can-i get nodes    --as=tester --as-group=myhr:operators
kubectl auth can-i create pods  --subresource=eviction \
                                --as=tester --as-group=myhr:operators -n myhr-prod
kubectl auth can-i delete nodes --as=tester --as-group=myhr:operators
kubectl auth can-i get secrets  --as=tester --as-group=myhr:operators -A
```
**ควรเห็น:** `yes` `yes` `no` `no` — `delete nodes` ต้องเป็น `no` เพราะ role ให้แค่
`get/list/watch/patch/update` · ส่วน `pods --subresource=eviction` ต้องเป็น `yes`
ไม่งั้น `kubectl drain` ในบทที่ 12 จะใช้ไม่ได้

> ⚠️ **`myhr:deployer` ยังไม่มี binding ชี้ถึงเลย** — ClusterRole ถูกสร้างไว้แล้วแต่ยังไม่มีใครใช้ได้
> ตั้งใจไว้แบบนั้นจนกว่าจะมีคน deploy จริง วันที่จะใช้ ให้สร้าง RoleBinding ผูกกับ group
> ของทีมนั้นใน namespace ที่ต้องการ แล้วทดสอบด้วยวิธีเดียวกันข้างบน

---

### 4.1 ออก kubeconfig ให้คนใหม่

ตอนนี้ยังไม่มี OIDC — ตัวตนของคนมาจาก **client certificate** ที่เซ็นด้วย CA ของ cluster
โดย `CN` กลายเป็นชื่อ user และ `O` กลายเป็น group ที่ [`rbac.yaml`](../config/security/rbac.yaml) ผูกสิทธิ์ไว้

```
/CN=somchai/O=myhr:developers
     │              └── group → ได้สิทธิ์ myhr:developer
     └── user → ชื่อที่โผล่ใน audit log
```

**ทางลัด — ใช้สคริปต์ทำทั้ง 5 ขั้นให้จบในคำสั่งเดียว**
([`issue-kubeconfig.sh`](../config/security/issue-kubeconfig.sh) ทำตามขั้นตอนด้านล่างนี้ทั้งหมด
แล้วทดสอบสิทธิ์ด้วยไฟล์ที่เพิ่งออกก่อนบอกว่าเสร็จ):

```bash
bash /root/k8s/config/security/issue-kubeconfig.sh teeradach --admin   # ผู้ดูแล cluster
bash /root/k8s/config/security/issue-kubeconfig.sh somchai             # dev (ค่าเริ่มต้น)
bash /root/k8s/config/security/issue-kubeconfig.sh somsak myhr:operators
```
ได้ไฟล์ `<ชื่อ>.kubeconfig` (0600) ไฟล์เดียวจบ · ไฟล์กลาง (key/csr/crt) ถูกลบให้อัตโนมัติ ·
รันซ้ำได้ ของเดิมชื่อเดียวกันจะถูกออกใหม่ทับ

> **`--admin` ผูกกับ group `myhr:admins` ไม่ใช่ `system:masters`** — `system:masters`
> ข้าม RBAC ทั้งหมดและ**ถอนไม่ได้**ถ้า cert หลุด สคริปต์จึงปฏิเสธให้ตรง ๆ ·
> ส่วน `myhr:admins` ตัดได้ทันทีด้วย `kubectl delete clusterrolebinding myhr-admins`
> โดยไม่ต้องรื้อ CA · binding อยู่ใน [`rbac.yaml`](../config/security/rbac.yaml) แล้ว
> ต้อง `kubectl apply` ก่อนออก cert ใบแรก

> ไฟล์นี้เป็น kubeconfig มาตรฐาน ใช้กับ `kubectl`, k9s, Lens หรือ **Headlamp แบบ desktop app**
> ได้ทันที · แต่ **Headlamp ที่ deploy ไว้ใน cluster ล็อกอินด้วย token ไม่ใช่ client cert**
> ต้องใช้ ServiceAccount แทน ดูหัวข้อ 4.1ก

**ทำเองทีละขั้น — 👑 บน master01:**
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

### 4.1ก เข้าผ่าน Headlamp / dashboard ที่รันใน cluster

UI ที่ deploy อยู่ใน cluster (Headlamp, Kubernetes Dashboard) รับ **bearer token** อย่างเดียว
ไม่รับ client certificate — kubeconfig จากข้อ 4.1 จึงใช้ล็อกอินหน้าเว็บไม่ได้
(ใช้ได้กับ Headlamp แบบ **desktop app** เพราะตัวนั้นอ่าน kubeconfig ตรง ๆ)

```bash
kubectl -n kube-system create serviceaccount headlamp-admin
kubectl create clusterrolebinding headlamp-admin \
  --clusterrole=cluster-admin --serviceaccount=kube-system:headlamp-admin

# token อายุสั้น — ขอใหม่ทุกครั้งที่จะใช้
kubectl -n kube-system create token headlamp-admin --duration=8h
```
เอา token ที่ได้ไปวางในหน้าล็อกอินของ Headlamp

> 🔴 **อย่าสร้าง Secret แบบ token ถาวรให้ ServiceAccount นี้** — token ที่ไม่มีวันหมดอายุ
> คือ cluster-admin ที่หลุดแล้วหลุดเลย · `kubectl create token --duration` ออกใบใหม่ได้
> ทุกครั้งที่ต้องใช้ ซึ่งเพียงพอสำหรับการเข้าดูเป็นครั้งคราว
>
> ถ้าจะให้ทีมใช้ประจำ ให้ผูก ServiceAccount กับ role ที่แคบกว่าแทน เช่น
> `--clusterrole=myhr:developer --serviceaccount=kube-system:headlamp-viewer`
> แล้วออก token คนละใบ จะได้แยกได้ใน audit log ว่าใครทำอะไร

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

## 5 · Audit log — บันทึกว่าใครทำอะไรกับ cluster

**ทำที่:** 5.1 🎩 master ทั้ง 3 **ทีละเครื่อง** · 5.2-5.3 บน 👑 master01
· **ต้องมีก่อน:** ข้อ 0 (ไฟล์ตรง repo) · ข้อ 1 จบ apiserver ทั้ง 3 ปกติ — 5.1 จะ restart apiserver อีกรอบ

**audit log คืออะไร** — กล้องวงจรปิดของ Kubernetes · ทุกคำสั่งที่ใครก็ตามส่งเข้า cluster (kubectl · Headlamp ·
pod ที่เรียก API) apiserver จะจดลงไฟล์ `/var/log/kubernetes/audit.log` บรรทัดละเรื่อง:
**ใคร ทำอะไร กับอะไร เมื่อไหร่ ผลเป็นยังไง** · เป็นที่เดียวที่ตอบได้ว่าใครลบ deployment ตอนตีสอง ·
ใครอ่าน secret · ใครเพิ่มสิทธิ์ให้ตัวเอง (log ของ pod ตอบไม่ได้ — นั่นคือเสียงของแอป ไม่ใช่ของ Kubernetes)

**ข้อนี้ทำอะไร** — กล้องเปิดอยู่แล้วตั้งแต่บท 04 แต่ใช้ **กฎชุดพื้นฐาน** (`config/kubeadm/audit-policy.yaml`)
ข้อนี้เปลี่ยนเป็น **กฎชุดเต็ม** (`config/security/audit-policy.yaml`) ซึ่งจดละเอียดขึ้นในเรื่องที่อันตราย
และเลิกจดเรื่องที่ไม่มีประโยชน์:

| เหตุการณ์ | จดไหม | จดละเอียดแค่ไหน |
|---|---|---|
| อ่าน Secret | ✅ | ใครอ่าน secret ไหน — **ไม่จดค่าข้างใน** (ถ้าจด ไฟล์ log จะกลายเป็นที่รั่วเสียเอง) |
| แก้สิทธิ์ (RBAC) | ✅ | ละเอียดทั้งหมด — เห็นว่าเพิ่มสิทธิ์อะไรให้ใคร |
| `exec` · `attach` · `port-forward` เข้า pod | ✅ | ละเอียดทั้งหมด — เป็นช่องแอบเอาข้อมูลออกได้ |
| สร้าง / แก้ / ลบ อะไรก็ตาม | ✅ | ละเอียดทั้งหมด |
| ดู pod · service · node | ✅ | แค่ว่าใครดู |
| `/healthz` · `/metrics` · kubelet · Prometheus | ❌ | ไม่จด — เกิดวินาทีละหลายครั้ง จดไปก็แค่ทำ disk เต็มและหาเรื่องจริงไม่เจอ |

ไฟล์หมุนเก็บที่ 100 MB × 10 ไฟล์ · เก็บ 30 วัน (ตั้งไว้ใน `kubeadm-config.yaml` ตั้งแต่บท 04)

> 🔴 **ไฟล์เป็นของแต่ละ master แยกกัน** — คำสั่งผ่าน VIP แล้วตกที่ apiserver เครื่องไหน ก็ถูกจดที่เครื่องนั้นเครื่องเดียว
> ทั้ง 3 เครื่องจึงมีเนื้อหาไม่เหมือนกัน · เวลาสืบว่าใครทำอะไร ต้องค้นให้ครบทั้งสามเครื่องเสมอ

### 5.1 เปลี่ยนเป็นกฎชุดเต็ม — 🎩 ทีละเครื่อง

**ทำที่:** ssh เข้า master ทีละเครื่อง (master01 → 02 → 03) รอ `ok` ก่อนไปเครื่องถัดไป

apiserver อ่านไฟล์กฎแค่ตอนเริ่ม จึงต้อง copy ไฟล์ แล้ว restart apiserver ของเครื่องนั้น — บล็อกเดียวจบ:
```bash
\cp -f /root/k8s/config/security/audit-policy.yaml /etc/kubernetes/audit-policy.yaml && chmod 600 /etc/kubernetes/audit-policy.yaml
echo "กฎชุดเต็ม: $(grep -c 'pods/exec' /etc/kubernetes/audit-policy.yaml)"
mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/ && sleep 10 && mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
until curl -sk https://127.0.0.1:6443/healthz | grep -q ok; do sleep 3; done; echo "apiserver ของ $(hostname) ok"
```
**ควรเห็น:** `กฎชุดเต็ม: 1` แล้ว `apiserver ของ k8s-masterXX ok` ภายใน ~1 นาที
· ได้ `กฎชุดเต็ม: 0` = copy ไม่โดน (`/root/k8s/config/security/` ยังเป็นไฟล์เก่า — กลับไปข้อ 0)

(บรรทัด `mv` คือการ restart — ย้ายไฟล์ manifest ออก kubelet จะหยุด apiserver ย้ายกลับก็สร้างใหม่ให้ ·
ระหว่างนั้น `kubectl` ผ่าน VIP ยังใช้ได้ เพราะ HAProxy ส่งไป master ที่เหลือ · ไม่ต้องแก้ `kube-apiserver.yaml`
— การตั้งค่า audit อยู่ในนั้นแล้วตั้งแต่บท 04)

### 5.2 พิสูจน์ว่าจดจริง

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** 5.1 ครบ 3 เครื่อง

ทำอะไรสักอย่างที่รู้หน้าตาแน่ ๆ (อ่านรายชื่อ secret) แล้วไปหาบรรทัดนั้นในไฟล์ของทั้ง 3 เครื่อง:
```bash
kubectl -n kube-system get secret > /dev/null
for ip in 101 102 103; do
  echo "== .$ip"
  ssh root@192.168.50.$ip "grep -h '\"resource\":\"secrets\"' /var/log/kubernetes/audit.log | tail -1" \
    | jq -c '{level, user:.user.username, verb, ns:.objectRef.namespace, body:(.requestObject // .responseObject // "ไม่มี")}'
done
```
**ควรเห็น:** อย่างน้อยหนึ่งเครื่องขึ้นบรรทัดประมาณ
`{"level":"Metadata","user":"kubernetes-admin","verb":"list","ns":"kube-system","body":"ไม่มี"}`

| ส่วน | บอกอะไร |
|---|---|
| `user` | ใครทำ — คนที่ใช้ kubeconfig จากข้อ 4.1 จะเห็นเป็นชื่อในช่อง `CN` ของ cert |
| `verb` · `ns` | ทำอะไร ที่ namespace ไหน (`list` = ดูรายชื่อ) |
| `level: Metadata` + `body: ไม่มี` | จดแค่ว่ามีคนอ่าน **ไม่ได้จดค่า secret** — ตรงตามกฎ ✅ |

(เครื่องที่ขึ้นว่าง = คำสั่งนั้นไม่ได้ตกที่เครื่องนั้น ปกติ)

**ด้านกลับ — เรื่องที่ไม่ควรจดต้องไม่อยู่ในไฟล์:**
```bash
grep -c '"/healthz' /var/log/kubernetes/audit.log
```
**ควรเห็น:** `0` — ได้เลขเยอะ = กฎชุดเต็มไม่ถูกโหลด (apiserver ยังไม่ได้ restart หลัง copy) disk จะเต็มใน 2-3 วัน → ทำ 5.1 เครื่องนั้นใหม่

### 5.3 เอาไปใช้ตอนสืบสวน

**ทำที่:** master เครื่องไหนก็ได้ — **ต้องรันครบทั้ง 3 เครื่อง** เพราะแต่ละเครื่องจดคนละส่วน
(หรือรันจากเครื่องคุณด้วย `ssh root@192.168.50.10X '<คำสั่ง>'` ทีละเครื่อง)

ใครลบอะไรไปบ้าง:
```bash
jq -r 'select(.verb=="delete")
       | "\(.requestReceivedTimestamp) \(.user.username) ลบ \(.objectRef.resource)/\(.objectRef.name)"' \
  /var/log/kubernetes/audit.log | tail -20
```
**ควรเห็น:** รายการว่าใครลบอะไรไปบ้างเรียงตามเวลา — คำถามแรกที่จะถูกถามเวลาของหาย

ใครแตะ RBAC บ้าง:
```bash
jq -r 'select(.objectRef.apiGroup=="rbac.authorization.k8s.io")
       | "\(.requestReceivedTimestamp) \(.user.username) \(.verb) \(.objectRef.resource)/\(.objectRef.name)"' \
  /var/log/kubernetes/audit.log | tail -20
```

ใคร exec เข้า pod ไหน:
```bash
jq -r 'select(.objectRef.subresource=="exec")
       | "\(.requestReceivedTimestamp) \(.user.username) → \(.objectRef.namespace)/\(.objectRef.name)"' \
  /var/log/kubernetes/audit.log
```
**ควรเห็น:** ว่างเปล่าในระบบที่ปกติ — ทุกบรรทัดที่โผล่ต้องอธิบายได้ว่าใครทำและทำไม

---

## 6 · หนี้เก่าที่ต้องจ่าย — หมุน credential

**ทำที่:** ไม่ใช่งานบน cluster — งานประสานกับทีม infra/network/registry · ติ๊กตารางนี้ให้ครบก่อนส่งมอบ

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

**สำหรับ registry — สร้าง 2 account แยกกัน:** account สำหรับ push (คนหรือ CI ที่สร้าง image)
กับ account ที่ **pull ได้อย่างเดียว** สำหรับ cluster

cluster ต้องใช้ตัวหลังเท่านั้น วิธีเอาเข้า cluster อยู่ที่ **หัวข้อ 7** ข้างล่าง

---

## 7 · imagePullSecret — ให้ cluster ดึง image จาก private registry

**ทำที่:** 👑 master01 (7.1 → 7.4) · **ต้องมีก่อน:** ข้อ 2 (namespace `myhr-prod` / `myhr-uat`) · รหัส registry
จาก `secrets.env` บนเครื่องคุณ (คีย์ `PULL_ONLY_USER` / `PULL_ONLY_PASSWORD`) พิมพ์ทางแป้นพิมพ์ตอน 7.2
· node ต่อ `registry.myhr.co.th` ได้แล้ว ([บท 02](02-container-runtime.md))

`registry.myhr.co.th` เป็น registry ส่วนตัว ยิง `/v2/` เปล่า ๆ จะได้ `401` เสมอ
**kubelet บนทุก node จึงต้องมี credential ก่อน ไม่งั้น pod ทุกตัวจะค้างที่ `ImagePullBackOff`**

วิธีที่ใช้คือแบบเดิมที่เคยทำมา 2 ขั้น: **สร้าง Secret ชนิด `dockerconfigjson` ชื่อ `regcred`**
แล้ว **อ้างถึงมันใน Deployment ด้วย `imagePullSecrets`**

> 🔴 **Secret ผูกกับ namespace** — ต้องสร้างทุก namespace ที่มี pod ดึง image
> จาก registry ส่วนตัว (ตอนนี้คือ `myhr-prod` และ `myhr-uat`)
> คู่มือชุดเดิมสร้างแค่ใน `default` แล้วงงว่าทำไม namespace อื่น pull ไม่ได้
> · Kubernetes ไม่มี imagePullSecret ระดับ cluster ให้ใช้ ทำซ้ำต่อ namespace คือทางที่ถูกแล้ว
>
> ไฟล์ Secret **ไม่มีอยู่ในrepo โดยตั้งใจ** เพราะมีรหัสจริงอยู่ข้างใน — เก็บได้แค่วิธีสร้าง

---

### 7.1 เช็กก่อนว่าเป็นปัญหารหัสจริงไหม

`ImagePullBackOff` ไม่ได้แปลว่าเรื่อง credential เสมอไป ถามตัว registry ก่อน —
บรรทัดแรกเอาค่า `REGISTRY_HOST` เข้า shell **ต้องรันใหม่ทุกครั้งที่ ssh เข้ามา**
ไม่งั้น URL จะกลายเป็น `https:///v2/` แล้วอ่านผลไม่ได้ความ:

```bash
set -a && . <(tr -d '\r' < /root/k8s/versions.env) && set +a
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "https://${REGISTRY_HOST}/v2/"
```

| ผลที่ได้ | แปลว่า |
|---|---|
| `HTTP 401` | ✅ เครือข่ายถึง · TLS ผ่าน · เหลือแค่ยังไม่ได้ล็อกอิน → ทำข้อ 7.2 ต่อ |
| `certificate ...` · `unknown authority` | cert/CA ของ registry — **สร้าง secret กี่รอบก็ไม่หาย** ([บทที่ 02 หัวข้อ 4](02-container-runtime.md)) |
| `could not resolve host` | DNS หรือ `/etc/hosts` ([บทที่ 01](01-prepare-os.md)) |
| `connection refused` · timeout | ไปไม่ถึงเครื่อง registry — ทีม network |

---

### 7.2 สร้าง Secret

**👑 บน master01** — เอาค่า `REGISTRY_HOST` เข้า shell ก่อน (shell ใหม่ทุกครั้งที่ ssh เข้ามา
ไม่มีค่านี้ติดมาเอง):

```bash
set -a && . <(tr -d '\r' < /root/k8s/versions.env) && set +a
echo "REGISTRY_HOST=[$REGISTRY_HOST]"
```
**ควรเห็น:** `REGISTRY_HOST=[registry.myhr.co.th]` — ถ้าได้ `[]` อย่าเพิ่งไปต่อ

รับรหัสทางแป้นพิมพ์ ไม่พิมพ์ต่อท้ายคำสั่ง (ไม่งั้นรหัสค้างใน `~/.bash_history`
และเห็นได้จาก `ps aux` ของทุกคนบนเครื่อง) แล้ว**ตรวจว่าครบทั้งสามค่าก่อนยิงจริง**:

```bash
read -rp  'registry user: ' PULL_USER
read -rsp 'registry password: ' PULL_PASS && echo

if [ -n "$REGISTRY_HOST" ] && [ -n "$PULL_USER" ] && [ -n "$PULL_PASS" ]; then
    echo "ครบ: host=$REGISTRY_HOST user=$PULL_USER pass=${#PULL_PASS} ตัวอักษร"
else
    echo "❌ ยังมีตัวที่ว่างอยู่ อย่าเพิ่งไปต่อ"
fi
```
**ควรเห็น:** `ครบ: host=... user=... pass=N ตัวอักษร`

> ⚠️ **ด่านนี้มีไว้เพราะตัวแปรว่างไม่ได้ทำให้คำสั่งเงียบ ๆ ผ่านไป** — `kubectl` จะขึ้น
> `error: either --from-file or the combination of --docker-username, --docker-password
> and --docker-server is required` ตามด้วย `no objects passed to apply`
> ซึ่งอ่านแล้วเหมือนพิมพ์คำสั่งผิด ทั้งที่จริงคือลืม source `versions.env`

```bash
for ns in myhr-prod myhr-uat; do
  kubectl -n "$ns" create secret docker-registry regcred \
    --docker-server="${REGISTRY_HOST}" \
    --docker-username="$PULL_USER" \
    --docker-password="$PULL_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
done
unset PULL_PASS
```
**ควรเห็น:** `secret/regcred created` (หรือ `configured` ถ้าเคยสร้างไว้แล้ว) namespace ละบรรทัด

> 🔴 **เพิ่ม namespace ใหม่เมื่อไหร่ ต้องกลับมารันบล็อกนี้ใหม่โดยใส่ชื่อมันเข้าไปด้วย**
> ไม่มีอะไรเตือนเลยจนกว่าจะ deploy แล้ว pod ค้าง `ImagePullBackOff` อยู่ namespace เดียว
> ทั้งที่ namespace อื่นใช้ได้ปกติ · เกณฑ์คือ **namespace ไหนมี pod ที่ดึง image
> จาก `registry.myhr.co.th` namespace นั้นต้องมี `regcred`** — namespace ที่ใช้ image
> จาก public registry ล้วน ๆ ไม่ต้องมี

**ตรวจว่าครบทุก namespace ที่ต้องมี:**
```bash
for ns in myhr-prod myhr-uat; do
  printf '%-12s ' "$ns"
  kubectl -n "$ns" get secret regcred -o name 2>/dev/null || echo "❌ ยังไม่มี"
done
```
**ควรเห็น:** `secret/regcred` ครบทุกบรรทัด

ใช้ `--dry-run=client | kubectl apply` แทน `create` เฉย ๆ เพื่อให้**รันซ้ำได้**
ตอนหมุนรหัส `create` ธรรมดาจะขึ้น `already exists` แล้วรหัสเก่าค้างอยู่โดยไม่มีใครรู้

**สามข้อที่พลาดกันบ่อยที่สุด:**

| พลาด | ผลที่ได้ |
|---|---|
| `--docker-server` ใส่เป็น `https://...` หรือมี path ต่อท้าย | ได้ `401` เหมือนไม่มี secret เลย — ต้องเป็น **host เปล่า ๆ** ตรงกับที่เขียนใน `image:` |
| สร้างแค่ namespace เดียว | namespace อื่น pull ไม่ได้ และไม่มีอะไรเตือนจนกว่าจะ deploy |
| ใช้ account เดียวกับที่ push ได้ | รหัสที่ push ได้กระจายไปอยู่ทุก node — ใช้ account ที่ **pull อย่างเดียว** (ข้อ 6) |

---

### 7.3 อ้างถึงใน Deployment

`imagePullSecrets` อยู่ใต้ `spec.template.spec` **ระดับเดียวกับ `containers`** ไม่ใช่ข้างใน container:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: regcred          # ชื่อ Secret ใน namespace เดียวกับ Deployment
      containers:
        - name: zeeme-ads
          image: registry.myhr.co.th/myhr/zeeme-ads:1.0.0
```

ใส่ไว้ให้แล้วทั้งใน [`deployments/zeeme-ads/deployment.yaml`](../deployments/zeeme-ads/deployment.yaml)
และแม่แบบ [`config/app/deployment-template.yaml`](../config/app/deployment-template.yaml)
— แอปใหม่ก็อปจากแม่แบบจะมีติดมาเอง

> **host ใน `image:` ต้องตรงกับ `--docker-server` เป๊ะ** — `registry.myhr.co.th/myhr/app`
> จะไปหา secret ที่ผูกกับ host `registry.myhr.co.th` เท่านั้น ถ้าตัวใดตัวหนึ่งเขียนเป็น IP
> หรือมี `:443` ต่อท้าย จะไม่ match กันแล้วได้ `401` ทั้งที่ secret ถูกต้องทุกอย่าง

---

### 7.4 ตรวจว่าใช้ได้จริง

**อ่าน host ที่อยู่ในตัว secret จริง ๆ ไม่ใช่แค่ดูว่ามี secret อยู่:**
```bash
kubectl -n myhr-prod get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```
**ควรเห็น:** `{"auths":{"registry.myhr.co.th":{"auth":"..."}}}` — host ต้องตรงกับใน `image:`
· ผลลัพธ์มี credential อยู่ข้างใน **อย่าวางต่อลงแชตหรือ ticket**

**Deployment เห็น secret จริงไหม:**
```bash
kubectl -n myhr-prod get deploy zeeme-ads -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}{"\n"}'
```
**ควรเห็น:** `regcred`

**pod ที่ค้างอยู่ต้องสั่งให้ลองใหม่** — `ImagePullBackOff` retry เองแต่ backoff ถอยไปถึง 5 นาที:
```bash
kubectl -n myhr-prod rollout restart deploy/zeeme-ads
```

**ถ้ายังไม่ผ่าน แยกชั้นด้วยการ pull จาก node ตรง ๆ:**
```bash
crictl pull --creds '<PULL_ONLY_USER>:<PULL_ONLY_PASSWORD>' "${REGISTRY_HOST}/myhr/zeeme-ads:1.0.0"
```
- node pull ได้ แต่ pod ไม่ได้ → เรื่อง secret · namespace · หรือชื่อ host (ข้อ 7.2/7.3)
- node ก็ pull ไม่ได้ → เรื่อง containerd · cert · network ([บทที่ 02 หัวข้อ 4](02-container-runtime.md))

---

### 7.5 ตอนหมุนรหัส registry

รันบล็อกในข้อ 7.2 ซ้ำได้เลย — `apply` เขียนทับให้

> ⚠️ **pod ที่รันอยู่แล้วจะไม่รู้ว่ารหัสเปลี่ยน** เพราะมันไม่ pull ใหม่ ปัญหาจะโผล่ตอน
> pod ถัดไปเกิด ซึ่งอาจเป็นตอน drain กลางดึกที่ไม่มีใครนั่งดู — หมุนรหัสเมื่อไหร่
> ให้ `rollout restart` ทุก Deployment ที่ใช้ registry นี้ในเวลาทำการเลย

---

## 8 · ตรวจทั้งบทด้วยสคริปต์เดียว

**ทำที่:** 👑 master01 · **ต้องมีก่อน:** ข้อ 1-5 และ 7 จบ (ข้อ 6 สคริปต์ตรวจไม่ได้) · apiserver ทั้ง 3 ปกติ

ทุกด่านในบทนี้ผ่านได้ทั้งที่ระบบยังไม่ปลอดภัย — เปิด encryption แค่ master01
แล้วทดสอบผ่าน VIP ก็ยังผ่าน 2 ใน 3 ครั้ง · ติด label PSA แล้วแต่ไม่มีผลจะรู้ตอนบทที่ 11 ·
apply NetworkPolicy สำเร็จไม่ได้แปลว่า Cilium บังคับใช้จริง

[`verify-security.sh`](../config/security/verify-security.sh) ยิงของจริงทุกข้อแล้วสรุปเป็น ผ่าน/ตก
(อยู่บนเครื่องแล้วจาก[บท 00](00-overview.md)):

**👑 บน master01:**
```bash
bash /root/k8s/config/security/verify-security.sh
```

**ควรเห็น:** `ผ่าน N · ตก 0 · ระวัง 0` แล้วปิดท้ายด้วย `✅ บทที่ 10 ใช้งานได้จริง`
(คืน exit code 0 เมื่อไม่มีข้อไหนตก — เอาไปต่อกับ CI ได้)

สคริปต์ตรวจ 5 เรื่อง:

| ตรวจ | วิธี |
|---|---|
| etcd encryption | เขียน Secret ใหม่จริง แล้วอ่าน byte ตรงจาก etcd · เทียบว่าค่าที่เขียนไม่โผล่เป็น plaintext |
| key ตรงกันทั้ง 3 master | ยิงตรงเข้า `:6443` ทีละเครื่อง ไม่ผ่าน VIP |
| PSA | ขอสร้าง privileged pod ด้วย `--dry-run=server` ต้องโดนปฏิเสธ |
| NetworkPolicy | `default-deny-all` กับ `allow-dns-egress` ต้องมาคู่กัน + Cilium โหลด policy แล้ว |
| audit log | flag ครบทั้ง 3 apiserver + ไฟล์ถูกเขียนภายใน 5 นาทีที่ผ่านมา |

> สคริปต์แตะของจริงอย่างเดียวคือสร้าง Secret ชั่วคราว `enc-verify-*` ใน `default`
> แล้วลบทิ้งเมื่อจบ — ต้องเขียนของใหม่ถึงจะรู้ว่า**ตอนนี้**ยังเข้ารหัสอยู่จริง
> ที่เหลืออ่านอย่างเดียว รันซ้ำได้ตลอด และควรรันซ้ำหลังทุกครั้งที่แตะ apiserver

**สองข้อที่สคริปต์ตรวจแทนไม่ได้** ต้องยืนยันด้วยคน — การหมุน credential เก่า (หัวข้อ 6)
และ encryption key ต้องอยู่ในที่เก็บ secret ขององค์กร ไม่ใช่ในเครื่องใครเครื่องมัน

---

## ✅ เกณฑ์ผ่านของบทนี้

- [ ] 🔴 อ่าน Secret ตรงจาก etcd แล้ว **เห็นเป็นข้อมูลเข้ารหัส** ไม่ใช่ plaintext
- [ ] encryption key เก็บในที่เก็บ secret แล้ว **และไม่ได้อยู่ใน git**
- [ ] Secret เก่าถูกเขียนทับให้เข้ารหัสครบแล้ว
- [ ] 🔴 **apiserver ทั้ง 3 เครื่องถอดรหัส Secret ตัวเดียวกันได้** — ยิงตรงที่ `--server=https://192.168.50.101|102|103:6443` ไม่ผ่าน VIP
- [ ] namespace ของ application เป็น PSA `restricted`
- [ ] 🔴 NetworkPolicy default-deny ทำงาน — **เทียบก่อน/หลัง apply ด้วยคำสั่งเดียวกัน** ผลต้องเปลี่ยนจาก `http=403` เป็น `exit=28` และ DNS ยังใช้ได้เหมือนเดิม
- [ ] RBAC role ครบ 3 ระดับ · `cluster-admin` ไม่เกิน 2 คน · จดรายชื่อไว้แล้ว
- [ ] audit log เขียนไฟล์จริงและอ่านได้
- [ ] 🔴 **credential ที่รั่วในเอกสารเดิม หมุนครบทุกตัวแล้ว**
- [ ] `regcred` เป็น account ที่ pull ได้อย่างเดียว ไม่ใช่รหัสเดียวกับ root
- [ ] 🔴 `regcred` มีครบ **ทุก namespace** ที่ต้อง pull image · host ในตัว secret ตรงกับที่เขียนใน `image:`
- [ ] `bash config/security/verify-security.sh` ขึ้น **ตก 0** บน master01

**➡️ ต่อที่ [บทที่ 11 — Deploy Application](11-deploy-app.md)**
