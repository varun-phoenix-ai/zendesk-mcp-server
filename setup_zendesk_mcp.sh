#!/usr/bin/env bash
# setup_zendesk_mcp.sh
# One-command setup: Zendesk MCP server for Claude Desktop (and Claude Code) on macOS.
# Usage:  bash setup_zendesk_mcp.sh
set -euo pipefail

# ---- Team settings (edit here if anything changes) --------------------------
REPO_URL="https://github.com/reminia/zendesk-mcp-server.git"
INSTALL_DIR="$HOME/github/zendesk-mcp-server"
ZENDESK_SUBDOMAIN="celerdata"
ZENDESK_CLIENT_ID="claude_mcp"
ZENDESK_SCOPES="tickets:read ticket_attachments:read users:read hc:read"
# -----------------------------------------------------------------------------

CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
CLAUDE_LOG="$HOME/Library/Logs/Claude/mcp-server-zendesk.log"
TOKEN_FILE="$HOME/.config/zendesk-mcp/tokens.json"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
trap 'red "Setup failed on line $LINENO. Scroll up for the error, or send this output to the setup owner."' ERR

# 1. Checks -------------------------------------------------------------------
step "Checking requirements"
[[ "$(uname)" == "Darwin" ]] || { red "This script supports macOS only."; exit 1; }
[[ -d "/Applications/Claude.app" ]] || { red "Claude Desktop not found in /Applications. Install it first: https://claude.ai/download"; exit 1; }
command -v git >/dev/null || { red "git not found. Run: xcode-select --install"; exit 1; }

if ! command -v uv >/dev/null; then
  yellow "uv not found, installing..."
  if command -v brew >/dev/null; then
    brew install uv
  else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
UV_PATH="$(command -v uv)"
green "uv: $UV_PATH"

# 2. Clone or update ----------------------------------------------------------
step "Getting the Zendesk MCP server"
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

step "Installing dependencies"
"$UV_PATH" venv --allow-existing >/dev/null
"$UV_PATH" pip install -e . >/dev/null
green "Installed in $INSTALL_DIR"

# 3. .env ---------------------------------------------------------------------
step "Writing .env"
[[ -f .env ]] && cp .env ".env.backup.$(date +%Y%m%d%H%M%S)"
cat > .env <<EOF
ZENDESK_SUBDOMAIN=$ZENDESK_SUBDOMAIN
ZENDESK_CLIENT_ID=$ZENDESK_CLIENT_ID
ZENDESK_OAUTH_SCOPES=$ZENDESK_SCOPES
EOF
chmod 600 .env
green ".env written"

# 4. Zendesk sign-in ----------------------------------------------------------
step "Signing in to Zendesk"
RUN_AUTH="y"
if [[ -f "$TOKEN_FILE" ]]; then
  read -r -p "You're already signed in. Sign in again? [y/N] " RUN_AUTH </dev/tty || RUN_AUTH="n"
fi
if [[ "$RUN_AUTH" =~ ^[Yy]$ ]]; then
  yellow "A browser tab will open. Log in to Zendesk and click Allow (you have 3 minutes)."
  "$UV_PATH" run zendesk-auth
fi

# 5. Claude Desktop config ----------------------------------------------------
step "Quitting Claude Desktop"
osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
for _ in {1..15}; do pgrep -x Claude >/dev/null || break; sleep 1; done
pgrep -x Claude >/dev/null && pkill -x Claude && sleep 2
green "Claude Desktop is closed"

step "Updating Claude Desktop config"
mkdir -p "$(dirname "$CLAUDE_CONFIG")"
[[ -s "$CLAUDE_CONFIG" ]] && cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.backup.$(date +%Y%m%d%H%M%S)"

"$INSTALL_DIR/.venv/bin/python" - "$CLAUDE_CONFIG" "$UV_PATH" "$INSTALL_DIR" <<'PY'
import json, sys, os
path, uv, repo = sys.argv[1:4]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f)   # fails loudly if the existing file is invalid JSON
data.setdefault("mcpServers", {})["zendesk"] = {
    "command": uv,
    "args": ["--directory", repo, "run", "zendesk"],
}
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
green "Added zendesk to $CLAUDE_CONFIG (backup saved next to it)"

# 6. Claude Code (optional, only if installed) --------------------------------
if command -v claude >/dev/null; then
  step "Adding to Claude Code"
  claude mcp remove zendesk -s user >/dev/null 2>&1 || true
  claude mcp add zendesk -s user -- "$UV_PATH" --directory "$INSTALL_DIR" run zendesk >/dev/null
  green "Added to Claude Code"
fi

# 7. Restart and verify -------------------------------------------------------
step "Starting Claude Desktop"
LOG_LINES=0; [[ -f "$CLAUDE_LOG" ]] && LOG_LINES=$(wc -l < "$CLAUDE_LOG")
open -a Claude

OK=""
for _ in {1..30}; do
  if [[ -f "$CLAUDE_LOG" ]] && tail -n +"$((LOG_LINES + 1))" "$CLAUDE_LOG" | grep -q "connected successfully"; then
    OK="yes"; break
  fi
  sleep 1
done

echo
if [[ -n "$OK" ]]; then
  green "All set! In Claude Desktop, start a NEW chat and try:"
  echo '  "Show me the 5 most recently updated Zendesk tickets, just ID, subject and status."'
else
  yellow "Claude Desktop started, but the Zendesk server hasn't reported in yet."
  yellow "Wait a few seconds, then check: tail -20 \"$CLAUDE_LOG\""
fi
