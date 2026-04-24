#!/bin/sh
set -e

CERT_DIR="/etc/nginx/certs"
CA_HOST="${CA_HOST:-192.168.50.25}"
CA_PORT="${CA_PORT:-8080}"
CA_URL="${CA_URL:-http://${CA_HOST}:${CA_PORT}/api/admin/proxy-cert}"
API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-5000}"

echo "[entrypoint] API_HOST=${API_HOST}, API_PORT=${API_PORT}"
echo "[entrypoint] CA_URL=${CA_URL}"
echo "[entrypoint] CA_HOST=${CA_HOST}, CA_PORT=${CA_PORT}"

# CRT가 없으면 CSR 생성 → CA 전송 → CRT 저장
if [ ! -f "$CERT_DIR/server.crt" ]; then
    echo "[entrypoint] server.crt 없음 → CSR 생성 후 CA 요청"

    # CSR 생성 (server.key는 이미 존재)
    openssl req -new \
      -key "$CERT_DIR/server.key" \
      -subj "/CN=Shore Gateway Reverse Proxy/O=KRINS/C=KR" \
      -out "$CERT_DIR/server.csr"

    # JSON 페이로드 생성
    PAYLOAD=$(python3 -c "
import json
csr = open('$CERT_DIR/server.csr').read()
print(json.dumps({
    'certType':     'REVERSE_PROXY',
    'csr':          csr,
    'subjectCn':    'Shore Gateway Reverse Proxy',
    'organization': 'KRINS',
    'country':      'KR',
    'dnsNames':     ['proxy.example.com'],
    'ipAddresses':  ['192.168.50.241']
}))
")

    # CA 서버로 JSON 전송 → 응답에서 certificatePem 추출 → server.crt 저장
    RESPONSE=$(curl -sf -X POST "$CA_URL" \
      -u "admin:admin1234" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD")

    echo "$RESPONSE" | python3 -c "
import json, sys
body = json.load(sys.stdin)
if not body.get('success'):
    print('[entrypoint][ERROR] 인증서 발급 실패:', body.get('message'))
    sys.exit(1)
pem = body['data']['certificatePem']
with open('$CERT_DIR/server.crt', 'w') as f:
    f.write(pem)
"
    echo "[entrypoint] server.crt 발급 완료"
else
    echo "[entrypoint] server.crt 존재 → CA 요청 생략"
fi

# CRL 다운로드 (CA_URL에서 host:port 추출)
CA_BASE=$(echo "$CA_URL" | sed 's|/api/.*||')
CRL_URL="${CA_BASE}/pki/crl"
echo "[entrypoint] CRL 다운로드: ${CRL_URL}"
CRL_OK=0
if curl -sf --max-time 15 -o "${CERT_DIR}/crl.der" "${CRL_URL}"; then
    openssl crl -inform DER -in "${CERT_DIR}/crl.der" \
                -out "${CERT_DIR}/crl.pem"
    echo "[entrypoint] crl.pem 생성 완료"
    CRL_OK=1
else
    echo "[entrypoint][WARN] CRL 다운로드 실패 — ssl_crl 비활성화"
fi

# 템플릿 → 실제 설정 파일로 치환
envsubst '${API_HOST} ${API_PORT} ${CA_HOST} ${CA_PORT}' \
  < /etc/nginx/conf.d/shore.conf.tmpl \
  > /etc/nginx/conf.d/shore.conf

# CRL 파일 없으면 ssl_crl 지시어 제거
if [ "$CRL_OK" = "0" ]; then
    sed -i '/ssl_crl /d' /etc/nginx/conf.d/shore.conf
    echo "[entrypoint] shore.conf에서 ssl_crl 제거 완료"
fi

echo "[entrypoint] shore.conf 생성 완료"

# nginx 시작 전 CRL 선(先) 다운로드 — crl.pem 없으면 nginx 기동 실패
echo "[entrypoint] CRL 선(先) 다운로드 시작"
if curl -sf --max-time 15 -o "${CERT_DIR}/crl.der" "http://${CA_HOST}:${CA_PORT}/pki/crl"; then
    if openssl crl -inform DER -in "${CERT_DIR}/crl.der" -out "${CERT_DIR}/crl.pem" 2>/dev/null; then
        echo "[entrypoint] CRL 다운로드 완료 → crl.pem 생성됨"
    else
        echo "[entrypoint] CRL DER→PEM 변환 실패 — 빈 crl.pem 생성"
        touch "${CERT_DIR}/crl.pem"
    fi
else
    echo "[entrypoint] CRL 다운로드 실패 — CA 서버 미응답, 빈 crl.pem 생성"
    touch "${CERT_DIR}/crl.pem"
fi

exec nginx -g "daemon off;"
