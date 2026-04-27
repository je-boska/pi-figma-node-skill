# figma-node

Pi skill for reading Figma node data from a Figma URL.

## Install

```bash
pi install git@github.com:je-boska/pi-figma-node-skill.git
```

## Auth

Create `~/.config/pi/figma-token.json`:

```json
{
  "accessToken": "figd_...",
  "createdAt": "2026-04-27",
  "expiresAt": "2026-07-26",
  "scopes": ["file_content:read"]
}
```

Then:

```bash
chmod 600 ~/.config/pi/figma-token.json
```

## Use

```bash
./scripts/figma-node.sh "https://www.figma.com/design/FILE_KEY/Name?node-id=12-34"
```

See `SKILL.md` for agent instructions.
