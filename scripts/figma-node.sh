#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: figma-node.sh [--image] <figma-node-url>

Fetches Figma node JSON and writes:
  /tmp/figma-node.json
  /tmp/figma-node-summary.json
Optional --image also writes:
  /tmp/figma-image.json

Token sources, in order:
  FIGMA_ACCESS_TOKEN
  ~/.config/pi/figma-token.json { accessToken, expiresAt, scopes }
  ~/.config/pi/figma-token
USAGE
}

FETCH_IMAGE=0
if [[ "${1:-}" == "--image" ]]; then
  FETCH_IMAGE=1
  shift
fi

URL="${1:-}"
if [[ -z "$URL" || "$URL" == "-h" || "$URL" == "--help" ]]; then
  usage
  exit 1
fi

TOKEN_JSON="$HOME/.config/pi/figma-token.json"
TOKEN_RAW="$HOME/.config/pi/figma-token"

TOKEN_INFO="$({
python3 - "$TOKEN_JSON" "$TOKEN_RAW" <<'PY'
import json, os, sys
from datetime import date, datetime
json_path, raw_path = sys.argv[1:3]
info = {"accessToken": os.environ.get("FIGMA_ACCESS_TOKEN", ""), "source": "env"}
if not info["accessToken"]:
    if os.path.exists(json_path):
        try:
            data = json.load(open(json_path))
            info = dict(data)
            info["source"] = json_path
        except Exception as e:
            print(json.dumps({"error": f"Could not read token JSON: {e}"}))
            sys.exit(0)
    elif os.path.exists(raw_path):
        info = {"accessToken": open(raw_path).read().strip(), "source": raw_path}
    else:
        info = {"accessToken": "", "source": "missing"}

exp = info.get("expiresAt")
if exp:
    try:
        d = datetime.strptime(exp, "%Y-%m-%d").date()
        days = (d - date.today()).days
        info["daysUntilExpiry"] = days
        if days < 0:
            info["expiryWarning"] = f"expired {-days} days ago"
        elif days <= 7:
            info["expiryWarning"] = f"expires in {days} days"
    except Exception:
        info["expiryWarning"] = "expiresAt not parseable; expected YYYY-MM-DD"

# Do not print token.
redacted = dict(info)
if redacted.get("accessToken"):
    redacted["accessToken"] = "<redacted>"
print(json.dumps({"token": info.get("accessToken", ""), "info": redacted}))
PY
} 2>/dev/null)"

TOKEN="$(python3 - <<'PY' "$TOKEN_INFO"
import json, sys
print(json.loads(sys.argv[1]).get('token',''))
PY
)"

if [[ -z "$TOKEN" ]]; then
  echo "Figma token missing. Set FIGMA_ACCESS_TOKEN or ~/.config/pi/figma-token.json" >&2
  exit 2
fi

python3 - <<'PY' "$TOKEN_INFO" >&2
import json, sys
info=json.loads(sys.argv[1]).get('info', {})
if info.get('expiryWarning'):
    print('Token warning:', info['expiryWarning'])
PY

PARSED="$(python3 - "$URL" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote
url = sys.argv[1]
p = urlparse(url)
parts = [x for x in p.path.split('/') if x]
file_key = None
for marker in ('design', 'file'):
    if marker in parts:
        i = parts.index(marker)
        if i + 1 < len(parts):
            file_key = parts[i + 1]
            break
qs = parse_qs(p.query)
node = (qs.get('node-id') or qs.get('node_id') or [''])[0]
node = unquote(node).replace('-', ':')
if not file_key or not node:
    print(json.dumps({"error": "Could not parse file key and node-id from URL", "pathParts": parts, "query": p.query}))
    sys.exit(3)
print(json.dumps({"fileKey": file_key, "nodeId": node}))
PY
)"

