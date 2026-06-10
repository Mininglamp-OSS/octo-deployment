#!/bin/sh
# init-speech.sh
# 在 Docker Compose 中作为 init container 运行，自动完成：
# 1. 等待 octo-speech-admin 就绪
# 2. 登录 speech-admin，获取/创建名为 "octo-default" 的 App
# 3. 获取 API key，写入共享文件 /run/secrets/speech_api_key
# 4. octo-server 通过 SPEECH_API_KEY_FILE 或启动脚本读取该文件

set -e

SPEECH_ADMIN_URL="${SPEECH_ADMIN_URL:-http://octo-speech-admin:8781}"
SPEECH_ADMIN_USER="${ADMIN_USERNAME:-admin}"
SPEECH_ADMIN_PASS="${ADMIN_PASSWORD:-}"
APP_NAME="${SPEECH_APP_NAME:-octo-default}"
OUTPUT_FILE="${SPEECH_KEY_OUTPUT:-/run/speech/api_key}"

echo "[init-speech] waiting for speech-admin at $SPEECH_ADMIN_URL ..."
for i in $(seq 1 30); do
  if wget -qO- "$SPEECH_ADMIN_URL/health" >/dev/null 2>&1 || \
     wget -qO- "$SPEECH_ADMIN_URL/" >/dev/null 2>&1; then
    echo "[init-speech] speech-admin is up"
    break
  fi
  echo "[init-speech] attempt $i/30, retrying in 3s..."
  sleep 3
done

# login
echo "[init-speech] logging in..."
LOGIN_RESP=$(wget -qO- --post-data="{\"username\":\"$SPEECH_ADMIN_USER\",\"password\":\"$SPEECH_ADMIN_PASS\"}" \
  --header="Content-Type: application/json" \
  --save-cookies=/tmp/speech_cookies.txt \
  "$SPEECH_ADMIN_URL/api/login")
echo "[init-speech] login resp: $LOGIN_RESP"

# get csrf token from cookie
CSRF=$(grep csrf_token /tmp/speech_cookies.txt | awk '{print $NF}' | head -1)
echo "[init-speech] csrf: $CSRF"

# check if app already exists
APPS=$(wget -qO- \
  --load-cookies=/tmp/speech_cookies.txt \
  "$SPEECH_ADMIN_URL/api/apps?name=$APP_NAME" 2>/dev/null)
echo "[init-speech] existing apps: $APPS"

# extract first app_id if exists
APP_ID=$(echo "$APPS" | grep -o '"app_id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -n "$APP_ID" ]; then
  echo "[init-speech] found existing app $APP_ID, resetting key..."
  KEY_RESP=$(wget -qO- \
    --method=POST \
    --header="X-CSRF-Token: $CSRF" \
    --load-cookies=/tmp/speech_cookies.txt \
    "$SPEECH_ADMIN_URL/api/apps/$APP_ID/reset-key" 2>/dev/null)
else
  echo "[init-speech] creating new app '$APP_NAME'..."
  KEY_RESP=$(wget -qO- \
    --post-data="{\"app_name\":\"$APP_NAME\"}" \
    --header="Content-Type: application/json" \
    --header="X-CSRF-Token: $CSRF" \
    --load-cookies=/tmp/speech_cookies.txt \
    "$SPEECH_ADMIN_URL/api/apps" 2>/dev/null)
fi

echo "[init-speech] key resp: $KEY_RESP"
API_KEY=$(echo "$KEY_RESP" | grep -o '"api_key":"[^"]*"' | cut -d'"' -f4)

if [ -z "$API_KEY" ]; then
  echo "[init-speech] ERROR: failed to get api_key from response"
  exit 1
fi

mkdir -p "$(dirname $OUTPUT_FILE)"
echo -n "$API_KEY" > "$OUTPUT_FILE"
echo "[init-speech] api_key written to $OUTPUT_FILE"
echo "[init-speech] SPEECH_API_KEY=$API_KEY"
