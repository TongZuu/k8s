#!/usr/bin/env bash
# =============================================================================
#  audit-node.sh — ดูว่าเครื่องนี้ทำบท 01/02 ไปถึงไหนแล้ว
# =============================================================================
#  อ่านอย่างเดียว ไม่แก้อะไรทั้งสิ้น รันซ้ำได้ตลอด
#
#  ใช้เมื่อ: ทำไปบางส่วนแล้วจำไม่ได้ว่าถึงไหน / จะรันซ้ำแต่ไม่แน่ใจว่าปลอดภัย
#
#  รัน:  bash /root/k8s/config/audit-node.sh
#  หรือ: scp config/audit-node.sh root@IP:/tmp/ && ssh root@IP bash /tmp/audit-node.sh
# =============================================================================
set -uo pipefail

DONE=0; TODO=0; WARN=0
ok()   { printf '  [ทำแล้ว]  %s\n' "$*"; DONE=$((DONE+1)); }
no()   { printf '  [ยังไม่]  %s\n' "$*"; TODO=$((TODO+1)); }
warn() { printf '  [ระวัง!]  %s\n' "$*"; WARN=$((WARN+1)); }

echo "==============================================================="
echo " $(hostname)  —  $(date '+%Y-%m-%d %H:%M')"
echo "==============================================================="

# ---------------------------------------------------------------- บทที่ 01
echo
echo "บทที่ 01 — เตรียม OS"

# 1 hostname
case "$(hostname)" in
    k8s-master0[1-3]|k8s-worker0[1-3]) ok "hostname = $(hostname)" ;;
    *) no "hostname ยังเป็น $(hostname) — ยังไม่ได้ตั้ง" ;;
esac

# 1b /etc/hosts  — ระวังบรรทัดซ้ำจากการรัน cat >> หลายรอบ
hosts_n=$(grep -c 'k8s-master01' /etc/hosts 2>/dev/null || true)
hosts_n=${hosts_n:-0}
if   [ "$hosts_n" -eq 0 ]; then no "/etc/hosts ยังไม่มีรายการ k8s"
elif [ "$hosts_n" -eq 1 ]; then ok "/etc/hosts มีรายการครบ"
else warn "/etc/hosts มีรายการซ้ำ $hosts_n ชุด — เกิดจากรัน 'cat >>' หลายรอบ"
     echo "            แก้: ลบบรรทัดซ้ำด้วย  vi /etc/hosts  (ไม่พังแต่ควรเก็บให้สะอาด)"
fi

# 2 kernel + versionlock
if uname -r | grep -q uek; then ok "kernel = $(uname -r)"
else warn "kernel = $(uname -r) — ไม่ใช่ UEK! ห้ามผสม UEK กับ RHCK ใน cluster เดียวกัน"; fi

if dnf versionlock list 2>/dev/null | grep -q kernel-uek; then ok "versionlock kernel-uek"
else no "ยังไม่ได้ versionlock kernel-uek"; fi

# 3 repo
if dnf repolist enabled 2>/dev/null | grep -q ol9_addons; then
    warn "ol9_addons ยังเปิดอยู่ — containerd ของ Oracle จะไปทับ tarball ในบท 02"
else ok "ol9_addons ปิดแล้ว"; fi

# 4 package + เวลา
missing=""
for p in chrony tar curl socat conntrack-tools ethtool jq; do
    rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
done
if [ -z "$missing" ]; then ok "package พื้นฐานครบ"
else no "ยังขาด package:$missing"; fi

if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then ok "เวลา sync แล้ว"
else warn "เวลายังไม่ sync — TLS cert และ etcd raft จะพัง ต้องแก้ก่อนไปบท 04"; fi

# 5 partition — จุดที่อันตรายที่สุดถ้าทำค้างครึ่งทาง
want=/var/lib/containerd
case "$(hostname)" in k8s-master*) want=/var/lib/etcd ;; esac

mounted=no;  findmnt -n "$want" >/dev/null 2>&1 && mounted=yes
in_fstab=no; grep -qE "[[:space:]]$want[[:space:]]" /etc/fstab 2>/dev/null && in_fstab=yes
home_fstab=no; grep -vE '^\s*#' /etc/fstab 2>/dev/null | grep -qE '[[:space:]]/home[[:space:]]' && home_fstab=yes

if   [ "$mounted" = yes ] && [ "$in_fstab" = yes ]; then ok "partition $want ย้ายเรียบร้อย (mount + fstab ตรงกัน)"
elif [ "$mounted" = no  ] && [ "$in_fstab" = no  ] && [ "$home_fstab" = yes ]; then
     no "ยังไม่ได้ย้าย partition — /home ยังอยู่ตามเดิม (สถานะสะอาด ทำต่อได้)"
elif [ "$mounted" = no ] && [ "$in_fstab" = no ] && [ "$home_fstab" = no ]; then
     no "ไม่มี partition /home แยกให้ย้าย — ต้องแบ่ง partition ที่ VM template ก่อน"
