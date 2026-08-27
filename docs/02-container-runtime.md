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

**ตรวจ sandbox image ให้ตรงกับที่ kubeadm คาด:**

```bash
grep -n 'sandbox' /etc/containerd/config.toml
```

เทียบกับสิ่งที่ kubeadm ต้องการ (รันได้หลังลง kubeadm ในขั้นที่ 5):
```bash
kubeadm config images list --kubernetes-version "v${K8S_VERSION}" | grep pause
```
ถ้าไม่ตรง ให้แก้ค่า `sandbox` ใน config.toml ให้ตรงกับที่ kubeadm บอก

> containerd 2.x ใช้ config **version 3** และ CRI plugin ถูกแยกเป็น
> `io.containerd.cri.v1.runtime` กับ `io.containerd.cri.v1.images`
> (เดิมรวมกันที่ `io.containerd.grpc.v1.cri`) — ถ้าเจอตัวอย่างเก่าในอินเทอร์เน็ตที่ใช้ชื่อเดิม อย่าลอกมาใช้

---

## 4 · ตั้งค่า private registry

```bash
mkdir -p "/etc/containerd/certs.d/${REGISTRY_HOST}"
```

### ถ้า registry เป็น HTTPS ที่มี cert ให้ trust ได้ (แนะนำ)

```bash
cat > "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" <<EOF
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
EOF
```

ถ้าเป็น cert ที่ออกโดย internal CA ให้วาง CA ลงเครื่องด้วย:
```bash
cp /root/k8s/config/registry/ca.crt /etc/pki/ca-trust/source/anchors/myhr-registry-ca.crt
update-ca-trust
```

### ถ้า registry เป็น HTTP ล้วน

```bash
cat > "/etc/containerd/certs.d/${REGISTRY_HOST}/hosts.toml" <<EOF
server = "http://${REGISTRY_HOST}"

[host."http://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

> ⚠️ **ต้องรู้ก่อนว่า registry เป็นแบบไหน** — ถ้าเดาผิดจะเจอ `failed to pull image`
> ตอน deploy แล้วมาไล่หาสาเหตุทีหลัง ตรวจได้จากเครื่องไหนก็ได้ด้วย:
> ```bash
> curl -sI https://registry.myhr.co.th/v2/ || curl -sI http://registry.myhr.co.th/v2/
> ```
> ตัวไหนตอบ `401` หรือ `200` คือตัวนั้น

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
  "kubelet-${K8S_VERSION}" "kubeadm-${K8S_VERSION}" "kubectl-${K8S_VERSION}"

systemctl enable kubelet
```

> **ยังไม่ต้อง start kubelet** — มันจะ crash loop จนกว่าจะมี cluster ซึ่งเป็นเรื่องปกติ

**ตรึงเวอร์ชันซ้ำอีกชั้น:**
```bash
dnf versionlock add kubelet kubeadm kubectl
dnf versionlock list | grep -E 'kube'
```

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
**ควรเห็น:** `Image is up to date` หรือ `Pulling image...` สำเร็จ
ถ้าได้ `401 Unauthorized` ถือว่า**ผ่าน**สำหรับขั้นนี้ (แปลว่าคุยกับ registry ได้แล้ว แค่ยังไม่มี credential)
ถ้าได้ `connection refused`, `x509` หรือ `no such host` **ให้หยุดแล้วกลับไปแก้ขั้นที่ 4**

**➡️ ต่อที่ [บทที่ 03 — HA Layer](03-ha-layer.md)**
