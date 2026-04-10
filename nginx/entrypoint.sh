#!/bin/sh
set -e

CERT_DIR="/etc/nginx/certs"
CA_URL="${CA_URL:-http://ca-server/sign}"
API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-5000}"

echo "[entrypoint] API_HOST=${API_HOST}, API_PORT=${API_PORT}"
echo "[entrypoint] CA_URL=${CA_URL}"

# CRT가 없으면 CSR 생성 → CA 전송 → CRT 저장
if [ ! -f "$CERT_DIR/server.crt" ]; then
    echo "[entrypoint] server.crt 없음 → CSR 생성 후 CA 요청"

    # CSR 생성 (server.key는 이미 존재)
    openssl req -new \
      -key "$CERT_DIR/server.key" \
      -subj "/CN=shore-nginx/O=IHO/C=KR" \
      -out "$CERT_DIR/server.csr"

    # CA 서버로 CSR 전송 → CRT 수신
    curl -sf -X POST "$CA_URL" \
      -F "csr=@$CERT_DIR/server.csr" \
      -F "type=server" \
      -o "$CERT_DIR/server.crt"

    echo "[entrypoint] server.crt 발급 완료"
else
    echo "[entrypoint] server.crt 존재 → CA 요청 생략"
fi

# 템플릿 → 실제 설정 파일로 치환
envsubst '${API_HOST} ${API_PORT}' \
  < /etc/nginx/conf.d/shore.conf.tmpl \
  > /etc/nginx/conf.d/shore.conf

echo "[entrypoint] shore.conf 생성 완료"

exec nginx -g "daemon off;"
