#!/bin/sh
# cert_watch.sh — Reverse Proxy (Nginx)
# 역할:
#   1. 기동 시 CA 에서 CRL 1회 다운로드 → ssl_crl TLS 핸드셰이크 검증에 즉시 반영
#   2. 5분마다 CRL 재갱신 + nginx reload
#      (폐기된 client.crt 는 최대 5분 내 핸드셰이크 단계에서 차단)
#   3. 24시간마다 server.crt 만료일 체크 → 7일 이내면 자동 재발급

set -e

CERT_DIR="/etc/nginx/certs"
CA_HOST="${CA_HOST:-192.168.50.25}"
CA_PORT="${CA_PORT:-8080}"
CA_URL="${CA_URL:-http://${CA_HOST}:${CA_PORT}/api/admin/proxy-cert}"
CA_CRL_URL="http://${CA_HOST}:${CA_PORT}/pki/crl"

CRL_INTERVAL=300       # 5분 (초)
RENEW_DAYS=7
CHECK_INTERVAL=86400   # 24시간 (초)

last_cert_check=0

log_info()  { echo "[cert_watch][INFO]  $1"; }
log_warn()  { echo "[cert_watch][WARN]  $1"; }
log_error() { echo "[cert_watch][ERROR] $1"; }

# ── CRL 다운로드 + nginx reload (verify_cert.sh [1/2] 방식) ──
download_crl() {
    log_info "CRL 다운로드: ${CA_CRL_URL}"
    if curl -sf --max-time 15 -o "${CERT_DIR}/crl.der" "${CA_CRL_URL}"; then
        if openssl crl -inform DER -in "${CERT_DIR}/crl.der" \
                       -out "${CERT_DIR}/crl.pem.new" 2>/dev/null; then
            mv "${CERT_DIR}/crl.pem.new" "${CERT_DIR}/crl.pem"
            REVOKED_COUNT=$(openssl crl -noout -text -in "${CERT_DIR}/crl.pem" 2>/dev/null \
                | grep -c "Serial Number" || true)
            log_info "CRL 갱신 완료 — 폐기 인증서 수: ${REVOKED_COUNT}"
            # nginx reload → 다음 TLS 핸드셰이크부터 새 CRL 즉시 반영
            nginx -s reload 2>/dev/null && log_info "nginx reload 완료" \
                || log_warn "nginx reload 실패 (아직 nginx 가 준비 안 됐을 수 있음)"
        else
            log_warn "CRL DER→PEM 변환 실패"
        fi
    else
        log_warn "CRL 다운로드 실패 (URL: ${CA_CRL_URL}) — 기존 CRL 유지"
    fi
}

# ── 만료까지 남은 일수 ────────────────────────────────────────
days_until_expiry() {
    local cert_file="$1"
    local end_date
    end_date=$(openssl x509 -noout -enddate -in "$cert_file" 2>/dev/null \
               | sed 's/notAfter=//')
    [ -z "$end_date" ] && echo "-1" && return

    python3 -c "
from datetime import datetime, timezone
try:
    end = datetime.strptime('${end_date}', '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    print(max(0, (end - now).days))
except Exception:
    print(-1)
" 2>/dev/null || echo "-1"
}

# ── server.crt 재발급 ────────────────────────────────────────
renew_server_cert() {
    log_warn "server.crt 만료 임박 — CA 에 재발급 요청 (${CA_URL})"

    openssl req -new \
      -key  "${CERT_DIR}/server.key" \
      -subj "/CN=Shore Gateway Reverse Proxy/O=KRINS/C=KR" \
      -out  "${CERT_DIR}/server.csr"

    PAYLOAD=$(python3 -c "
import json
csr = open('${CERT_DIR}/server.csr').read()
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

    RESPONSE=$(curl -sf -X POST "${CA_URL}" \
      -u "admin:admin1234" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD") || { log_error "CA 서버 응답 없음 — 재발급 실패"; return 1; }

    echo "$RESPONSE" | python3 -c "
import json, sys
body = json.load(sys.stdin)
if not body.get('success'):
    print('[cert_watch][ERROR] 재발급 실패:', body.get('message'))
    sys.exit(1)
pem = body['data']['certificatePem']
with open('${CERT_DIR}/server.crt', 'w') as f:
    f.write(pem)
exp = body['data'].get('notAfter', '(unknown)')
print('[cert_watch][INFO]  재발급 완료 — 새 만료일:', exp)
" || return 1

    nginx -s reload 2>/dev/null && log_info "nginx reload (새 서버 인증서 반영) 완료" \
        || log_warn "nginx reload 실패"
}

# ════════════════════════════════════════════════════════════
# 기동 시: CRL 1회 다운로드
# ════════════════════════════════════════════════════════════
download_crl

# ════════════════════════════════════════════════════════════
# 주기 루프: 5분마다 CRL 갱신, 24시간마다 server.crt 만료 체크
# ════════════════════════════════════════════════════════════
while true; do
    sleep ${CRL_INTERVAL}

    # CRL 5분 주기 갱신
    download_crl

    # 24시간마다 server.crt 만료 체크
    now=$(date +%s)
    elapsed=$((now - last_cert_check))
    if [ "$elapsed" -ge "$CHECK_INTERVAL" ]; then
        last_cert_check=$now
        CERT_FILE="${CERT_DIR}/server.crt"
        if [ -f "$CERT_FILE" ]; then
            END_DATE=$(openssl x509 -noout -enddate -in "$CERT_FILE" 2>/dev/null \
                       | sed 's/notAfter=//')
            log_info "server.crt 만료 체크 — 만료일: ${END_DATE}"
            REMAINING=$(days_until_expiry "$CERT_FILE")
            if [ "$REMAINING" -lt 0 ]; then
                log_error "만료일 파싱 실패"
            elif [ "$REMAINING" -le "$RENEW_DAYS" ]; then
                log_warn "server.crt 만료 임박: ${REMAINING}일 남음 — 재발급 시도"
                renew_server_cert || log_error "재발급 실패 — 다음 주기에 재시도"
            else
                log_info "server.crt 유효: ${REMAINING}일 남음"
            fi
        fi
    fi
done
