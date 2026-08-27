# บทที่ 02 — Container Runtime

> **รันที่: 🖥️ ทุกเครื่อง (ทั้ง 6 เครื่อง)**
> **เวลาที่ใช้:** ~15 นาที/เครื่อง
> **ต้องผ่านบทที่ 01 มาก่อน** — โดยเฉพาะขั้นที่ 5 (partition) และขั้นที่ 10 (reboot)

---

## ทำไมลงจาก tarball ไม่ใช่ `dnf`

เพื่อคุมเวอร์ชันให้เป๊ะตามหลัก reproducible — repo ของ distro จะอัปเดตเองและทำให้ node
สองเครื่องไม่เหมือนกันโดยไม่มีใครสังเกต แลกมาด้วยการต้องอัปเดตเองด้วยมือ ซึ่งยอมรับได้

> เราปิด `ol9_addons` ไปแล้วในบทที่ 01 เพราะ repo นั้นมี `containerd.io` ของ Oracle
> ที่จะมาทับตัวนี้ตอน `dnf update` รอบหน้า

---

## 0 · โหลดตัวแปร

```bash
set -a && source /root/k8s/versions.env && set +a
echo "containerd=$CONTAINERD_VERSION runc=$RUNC_VERSION cni=$CNI_PLUGINS_VERSION"
```

**ควรเห็น:** `containerd=2.2.7 runc=1.5.1 cni=1.9.1`

---

## 1 · ดาวน์โหลดและตรวจ checksum

```bash
mkdir -p /root/k8s/dl && cd /root/k8s/dl

curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz.sha256sum"
curl -fsSLO "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
curl -fsSLO "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"
# containerd.service ไม่ได้อยู่ใน release asset — อยู่ในซอร์สตาม tag
curl -fsSLO "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"

sha256sum -c "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz.sha256sum"
```

**ควรเห็น:** `containerd-2.2.7-linux-amd64.tar.gz: OK`
ถ้าไม่ใช่ `OK` **ให้หยุด** — อย่าติดตั้งไฟล์ที่ checksum ไม่ตรง

> ถ้า node ออกอินเทอร์เน็ตไม่ได้ ให้โหลดไฟล์เหล่านี้จากเครื่องที่ออกได้
> แล้ว `scp` มาวางที่ `/root/k8s/dl/` บนทุกเครื่อง — ขั้นตอนที่เหลือเหมือนกัน

---

## 2 · ติดตั้ง

```bash
cd /root/k8s/dl

# containerd
tar Cxzvf /usr/local "containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"

# runc
install -m 755 runc.amd64 /usr/local/sbin/runc

# CNI plugins (binary ที่ Cilium เรียกใช้)
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin "cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"

# systemd unit
install -m 644 containerd.service /usr/local/lib/systemd/system/containerd.service 2>/dev/null \
  || { mkdir -p /usr/local/lib/systemd/system && install -m 644 containerd.service /usr/local/lib/systemd/system/containerd.service; }

systemctl daemon-reload
```

**ตรวจ:**
```bash
containerd --version && runc --version

# ตรวจ plugin ที่ต้องมีจริง ๆ — อย่าใช้ head เพราะเรียงตามตัวอักษรแล้วตัวสำคัญหลุด
ls /opt/cni/bin | grep -cE '^(bridge|host-local|loopback|portmap)$'
```
**ควรเห็น:**
- `containerd github.com/containerd/containerd/v2 v${CONTAINERD_VERSION}`
- `runc version ${RUNC_VERSION}`
- บรรทัดสุดท้ายเป็น **`4`** — ครบทั้ง `bridge`, `host-local`, `loopback`, `portmap`

> `loopback` คือตัวที่ Cilium ต้องใช้จริง (ให้ pod มี `lo`) ส่วน `portmap` ใช้ตอนมี `hostPort`
> ถ้าได้น้อยกว่า 4 แปลว่าแตก tarball ไม่ครบ ให้ลบ `/opt/cni/bin` แล้วแตกใหม่

---

## 3 · สร้าง config.toml

คู่มือชุดเดิม**ไม่มีไฟล์นี้เลย** ทำให้ containerd ใช้ค่า default ซึ่งเป็น `cgroupfs`
ขณะที่ kubelet ถูกตั้งเป็น `systemd` — เป็น mismatch ที่ทำให้ node evict pod มั่วตอนโหลดสูง

