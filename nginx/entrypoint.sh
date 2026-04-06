#!/bin/sh
set -e

API_HOST="${API_HOST:-localhost}"
API_PORT="${API_PORT:-5000}"

echo "[entrypoint] API_HOST=${API_HOST}, API_PORT=${API_PORT}"

# 템플릿 → 실제 설정 파일로 치환
envsubst '${API_HOST} ${API_PORT}' \
  < /etc/nginx/conf.d/shore.conf.tmpl \
  > /etc/nginx/conf.d/shore.conf

echo "[entrypoint] shore.conf 생성 완료"

exec nginx -g "daemon off;"
