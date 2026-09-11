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
- [x] เพิ่มไฟล์ [`config/monitoring/alertmanager-config.yaml`](../config/monitoring) — เขียนแล้ว เหลือแทนค่า SMTP/ปลายทางจริงตอนทำบท 09 ข้อ 5
      ([09-observability.md:192](09-observability.md:192)) และวิธีที่เขียนไว้ตอนนี้คือ `kubectl edit secret`
      ซึ่งขัดกับกติกาข้อ 4 ของคู่มือ
- [x] **เพิ่ม `config/audit-node.sh`** (26 ส.ค. 2026) — ตรวจว่าเครื่องทำบท 01/02 ไปถึงไหน
      อ่านอย่างเดียว ใช้ก่อนรันขั้นตอนซ้ำบนเครื่องที่ทำค้างไว้
- [x] **สร้างคู่มือเวอร์ชัน HTML** (27 ส.ค. 2026) — `python tools/build-html.py` → `html/index.html`
      ปุ่มคัดลอกทุก code block · ทำเครื่องหมาย "ทำแล้ว" รายขั้น (เปลี่ยนสีพื้นหลัง) ·
      แถบกรองตามเครื่อง 👑🎩⚙️ ในบทที่มีหลายเครื่องปนกัน (28 ส.ค. 2026) ·
      ปุ่มลอยกระโดดไปขั้นที่ค้าง · ทดสอบด้วยเบราว์เซอร์จริงแล้ว
- [ ] **แก้ `.md` แล้วอย่าลืมรัน `python tools/build-html.py` ใหม่** — `html/` ไม่ได้ sync เอง
- [x] **เพิ่ม `.gitattributes` บังคับ LF** — กัน CRLF ตอน clone บน Windows แล้ว scp ไป Linux
- [ ] เตรียมช่องทางแจ้งเตือนจริงให้ทีม แล้วใส่ลง alertmanager config — email หรือ Teams
      (LINE Notify **ปิดบริการไปแล้ว** ถ้าจะใช้ LINE ต้องเป็น Messaging API ผ่าน webhook + ตัวกลาง)
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
- [x] เติม `LOKI_CHART` / `ALLOY_CHART` ที่ยังเป็น `<PIN_AT_INSTALL>` แล้ว (5 ก.ย. 2026)
      `LOKI_CHART=7.3.0` (app 3.6.12) · `ALLOY_CHART=1.12.0` (app 1.19.0)
      `LOKI_VERSION` เดิมเขียนไว้ `3.7.6` ซึ่ง**ไม่มีอยู่จริงในchart ไหนเลย** แก้เป็น `3.6.12` แล้ว

---

## A2 · 🔴 ด่วน — มีวันหมดอายุ

- [ ] 🔴 **cert ของ `registry.myhr.co.th` หมดอายุ 6 ก.ย. 2026** (เหลือ 10 วันนับจาก 27 ส.ค.)
      wildcard `*.myhr.co.th` จาก GlobalSign AlphaSSL · ออก 5 ส.ค. 2025
      · หมดเมื่อไหร่ **ทุก node pull image ไม่ได้พร้อมกัน** และอาการจะดูเหมือนปัญหา containerd
      · แจ้งคนดูแล registry ให้ต่ออายุ แล้วจดวันหมดอายุใหม่ลงปฏิทินทีม
      · ตรวจซ้ำ: `openssl s_client -connect registry.myhr.co.th:443 -servername registry.myhr.co.th </dev/null 2>/dev/null | openssl x509 -noout -dates`

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
- [x] **ได้ public cert มาแล้ว — ตรวจผ่านครบ (4 ก.ย. 2026)**
      · **wildcard `*.myhr.co.th`** + apex `myhr.co.th` → ครอบทุกชื่อที่จะเปิด
        **ไม่ต้องลง cert-manager ไม่ต้องไล่ root CA ลงเครื่อง client** — ทางเลือกที่ใช้
        internal CA ถูกย้ายไปภาคผนวก ข ของบท 07 แล้ว ไม่อยู่ในเส้นทางหลัก
      · ผู้ออก: GlobalSign GCC R46 AlphaSSL CA 2025 · chain ครบ 3 ใบเรียงถูก
      · key เป็น PKCS#8 ไม่มี passphrase และเป็นคู่กับ cert
      · ตรวจด้วย `bash config/gateway/import-public-cert.sh --dry-run <chain> <key>` → ผ่านทุกข้อ