```bash
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
```

**แก้ 1 ค่า — `SystemdCgroup`:**

```bash
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml
```
**ควรเห็น:** `SystemdCgroup = true` (ต้องไม่เหลือ `false` แม้แต่บรรทัดเดียว)

> **sandbox image ตรวจที่ขั้นที่ 5** หลังลง kubeadm แล้ว — ตอนนี้ยังเทียบไม่ได้


> containerd 2.x ใช้ config **version 3** และ CRI plugin ถูกแยกเป็น
> `io.containerd.cri.v1.runtime` กับ `io.containerd.cri.v1.images`
> (เดิมรวมกันที่ `io.containerd.grpc.v1.cri`) — ถ้าเจอตัวอย่างเก่าในอินเทอร์เน็ตที่ใช้ชื่อเดิม อย่าลอกมาใช้

---

## 4 · ตั้งค่า private registry

> **ยืนยันจากของจริงแล้วเมื่อ 27 ส.ค. 2026 — ไม่ต้องเดาและไม่ต้องเลือกทาง**
> `registry.myhr.co.th` เป็น **HTTPS** · cert เป็น wildcard `CN=*.myhr.co.th`
> ออกโดย **GlobalSign AlphaSSL ซึ่งเป็น CA สาธารณะ** → Oracle Linux 9.8 trust อยู่แล้ว
>
> 🔴 cert หมดอายุ **6 ก.ย. 2026** — ดู [CHECKLIST หมวด A2](CHECKLIST.md)

**รันสองบล็อกนี้ จบ:**

```bash
mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}"
```

```bash
cat > "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" <<EOF
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
EOF
```

> ✅ **ไม่มีขั้นตอนเรื่อง CA ในบทนี้** — เพราะ cert ออกโดย CA สาธารณะ
> ถ้าเคยเห็นคู่มือรุ่นเก่าที่ให้ `cp ca.crt` แล้ว `update-ca-trust` **ข้ามได้เลย**
> ไฟล์ `config/registry/ca.crt` ไม่มีอยู่จริงและไม่จำเป็นต้องมี

**ตรวจ:**
```bash
cat "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml"

# TLS ผ่านไหม
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "https://${REGISTRY_HOST}/v2/"

# cert เหลืออีกกี่วัน
openssl s_client -connect "${REGISTRY_HOST}:443" -servername "${REGISTRY_HOST}" \
  </dev/null 2>/dev/null | openssl x509 -noout -enddate
```

**ควรเห็น:**
- `HTTP 401` — **401 คือผ่าน** แปลว่า TLS verify สำเร็จ เหลือแค่ยังไม่ได้ล็อกอิน
  (credential ใส่ตอนบท 10) · ถ้าได้ `curl: (60) SSL certificate problem` แปลว่า cert เปลี่ยนไปแล้ว
- `notAfter=Sep  6 06:00:55 2026 GMT` — **ถ้าใกล้หมดหรือหมดแล้ว หยุดแล้วไปต่ออายุก่อน**

> ⚠️ cert ของ registry หมดอายุเมื่อไหร่ ทุก node จะ pull image ไม่ได้พร้อมกัน
> และอาการจะโผล่เป็น `x509: certificate has expired` ซึ่งดูเหมือนปัญหา containerd
> ทำให้ไล่ผิดทาง — จึงใส่การดู `notAfter` ไว้ในขั้นตรวจของบทนี้

---

<details>
<summary><b>ถ้าวันหนึ่ง registry เปลี่ยนไปจากนี้</b> — ตอนนี้ไม่ต้องทำ</summary>

