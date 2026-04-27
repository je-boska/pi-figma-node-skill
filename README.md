# figma-node

Pi skill for reading Figma node data from a Figma URL.

## Install

Clone/copy this repo into a Pi skill location, for example:

```bash
~/.pi/agent/skills/figma-node
```

Or install from git once hosted:

```bash
pi install git:<repo-url>
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
