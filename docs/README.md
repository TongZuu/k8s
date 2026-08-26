# คู่มือติดตั้ง Kubernetes 1.36 — MyHR

คู่มือ runbook สำหรับสร้าง on-prem HA cluster ชุดใหม่ ทุกคำสั่ง copy วางได้
และทุกขั้นมี "ผลลัพธ์ที่ควรเห็น" กำกับ

> เหตุผลเบื้องหลังการตัดสินใจแต่ละข้อ (D1–D10) อยู่ใน
> [`../k8s-architecture-blueprint.html`](../k8s-architecture-blueprint.html) — เปิดด้วยเบราว์เซอร์
> **คู่มือชุดนี้ตอบว่า "ทำอะไร" · blueprint ตอบว่า "ทำไม"**

---

## เปิดเป็นเว็บก็ได้

คู่มือชุดเดียวกันนี้มีเวอร์ชัน HTML ที่มีปุ่มคัดลอกทุก code block,
ปุ่มทำเครื่องหมาย "ทำแล้ว" รายขั้น และปุ่มลอยกระโดดกลับไปขั้นที่ค้างอยู่

```bash
python tools/build-html.py     # แล้วเปิด html/index.html
```

ความคืบหน้าเก็บใน localStorage ของเบราว์เซอร์เครื่องนั้น — **เป็นของใครของมัน**
ไม่ได้ sync ข้ามเครื่องและไม่ได้ส่งไปไหน · แก้ `.md` แล้วต้องรัน build ใหม่ทุกครั้ง

---

## ลำดับการอ่านและทำ

| บท | เรื่อง | รันที่ |
|---|---|---|
| | **เตรียม** | |
| [00](00-overview.md) | ภาพรวม ลำดับงาน สิ่งที่ต้องมีก่อนเริ่ม | อ่านอย่างเดียว |
| [01](01-prepare-os.md) | เตรียม OS · kernel · firewalld · partition | ทุกเครื่อง (6) |
| [02](02-container-runtime.md) | containerd + runc + CNI plugins | ทุกเครื่อง (6) |
| | **สร้าง** | |
| [03](03-ha-layer.md) | keepalived + HAProxy + **failover test** | master (3) |
| [04](04-create-cluster.md) | `kubeadm init` + join ทุก node | master01 → ที่เหลือ |
| [05](05-cilium.md) | Cilium — CNI + kube-proxy + LB-IPAM | master01 |
| [06](06-verify.md) | ตรวจรับระบบ + ซ้อม failover | master01 |
| [07](07-gateway-tls.md) | Envoy Gateway + cert-manager + internal CA | master01 |
| [08](08-storage.md) | Storage — ไม่มี CSI + static local PV | master01 + worker03 |
| | **ใช้งานและดูแล** | |
| [09](09-observability.md) | metrics-server · Prometheus · Loki · **alert** | master01 |
| [10](10-security.md) | etcd encryption · PSA · NetworkPolicy · RBAC · audit | master ทั้ง 3 |
| [11](11-deploy-app.md) | แม่แบบ manifest + CI policy check | dev + ops |
| [12](12-day2-operations.md) | **backup · cert renewal · rolling reboot · upgrade** | ops |
| [13](13-troubleshooting.md) | ไล่ปัญหาตามอาการที่เห็น | ทุกคน |

**⚠️ ห้ามข้ามบทที่ 03** — `controlPlaneEndpoint` ฝังลงใน certificate
แก้ทีหลังหมายถึงรื้อ cluster ทำใหม่

---

## ไฟล์ config

```
config/
├── haproxy/haproxy.cfg                    บท 03 · เหมือนกันทั้ง 3 master
├── keepalived/                            บท 03
│   ├── check_apiserver.sh                 เหมือนกันทั้ง 3 master
│   ├── keepalived-master01.conf           state MASTER · priority 110
│   ├── keepalived-master02.conf           state BACKUP · priority 100
│   └── keepalived-master03.conf           state BACKUP · priority  90
├── kubeadm/kubeadm-config.yaml            บท 04 · ใช้บน master01 เท่านั้น
├── cilium/                                บท 05
│   ├── values.yaml                        Helm values
│   ├── lb-ippool.yaml                     cilium.io/v2
│   └── l2-announcement-policy.yaml        cilium.io/v2alpha1  ← คนละ apiVersion
├── cert-manager/                          บท 07
│   ├── internal-ca.yaml                   root CA อายุ 10 ปี + ClusterIssuer
│   └── pdb.yaml
├── gateway/                               บท 07
│   ├── gateway.yaml                       Gateway หลัก — กิน LB IP ตัวเดียว
│   ├── httproute-example.yaml             แม่แบบต่อ service
│   └── https-redirect.yaml
├── storage/                               บท 08
│   ├── local-storage-class.yaml           no-provisioner · WaitForFirstConsumer
│   └── monitoring-pv.yaml                 static local PV ผูกกับ worker03
├── monitoring/                            บท 09
│   ├── kube-prometheus-values.yaml
│   ├── loki-values.yaml
│   ├── alloy-values.yaml
│   ├── myhr-alerts.yaml                   alert 6 ข้อที่เฉพาะกับ cluster นี้
│   └── grafana-route.yaml
├── security/                              บท 10
│   ├── encryption-config.yaml             etcd encryption at rest
│   ├── namespaces.yaml                    PSA restricted + quota + limitrange
│   ├── default-deny.yaml                  NetworkPolicy
│   ├── allow-dns.yaml                     ← ต้อง apply คู่กับ default-deny เสมอ
│   ├── rbac.yaml                          developer / deployer / operator
│   └── audit-policy.yaml
├── app/                                   บท 11
│   ├── deployment-template.yaml           แม่แบบที่ผ่าน PSA restricted
│   └── validate-manifests.sh              CI policy check — แทน GitOps
└── day2/                                  บท 12
    └── etcd-backup-cronjob.yaml
```

