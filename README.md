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

ขั้นถัดไปคือตอบคำถามตัดสินใจ D1–D10 ใน blueprint ก่อนเริ่มเขียนคู่มือบท 00–13

## สิ่งที่ไม่ได้อยู่ใน repo นี้

ดู `.gitignore` — มีสองกลุ่ม:

1. **ไฟล์ติดตั้งขนาดใหญ่** (`install file/`, `*.zip`) รวมกันราว 230 MB และไฟล์เดียวใหญ่เกิน
   ลิมิต 100 MB ของ GitHub ให้ดาวน์โหลดจาก upstream ตามเวอร์ชันที่ระบุแทน
2. **ไฟล์ที่มีความลับแบบ plaintext** — คู่มือชุดเดิมมี root password, VPN password,
   registry password, cluster-admin token และ client key ฝังอยู่ในเนื้อไฟล์
   ต้อง redact ก่อนนำเข้า repo และ**ควรหมุน credential เหล่านั้นทั้งหมด**
