# FastMix AI MCP bridge

stdio MCP → `/tmp/fastmix-ai.sock`.

## Tools

- `fastmix_ping` — health + live state
- `fastmix_list_commands` — catalog
- `fastmix_<cmd>` — **one tool per real socket command** (~40 from `handleCommand`)
- `fastmix_cmd` — escape hatch

There are **not** 100+ socket commands in the app. Fake tools would be a lie. When you add a cmd in `main.zig`, add it to `COMMANDS` in `index.mjs`.

## Reload

After editing: **MCP: Restart Servers** / Reload Window so Cursor re-lists tools.
