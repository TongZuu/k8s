# =============================================================================
#  kubeadm-docsplit.awk — จำลองวิธีที่ kubeadm หั่น --config เป็น document
# =============================================================================
#  kubeadm ไม่ได้ parse YAML ก่อนแล้วค่อยหั่น มันหั่นที่บรรทัดขึ้นต้นด้วย "---"
#  ตรง ๆ แล้วบังคับว่าทุกชิ้นที่มีตัวอักษรอยู่ต้องมี apiVersion และ kind
#  ชิ้นที่มีแต่คอมเมนต์หรือบรรทัดว่างจึงทำให้ init ตายด้วยข้อความที่ไม่บอกบรรทัด
#
#  ใช้:  awk -f config/kubeadm-docsplit.awk config/kubeadm/kubeadm-config.yaml
#  ไม่พิมพ์อะไร = ผ่าน · พิมพ์บรรทัดละ 1 ปัญหา = ไม่ผ่าน
# =============================================================================
function flush() {
    if (lines > 0 && !(api && kind))
        print FILENAME ": บรรทัด " start "-" (NR - 1) " เป็น document ที่ไม่มี apiVersion/kind" \
              " — kubeadm จะฟ้อง GroupVersionKind /, Kind= โดยไม่บอกว่าไฟล์ไหนบรรทัดไหน"
    lines = 0; api = 0; kind = 0; start = NR + 1
}
BEGIN          { start = 1 }
/^---/         { flush(); next }
               { lines++ }
/^apiVersion:/ { api = 1 }
/^kind:/       { kind = 1 }
END            { NR++; flush() }