- [ ] 🔴 **จดวันหมดอายุลงปฏิทินทีม — `11 มี.ค. 2027`** ตั้งเตือน **9 ก.พ. 2027** (ล่วงหน้า 30 วัน)
      public cert ไม่ต่ออายุให้เอง — ลืมแล้วทุก service ล่มพร้อมกันโดยที่ pod ยังเขียวหมด
      วิธีต่ออายุอยู่ที่ [บท 12 หัวข้อ 3.1](12-day2-operations.md)

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
- [ ] **เตรียมเครื่องทดสอบในวง `192.168.50.0/24` ที่ไม่ใช่ node** — ใช้ยืนยัน L2 announcement ในบท 05
      (ARP ข้าม subnet ไม่ได้ · ยิงจากเครื่องคนละวงตีความผลไม่ได้)
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

- [ ] **ทำ kernel ทุกเครื่องให้เป็นเลขเดียวกัน** — จะปิดเองตอนรัน `prepare-os.yml` รอบลง OS ใหม่
      (เดิมตัดสินใจเลื่อน 27 ส.ค. 2026 · ลง OS ใหม่ทั้ง 6 เครื่อง 10-11 ก.ย. 2026)
      สถานะจริง 11 ก.ย. 2026 หลังลงใหม่ ก่อนรัน playbook:
      · รันอยู่: `105.51.5` → master01-02 · `203.76.7.3` → master03, worker01-03
      · **ทุกเครื่องมี `6.12.0-206.104.3.3` ติดตั้งแล้ว และ `grubby --default-kernel`
        ชี้ไปที่ 206 ครบทั้ง 6** → reboot ของ `prepare-os.yml` พาทุกเครื่องไปเลขเดียวกัน
      · `versions.env` คุมแค่สาย `KERNEL_UEK=6.12` (ตกลงแล้ว ไม่คุมหางเลข) · playbook
        จึง**ไม่ใช่**ตัวพิสูจน์ข้อนี้ — ตัวพิสูจน์คือ `ansible k8s_nodes -a 'uname -r'`
        ได้เลขเดียวทั้ง 6 และ alert `NodeKernelVersionMismatch` เงียบ
      · ยืนยันซ้ำหลังจบบท 01: `ansible k8s_nodes -a 'uname -r'` ต้องได้เลขเดียวทั้ง 6
      · บทเรียน: **ไม่กระทบ Cilium** เพราะ major.minor เดียวกัน (6.12) แต่ตอนมี workload
        แล้วค่อยแก้คือครึ่งวัน + drain — รอบนี้ปิดได้ฟรีเพราะ playbook reboot อยู่แล้ว
- [ ] **เคาะนโยบาย: ยอมให้มี Gateway API CRD ช่อง `experimental` บน production ไหม**
      chart ของ Envoy Gateway ลงช่องนี้มาเป็นค่าเริ่มต้น (ยืนยันบน cluster จริง 4 ก.ย. 2026)
      · **ไม่กระทบการใช้งาน** — `Gateway`/`HTTPRoute`/`GRPCRoute`/`GatewayClass`/`ReferenceGrant`
        ที่เราใช้ทั้งหมดอยู่ในช่อง `standard` อยู่แล้ว `experimental` เป็น superset
      · ส่วนที่เกินมา (`TCPRoute`, `UDPRoute`, `TLSRoute`, field ทดลอง) เราไม่ได้ใช้
      · ความเสี่ยงจะเกิดก็ต่อเมื่อ **มีคนเขียน manifest ไปใช้ของในช่องนั้น** แล้วมันเปลี่ยน
        ตอน upgrade — กันได้ด้วย policy check ที่ CI (บท 11)
      · ถ้าเคาะว่าห้าม: ต้องลง CRD แยกด้วย chart `gateway-crds-helm` พร้อม
        `--set crds.gatewayAPI.channel=standard` แล้ว main chart ใส่ `--set crds.enabled=false`
        (เพิ่มหนึ่งขั้นตอนในบท 07 · วิธีอยู่ในเอกสารทางการหัวข้อ Install CRDs separately)
      · **ต้องเคาะก่อนขึ้น production** — เปลี่ยนทีหลังต้องรื้อ CRD ซึ่งลบ object ใต้มันทั้งหมด
- [ ] 🔴 **แก้ต้นเหตุ: ขั้นตอนสร้าง VM ต้องไม่ใช่ `dnf update` ลอย ๆ**
      ต้องเป็น "ลง kernel เวอร์ชันที่ระบุใน `versions.env` แล้ว `versionlock` ทันที"
      ไม่งั้นเครื่องที่สร้างเพิ่มในอนาคตจะได้เลขใหม่เรื่อย ๆ ตามวันที่สร้าง

