
## SSH Key Tools

Automated SSH key generation and management for **multiple git repositories** across **any provider** — GitHub, GitLab, Bitbucket, or custom SSH hosts.  
Each repo gets its own dedicated SSH key without overwriting others.

### Install

```shell
git clone https://github.com/tieutantan/SSH-Key-Tools.git
cd SSH-Key-Tools
chmod +x ssh-tools.sh
```

### Usage

```shell
# Interactive mode (menu)
./ssh-tools.sh

# Generate key for a GitHub repository
./ssh-tools.sh git@github.com:user/repo.git

# Generate key for a GitLab project
./ssh-tools.sh git@gitlab.com:group/project.git

# Generate keys for multiple providers at once
./ssh-tools.sh git@github.com:user/repo.git git@bitbucket.org:team/project.git

# List all existing SSH keys and clone commands
./ssh-tools.sh --list

# Remove key for a repository
./ssh-tools.sh --remove <repo_name>

# Show help
./ssh-tools.sh --help
```

The provider (github, gitlab, bitbucket, etc.) is **auto-detected** from the URL.

### Key naming convention

| Component | Format | Example |
|---|---|---|
| Key file | `~/.ssh/id_ed25519_<repo_name>` | `~/.ssh/id_ed25519_my-app` |
| Host alias | `<provider>-<repo_name>` | `github-my-app`, `gitlab-my-app` |

### SSH Config

The script automatically adds a host alias to `~/.ssh/config`, **without overwriting** the original host entry:

```
Host github-my-app
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_my-app
    AddKeysToAgent yes
    IdentitiesOnly yes
```

Clone command using the host alias:

```shell
git clone git@github-my-app:user/my-app.git
```

### Add Deploy Key

After running the script, copy the displayed public key and add it to your git provider:

```
Repository → Settings → Deploy keys → Add deploy key
```
