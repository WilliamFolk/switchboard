# Switchboard

A Windows launcher for [Claude Code](https://claude.com/claude-code) running inside WSL.
Pick a Claude account, pick a project, then open it in VS Code — either as the project
itself, or as a separate **agent** on its own git branch and worktree, so several Claude
sessions can work on the same project in parallel. When an agent is done, Claude merges
its work back for you.

## Requirements

On Windows:

- WSL 2 with an Ubuntu distribution
- VS Code with the **WSL** extension (`ms-vscode-remote.remote-wsl`)

Inside Ubuntu (WSL):

- Claude Code (`claude`) — installed *inside* WSL; a Windows install does not count
- `git`, with your name and email set
- `jq`

And a Claude account to sign in with.

## Setup from scratch

1. **Install WSL and Ubuntu.** In PowerShell opened as administrator:

   ```powershell
   wsl --install -d Ubuntu
   ```

   Restart if asked, then open **Ubuntu** from the Start menu once and create your Linux user.

2. **Install the tools inside Ubuntu:**

   ```bash
   sudo apt update && sudo apt install -y git jq
   curl -fsSL https://claude.ai/install.sh | bash
   git config --global user.name "Your Name"
   git config --global user.email you@example.com
   ```

   Open a new Ubuntu window afterwards and check that `claude --version` works.

3. **Install VS Code** on Windows and add the **WSL** extension. In a new Ubuntu window,
   `code .` should open VS Code connected to WSL.

4. **Get Switchboard** — clone this repository, or download it as a ZIP and unpack it,
   anywhere you like (for example `C:\Tools\switchboard`).

5. **Run `Setup-Switchboard.bat`.** It checks everything listed under Requirements, lets
   you pick the Ubuntu distribution and the folder that holds your projects, and creates a
   `Switchboard` shortcut (optionally on the Desktop too). Your choices are saved in
   `switchboard.local.json`, which stays on your PC and is not part of the repository.

6. **Start Switchboard** from the shortcut. The first time, the `Default` account shows
   *not signed in* — select it and finish the login in your browser. Press `H` on the
   accounts or projects screen for a short guide.

## Projects and agents

Every folder directly inside your projects folder is a project. To start a new one, press
`N` on the projects screen: it creates a git repository with a first commit, ready for
agents. To work on an existing repository, clone it into the projects folder.

Agents need a git repository with at least one commit. In a folder without git, Switchboard
offers only *Open the project itself*.

## Updating

From the Switchboard folder:

```bash
git pull
```

Your `switchboard.local.json` and shortcut are untouched by updates.

## Troubleshooting

| Problem | What to do |
|---|---|
| Windows says it protected your PC when starting a `.bat` | The files came from a downloaded ZIP. Click *More info* → *Run anyway*, or clone the repository with git instead. |
| "Could not determine HOME in WSL distribution" | The configured distribution does not exist on this PC. Run `Setup-Switchboard.bat` again. |
| No projects listed | Press `N` on the projects screen, or clone a repository into the projects folder. |
| No *Open a new agent* in a project | The folder is not a git repository or has no commits yet. Run `git init` there and make a first commit (or ask Claude to). |
| VS Code does not open | `code .` has to work inside Ubuntu, which needs the WSL extension in VS Code. |
| An account shows *not signed in*, or *sign-in expired* in orange | Select it to sign in. An expired account keeps its settings and history; its plan, tier and usage stay frozen until you do. |
