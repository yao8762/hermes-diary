#!/bin/bash
#===============================================================================
# Hermes Diary Builder — 每天凌晨跑
# 讀取前日 session → 濃縮摘要 → 更新 HTML → git push → Telegram 通知
#===============================================================================

set -e

#------------------- 設定 -------------------
REPO_DIR="/tmp/hermes-diary-work"
SESSION_DIR="$HOME/.hermes/sessions"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-1974531415}"
LLM_API_KEY="${LLM_API_KEY}"
LLM_API_BASE="${LLM_API_BASE:-https://api.minimax.io/anthropic}"
LLM_MODEL="${LLM_MODEL:-MiniMax-M2.7}"
VERCEL_URL="https://hermes-diary.vercel.app"

# SSH 金鑰（給 git push 用）
export GIT_SSH_KEY="$HOME/.ssh/hermes_diary_deploy"
export GIT_SSH_COMMAND="ssh -i $GIT_SSH_KEY"

#------------------- 準備 -------------------
if [ -d "$REPO_DIR" ]; then
  rm -rf "$REPO_DIR"
fi
git clone git@github.com:yao8762/hermes-diary.git "$REPO_DIR"
cd "$REPO_DIR"

#------------------- 抓昨日日期 -------------------
YESTERDAY=$(date -d "yesterday" +%Y%m%d)
TODAY_DISPLAY=$(date -d "yesterday" +%Y/%m/%d)

#------------------- 找昨日 session 檔案 -------------------
SESSION_FILES=$(find "$SESSION_DIR" -maxdepth 1 -name "session_${YESTERDAY}_*.json" 2>/dev/null | sort)

if [ -z "$SESSION_FILES" ]; then
  echo "No sessions found for $YESTERDAY, skipping."
  exit 0
fi

