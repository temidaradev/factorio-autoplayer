# Factorio Autoplayer

Use a vision-capable MCP agent to play an ordinary Factorio or Space Age save. The background launcher runs Factorio on a private Linux display. The native macOS launcher drives the foreground Factorio window. Both use screenshots and normal keyboard and mouse input for placement, inventory, crafting, research and combat.

Normal input leaves an otherwise eligible save eligible for Steam achievements. Factorio's usual achievement conditions still apply. See [Factorio's achievement rules](https://wiki.factorio.com/Achievements#Disabling_achievements).

## Run on an x86-64 Linux computer

Run these steps on the Linux computer. Install Git, [Docker Engine with Buildx](https://docs.docker.com/engine/install/), and the [Codex CLI](https://learn.chatgpt.com/docs/codex/cli). Sign in to Codex on that machine. The same user who launches Codex needs access to the running local Docker daemon. The container supplies its own display and software graphics, so the Linux host can run without a monitor or desktop session.

```sh
uname -m       # Expected: x86_64
docker version # Check that both Client and Server are listed
docker buildx version
codex --version
git clone https://github.com/temidaradev/factorio-autoplayer.git
cd factorio-autoplayer
```

Download the licensed **full Factorio: Space Age Linux x64** archive. Choose a version that can open your save. Copy your Nauvis save ZIP to the Linux computer, for example into `~/Downloads`. Extract the game archive and start the background client. Replace the filenames below with yours. The extracted directory should contain `bin/x64/factorio` and `data/`. [Factorio downloads](https://www.factorio.com/download)

```sh
mkdir -p "$HOME/games"
tar -xf "$HOME/Downloads/factorio-space-age_linux_2.1.24.tar.xz" -C "$HOME/games"
./background-game start "$HOME/games/factorio" "$HOME/Downloads/Nauvis.zip"
./background-game logs
```

Once the log shows `Factorio initialised`, launch the planner and player in the same repository. Keep the Codex session running while they play. The CLI connects to the background client on that Linux computer.

```sh
./play-team --background "Continue the loaded Nauvis save until the first working space platform"
```

On first import, the launcher copies the ZIP to `.factorio-background/saves/start.zip` and opens the copy. To start fresh or resume a previously saved background game, omit the ZIP and have the player use Factorio's **New game** or **Load game** menu. Ask the player to save in-game before running `./background-game stop`. The saved ZIP remains in `.factorio-background/saves/` and can be copied back to the Mac. This setup runs the standalone client. Save eligibility is preserved through normal play, while Steam unlocks during the standalone session are unverified. [Factorio achievement rules](https://wiki.factorio.com/Achievements)

## Build the native macOS player

Requires macOS 14 or newer and the Swift 5.9+ toolchain. Run from this repository:

```sh
swift test
swift build -c release
.build/release/factorio-player doctor
```

The diagnostic reports whether Factorio is running and whether the process has Screen Recording and Accessibility access. The program checks these permissions without requesting or modifying them. Screen Recording is needed for screenshots. Accessibility is needed to deliver foreground input.

## Play with two agents on macOS

Launch Factorio and open the intended save. Then start a Codex CLI session with the project launcher:

```sh
./play-team "Build and launch the first working Space Age platform"
```

The planner turns verified game state into one milestone at a time. The player controls Factorio and returns visible proof, inventory changes and any blockers. The main session relays their messages. The launcher supplies the Factorio connection for that session. It uses the two [project-scoped Codex agent definitions](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents).

## Play in the background on a Mac

Start Docker Desktop and extract the licensed **full Linux Space Age client** from Factorio into its own directory. Use Linux arm64 on Apple silicon or Linux x64 on an Intel Mac. For an existing save, use a client version that can load it. [Factorio downloads](https://factorio.com/download)

```sh
./background-game start "/path/to/extracted/factorio" "/path/to/Nauvis.zip"
./play-team --background "Continue Nauvis until the first working space platform"
```

Omit the save argument to start at the game menu or resume a save already in the background profile. Imported saves are copied to `.factorio-background/saves/`. The game install and import are mounted read-only. The background game has its own Linux display, pointer, and keyboard, so switching Mac apps has no effect on its controls. Save through the in-game menu before running `./background-game stop`. Use `./background-game logs` if startup fails.

This runs the standalone Linux client. It uses normal game input and leaves save eligibility intact. Steam unlocks aren't verified in standalone mode. The background profile keeps its own config and saves, and the native Mac game can remain closed. [Factorio achievement rules](https://wiki.factorio.com/Achievements)

## Connect another native macOS MCP session

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

A batch accepts up to 12 actions with a timing budget of roughly four seconds. In background mode, focus is checked on the private display. In native macOS mode, focus and pointer visibility are checked on the Mac. A batch consumes its frame ID. Observe again to verify the game result before sending another batch. Failed or partly executed batches report how far they got. An action that stopped mid-hold may still have affected the game.

For a read-only picture outside MCP, run `.build/release/factorio-player snapshot /absolute/path/to/new-frame.png`.

## Design references

Astra Claw demonstrates bounded visual play through a vanilla Factorio client. Open Computer Use documents the macOS foreground HID event approach. This project combines those ideas in a Swift executable targeting the visible Factorio window, with a separate agent supplying gameplay decisions. [Astra Claw](https://github.com/zackhs/astra-claw) · [Open Computer Use](https://github.com/opensymph/open-computer-use)