- [ ] **ปลดหนี้ `--kubelet-insecure-tls` ของ metrics-server** (ตัดสินใจเลื่อน 4 ก.ย. 2026)
      metrics-server ไม่ตรวจ cert ของ kubelet เลย เพราะใบที่ kubelet เซ็นเองไม่มี IP SAN
      · **ความเสี่ยง:** คนที่ยืนกลางทางบนวง 192.168.50.0/24 ป้อน metric ปลอมได้
        กระทบแค่ `kubectl top` กับ HPA — ไม่ได้เปิดทางเข้าถึง cluster เพิ่ม
      · **ทางปลด C** ออก cert เองจาก cluster CA แล้วชี้ `tlsCertFile` ใน `KubeletConfiguration`
        → ไม่มีของเพิ่มให้ดูแล แต่ node ใหม่ต้องออก cert ก่อน join ทุกครั้ง ไม่งั้น kubelet ไม่ start
      · **ทางปลด B+** `serverTLSBootstrap: true` + ลง `kubelet-csr-approver`
        → node ใหม่ทำงานเอง cert ต่ออายุเอง แต่เพิ่ม controller ที่ต้องดูแล 1 ตัว
      · **ไม่ต้องเคาะก่อนขึ้น production** — เปลี่ยนทีหลังแค่ถอด flag ออก ไม่ต้องรื้ออะไร
        แต่ทั้งสองทางต้อง restart kubelet ทั้ง 6 เครื่อง จึงห้ามทำตอนเร่ง

- [ ] 🔴 **เคาะว่าจะเปิด `dashboard.myhr.co.th` ผ่าน Gateway หรือใช้ `port-forward` อย่างเดียว**
      (บทที่ 15 ข้อ 5 · ตอนนี้ `httpRoute.enabled: false` ใน `config/headlamp/headlamp-values.yaml`)
      · Headlamp ที่หลุด **ไม่เท่ากับ** Grafana ที่หลุด — token ของ `headlamp-admin`
        คือ `cluster-admin` ที่เอาไปยิง `curl` ตรง ๆ ก็ได้ ไม่ต้องผ่านหน้าเว็บ
      · เงื่อนไขที่ต้องจริงครบ 3 ข้อก่อนเปิด เขียนไว้ในไฟล์ values แล้ว
      · **ต้องเคาะก่อนส่งมอบให้ทีม dev** เพราะมันเปลี่ยนวิธีที่ทีมเข้าใช้งานทั้งหมด

- [ ] **บอกทีม dev ว่า Headlamp แก้ของผ่าน YAML ไม่เหมือน Dashboard ตัวเก่าที่มีปุ่มแยก**
      (บทที่ 15 ข้อ 4 · ต้องกดดูของจริงก่อนแล้วจดว่าเห็นอะไร)
      · ทีมมาจาก cluster เดิมที่ใช้ Kubernetes Dashboard จึงคาดหวังปุ่ม Scale
      · ถ้าไม่บอกล่วงหน้า จะกลายเป็น "ของใหม่ใช้ยากกว่าเดิม" ทั้งที่เป็นแค่คนละ UX
      · **ทำก่อนส่งมอบ** — ราคาถูกมากถ้าบอกก่อน แพงมากถ้าให้เขาไปเจอเอง

---

## D · Phase 1 — Lab (~2 สัปดาห์)

- [ ] สร้าง lab 2 master + 2 worker บน OL 9.8 + UEK 8U2 (ใช้เครื่องฝึกอบรม `192.168.50.180-183` ได้)
      · ⚠️ **ต้องใช้ VIP, `virtual_router_id` และ LB pool คนละชุดกับ production**
- [ ] เดินตามบท 01 → 06 ทีละชั้น ห้ามข้าม — **failover test ของบท 03 แบ่งเป็นสองรอบ**
      · ข้อ 5.1-5.3 ทำก่อน `kubeadm init` (พิสูจน์ว่า keepalived ย้าย IP เป็น)
      · **ข้อ 5.4 ทำได้หลังบท 04 เท่านั้น** (พิสูจน์ว่าย้ายแล้ว `kubectl` ยังใช้ได้)
      เพราะก่อนมี cluster ยังไม่มี apiserver ให้ `check_apiserver.sh` ตรวจ ด่าน 3 จึงไม่เคยทำงาน
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
- [ ] alert 11 ข้อใน `myhr-alerts.yaml` ยิงถึงปลายทางจริง (ทดสอบด้วยของปลอมหนึ่งครั้ง)
- [ ] ตรวจว่า PVC ของ monitoring **ผูก PV ถูกก้อน** (ดูคอลัมน์ `VOL` ไม่ใช่แค่คำว่า `Bound`)
- [ ] ตรวจว่า **Alloy ไม่เก็บ log ซ้ำ** — บรรทัดเดียวกันต้องโผล่ครั้งเดียว ไม่ใช่ 6 ครั้ง
- [ ] ประกาศ **กฎ log 3 ข้อ** ให้ทีม dev (stdout เท่านั้น · JSON บรรทัดเดียว · มีเพดาน 10 MB/s)
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
