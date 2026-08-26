# เช็กลิสต์งานที่ต้องทำ — MyHR Kubernetes 1.36

> สรุปสถานะ ณ 26 ส.ค. 2026 · อ้างอิงแผน Phase 0–5 จาก
> [`../k8s-architecture-blueprint.html`](../k8s-architecture-blueprint.html) หมวด 05
>
> **สถานะรวม:** ตัดสินใจสถาปัตยกรรมครบ (D1–D10) · คู่มือบท 00–13 + `config/` ร่างเสร็จแล้ว
> · **ยังไม่ได้ลงมือกับเครื่องจริงเลย** และของทั้งหมดยังไม่ได้ commit

---

## A · งานในตัว repo — ทำก่อน scp ขึ้นเครื่อง

- [x] 🔴 **ลบรหัสผ่าน VRRP ที่หลุดใน `keepalived-master02/03`** — แก้เป็น `<VRRP_AUTH_PASS>`
      ให้ตรงกับ [`keepalived-master01.conf:45`](../config/keepalived/keepalived-master01.conf:45) แล้ว
      (26 ส.ค. 2026) · ตรวจแล้วว่าค่าเดิม **ไม่เคยเข้า git history** เพราะ `config/` ยัง untracked
- [ ] 🔴 **ถือว่ารหัส VRRP เดิมถูกเผาแล้ว** — ตั้งค่าใหม่ (8 ตัวอักษร) เก็บในที่เก็บ secret
      และห้ามใช้ค่าเดิมซ้ำ ทั้งใน production และ lab
- [ ] 🔴 **commit `docs/` และ `config/`** — ตอนนี้ยัง untracked ทั้งโฟลเดอร์ (เสี่ยงหายทั้งชุด)
      พร้อม README.md และ blueprint ที่แก้ค้างไว้ · commit หลังข้อบนเท่านั้น
- [ ] เพิ่มไฟล์ [`config/monitoring/alertmanager-config.yaml`](../config/monitoring) — บท 09 อ้างถึงแต่ไฟล์ยังไม่มี
      ([09-observability.md:192](09-observability.md:192)) และวิธีที่เขียนไว้ตอนนี้คือ `kubectl edit secret`
      ซึ่งขัดกับกติกาข้อ 4 ของคู่มือ
- [x] **เพิ่ม `config/audit-node.sh`** (26 ส.ค. 2026) — ตรวจว่าเครื่องทำบท 01/02 ไปถึงไหน
      อ่านอย่างเดียว ใช้ก่อนรันขั้นตอนซ้ำบนเครื่องที่ทำค้างไว้
- [x] **สร้างคู่มือเวอร์ชัน HTML** (27 ส.ค. 2026) — `python tools/build-html.py` → `html/index.html`
      ปุ่มคัดลอกทุก code block · ทำเครื่องหมาย "ทำแล้ว" รายขั้น (เปลี่ยนสีพื้นหลัง) ·
      ปุ่มลอยกระโดดไปขั้นที่ค้าง · ทดสอบด้วยเบราว์เซอร์จริงแล้ว
- [ ] **แก้ `.md` แล้วอย่าลืมรัน `python tools/build-html.py` ใหม่** — `html/` ไม่ได้ sync เอง
- [x] **เพิ่ม `.gitattributes` บังคับ LF** — กัน CRLF ตอน clone บน Windows แล้ว scp ไป Linux
- [ ] เตรียมช่องทางแจ้งเตือนจริง (email / Teams / Line) ให้ทีม แล้วใส่ลง alertmanager config
- [x] 🔴 **แก้ `versions.env` บั๊ก `<` ที่ทำให้ `source` แตก** — `LOKI_CHART=<PIN_AT_INSTALL>` และ
      `ALLOY_CHART=<PIN_AT_INSTALL>` ไม่ได้ใส่ quote ทำให้ bash อ่าน `<` เป็น input redirection
      แทนตัวอักษรจริง (เจอจริงตอนรัน `source /root/k8s/versions.env`) → ใส่ quote ครอบเป็น
      `LOKI_CHART="<PIN_AT_INSTALL>"` แล้ว (26 ส.ค. 2026)
- [x] **กวาดตัวแปรที่ใช้แต่ไม่เคยประกาศ** (26 ส.ค. 2026) — `$GW_IP` ในบท 09/11/12,
      `$NEW_CILIUM` ในบท 12, และ `$NS`/`$POD`/`$APP`/`$SVC`/`$NODE`/`$POD_A`/`$POD_B_IP` ในบท 13
      ทั้งหมด copy ไปวางแล้วได้ค่าว่าง → เติมบรรทัดตั้งค่าให้ครบแล้ว
