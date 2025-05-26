#!/bin/bash
set -euo pipefail

# === Load .env file ===
if [[ -f ~/VGW/repository/.env ]]; then
  echo "📄 Loading environment variables from .env"
  set -o allexport
  source ~/VGW/repository/.env
  set +o allexport
else
  echo "⚠️  .env file not found at path ~/VGW/repository. Continuing with existing environment."
fi

# === Validate required environment variables ===
validate_env_vars() {
  local REQUIRED_VARS=("APP_ID" "REPO_OWNER" "REPO_NAME" "PRIVATE_KEY_PATH")
  local missing=0

  echo "🔍 Checking required environment variables..."
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "❌ Environment variable '$var' is not set."
      missing=1
    fi
  done

  if [[ $missing -eq 1 ]]; then
    echo "🚫 Missing required environment variables. Aborting."
    exit 1
  fi

  echo "✅ All required environment variables are set."
}

validate_env_vars

# === Load Configuration ===
APP_ID="${APP_ID:-}"
REPO_OWNER="${REPO_OWNER:-}"
REPO_NAME="${REPO_NAME:-}"
PRIVATE_KEY_PATH="${PRIVATE_KEY_PATH:-./private-key.pem}"


# === Dependency Check ===
for cmd in openssl curl jq git; do
  if ! command -v $cmd &>/dev/null; then
    echo "❌ Missing required command: $cmd"
    exit 1
  fi
done

# === Generate JWT ===
NOW=$(date +%s)
EXP=$((NOW + 600))

HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$NOW" "$EXP" "$APP_ID" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
DATA="${HEADER}.${PAYLOAD}"

SIGNATURE=$(echo -n "$DATA" | openssl dgst -sha256 -sign "$PRIVATE_KEY_PATH" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
JWT="${DATA}.${SIGNATURE}"

# === Get Installation ID Dynamically ===
INSTALLATIONS=$(curl -s -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" https://api.github.com/app/installations)
INSTALLATION_ID=$(echo "$INSTALLATIONS" | jq ".[] | select(.account.login==\"$REPO_OWNER\") | .id")

if [[ -z "$INSTALLATION_ID" ]]; then
  echo "❌ Could not determine installation ID for $REPO_OWNER"
  exit 1
fi

# === Get Access Token ===
TOKEN_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")

INSTALL_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r .token)

if [ "$INSTALL_TOKEN" = "null" ]; then
    echo "❌ Failed to get installation token"
    echo "$TOKEN_RESPONSE"
    exit 1
fi

# === Clone or Overwrite Repo ===
CLONE_URL="https://x-access-token:$INSTALL_TOKEN@github.com/$REPO_OWNER/$REPO_NAME.git"
TARGET_DIR="~/VGW/repository/$REPO_NAME"

if [[ -d "$TARGET_DIR/.git" ]]; then
  echo "🔄 Repository '$REPO_NAME' already exists. Pulling latest changes..."
  cd "$TARGET_DIR"
  git remote set-url origin "$CLONE_URL"
  git fetch origin
  git reset --hard origin/main  # or origin/your-branch
  git clean -fdx  # remove untracked files and directories
  cd ..
else
  echo "📥 Cloning $REPO_OWNER/$REPO_NAME..."
  git clone "$CLONE_URL"
fi