FILE_KEY="$(python3 - <<'PY' "$PARSED"
import json, sys
print(json.loads(sys.argv[1])['fileKey'])
PY
)"
NODE_ID="$(python3 - <<'PY' "$PARSED"
import json, sys
print(json.loads(sys.argv[1])['nodeId'])
PY
)"

API_URL="https://api.figma.com/v1/files/${FILE_KEY}/nodes?ids=${NODE_ID}"
HTTP_CODE="$(curl -sS -w '%{http_code}' -o /tmp/figma-node.json -H "X-Figma-Token: $TOKEN" "$API_URL")"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Figma API failed: HTTP $HTTP_CODE" >&2
  if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "Likely expired/revoked token, missing file_content:read, or account lacks file access." >&2
  fi
  echo "Response saved: /tmp/figma-node.json" >&2
  exit 4
fi

python3 - /tmp/figma-node.json /tmp/figma-node-summary.json "$FILE_KEY" "$NODE_ID" <<'PY'
import json, sys
src, dst, file_key, node_id = sys.argv[1:5]
data = json.load(open(src))
node_entry = data.get('nodes', {}).get(node_id) or next(iter(data.get('nodes', {}).values()), None)
doc = (node_entry or {}).get('document') or {}

def pick(o, keys):
    return {k: o[k] for k in keys if k in o}

def rgba(fill):
    c = fill.get('color') or {}
    if not c: return None
    return {
        'r': round(c.get('r', 0)*255),
        'g': round(c.get('g', 0)*255),
        'b': round(c.get('b', 0)*255),
        'a': round(c.get('a', fill.get('opacity', 1)), 3),
    }

def compact(n, depth=0, max_depth=3):
    out = pick(n, [
        'id','name','type','absoluteBoundingBox','constraints','layoutMode',
        'primaryAxisSizingMode','counterAxisSizingMode','primaryAxisAlignItems',
        'counterAxisAlignItems','itemSpacing','paddingLeft','paddingRight',
        'paddingTop','paddingBottom','style','characters','cornerRadius',
        'strokeWeight','effects'
    ])
    if 'fills' in n:
        out['fills'] = [{k:v for k,v in f.items() if k in ('type','visible','opacity','blendMode')} | ({'rgba': rgba(f)} if rgba(f) else {}) for f in n.get('fills') or []]
    if 'strokes' in n:
        out['strokes'] = [{k:v for k,v in s.items() if k in ('type','visible','opacity','blendMode')} | ({'rgba': rgba(s)} if rgba(s) else {}) for s in n.get('strokes') or []]
    children = n.get('children') or []
    out['childCount'] = len(children)
    if depth < max_depth and children:
        out['children'] = [compact(c, depth+1, max_depth) for c in children]
    return out

texts=[]
def walk(n):
    if n.get('type') == 'TEXT':
        texts.append(pick(n, ['id','name','characters','absoluteBoundingBox','style','fills']))
    for c in n.get('children') or []:
        walk(c)
walk(doc)

summary = {
    'fileKey': file_key,
    'nodeId': node_id,
    'root': compact(doc),
    'textNodes': texts[:50],
    'textNodeCount': len(texts),
}
json.dump(summary, open(dst, 'w'), indent=2)
print(json.dumps(summary, indent=2))
PY

if [[ "$FETCH_IMAGE" == "1" ]]; then
  IMG_URL="https://api.figma.com/v1/images/${FILE_KEY}?ids=${NODE_ID}&format=png&scale=2"
  IMG_CODE="$(curl -sS -w '%{http_code}' -o /tmp/figma-image.json -H "X-Figma-Token: $TOKEN" "$IMG_URL")"
  if [[ "$IMG_CODE" != "200" ]]; then
    echo "Figma image API failed: HTTP $IMG_CODE" >&2
    echo "Response saved: /tmp/figma-image.json" >&2
    exit 5
  fi
  echo "Image response saved: /tmp/figma-image.json" >&2
fi

echo "Saved raw: /tmp/figma-node.json" >&2
echo "Saved summary: /tmp/figma-node-summary.json" >&2
