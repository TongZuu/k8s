# MyHR Kubernetes

เอกสารสำหรับสร้างและดูแล on-prem Kubernetes HA cluster ของ MyHR

## โครงสร้าง

| ที่อยู่ | คืออะไร |
|---|---|
| `k8s-architecture-blueprint.html` | **ข้อเสนอสถาปัตยกรรมฉบับปรับปรุง 2026** — สถาปัตยกรรม 13 ชั้น, ตารางตัดสินใจ D1–D10, โครงเอกสารที่เสนอ, version matrix และแผนดำเนินการ เปิดด้วยเบราว์เซอร์ได้เลย |
| `k8s-training-old/` | คู่มือชุดเดิม (Kubernetes 1.30, ~2024) เก็บไว้อ้างอิงระหว่างเขียนชุดใหม่ |

## สถานะ

คู่มือชุดเดิมอิง Kubernetes 1.30 ซึ่ง**หมดระยะ support ไปตั้งแต่ มิ.ย. 2025** และขาดส่วน day-2
operations (backup / cert renewal / upgrade) ทั้งหมด จึงเป็นที่มาของการเขียนใหม่รอบนี้

**เคาะครบทุกข้อแล้ว** ขั้นถัดไปคือเริ่ม Phase 0 (สำรวจ + ทำ VM template) แล้วเขียนคู่มือบท 00–13

สรุปสถาปัตยกรรมที่เลือก:

| | เลือก |
|---|---|
| Kubernetes | 1.36.x · kubeadm · stacked etcd 3 master |
| OS / kernel | Oracle Linux 9.8 (ฟรี) · UEK 8U2 (6.12) |
| HA / VIP | keepalived + HAProxy เป็น **systemd service** |
| CNI | **Cilium** — ทำ CNI + kube-proxy replacement + LB-IPAM ในตัวเดียว |
| kube-proxy | **ไม่ติดตั้ง** (`skipPhases: [addon/kube-proxy]`) |
| ทางเข้า | **Envoy Gateway** (Gateway API) + cert-manager |
| Storage | **ไม่มี** โดยเจตนา — ฐานข้อมูลอยู่นอก cluster |
| Deploy | `kubectl apply` จาก git + policy check ที่ CI |

หมายเหตุสำคัญสองข้อจากการเลือก OS: Oracle Linux แบบใช้ฟรี **ไม่มี Ksplice และไม่มี vendor support**
แปลว่าปะ kernel ต้อง rolling reboot ทุกครั้ง ซึ่งบังคับให้ทุก Deployment ต้องมี PDB และ replica ≥ 2
ส่วน kernel เลือก UEK 8U2 (6.12) เพราะไม่มี agent ระดับ OS อะไรผูกกับ RHCK และ 6.12 ทำให้ Cilium
กับ kube-proxy replacement ที่ L05 หมดข้อจำกัดเรื่อง kernel

แผน IP ของ cluster ใหม่ (วง `192.168.50.0/24`):

| | IP | สเปก |
|---|---|---|
| VIP | `.100` | **ยังต้องขอจองเพิ่ม** |
| master01–03 | `.101` – `.103` | 4 vCPU / 16 GB / 400 GB |
| worker01–03 | `.104` – `.106` | 16 vCPU / 48 GB / 500 GB |
| กันไว้ขยาย | `.107` – `.110` | — |
| LB-IPAM pool |  `.200` – `.209` | สำหรับ `type: LoadBalancer` (ใช้จริง 1–2 ตัว) |
| pod / service CIDR | `10.246.0.0/16` / `10.247.0.0/16` | ไม่ซ้ำกับ cluster เดิม |

## สิ่งที่ไม่ได้อยู่ใน repo นี้

ดู `.gitignore` — มีสองกลุ่ม:

1. **ไฟล์ติดตั้งขนาดใหญ่** (`install file/`, `*.zip`) รวมกันราว 230 MB และไฟล์เดียวใหญ่เกิน
   ลิมิต 100 MB ของ GitHub ให้ดาวน์โหลดจาก upstream ตามเวอร์ชันที่ระบุแทน
2. **ไฟล์ที่มีความลับแบบ plaintext** — คู่มือชุดเดิมมี root password, VPN password,
   registry password, cluster-admin token และ client key ฝังอยู่ในเนื้อไฟล์
   ต้อง redact ก่อนนำเข้า repo และ**ควรหมุน credential เหล่านั้นทั้งหมด**
