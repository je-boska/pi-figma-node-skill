# figma-node

Pi skill for fetching compact Figma node data from a Figma URL.

## Install

```bash
pi install git:git@github.com:je-boska/pi-figma-node-skill.git
```

Then run `/reload` in Pi if already running.

You need a Figma API token with `file_content:read`.

Store it at `~/.config/pi/figma-token.json`:

```json
{ "accessToken": "figd_..." }
```
