---
name: figma-node
description: Fetch and inspect Figma node data from a Figma URL using the Figma REST API. Use when user gives a Figma design/file URL and asks to inspect design, layout, typography, colors, spacing, components, or implement frontend from Figma.
---

# Figma Node

Use this skill when user provides a Figma URL and wants frontend/design implementation guidance.

## Auth

Read token from:

1. `$FIGMA_ACCESS_TOKEN`
2. `~/.config/pi/figma-token.json` (`accessToken` field)
3. legacy fallback `~/.config/pi/figma-token` (raw token)

Never print token.

Token metadata file shape:

```json
{
  "accessToken": "figd_...",
  "createdAt": "2026-04-27",
  "expiresAt": "2026-07-26",
  "scopes": ["file_content:read"]
}
```

Warn if token is expired or expires within 7 days. For 401/403, mention likely expired/revoked token, missing `file_content:read`, or missing account permission to the file.

## Preferred helper

From this skill directory, run:

```bash
./scripts/figma-node.sh "https://www.figma.com/design/FILE_KEY/Name?node-id=12-34"
```

The script:

- extracts file key
- converts URL node id `12-34` to API node id `12:34`
- fetches node JSON to `/tmp/figma-node.json`
- writes compact summary to `/tmp/figma-node-summary.json`
- optionally fetches render URL with `--image`

## Manual URL parsing

Figma URL examples:

```txt
https://www.figma.com/design/FILE_KEY/Name?node-id=12-34
https://www.figma.com/file/FILE_KEY/Name?node-id=12-34
```

Extract:

- `fileKey`: path segment after `/design/` or `/file/`
- `nodeId`: `node-id` query param, with all `-` replaced by `:`

Example:

```txt
node-id=12-34 -> 12:34
```

## Manual fetch

```bash
TOKEN="${FIGMA_ACCESS_TOKEN:-$(python3 - <<'PY'
import json, os
p=os.path.expanduser('~/.config/pi/figma-token.json')
try:
  print(json.load(open(p))['accessToken'])
except Exception:
  p=os.path.expanduser('~/.config/pi/figma-token')
  print(open(p).read().strip() if os.path.exists(p) else '')
PY
)}"

curl -sS \
  -H "X-Figma-Token: $TOKEN" \
  "https://api.figma.com/v1/files/$FILE_KEY/nodes?ids=$NODE_ID" \
  > /tmp/figma-node.json
```

## Inspect useful data

Prefer `jq` summaries before reading full JSON.

Basic node:

```bash
jq '.nodes | to_entries[0].value.document | {
  id,
  name,
  type,
  absoluteBoundingBox,
  constraints,
  layoutMode,
  primaryAxisSizingMode,
  counterAxisSizingMode,
  itemSpacing,
  paddingLeft,
  paddingRight,
  paddingTop,
  paddingBottom,
  fills,
  strokes,
  effects,
  style,
  characters
}' /tmp/figma-node.json
```

Children summary:

```bash
jq '.nodes | to_entries[0].value.document.children[]? | {
  id,
  name,
  type,
  absoluteBoundingBox,
  layoutMode,
  itemSpacing,
  fills,
  style,
  characters
}' /tmp/figma-node.json
```

Text nodes:

```bash
jq '.. | objects | select(.type? == "TEXT") | {
  name,
  characters,
  absoluteBoundingBox,
  style,
  fills
}' /tmp/figma-node.json
```

Colors:

```bash
jq '.. | objects | select(.fills?) | {
  name,
  type,
  fills
}' /tmp/figma-node.json
```

## Optional render/image

Use helper:

```bash
./scripts/figma-node.sh --image "https://www.figma.com/design/FILE_KEY/Name?node-id=12-34"
```

Manual:

```bash
curl -sS \
  -H "X-Figma-Token: $TOKEN" \
  "https://api.figma.com/v1/images/$FILE_KEY?ids=$NODE_ID&format=png&scale=2" \
  > /tmp/figma-image.json
```

Then:

```bash
jq -r '.images[]' /tmp/figma-image.json
```

## Frontend implementation workflow

1. Fetch node JSON with helper.
2. Inspect summary first.
3. If needed, inspect `/tmp/figma-node.json` with focused `jq` queries.
4. Extract dimensions, layout mode, spacing, padding, typography, colors, effects, hierarchy.
5. Compare with existing component files.
6. Implement using project conventions.
7. Mark guesses as `(assumption)` when not directly backed by Figma data.

## Notes

- Figma API uses `:` in node ids. URL uses `-`.
- Large nodes produce large JSON. Use summaries first.
- Do not edit frontend until node data is inspected.
- Do not expose token in code, logs, client bundles, or final answers.
