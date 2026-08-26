#!/usr/bin/env bash
# =============================================================================
#  validate-manifests.sh — ตรวจ manifest ก่อนขึ้น cluster
# =============================================================================
#  นี่คือสิ่งที่มาแทน GitOps
#  D9 เลือก kubectl apply มือ จึงไม่มีอะไรบังคับให้ manifest ผ่านมาตรฐาน
#  สคริปต์นี้ทำหน้าที่นั้นแทน โดยรันที่ CI และ exit 1 ถ้าไม่ผ่าน
#
#  ใช้:  ./validate-manifests.sh prod/
#  ต้องมี: kubeconform, yq
# =============================================================================

set -euo pipefail

DIR="${1:-.}"
K8S_VERSION="${K8S_VERSION:-1.36.3}"
FAIL=0

red()  { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=1; }
grn()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
info() { printf '\n\033[1m── %s ──\033[0m\n' "$*"; }

# =============================================================================
info "1. schema ถูกต้องตาม Kubernetes ${K8S_VERSION}"
# =============================================================================
if kubeconform \
      -kubernetes-version "${K8S_VERSION}" \
      -strict \
      -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -summary \
      "${DIR}"; then
  grn "schema ผ่าน"
else
  red "schema ไม่ผ่าน"
fi

# =============================================================================
info "2. ทุก Deployment ต้องมี PodDisruptionBudget คู่กัน"
# =============================================================================
# เหตุผล: ไม่มี Ksplice → drain ทุก 1-2 เดือน → ไม่มี PDB = service ดับ
DEPLOYS=$(grep -rl 'kind: Deployment' "${DIR}" --include='*.yaml' || true)
for f in ${DEPLOYS}; do
  name=$(yq eval-all 'select(.kind == "Deployment") | .metadata.name' "$f" | head -1)
  [ -z "$name" ] && continue

  if grep -rq 'kind: PodDisruptionBudget' "$(dirname "$f")"; then
    grn "${name}: มี PDB"
  else
    red "${name}: ไม่มี PodDisruptionBudget — drain node แล้วจะดับ"
  fi
done

# =============================================================================
info "3. replicas ต้อง >= 2"
# =============================================================================
# PDB ช่วยไม่ได้ถ้ามี replica เดียว — drain จะค้างหรือ service ดับ
for f in ${DEPLOYS}; do
  while IFS=$'\t' read -r name replicas; do
    [ -z "$name" ] && continue
    if [ "${replicas:-1}" -lt 2 ] 2>/dev/null; then
      red "${name}: replicas = ${replicas} (ต้อง >= 2)"
    else
      grn "${name}: replicas = ${replicas}"
    fi
  done < <(yq eval-all 'select(.kind == "Deployment") | [.metadata.name, .spec.replicas] | @tsv' "$f")
done

# =============================================================================
info "4. ทุก container ต้องมี resources.requests"
# =============================================================================
# ไม่มี requests → scheduler ตัดสินใจมั่ว และ ResourceQuota บล็อกทั้ง namespace
for f in ${DEPLOYS}; do
  missing=$(yq eval-all '
    select(.kind == "Deployment")
    | .spec.template.spec.containers[]
    | select(.resources.requests.cpu == null or .resources.requests.memory == null)
    | .name' "$f")
  if [ -n "$missing" ]; then
    red "$(basename "$f"): container ไม่มี requests → ${missing//$'\n'/, }"
  else
    grn "$(basename "$f"): resources ครบ"
  fi
done

# =============================================================================
info "5. ทุก container ต้องมี readinessProbe และ livenessProbe"
# =============================================================================
for f in ${DEPLOYS}; do
  missing=$(yq eval-all '
    select(.kind == "Deployment")
    | .spec.template.spec.containers[]
    | select(.readinessProbe == null or .livenessProbe == null)
    | .name' "$f")
  if [ -n "$missing" ]; then
    red "$(basename "$f"): container ขาด probe → ${missing//$'\n'/, }"
  else
    grn "$(basename "$f"): probes ครบ"
  fi
done

# =============================================================================
info "6. ห้าม root และห้าม :latest"
# =============================================================================
if grep -rn 'runAsUser: 0' "${DIR}" --include='*.yaml'; then
  red "พบ runAsUser: 0 — PSA restricted จะบล็อก"
else
  grn "ไม่มี runAsUser: 0"
fi

if grep -rnE 'image:.*:latest' "${DIR}" --include='*.yaml'; then
  red "พบ image tag :latest — deploy ซ้ำแล้วอาจได้คนละ image"
else
  grn "ไม่มี :latest"
fi

# แนะนำแต่ยังไม่บังคับ — เปลี่ยนเป็น red ได้เมื่อทีมพร้อม
if ! grep -rqE 'image:.*@sha256:' "${DIR}" --include='*.yaml'; then
  printf '\033[33m! ยังไม่ได้ pin image ด้วย digest (@sha256:) — แนะนำให้ทำ\033[0m\n'
fi

# =============================================================================
echo
if [ "${FAIL}" -eq 0 ]; then
  grn "ผ่านทั้งหมด"
else
  red "ไม่ผ่าน — แก้ก่อน merge"
fi
exit "${FAIL}"