#------------------- 統計 user 訊息數 -------------------
MSG_COUNT=$(python3 -c "
import json, glob
import os
yesterday = os.environ.get('YESTERDAY', '')
files = sorted(glob.glob(os.path.expanduser('~/.hermes/sessions/session_') + yesterday + '_*.json'))
count = 0
for f in files:
    with open(f) as fp:
        data = json.load(fp)
    for m in data.get('messages', []):
        if m.get('role') == 'user' and m.get('content'):
            count += 1
print(count)
")
export MSG_COUNT

#------------------- 組對話文字 -------------------
CONVO_TEXT=""
for FILE in $SESSION_FILES; do
  USER_MSGS=$(cat "$FILE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('messages', []):
    if m.get('role') == 'user':
        content = m.get('content', '')
        if content:
            print(f'用戶: {content}')
    elif m.get('role') == 'assistant':
        content = m.get('content', '')
        if content and len(content) > 5:
            print(f'助理: {content}')
" 2>/dev/null)
  CONVO_TEXT="${CONVO_TEXT}
${USER_MSGS}"
done

# 限制在 200000 字
CONVO_TEXT="${CONVO_TEXT:0:200000}"
export CONVO_TEXT

#------------------- LLM 摘要（結果寫入 temp 檔） -------------------
SUMMARY_TMP=$(mktemp)
export YESTERDAY TODAY_DISPLAY LLM_API_KEY LLM_API_BASE LLM_MODEL

python3 - "$SUMMARY_TMP" <<'PYEOF'
import os, urllib.request, json

convo_text = os.environ.get('CONVO_TEXT', '')
today_display = os.environ.get('TODAY_DISPLAY', '')
msg_count = os.environ.get('MSG_COUNT', '0')
llm_api_key = os.environ.get('LLM_API_KEY', '')
llm_api_base = os.environ.get('LLM_API_BASE', 'https://api.minimax.io/anthropic')
llm_model = os.environ.get('LLM_MODEL', 'MiniMax-M2.7')
out_path = sys.argv[1]

prompt = '''你是一個日誌摘要機器。將以下對話記錄濃縮成條列式日記摘要。

格式嚴格遵守以下三類，請直接使用這些 emoji 作為每條的開頭：
🔧 做的事
💡 學到的東西
📌 重要決定

不要使用其他標題或格式，也不要寫「記憶更新」「技能更新」等段落。

日期：''' + today_display + '''

（共 ''' + msg_count + ''' 筆對話）

### 🔧 做的事
列出所有實質操作，每條一行為動詞開頭，範例：
- 使用 docker build 建置了 hermes-portable 映像
- 設定 SSH deploy key 讓 git push 可以自動化
- 放棄使用 docker run alias 方案，改用自建 image

### 💡 學到的東西
每條一行，說明從錯誤或實驗中得到的具體知識，範例：
- 容器內的 hermes 用戶 UID 10000 與主機 UID 1000 不同，會造成資料寫入權限問題
- Vercel CLI 需登入才能部署，改用 GitHub integration 較簡單

### 📌 重要決定
每條一行，說明採用的方案及放棄的替代方案，範例：
- 採用方案二（自建 Docker image），放棄方案一（docker run alias）因為攜帶不便
- 使用 SSH deploy key 而非 PAT，避免明文 token 風險

要求：
- 必須列出所有重要操作，不能遺漏 hermes-diary、Telegram hook 等專案
- 🔧 至少 5 條，💡 至少 3 條，📌 至少 2 條
- 保持繁體中文
- 不要臆測，純粹根據對話內容

對話記錄：
''' + convo_text + '''
'''

payload = {
    'model': llm_model,
    'max_tokens': 2000,
    'messages': [{'role': 'user', 'content': prompt}]
}

req = urllib.request.Request(
    llm_api_base + '/v1/messages',
    data=json.dumps(payload).encode(),
    headers={
        'Authorization': 'Bearer ' + llm_api_key,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://hermes-diary',
        'X-Title': 'Hermes-Diary',
    },
    method='POST'
)

with urllib.request.urlopen(req, timeout=30) as resp:
    result = json.load(resp)
    summary = result['content'][0]['text']

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(summary)
PYEOF

SUMMARY=$(cat "$SUMMARY_TMP")
rm -f "$SUMMARY_TMP"

if [ -z "$SUMMARY" ]; then
  echo "LLM summarization failed, skipping push."
  exit 1
fi

#------------------- 更新 HTML -------------------
ENTRY_HTML="<div class=\"entry\">
  <div class=\"entry-header\">
    <span class=\"entry-title\">📅 ${TODAY_DISPLAY}</span>
    <div class=\"entry-meta\">
      <span>${MSG_COUNT} 筆對話</span>
      <span class=\"entry-toggle\">▾</span>
    </div>
  </div>
  <div class=\"entry-content\">
    <pre>${SUMMARY}</pre>
  </div>
</div>"

# 把 ENTRY_HTML 寫入 temp 檔，避免 shell injection
ENTRY_TMP=$(mktemp)
echo "$ENTRY_HTML" > "$ENTRY_TMP"

python3 - "$REPO_DIR/index.html" "$ENTRY_TMP" <<'PYEOF'
import sys, re
html_path = sys.argv[1]
entry_path = sys.argv[2]

with open(html_path, 'r', encoding='utf-8') as f:
    html = f.read()
with open(entry_path, 'r', encoding='utf-8') as f:
    entry_html = f.read()

# 移除所有現有 entry div
html = re.sub(
    r'\n  <div class="entry">.*?</div>\n',
    '\n',
    html,
    flags=re.DOTALL
)

# 在 <main>...</main> 裡插入新 entry
html = re.sub(
    r'(<main id="diary-entries">)',
    r'\1\n  ' + entry_html,
    html,
    count=1
)

with open(html_path, 'w', encoding='utf-8') as f:
    f.write(html)
PYEOF

rm -f "$ENTRY_TMP"

#------------------- Git push -------------------
git config --global user.email "hermes@diary"
git config --global user.name "Hermes Diary Bot"
git add -A
git commit -m "Diary update: $TODAY_DISPLAY"
git push origin main

#------------------- Telegram 通知 -------------------
FIRST_LINE=$(echo "$SUMMARY" | head -3 | grep -v '^$' | head -1 | sed 's/^[^\w]*//')
FIRST_LINE=${FIRST_LINE:-"今日摘要已更新"}

COUNT_DONE=$(echo "$SUMMARY" | grep -c '🔧\|💡\|📌' || true)

MESSAGE="📔 Hermes 日記 | ${TODAY_DISPLAY}
${FIRST_LINE}
共 ${MSG_COUNT} 筆對話 · ${COUNT_DONE} 個分類
🔗 ${VERCEL_URL}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "text=${MESSAGE}" \
  -d "parse_mode=HTML" \
  > /dev/null

echo "Done. Pushed and notified."
