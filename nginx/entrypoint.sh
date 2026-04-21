#!/bin/sh
set -e

CERT_DIR="/etc/nginx/certs"
CA_URL="${CA_URL:-http://ca-server/api/admin/proxy-cert}"
CA_HOST="${CA_HOST:-192.168.50.25}"
CA_PORT="${CA_PORT:-8080}"
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

# 템플릿 → 실제 설정 파일로 치환 (CA_HOST, CA_PORT 추가)
envsubst '${API_HOST} ${API_PORT} ${CA_HOST} ${CA_PORT}' \
  < /etc/nginx/conf.d/shore.conf.tmpl \
  > /etc/nginx/conf.d/shore.conf

echo "[entrypoint] shore.conf 생성 완료"

# ── cert_watch.sh 백그라운드 시작 ──────────────────────────────
# - 기동 시 CA 에서 CRL 1회 다운로드 (ssl_crl 핸드셰이크 검증 즉시 반영)
# - 5분마다 CRL 재갱신 + nginx reload
# - 24시간마다 server.crt 만료 체크 → 7일 이내면 자동 재발급
chmod +x /cert_watch.sh
CA_HOST="${CA_HOST}" CA_PORT="${CA_PORT}" CA_URL="${CA_URL}" /cert_watch.sh &
echo "[entrypoint] cert_watch.sh 시작 (PID=$!)"

exec nginx -g "daemon off;"
