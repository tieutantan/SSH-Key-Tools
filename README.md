
## SSH Key Tools

Script `ssh-tools.sh` creates ED25519 SSH key pairs for GitHub repositories.  
Supports **multiple repositories** on the same machine — each repo gets its own key without overwriting others.

### Install

```shell
git clone git@github.com:tieutantan/SSH-Key-Tools.git
```

### Usage

```shell
# Interactive mode (menu)
./ssh-tools.sh

# Generate key for 1 repository
./ssh-tools.sh git@github.com:user/repo.git

# Generate keys for multiple repositories at once
./ssh-tools.sh git@github.com:user/repo-a.git git@github.com:user/repo-b.git

# List all existing SSH keys and clone commands
./ssh-tools.sh --list

# Remove key for a repository
./ssh-tools.sh --remove <repo_name>

# Show help
./ssh-tools.sh --help
```

### Key naming convention

| Component | Format | Example |
|---|---|---|
| Key file | `~/.ssh/id_ed25519_<repo_name>` | `~/.ssh/id_ed25519_dudu-bot` |
| Host alias | `github-<repo_name>` | `github-dudu-bot` |

### SSH Config

The script automatically adds a host alias to `~/.ssh/config`, **without overwriting** the original `github.com` entry:

```
Host github-dudu-bot
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_dudu-bot
    AddKeysToAgent yes
    IdentitiesOnly yes
```

Clone command using the host alias:

```shell
git clone git@github-dudu-bot:user/dudu-bot.git
```

### Add to GitHub Deploy Keys

After running the script, copy the displayed public key and add it at:

```
Repository → Settings → Deploy keys → Add deploy key
```