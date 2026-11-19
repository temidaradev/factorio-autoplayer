# Factorio Autoplayer for macOS

Use a vision-capable MCP agent to play an ordinary Factorio or Space Age save on a Mac. The player observes the Factorio window, then uses native foreground mouse and keyboard events. Factorio handles placement, inventory, crafting, research, combat and time. The player uses no mods, RCON, Lua commands, or save edits.

Normal input leaves an otherwise eligible save eligible for Steam achievements. Factorio's usual achievement conditions still apply. See [Factorio's achievement rules](https://wiki.factorio.com/Achievements#Disabling_achievements).

## Build and connect

Requires macOS 14 or newer and the Swift 5.9+ toolchain. Run from this repository:

```sh
swift test
swift build -c release
.build/release/factorio-player doctor
```

The diagnostic reports whether Factorio is running and whether the process has Screen Recording and Accessibility access. The program checks these permissions without requesting or modifying them. Screen Recording is needed for screenshots. Accessibility is needed to deliver foreground input.

## Play with two agents

Launch Factorio and open the intended save. Then start a Codex CLI session with the project launcher:

```sh
./play-team "Build and launch the first working Space Age platform"
```

The planner turns verified game state into one milestone at a time. The player controls Factorio and returns visible proof, inventory changes and any blockers. The main session relays their messages. The launcher supplies the Factorio connection for that session. It uses the two [project-scoped Codex agent definitions](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents).

## Connect another MCP session

In your MCP client's local configuration, use the absolute path of the built executable. For a Codex CLI installation, from this repository run:

```sh
codex mcp add factorio-player -- "$PWD/.build/release/factorio-player" mcp --allow-input
```

Start a session with that MCP server available, launch Factorio and open the world you want the agent to play. Ask the agent to follow [the gameplay playbook](docs/playbook.md) and name the first milestone. The MCP process is local and makes no outbound requests. The connected client handles the agent and receives the game frames.

Omit `--allow-input` for observation only. Switch away from Factorio to stop input during a batch, or stop the MCP session. The agent should wait for you before focusing the game again.

## Controls

| Tool | What it does |
|---|---|
| `factorio_status` | Reports the game and permission status. |
| `factorio_focus` | Requests focus for the already open game. |
| `factorio_observe` | Returns a PNG and a frame ID. Coordinates are pixels relative to the PNG. |
| `factorio_act` | Sends one bounded batch for the most recent frame. |

Example arguments for `factorio_act`, using a fresh frame ID and a location observed in that frame:

```json
{
  "frameId": "copy-from-factorio_observe",
  "actions": [
    {"type": "click", "at": {"x": 820, "y": 440}, "button": "right", "durationMs": 950},
    {"type": "key", "key": "e"}
  ]
}
```

Use `key` with a duration for movement, including diagonals like `w+d`. Use `move`, `click`, `drag` and `scroll` for the pointer. Drag takes `at` and `to`. Scroll takes signed `ticks`, positive for up. Click and drag support `shift` and `control`. The `text` action is for short recipe searches and save names. It uses US ANSI key positions, so a different keyboard layout can produce different characters.

A batch accepts up to 12 actions with a timing budget of roughly four seconds. The player checks that the visible Factorio window still matches the frame, that the game owns foreground focus and that pointer targets are visible. A batch consumes its frame ID. Observe again to verify the game result before sending another batch. Failed or partly executed batches report how far they got. An action that stopped mid-hold may still have affected the game.

For a read-only picture outside MCP, run `.build/release/factorio-player snapshot /absolute/path/to/new-frame.png`.

## Design references

Astra Claw demonstrates bounded visual play through a vanilla Factorio client. Open Computer Use documents the macOS foreground HID event approach. This project combines those ideas in a Swift executable targeting the visible Factorio window, with a separate agent supplying gameplay decisions. [Astra Claw](https://github.com/zackhs/astra-claw) · [Open Computer Use](https://github.com/opensymph/open-computer-use)
