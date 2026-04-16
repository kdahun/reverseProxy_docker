FROM nginx:1.27-alpine

# curl, openssl 설치 (CSR 생성 및 CA 서버 전송용)
RUN apk add --no-cache curl openssl jq