- [x] **มีสคริปต์ตรวจไฟล์แล้ว** — [`config/validate-repo.sh`](../config/validate-repo.sh) ตรวจ 5 อย่าง:
      `bash -n` ทุก `.sh` · `source versions.env` · parse YAML · ตัวแปรที่ไม่เคยประกาศ ·
      ความลับที่หลุด · **รัน `bash config/validate-repo.sh` ก่อน commit ทุกครั้ง**
- [ ] ต่อสคริปต์นี้เข้ากับ pre-commit hook หรือ CI ให้รันเองอัตโนมัติ
- [x] **ร่าง Ansible playbook บท 01–02 แล้ว** (26 ส.ค. 2026) — อยู่ที่ [`ansible/`](../ansible/README.md)
      อ่านเวอร์ชันจาก `versions.env` ตรง ๆ ไม่มีเลขซ้ำที่สอง
- [ ] 🔴 **playbook ยังไม่เคยรันจริง** — ตรวจแค่ YAML syntax เท่านั้น
      ห้ามใช้กับ production ก่อนผ่าน Phase 3 · ลำดับทดสอบอยู่ใน [`ansible/README.md`](../ansible/README.md)
- [ ] ลง WSL2 + `ansible` (ตัวเต็ม ไม่ใช่ `ansible-core`) + แจก SSH key ให้ครบ 6 เครื่อง
- [ ] ยืนยันว่า registry เป็น HTTP หรือ HTTPS แล้วตั้ง `registry_scheme` ใน
      [`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml) ก่อนรัน `container-runtime.yml`
- [ ] ทวนเลขเวอร์ชันใน [`versions.env`](versions.env) อีกรอบก่อนเริ่ม Phase 1 แล้ว **ตรึง** ตลอดโครงการ
- [ ] เติม `LOKI_CHART` / `ALLOY_CHART` ที่ยังเป็น `<PIN_AT_INSTALL>` ตอนติดตั้งจริง แล้วเขียนกลับลงไฟล์

---

## B · Secret ที่ต้องสร้างและเก็บก่อนลงมือ

ค่าจริงทั้งหมดอยู่ใน **`secrets.env`** ที่ root ของ repo (`.gitignore` กันไว้ · `chmod 600`)
สร้างแล้วเมื่อ 26 ส.ค. 2026 — ตรวจว่า git มองไม่เห็นด้วย `git check-ignore -v secrets.env`

**สุ่มมาแล้ว อยู่ใน `secrets.env`:**

- [x] `VRRP_AUTH_PASS` — 8 ตัวพอดี (keepalived ตัดตัวเกินเงียบ ๆ · ห้ามต่อท้าย)
- [x] `GRAFANA_ADMIN_PASSWORD` — 24 ตัว · ยังต้องเปลี่ยนผ่านหน้าเว็บหลังเข้าครั้งแรก แล้วอัปเดตกลับลงไฟล์
- [x] 🔴 `ENCRYPTION_KEY_BASE64` — 32 ไบต์ตามที่ `aescbc` ต้องการ

**ยังต้องเติมเอง — ต้องไปถามคนอื่น:**

- [x] **เคาะแล้ว: ยังไม่ใช้ OIDC** (26 ส.ค. 2026) — ใช้ client certificate แทน
      group มาจากช่อง `O` ของ cert · [`rbac.yaml`](../config/security/rbac.yaml) ใช้ชื่อ
      `myhr:developers` / `myhr:operators` แล้ว ไม่ต้องขอชื่อ group จากทีม IT
      · วิธีออก kubeconfig อยู่ที่ [บท 10 หัวข้อ 4.1](10-security.md)
      · เส้นทางย้ายไป OIDC ทีหลังบันทึกไว้ที่หัวข้อ 4.2 (ยังไม่ต้องทำ)
- [ ] ⚠️ **ตั้งรอบออก kubeconfig ใหม่ทุก 90 วัน** — cert ถอนไม่ได้ (ไม่มี CRL)
      ทำพร้อมรอบทบทวนรายชื่อ `cluster-admin` รายไตรมาส
- [ ] ทบทวนเมื่อคนถือ kubeconfig เกิน ~10 คน → ถึงเวลาย้ายไป OIDC (บท 10 หัวข้อ 4.2)
- [ ] `PULL_ONLY_USER` / `PULL_ONLY_PASSWORD` ของ registry (บท 10) — บัญชี pull อย่างเดียว

**สำคัญกว่าทุกข้อข้างบน:**

- [ ] 🔴 **คัดลอกทุกค่าใน `secrets.env` ไปเก็บที่เก็บ secret ขององค์กร** — ตอนนี้อยู่บนเครื่องเดียว
      เครื่องพังแล้วจบ · โดยเฉพาะ `ENCRYPTION_KEY_BASE64` ที่ต้องมีสำเนาออฟไลน์อีกชุดด้วย
- [ ] `config/registry/ca.crt` — ถ้า registry เป็น HTTPS ด้วย internal CA ([02:137](02-container-runtime.md:137))
- [ ] 🔴 **หมุน credential ทุกตัวที่รั่วในคู่มือชุดเดิม** — root password, VPN, registry,
      cluster-admin token, client key (ดู README หัวข้อสุดท้าย)

---

## C · Phase 0 — สำรวจและเตรียมของ (~1 สัปดาห์)

- [ ] **ขอจอง VIP `192.168.50.100`** จากทีม network — ยังไม่ได้จอง · ยืนยันด้วย `ping -c2` ต้องไม่มีคนตอบ
- [ ] ขอกัน LB-IPAM pool `192.168.50.200-209` และยืนยันว่า switch **ไม่ได้เปิด Dynamic ARP Inspection**
- [ ] ยืนยันว่าไม่มี route `10.246.0.0/16` และ `10.247.0.0/16` ในองค์กร
- [ ] ยืนยัน `virtual_router_id 60` ไม่ชนกับ cluster เดิม/lab ที่อยู่ L2 เดียวกัน (ของเดิมใช้ 51)
- [ ] ตรวจ cert ของ cluster เดิม — `kubeadm certs check-expiration`
      (ถ้าหมดอายุแล้วจะย้าย workload แบบค่อยเป็นค่อยไปไม่ได้ ต้องเร่งแผน)
- [ ] วัด fsync ของ disk ด้วย `fio` → ถ้าเกิน 10 ms ขอ VMDK แยกให้ etcd
- [ ] ยืนยัน `registry.myhr.co.th` เป็น HTTP หรือ HTTPS และเข้าถึงได้จากทุก node
- [ ] ทำ **VM template ของ OL 9.8** — versionlock `kernel-uek` แล้ว + แผน partition ใหม่ (แยก `/var`, ย้าย `/home`)
- [ ] ขอ VM 6 เครื่องตามสเปกในบท 00 · **master ทั้ง 3 ต้องอยู่คนละ ESXi host** (DRS anti-affinity)
- [ ] ยืนยันอีกครั้งว่า **ไม่มีนโยบายลง EDR / backup agent** บน node (ถ้ามี ต้องกลับไปทบทวน D2a ก่อนลง kernel)

---

## C2 · หนี้ค้างที่ตัดสินใจเลื่อนไว้

- [ ] **ทำ kernel ทุกเครื่องให้เป็นเลขเดียวกัน** (ตัดสินใจเลื่อน 27 ส.ค. 2026)
      สถานะจริง (ตรวจครบทั้ง 6 เครื่องแล้ว 27 ส.ค. 2026):
      · `6.12.0-204.92.4.3.1` → master01, master02  (2 เครื่อง)
      · `6.12.0-203.76.7.3`   → master03, worker01-03  (4 เครื่อง)
      สาเหตุ: template แจก `6.12.0-105.51.5` เหมือนกัน แล้วแต่ละเครื่อง `dnf update`
      คนละวัน จึงได้คนละ errata
      · **ไม่กระทบ Cilium** เพราะ major.minor เดียวกัน (6.12) — playbook จึงแค่เตือน ไม่หยุด
      · ต้นทุนแก้ตอนนี้ ~15 นาที/เครื่อง · ตอนมี workload แล้วคือครึ่งวัน + ต้อง drain
      · ทางที่แนะนำ: **ยกทั้ง 6 เครื่องไป `6.12.0-205.92.4.2`** (ใหม่สุด ยังมีในrepo)
        เพราะ `204.92.4.3.1` อาจหาไม่ได้แล้ว และการยก 2 เครื่องลง 203 คือ downgrade
      · ต้องเคาะ **ก่อนจบ Phase 4** — หลังรับ workload แล้วราคาขึ้นทันที
- [ ] 🔴 **แก้ต้นเหตุ: ขั้นตอนสร้าง VM ต้องไม่ใช่ `dnf update` ลอย ๆ**
      ต้องเป็น "ลง kernel เวอร์ชันที่ระบุใน `versions.env` แล้ว `versionlock` ทันที"
      ไม่งั้นเครื่องที่สร้างเพิ่มในอนาคตจะได้เลขใหม่เรื่อย ๆ ตามวันที่สร้าง

---

## D · Phase 1 — Lab (~2 สัปดาห์)

- [ ] สร้าง lab 2 master + 2 worker บน OL 9.8 + UEK 8U2 (ใช้เครื่องฝึกอบรม `192.168.50.180-183` ได้)
      · ⚠️ **ต้องใช้ VIP, `virtual_router_id` และ LB pool คนละชุดกับ production**
- [ ] เดินตามบท 01 → 06 ทีละชั้น ห้ามข้าม — โดยเฉพาะ **failover test ที่บท 03 ต้องผ่านก่อน `kubeadm init`**
- [ ] **พิสูจน์ว่าทีม debug Cilium ได้จริง** ไม่ใช่แค่ติดตั้งผ่าน (ลองทำให้พังแล้วไล่หา)
- [ ] จดทุกอย่างที่ติดขัดระหว่างทำ → เอาไปเติมบท [13](13-troubleshooting.md)
- [ ] ตัดสินใจขั้นสุดท้ายเรื่อง Cilium vs แผนสำรอง (Calico + kube-proxy nftables + MetalLB)
      **ต้องเคาะก่อนจบ Phase 3** เปลี่ยนหลังจากนั้นคือรื้อ L05–L06 ทั้งชั้น

---

## E · Phase 2 — คู่มือ (ร่างเสร็จแล้ว เหลือปรับจากของจริง)

- [x] เขียนบท 00–13 และไฟล์ `config/` ครบ
- [x] ทำ `versions.env` เป็นแหล่งความจริงเดียว
- [ ] แก้คู่มือตามสิ่งที่เจอจริงใน Phase 1 (ผลลัพธ์ที่ควรเห็นต้องตรงกับของจริงทุกคำสั่ง)
- [ ] ทำ Ansible playbook ตามข้อ A ถ้าตัดสินใจว่าทำ

---

## F · Phase 3 — ทดสอบคู่มือ (~1 สัปดาห์) 🔴 ขั้นตอนสำคัญที่สุด

- [ ] **รื้อ lab ทิ้งแล้วสร้างใหม่ตามคู่มือ โดยให้คนที่ไม่ได้เขียนเป็นคนทำ**
- [ ] ทุกจุดที่คนทำต้องหันไปถามคนเขียน = ช่องโหว่ในคู่มือ → จดและแก้
- [ ] เกณฑ์ผ่าน: ทำจนจบได้โดยไม่ต้องถามเลย

---

## G · Phase 4 — Production (~2 สัปดาห์)

- [ ] สร้าง cluster จริง 3 master + 3 worker ตามคู่มือที่ผ่าน Phase 3
- [ ] ทำบท 09 observability — metrics-server · Prometheus · Loki · Alloy
- [ ] ทำบท 10 security — etcd encryption · PSA · NetworkPolicy (`default-deny` + `allow-dns` คู่กันเสมอ) · RBAC · audit
- [ ] ทำบท 12 day-2 — **etcd backup CronJob ต้องทำงานจริง + ทดสอบ restore หนึ่งรอบ**
- [ ] alert 6 ข้อใน `myhr-alerts.yaml` ยิงถึงปลายทางจริง (ทดสอบด้วยของปลอมหนึ่งครั้ง)
- [ ] เพิ่ม alert เทียบ `node_uname_info` ข้าม node — กัน node บูตคนละ kernel โดยไม่รู้ตัว
- [ ] **ซ้อม rolling reboot ปะ kernel หนึ่งรอบตั้งแต่ยังไม่มี workload** (ไม่มี Ksplice ให้ใช้)
- [ ] 🔴 **ห้ามย้าย workload เข้ามาก่อน backup + alert ทำงานจริง** — บทเรียนตรงจาก cluster เดิม

---

## H · Phase 5 — ย้าย workload และส่งมอบ (~2–3 สัปดาห์)

- [ ] ย้าย microservices ทีละตัวตาม [`deployment-template.yaml`](../config/app/deployment-template.yaml)
      — แก้ `runAsUser`, ใส่ probes / resources / **PDB + replica ≥ 2** (บังคับ ไม่ใช่ข้อแนะนำ)
- [ ] คุมให้ผลรวม `requests` ทุก pod ไม่เกิน **32 vCPU / 96 GB** (เพดาน N+1 ของ worker 3 เครื่อง)
- [ ] pin image เป็น `@sha256:` ทุกตัว แล้วต่อ `validate-manifests.sh` เข้ากับ CI
- [ ] ซ้อมกู้ etcd จาก backup หนึ่งรอบ (ทำบน cluster จริงก่อนส่งมอบ)
- [ ] อบรมทีมด้วยคู่มือชุดใหม่
- [ ] ปลด cluster เดิม + เก็บ credential เก่าที่หมุนแล้วให้เรียบร้อย

---

## ถ้าเวลาไม่พอ — ตัดตามนี้ ห้ามตัดตามลำดับเลข

| ต้องมี | เลื่อนได้ |
|---|---|
| บท 00–06 (cluster ใช้งานได้) | บท 07 (ใช้ NodePort ชั่วคราวได้) |
| **บท 12 — backup + cert renewal** | บท 09 (แต่จะ debug ยากมาก) |
| บท 10 etcd encryption + หมุน credential เก่า | บท 11 CI check (แต่จะเสื่อมใน 2-3 เดือน) |