**วิธีตรวจว่าเป็นแบบไหน:**
```bash
openssl s_client -connect "${REGISTRY_HOST}:443" -servername "${REGISTRY_HOST}" \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

| `issuer` | แปลว่า | ต้องทำเพิ่ม |
|---|---|---|
| เป็น CA สาธารณะ (GlobalSign, Let's Encrypt, DigiCert) | trust ได้เลย | **ไม่ต้องทำอะไร** ← สถานะปัจจุบัน |
| เป็นชื่อ CA ขององค์กร | internal CA | ต้องวางไฟล์ CA |
| เหมือน `subject` เป๊ะ | self-signed | ต้องเอา cert ตัวมันเองมาเป็น CA |

**ถ้าต้องวาง CA:**
```bash
cp /root/k8s/config/registry/ca.crt /etc/pki/ca-trust/source/anchors/myhr-registry-ca.crt
update-ca-trust
```

**ถ้าย้ายไปเป็น HTTP ล้วน:**
```bash
cat > "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" <<EOF
server = "http://${REGISTRY_HOST}"

[host."http://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
EOF
```

</details>

---
## 5 · เปิด containerd และลง kubeadm/kubelet/kubectl

```bash
systemctl enable --now containerd
systemctl status containerd --no-pager | head -5
```
**ควรเห็น:** `Active: active (running)`

**เพิ่ม repo ของ Kubernetes:**

```bash
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_REPO_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
```

> `exclude=` ทำให้ `dnf update` ปกติไม่ยก Kubernetes ขึ้นเอง
> ต้องใส่ `--disableexcludes=kubernetes` เจตนาเท่านั้นถึงจะขยับได้ — นี่คือการป้องกันชั้นแรก

```bash
dnf install -y --disableexcludes=kubernetes \
  "kubelet-${K8S_VERSION}" "kubeadm-${K8S_VERSION}" "kubectl-${K8S_VERSION}" \
  "cri-tools-${CRICTL_VERSION}"

systemctl enable kubelet
```

> **ทำไมต้องระบุ `cri-tools` เอง** — `kubeadm` ประกาศว่าต้องการ `cri-tools >= 1.30.0`
> แต่ `exclude=` ที่เราใส่ไว้ใน repo กันมันไว้ ทำให้ `dnf` ลง kubeadm ได้โดยไม่ลาก
> `cri-tools` มาด้วย ผลคือ **ไม่มี `crictl` บนเครื่อง** แล้วขั้นตรวจของบทนี้กับ
> บท 04/13 จะใช้ไม่ได้ทั้งหมด — ระบุเวอร์ชันเองจึงชัวร์กว่าและตรึงเลขได้ด้วย


> **ยังไม่ต้อง start kubelet** — มันจะ crash loop จนกว่าจะมี cluster ซึ่งเป็นเรื่องปกติ

**ตรึงเวอร์ชันซ้ำอีกชั้น:**
```bash
dnf versionlock add kubelet kubeadm kubectl cri-tools
dnf versionlock list | grep -E 'kube|cri-tools'
```

### 5.1 ตรวจ sandbox image — ทำได้ตรงนี้เพราะเพิ่งมี kubeadm

containerd มีค่า `sandbox` (pause image) ของตัวเอง ส่วน kubeadm ก็มีค่าที่มันคาดไว้
สองอันนี้**มักไม่ตรงกัน** เพราะ containerd กับ Kubernetes ออกเวอร์ชันคนละรอบ

```bash
want=$(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" | grep pause)

# ⚠️ containerd 2.x เขียน TOML ด้วย single quote และมี key ชื่อ sandboxer อยู่ใกล้ ๆ
#    regex จึงต้องรับทั้งสอง quote และต้องมี ' = ' คั่นเพื่อไม่ให้ไปโดน sandboxer
have=$(grep -oE "^[[:space:]]*sandbox = ['\"][^'\"]+['\"]" /etc/containerd/config.toml \
       | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" | head -1)

echo "kubeadm อยาก : ${want:-หาไม่เจอ}"
echo "containerd มี: ${have:-หาไม่เจอ}"
[ "$want" = "$have" ] && echo "ตรงกัน ✓" || echo "ไม่ตรง — รันบล็อกถัดไป"
```

**ถ้าไม่ตรง — รันบล็อกนี้ต่อได้เลย** (ใช้ตัวแปร `$want` จากบล็อกบน):

```bash
cp /etc/containerd/config.toml /etc/containerd/config.toml.bak

# แก้เฉพาะบรรทัดที่เป็น 'sandbox = ' เป๊ะ ๆ — ไม่โดน sandboxer
sed -i "s|^\([[:space:]]*sandbox = \).*|\1'${want}'|" /etc/containerd/config.toml

systemctl restart containerd
```

**ตรวจซ้ำ:**
```bash
grep -n 'sandbox' /etc/containerd/config.toml
systemctl is-active containerd
```
**ควรเห็น:** ทุกบรรทัด `sandbox = ` เป็นค่าเดียวกับที่ kubeadm บอก · `sandboxer` ไม่เปลี่ยน
· containerd ยัง `active`

> ถ้า containerd ไม่ขึ้นหลัง restart ให้กู้ด้วย
> `cp /etc/containerd/config.toml.bak /etc/containerd/config.toml && systemctl restart containerd`

> **ไม่แก้ได้ไหม** — ได้ cluster ยังทำงาน แต่จะมี pause image สองตัวใน node
> และเวลามีปัญหาเรื่อง sandbox จะไล่ยากขึ้นเพราะไม่รู้ว่าตัวไหนถูกใช้

> containerd 2.x ใช้ config **version 3** และ CRI plugin แยกเป็น
> `io.containerd.cri.v1.runtime` กับ `io.containerd.cri.v1.images` — ค่า `sandbox`
> อยู่ใต้ `images` และอาจมีซ้ำใต้ `pinned_images` ด้วย คำสั่งข้างบนแก้ให้ทุกจุด

---
## 6 · ตั้ง crictl

`crictl` ไม่รู้เองว่า containerd อยู่ที่ไหน ถ้าไม่ตั้งจะเจอ warning ทุกครั้งที่รัน

```bash
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
```

---

## ✅ เกณฑ์ผ่านของบทนี้

```bash
echo "=== $(hostname) ==="
crictl info | jq -r '.config.containerd.runtimes.runc.options.SystemdCgroup'
crictl version | grep -E 'RuntimeName|RuntimeVersion'
kubeadm version -o short
kubelet --version
dnf list installed 2>/dev/null | grep -c containerd
```

**ต้องได้:**

| ตรวจ | ผลลัพธ์ที่ควรเห็น |
|---|---|
| `SystemdCgroup` | `true` |
| `RuntimeName` | `containerd` |
| `RuntimeVersion` | `v2.2.7` |
| `kubeadm version` | `v1.36.3` |
| `kubelet --version` | `Kubernetes v1.36.3` |
| จำนวน containerd จาก dnf | **`0`** ← ต้องเป็นศูนย์ ถ้าไม่ใช่แปลว่า `ol9_addons` ยังเปิดอยู่ |

**ทดสอบ pull จริงจาก registry:**
```bash
crictl pull "${REGISTRY_HOST}/library/busybox:latest" 2>&1 | tail -3
```
**ผลที่ถือว่าผ่าน** — ข้อความจริงที่ `crictl` พ่นออกมา (ยืนยันจากเครื่องจริง 27 ส.ค. 2026):

```
authorization failed: no basic auth credentials
```

อ่านจากท้ายไปหน้า: registry ตอบว่ายังไม่ได้ล็อกอิน → **ไปถึง registry แล้ว** →
ไม่ใช่ TLS error ไม่ใช่ DNS error · แปลว่า DNS, TLS และ `hosts.toml` ถูกต้องหมด
เหลือแค่ credential ซึ่งจะใส่ตอน**บทที่ 10**

(ถ้า registry ตัวนั้นเปิดให้ pull สาธารณะได้ จะเห็น `Image is up to date` แทน ซึ่งก็ผ่าน)

**ผลที่แปลว่ามีปัญหาจริง — ต้องหยุดแก้ก่อนไปต่อ:**

| ข้อความ | แปลว่า | กลับไปแก้ที่ |
|---|---|---|
| `x509: certificate signed by unknown authority` | CA ไม่ถูก trust | ข้อ 4 |
| `x509: certificate has expired` | 🔴 cert ของ registry หมดอายุ | แจ้งคนดูแล registry |
| `no such host` | `/etc/hosts` ไม่มีบรรทัด registry | บท 01 ข้อ 1 |
| `connection refused` · `i/o timeout` | เข้าไม่ถึงเครื่อง registry | ทีม network |
| `crictl: command not found` | `cri-tools` ไม่ได้ลง | ข้อ 5 |

**➡️ ต่อที่ [บทที่ 03 — HA Layer](03-ha-layer.md)**