**[`versions.env`](versions.env) คือแหล่งความจริงเดียวของทุกเวอร์ชันและทุก IP**
ห้ามเขียนเลขเวอร์ชันตรง ๆ ในบทไหน — เวลา upgrade แก้ที่ไฟล์นี้ที่เดียว

---

## เตรียมก่อนเริ่ม

คัดลอกไปวางที่ `/root/k8s/` บนทุกเครื่อง:

```bash
scp -r docs/versions.env config/ root@192.168.50.101:/root/k8s/
```

แล้วรันบรรทัดนี้ก่อนเริ่มทุก session:

```bash
set -a && source /root/k8s/versions.env && set +a
```

---

## สรุปสถาปัตยกรรม

| | |
|---|---|
| Kubernetes | **1.36.3** · kubeadm · stacked etcd 3 master |
| OS / kernel | Oracle Linux 9.8 (ใช้ฟรี) · UEK 8U2 (6.12) |
| Runtime | containerd 2.2.7 จาก tarball · runc 1.5.1 |
| HA / VIP | keepalived + HAProxy เป็น **systemd** · VIP `192.168.50.100:8443` |
| CNI | **Cilium 1.20.1** — CNI + kube-proxy replacement + LB-IPAM |
| kube-proxy | **ไม่ติดตั้ง** (`--skip-phases=addon/kube-proxy`) |
| pod / service CIDR | `10.246.0.0/16` / `10.247.0.0/16` |
| LB pool | `192.168.50.200-209` |
| Storage | **ไม่มี** โดยเจตนา — ฐานข้อมูลอยู่นอก cluster |

---

## ⚠️ สองข้อที่ส่งผลกับทุกอย่าง

**ไม่มี Ksplice** — Oracle Linux แบบฟรีไม่มี live patching ปะ kernel ต้อง reboot ทุกครั้ง
ต้อง drain ทุก node ทุก 1-2 เดือน ผลคือ **ทุก Deployment ต้องมี PDB และ replica ≥ 2**
และผลรวม `requests` ทุก pod ต้องไม่เกิน **32 vCPU / 96 GB** (เพดาน N+1 ของ worker 3 เครื่อง)

**Cilium ถือ 3 หน้าที่พร้อมกัน** — พังทีเดียว pod network, Service และ LoadBalancer ดับหมด
และไม่มี kube-proxy ให้ถอยกลับ · แผนสำรองคือ Calico + kube-proxy nftables + MetalLB
ซึ่ง**ต้องตัดสินก่อนจบ Phase 3** เพราะเปลี่ยนหลังจากนั้นคือรื้อ L05–L06 ทั้งชั้น

---

## ค่าที่ต้องเติมก่อนใช้จริง

placeholder ทั้งหมดเป็น `<UPPERCASE>` — หาให้ครบด้วย:

```bash
grep -rn '<[A-Z_]*>' config/ docs/
```

| ไฟล์ | ค่า | หมายเหตุ |
|---|---|---|
| `keepalived-master0*.conf` | `<VRRP_AUTH_PASS>` | ⚠️ ยาวได้แค่ **8 ตัวอักษร** ตัวเกินถูกตัดเงียบ ๆ |
| `kubeadm-config.yaml` | `<BOOTSTRAP_TOKEN>` | หรือลบบล็อกให้ kubeadm สร้างเอง |
| `encryption-config.yaml` | `<ENCRYPTION_KEY_BASE64>` | 🔴 **หายแล้วกู้ etcd backup ไม่ได้เลย** |
| `kube-prometheus-values.yaml` | `<GRAFANA_ADMIN_PASSWORD>` | เปลี่ยนทันทีหลังเข้าครั้งแรก |
| `rbac.yaml` | `<LDAP_GROUP_*>` | ชื่อ group จริงขององค์กร |
| `deployment-template.yaml` | `<IMAGE_DIGEST>` | `@sha256:...` |
| `versions.env` | `<PIN_AT_INSTALL>` | chart version ของ Loki/Alloy |

---

## ลำดับความสำคัญถ้าเวลาไม่พอ

ถ้าทำไม่ครบทุกบท **ห้ามตัดตามลำดับเลข** ให้ตัดตามนี้:

| ต้องมี | เลื่อนได้ |
|---|---|
| บท 00–06 (cluster ใช้งานได้) | บท 07 (ใช้ NodePort ชั่วคราวได้) |
| **บท 12 — backup + cert renewal** | บท 09 (แต่จะ debug ยากมาก) |
| บท 10 ข้อ etcd encryption + หมุน credential เก่า | บท 11 CI check (แต่จะเสื่อมใน 2-3 เดือน) |

🔴 **อย่าย้าย workload เข้ามาก่อนที่ backup และ alert จะทำงานจริง**
นั่นคือบทเรียนตรง ๆ จาก cluster เดิม