else
     warn "🔴 partition ค้างครึ่งทาง — mounted=$mounted fstab=$in_fstab home_ใน_fstab=$home_fstab"
     echo "            ห้าม reboot จนกว่าจะแก้! ตรวจ /etc/fstab ให้ตรงกับของจริงก่อน"
     echo "            ดู:  findmnt $want ; grep -v '^#' /etc/fstab"
fi

# 6 module + sysctl
[ "$(lsmod | grep -cE '^overlay|^br_netfilter')" -eq 2 ] \
  && ok "module overlay + br_netfilter โหลดอยู่" || no "module ยังโหลดไม่ครบ"
[ -f /etc/modules-load.d/k8s.conf ] \
  && ok "modules-load.d/k8s.conf มีแล้ว (อยู่รอด reboot)" \
  || no "ไม่มี /etc/modules-load.d/k8s.conf — reboot แล้ว module จะหาย"
[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] \
  && ok "net.ipv4.ip_forward = 1" || no "net.ipv4.ip_forward ยังไม่ใช่ 1"

# 7 swap + selinux
[ "$(free -m | awk '/Swap/{print $2}')" = "0" ] && ok "swap ปิดแล้ว" || no "swap ยังเปิดอยู่"
if grep -qE '^##' /etc/fstab 2>/dev/null; then
    warn "fstab มีบรรทัดขึ้นต้น '##' — เกิดจากรัน sed ปิด swap ซ้ำ (ไม่พัง แต่รก)"
fi
[ "$(getenforce)" = "Permissive" ] && ok "SELinux = Permissive" || no "SELinux = $(getenforce)"

# 8 firewalld
case "$(hostname)" in
    k8s-master*) need="6443/tcp 8443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp 8472/udp 4240/tcp 4244-4245/tcp" ;;
    *)           need="10250/tcp 30000-32767/tcp 8472/udp 4240/tcp 4244-4245/tcp" ;;
esac
open=$(firewall-cmd --list-ports 2>/dev/null || echo "")
miss=""
for p in $need; do echo "$open" | grep -qw -- "$p" || miss="$miss $p"; done
if [ -z "$miss" ]; then ok "firewalld เปิดพอร์ตครบ"
else no "firewalld ยังขาดพอร์ต:$miss"; fi

case "$(hostname)" in k8s-master*)
    firewall-cmd --list-all 2>/dev/null | grep -q vrrp \
      && ok "firewalld อนุญาต vrrp (keepalived)" || no "firewalld ยังไม่อนุญาต vrrp" ;;
esac

# ---------------------------------------------------------------- บทที่ 02
echo
echo "บทที่ 02 — Container runtime"

command -v containerd >/dev/null 2>&1 \
  && ok "containerd $(containerd --version 2>/dev/null | awk '{print $3}')" \
  || no "ยังไม่ได้ลง containerd"
command -v runc >/dev/null 2>&1 \
  && ok "runc $(runc --version 2>/dev/null | head -1 | awk '{print $3}')" || no "ยังไม่ได้ลง runc"
[ -f /opt/cni/bin/bridge ] && ok "CNI plugins อยู่ที่ /opt/cni/bin" || no "ยังไม่ได้ลง CNI plugins"

if [ -f /etc/containerd/config.toml ]; then
    if grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
        ok "config.toml — SystemdCgroup = true"
    else
        warn "config.toml มีอยู่ แต่ SystemdCgroup ยังไม่ใช่ true"
        echo "            มักเกิดจากรัน 'containerd config default >' ซ้ำแล้วลืม sed ตามหลัง"
        echo "            แก้: sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
        echo "                 systemctl restart containerd"
    fi
else no "ยังไม่มี /etc/containerd/config.toml"; fi

systemctl is-active containerd >/dev/null 2>&1 && ok "containerd กำลังทำงาน" || no "containerd ยังไม่ทำงาน"
command -v kubeadm >/dev/null 2>&1 && ok "kubeadm $(kubeadm version -o short 2>/dev/null)" || no "ยังไม่ได้ลง kubeadm"
[ -f /etc/crictl.yaml ] && ok "crictl.yaml ตั้งแล้ว" || no "ยังไม่มี /etc/crictl.yaml"

n=$(dnf list installed 2>/dev/null | grep -c '^containerd' || true)
[ "$n" -eq 0 ] && ok "ไม่มี containerd จาก dnf (ถูกต้อง — ใช้จาก tarball)" \
               || warn "มี containerd จาก dnf $n ตัว — ol9_addons เคยเปิด ต้องถอนออก"

# ---------------------------------------------------------------- สรุป
echo
echo "==============================================================="
printf ' ทำแล้ว %d · ยังไม่ทำ %d · ต้องดู %d\n' "$DONE" "$TODO" "$WARN"
echo "==============================================================="
if [ "$WARN" -gt 0 ]; then
    echo " มีข้อ [ระวัง!] — อ่านให้ครบก่อนรันขั้นตอนซ้ำ"
    exit 1
fi
echo " ไม่มีอะไรค้างครึ่งทาง — รันขั้นตอนที่ยังไม่ทำต่อได้เลย ไม่ต้องล้างเครื่อง"
