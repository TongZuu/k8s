#!/bin/bash
# =============================================================================
#  /etc/keepalived/check_apiserver.sh
#  วางเหมือนกันทั้ง 3 master · chmod 700
# =============================================================================
#  keepalived เรียกสคริปต์นี้ทุก 3 วินาที
#    exit 0  = เครื่องนี้ยังทำหน้าที่ได้  → priority คงเดิม
#    exit 1  = เครื่องนี้มีปัญหา          → priority ลดลง → VIP ย้ายไปเครื่องอื่น
#
#  ตรวจ 2 อย่าง:
#    1. HAProxy บนเครื่องนี้ยังตอบอยู่ไหม
#    2. ถ้าเครื่องนี้ถือ VIP อยู่ — ต่อผ่าน VIP แล้วถึง apiserver จริงไหม
#       (ข้อ 2 สำคัญ เพราะ HAProxy อาจรันอยู่แต่ backend ตายหมด)
# =============================================================================

VIP=192.168.50.100
VIP_PORT=8443

errorExit() {
    echo "check_apiserver: $*" >&2
    exit 1
}

# --- 1. HAProxy บนเครื่องนี้ตอบไหม -------------------------------------------
# 6443 บน localhost คือ kube-apiserver ของเครื่องนี้เอง
# ระหว่าง bootstrap (ก่อน kubeadm init) จะยังไม่มี apiserver จึงยอมให้ผ่าน
# โดยดูแค่ว่า HAProxy เปิดพอร์ตอยู่
if ! ss -lnt | grep -q ":${VIP_PORT} "; then
    errorExit "HAProxy ไม่ได้ฟังที่พอร์ต ${VIP_PORT}"
fi

# --- 2. ถ้าถือ VIP อยู่ ต้องยิงผ่าน VIP ถึง apiserver ได้จริง ------------------
if ip -4 addr show | grep -q "inet ${VIP}/"; then
    curl --silent --max-time 2 --insecure \
         "https://${VIP}:${VIP_PORT}/healthz" -o /dev/null \
      || errorExit "ถือ VIP อยู่ แต่ยิง https://${VIP}:${VIP_PORT}/healthz ไม่ผ่าน"
fi

exit 0
