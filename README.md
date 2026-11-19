# Factorio Autoplayer for NixOS x86-64

Run Factorio: Space Age on a private Linux display. A planner chooses the next factory milestone and a player carries it out using screenshots and normal keyboard and mouse input. You can run it over SSH on a computer without a monitor or desktop session.

## 1. Configure NixOS

Add these settings to your existing NixOS configuration, typically `/etc/nixos/configuration.nix` or the host module in your flake. Replace `yourusername` with the Linux account that will run Codex. The `docker` group grants control of the system Docker daemon, which is equivalent to root access. Add only a trusted account. [NixOS Docker documentation](https://wiki.nixos.org/wiki/Docker#System_setup)

```nix
{ pkgs, ... }:
{
  virtualisation.docker.enable = true;
  users.users.yourusername.extraGroups = [ "docker" ];

  environment.systemPackages = with pkgs; [
    git
    codex
  ];
}
```

Merge these settings into the options you already have. Apply your configuration with `sudo nixos-rebuild switch` or your usual flake rebuild command. Sign out and back in so group membership takes effect. Then run the following as your regular user:

```sh
uname -m        # Expected: x86_64
docker version  # Both Client and Server should be listed
docker buildx version
codex --version
codex login

git clone https://github.com/temidaradev/factorio-autoplayer.git
cd factorio-autoplayer
```

If you're signing in over SSH, use `codex login --device-auth` if your account supports device authentication. [Codex CLI](https://learn.chatgpt.com/docs/codex/cli)

## 2. Start Factorio

Download the licensed full **Factorio: Space Age Linux x64** archive and copy it to the NixOS machine. Copy your existing save ZIP there as well. Use a game version that can open the save. The extracted directory should contain `bin/x64/factorio` and `data/`. [Factorio downloads](https://www.factorio.com/download)

Replace the archive and save filenames in this example with your own:

```sh
mkdir -p "$HOME/games"
tar -xf "$HOME/Downloads/YOUR_SPACE_AGE_LINUX_X64_ARCHIVE.tar.xz" -C "$HOME/games"

./background-game start "$HOME/games/factorio" "$HOME/Downloads/Nauvis.zip"
./background-game logs
```

The first start builds the Docker image. Check the logs for `Factorio initialised`. The launcher copies the supplied ZIP to `.factorio-background/saves/start.zip` and opens the copy. The original archive remains read-only inside the container.

## 3. Run the two agents

```sh
./play-team --background "Continue the loaded Nauvis save until the first working space platform"
```

The launcher configures the Factorio MCP connection for that Codex session. The planner issues one milestone at a time. The player verifies each result in the game before reporting back. Keep the Codex session running while they play. If you connect over SSH, start the session inside a terminal multiplexer to keep it running across disconnects. [Codex custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents)

## Save, stop, or resume

Ask the player to save through Factorio's game menu. The save ZIP will be in `.factorio-background/saves/` on the NixOS machine. Then stop the private game client:

```sh
./background-game stop
```

To resume, start without passing the original ZIP again. The private profile still contains the imported and newly saved worlds:

```sh
./background-game start "$HOME/games/factorio"
./play-team --background "Load my saved Nauvis game and continue building the space platform"
```

The container runs the standalone client and uses regular game inputs. The save retains its normal achievement eligibility. Steam unlocks during the standalone session are unverified. [Factorio achievement rules](https://wiki.factorio.com/Achievements#Disabling_achievements)

## Connect your own MCP client

Run `./background-game mcp --allow-input` as a stdio MCP server while the background client is running. Omit `--allow-input` for observation only. The game accepts one input-enabled session at a time. See the [gameplay playbook](docs/playbook.md) for operating instructions.
