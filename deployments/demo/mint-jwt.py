#!/usr/bin/env python3
"""mint-jwt.py — ออก JWT + สร้าง JWKS ที่คู่กัน โดยไม่ต้องลง library เพิ่ม

ใช้:
  # HS256 — กุญแจลับร่วมกัน (ง่าย แต่ใครถือกุญแจก็ปลอม token ได้)
  python mint-jwt.py hs256 --secret "<ความลับ>" --iss myhr --aud demo-jwt --sub user-1

  # RS256 — กุญแจส่วนตัว/สาธารณะ (ท่าที่ควรใช้จริง)
  openssl genrsa -out jwt-private.pem 2048
  python mint-jwt.py rs256 --key jwt-private.pem --iss myhr --aud demo-jwt --sub user-1

พิมพ์ออกมา 2 อย่าง: JWKS (เอาไปใส่ SecurityPolicy) และ token (เอาไปทดสอบ)
"""
import argparse, base64, hashlib, hmac, json, subprocess, sys, tempfile, time, os

# console ของ Windows เป็น cp1252 — ไม่ตั้งบรรทัดนี้จะพังตอน print ภาษาไทย
# (ท่าเดียวกับ tools/build-html.py)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def signing_input(hdr: dict, payload: dict) -> str:
    j = lambda d: json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode()
    return b64u(j(hdr)) + "." + b64u(j(payload))


def rsa_pub_numbers(key_path: str):
    """ดึง modulus (n) กับ exponent (e) ออกจาก private key ด้วย openssl"""
    mod = subprocess.run(["openssl", "rsa", "-in", key_path, "-noout", "-modulus"],
                         capture_output=True, text=True, check=True).stdout.strip()
    n_hex = mod.split("=", 1)[1]
    n = bytes.fromhex(n_hex)

    txt = subprocess.run(["openssl", "rsa", "-in", key_path, "-noout", "-text"],
                         capture_output=True, text=True, check=True).stdout
    # openssl พิมพ์ว่า  publicExponent: 65537 (0x10001)
    # เอาเลขฐานสิบตัวแรกหลัง ':' เท่านั้น — ตอนแรกเผลออ่าน 65537 เป็นฐาน 16
    # ได้ e ผิดเป็น 415031 แล้ว JWKS ออกมาเป็น "BlU3" แทนที่จะเป็น "AQAB"
    e = 65537
    for line in txt.splitlines():
        ls = line.strip()
        if ls.lower().replace(" ", "").startswith("publicexponent"):
            e = int(ls.split(":", 1)[1].strip().split()[0])
            break
    e_bytes = e.to_bytes((e.bit_length() + 7) // 8, "big")
    return n, e_bytes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("alg", choices=["hs256", "rs256"])
    ap.add_argument("--secret", help="HS256 เท่านั้น")
    ap.add_argument("--key", help="RS256 เท่านั้น — ไฟล์ private key (PEM)")
    ap.add_argument("--iss", required=True)
    ap.add_argument("--aud", required=True)
    ap.add_argument("--sub", default="demo-user")
    ap.add_argument("--kid", default="demo-key")
    ap.add_argument("--days", type=int, default=365, help="อายุ token (วัน)")
    a = ap.parse_args()

    now = int(time.time())
    payload = {"iss": a.iss, "aud": a.aud, "sub": a.sub,
               "iat": now, "exp": now + a.days * 86400}

    if a.alg == "hs256":
        if not a.secret:
            sys.exit("hs256 ต้องมี --secret")
        secret = a.secret.encode()
        hdr = {"alg": "HS256", "typ": "JWT", "kid": a.kid}
        si = signing_input(hdr, payload)
        sig = hmac.new(secret, si.encode(), hashlib.sha256).digest()
        jwks = {"keys": [{"kty": "oct", "alg": "HS256", "kid": a.kid, "k": b64u(secret)}]}
    else:
        if not a.key or not os.path.exists(a.key):
            sys.exit("rs256 ต้องมี --key ที่ชี้ไฟล์ PEM ที่มีอยู่จริง")
        hdr = {"alg": "RS256", "typ": "JWT", "kid": a.kid}
        si = signing_input(hdr, payload)
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(si.encode()); tmp = f.name
        try:
            sig = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", a.key, "-binary", tmp],
                capture_output=True, check=True).stdout
        finally:
            os.unlink(tmp)
        n, e = rsa_pub_numbers(a.key)
        jwks = {"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig",
                          "kid": a.kid, "n": b64u(n), "e": b64u(e)}]}

    token = si + "." + b64u(sig)
    print("JWKS (เอาไปใส่ localJWKS.inline ของ SecurityPolicy):")
    print(json.dumps(jwks, separators=(",", ":")))
    print()
    print("TOKEN:")
    print(token)
    print()
    print("exp:", time.strftime("%Y-%m-%d", time.localtime(payload["exp"])))


if __name__ == "__main__":
    main()
