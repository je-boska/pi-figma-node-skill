#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: figma-node.sh [--image] [--depth N] <figma-node-url>

Fetches Figma node JSON and writes:
  /tmp/figma-node.json             raw API response; do not paste into chat
  /tmp/figma-node-summary.json     compact LLM-friendly summary
Optional --image also writes:
  /tmp/figma-image.json

Default compact depth: 4. Increase only when children are truncated.

Token sources, in order:
  FIGMA_ACCESS_TOKEN
  ~/.config/pi/figma-token.json { accessToken, expiresAt, scopes }
  ~/.config/pi/figma-token
USAGE
}

FETCH_IMAGE=0
DEPTH=4
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) FETCH_IMAGE=1; shift ;;
    --depth) DEPTH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

URL="${1:-}"
if [[ -z "$URL" ]]; then usage; exit 1; fi
if ! [[ "$DEPTH" =~ ^[0-9]+$ ]]; then echo "--depth must be integer" >&2; exit 1; fi

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
        if days < 0: info["expiryWarning"] = f"expired {-days} days ago"
        elif days <= 7: info["expiryWarning"] = f"expires in {days} days"
    except Exception:
        info["expiryWarning"] = "expiresAt not parseable; expected YYYY-MM-DD"

redacted = dict(info)
if redacted.get("accessToken"): redacted["accessToken"] = "<redacted>"
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
for marker in ('design', 'file', 'proto', 'board', 'slides'):
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

python3 - /tmp/figma-node.json /tmp/figma-node-summary.json "$FILE_KEY" "$NODE_ID" "$DEPTH" <<'PY'
import json, sys
src, dst, file_key, node_id, max_depth_s = sys.argv[1:6]
max_depth = int(max_depth_s)
data = json.load(open(src))
node_entry = data.get('nodes', {}).get(node_id) or next(iter(data.get('nodes', {}).values()), None)
doc = (node_entry or {}).get('document') or {}

# Compact transform inspired by pi-figma: hex colors, rounded bboxes, defaults dropped.
def bbox(n):
    b = n.get('absoluteBoundingBox')
    if not b: return None
    return [round(b.get('x',0)), round(b.get('y',0)), round(b.get('width',0)), round(b.get('height',0))]

def color_to_str(c, opacity=1):
    a = (c.get('a', 1) if c else 1) * (opacity if opacity is not None else 1)
    r = max(0, min(255, round((c or {}).get('r',0)*255)))
    g = max(0, min(255, round((c or {}).get('g',0)*255)))
    b = max(0, min(255, round((c or {}).get('b',0)*255)))
    if a >= 0.999: return f'#{r:02x}{g:02x}{b:02x}'
    return f'rgba({r},{g},{b},{round(a,2)})'

def first_paint(paints):
    for p in paints or []:
        if p.get('visible') is False: continue
        t = p.get('type')
        if t == 'SOLID' and p.get('color'):
            return color_to_str(p.get('color'), p.get('opacity', 1))
        if t == 'IMAGE': return '<image>'
        if isinstance(t, str) and t.startswith('GRADIENT_'): return '<gradient>'
    return None

def descendants(n):
    cs = n.get('children') or []
    return len(cs) + sum(descendants(c) for c in cs)

def text_style(s):
    if not s: return None
    out = {}
    for src_key, dst_key in [
        ('fontFamily','font'),('fontPostScriptName','postScript'),('fontSize','size'),
        ('fontWeight','weight'),('lineHeightPx','lineHeight'),('letterSpacing','letterSpacing'),
        ('textCase','case'),('textAlignHorizontal','align')
    ]:
        if src_key in s: out[dst_key] = s[src_key]
    return out or None

def compact(n, depth=0, path=''):
    out = {'id': n.get('id'), 'name': n.get('name'), 'type': n.get('type')}
    bb = bbox(n)
    if bb: out['bbox'] = bb
    if n.get('layoutMode') == 'HORIZONTAL': out['layout'] = 'H'
    elif n.get('layoutMode') == 'VERTICAL': out['layout'] = 'V'
    pad = [n.get('paddingTop',0) or 0, n.get('paddingRight',0) or 0, n.get('paddingBottom',0) or 0, n.get('paddingLeft',0) or 0]
    if any(pad): out['padding'] = pad
    if n.get('itemSpacing',0): out['gap'] = n.get('itemSpacing')
    if n.get('cornerRadius',0): out['radius'] = n.get('cornerRadius')
    fill = first_paint(n.get('fills'))
    if fill: out['fill'] = fill
    stroke = first_paint(n.get('strokes'))
    if stroke and n.get('strokeWeight',0): out['stroke'] = {'color': stroke, 'width': n.get('strokeWeight')}
    if n.get('effects'):
        out['effects'] = [e.get('type') for e in n.get('effects', []) if e.get('visible', True)]
    if n.get('type') == 'TEXT':
        if 'characters' in n: out['text'] = n.get('characters')
        ts = text_style(n.get('style'))
        if ts: out['textStyle'] = ts
    children = [c for c in (n.get('children') or []) if c.get('visible') is not False]
    if children:
        if depth >= max_depth:
            out['truncatedChildren'] = sum(1 + descendants(c) for c in children)
        else:
            out['children'] = [compact(c, depth+1, f"{path}/{n.get('name','')}") for c in children]
    return out

texts=[]
def walk(n, parts=()):
    here = parts + (n.get('name') or '',)
    if n.get('type') == 'TEXT' and n.get('characters'):
        texts.append({
            'id': n.get('id'),
            'path': ' / '.join([p for p in here if p]),
            'text': n.get('characters'),
            'bbox': bbox(n),
            'style': text_style(n.get('style')),
            'fill': first_paint(n.get('fills')),
        })
    for c in n.get('children') or []: walk(c, here)
walk(doc)

summary = {
    'fileKey': file_key,
    'nodeId': node_id,
    'depth': max_depth,
    'root': compact(doc),
    'textNodes': texts[:80],
    'textNodeCount': len(texts),
}
json.dump(summary, open(dst, 'w'), separators=(',', ':'))
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
echo "Saved compact summary: /tmp/figma-node-summary.json" >&2
