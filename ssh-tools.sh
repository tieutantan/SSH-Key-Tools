#!/bin/bash

################################################################################
# SSH Key Generation Script
# Purpose: Generate SSH key pairs for multiple git repositories
#          Supports GitHub, GitLab, Bitbucket, and any custom SSH git host.
# Usage:
#   Interactive mode:        ./ssh-tools.sh
#   Single repository:       ./ssh-tools.sh git@github.com:user/repo.git
#   Multiple repositories:   ./ssh-tools.sh repo1.git repo2.git repo3.git
#   List all keys:           ./ssh-tools.sh --list
#   Remove a key:            ./ssh-tools.sh --remove <repo_name>
#   Show help:               ./ssh-tools.sh --help
#
# Each repository gets its own key: ~/.ssh/id_ed25519_<repo_name>
# SSH config uses Host aliases: Host <provider>-<repo_name>
#   where <provider> is detected from the URL (e.g. github, bitbucket, gitlab).
# The original host entry (e.g. github.com) is never overwritten.
#
# NOTE: This script intentionally does NOT use set -e.
# We use explicit error handling everywhere for clarity and compatibility.
################################################################################

# ═══════════════════════════════════════════════════════════════════════════
# COLOR & FORMATTING
# ═══════════════════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║  $1${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_subheader() {
    echo -e "${CYAN}${BOLD}─── $1 ───${NC}"
}

print_step()    { echo -e "${CYAN}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════
SSH_DIR="$HOME/.ssh"
SSH_CONFIG_FILE="$SSH_DIR/config"

# These are set by detect_key_type()
KEY_TYPE=""
KEY_PREFIX=""

# All supported key prefixes (used by list, remove, and detect functions)
SUPPORTED_KEY_PREFIXES=("id_ed25519" "id_rsa")

# These are detected from the git URL per-repository
PROVIDER=""       # e.g. github, bitbucket, gitlab
PROVIDER_HOST=""  # e.g. github.com, bitbucket.org, gitlab.com
HOST_PREFIX=""    # alias prefix, same as provider name

# ═══════════════════════════════════════════════════════════════════════════
# DETECT KEY TYPE
# ═══════════════════════════════════════════════════════════════════════════

detect_key_type() {
    # First ensure ssh-keygen exists
    if ! command -v ssh-keygen &> /dev/null; then
        print_error "'ssh-keygen' not found. Install it with: apt-get install openssh-client -y"
        exit 1
    fi

    print_step "Checking supported SSH key types..."

    local test_dir
    test_dir="/tmp/ssh-tools-test.$$"
    mkdir -p "$test_dir" 2>/dev/null || {
        print_error "Cannot create temp directory: $test_dir"
        exit 1
    }

    local test_key="${test_dir}/test_key"

    # Try ED25519 first
    printf "  Testing ED25519 support... "
    if ssh-keygen -t ed25519 -f "$test_key" -N "" -C "test" > /dev/null 2>&1; then
        printf "%s%s%s\n" "$GREEN" "supported" "$NC"
        KEY_TYPE="ed25519"
        KEY_PREFIX="id_ed25519"
        rm -rf "$test_dir"
        print_success "Using ED25519 keys"
        return 0
    fi
    printf "%s%s%s\n" "$YELLOW" "not supported" "$NC"

    # Fallback to RSA 4096
    printf "  Testing RSA 4096 support... "
    if ssh-keygen -t rsa -b 4096 -f "$test_key" -N "" -C "test" > /dev/null 2>&1; then
        printf "%s%s%s\n" "$GREEN" "supported" "$NC"
        KEY_TYPE="rsa"
        KEY_PREFIX="id_rsa"
        rm -rf "$test_dir"
        print_warning "ED25519 not supported. Falling back to RSA 4096."
        return 0
    fi
    printf "%s%s%s\n" "$RED" "failed" "$NC"

    rm -rf "$test_dir"
    print_error "ssh-keygen is available but neither ED25519 nor RSA 4096 work."
    print_error "Try: apt-get update && apt-get install --reinstall openssh-client -y"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Detect git provider from URL and set PROVIDER / PROVIDER_HOST / HOST_PREFIX
# Input:  git@github.com:user/repo.git
#         git@bitbucket.org:user/repo.git
#         git@gitlab.com:user/repo.git
detect_provider() {
    local url="$1"
    if [[ "$url" == *"@github.com"* ]]; then
        PROVIDER="github"
        PROVIDER_HOST="github.com"
    elif [[ "$url" == *"@bitbucket.org"* ]]; then
        PROVIDER="bitbucket"
        PROVIDER_HOST="bitbucket.org"
    elif [[ "$url" == *"@gitlab.com"* ]]; then
        PROVIDER="gitlab"
        PROVIDER_HOST="gitlab.com"
    else
        # Extract host from custom git URL: git@host:path/repo.git or ssh://git@host/path/repo.git
        if [[ "$url" =~ ^git@([^:]+): ]]; then
            PROVIDER="${BASH_REMATCH[1]}"
            PROVIDER_HOST="${BASH_REMATCH[1]}"
        elif [[ "$url" =~ ^ssh://git@([^/]+) ]]; then
            local extracted="${BASH_REMATCH[1]}"
            # Strip port number if present (e.g. github.com:22 -> github.com)
            PROVIDER="${extracted%:*}"
            PROVIDER_HOST="${extracted%:*}"
        else
            print_error "Unrecognized git URL format: $url"
            print_error "Expected format: git@<host>:user/repo.git"
            exit 1
        fi
    fi
    HOST_PREFIX="$PROVIDER"
}

# Extract repo name from a git SSH URL
# Input:  git@github.com:user/My-Repo.git  or  git@bitbucket.org:user/My-Repo.git
# Output: my-repo
parse_repo_name() {
    local url="$1"
    local repo_full
    # Extract everything after the first colon (git@host:...), strip .git suffix
    repo_full="${url#*:}"
    repo_full="${repo_full%.git}"
    echo "$repo_full" | sed 's/.*\///' | tr '[:upper:]' '[:lower:]'
}

# Extract full owner/repo from URL (for clone command display)
# Input:  git@github.com:user/My-Repo.git
# Output: user/My-Repo
parse_repo_full() {
    local url="$1"
    local repo_full
    repo_full="${url#*:}"
    repo_full="${repo_full%.git}"
    echo "$repo_full"
}

# Get SSH key path by repo name
get_key_path() {
    local name="$1"
    echo "$SSH_DIR/${KEY_PREFIX}_${name}"
}

# Get host alias by repo name
get_host_alias() {
    local name="$1"
    echo "${HOST_PREFIX}-${name}"
}

# Ensure SSH directory exists
ensure_ssh_dir() {
    if [ ! -d "$SSH_DIR" ]; then
        mkdir -p "$SSH_DIR" || {
            print_error "Cannot create SSH directory: $SSH_DIR"
            exit 1
        }
        chmod 700 "$SSH_DIR"
        print_success "SSH directory created at $SSH_DIR"
    fi
}

# Ensure SSH config file exists
ensure_ssh_config() {
    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        touch "$SSH_CONFIG_FILE" || {
            print_error "Cannot create SSH config file: $SSH_CONFIG_FILE"
            exit 1
        }
        chmod 600 "$SSH_CONFIG_FILE"
        print_step "Created new SSH config file at $SSH_CONFIG_FILE"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# BACKUP SSH CONFIG
# ═══════════════════════════════════════════════════════════════════════════

# Create a timestamped backup of the SSH config file
backup_ssh_config() {
    local backup_file
    backup_file="${SSH_CONFIG_FILE}.backup.$(date +%s)"
    cp "$SSH_CONFIG_FILE" "$backup_file" 2>/dev/null || true
    print_step "Backed up SSH config to: $backup_file"
    echo "$backup_file"
}

# ═══════════════════════════════════════════════════════════════════════════
# LIST FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Reconstruct clone command from a public key's comment + repo name
# Comment is usually the original SSH URL: git@github.com:user/repo.git
# Works with any provider (github, bitbucket, gitlab, etc.)
make_clone_command() {
    local name="$1"    # repo name (e.g. xep-hinh)
    local comment="$2" # comment from public key (original SSH URL)
    if [ -z "$comment" ]; then
        return 1
    fi
    # Extract host from comment: git@<host>:user/repo.git
    local host repo_path
    if [[ "$comment" =~ ^git@([^:]+):(.+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        repo_path="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    repo_path="${repo_path%.git}"
    if [ -z "$repo_path" ] || [ -z "$host" ]; then
        return 1
    fi
    # Re-detect provider from the comment to use the correct HOST_PREFIX
    # (e.g., for github.com, HOST_PREFIX="github", not "github.com")
    detect_provider "$comment"
    echo "git@${HOST_PREFIX}-${name}:${repo_path}.git"
}

# List all existing SSH keys managed by this script
# Scans for both id_ed25519_* and id_rsa_* patterns
list_existing_keys() {
    print_header "Existing SSH Keys (managed by this script)"

    local found=false
    local count=0
    local key_file
    local prefix

    for prefix in "${SUPPORTED_KEY_PREFIXES[@]}"; do
        for key_file in "$SSH_DIR"/"${prefix}"_*; do
            [ -f "$key_file" ] || continue
            local pub_file="${key_file}.pub"
            local name
            name="${key_file#"${SSH_DIR}/${prefix}"_}"
            # Strip leading underscore if any
            name="${name#_}"

            if [ -f "$pub_file" ]; then
                local comment fingerprint key_type_str clone_url host_from_comment
                comment=$(awk '{print $3}' "$pub_file" 2>/dev/null)
                fingerprint=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $2}')
                key_type_str=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $1}')

                clone_url=$(make_clone_command "$name" "$comment")

                # Extract host from comment for display
                if [[ "$comment" =~ ^git@([^:]+): ]]; then
                    host_from_comment="${BASH_REMATCH[1]}"
                else
                    host_from_comment="?"
                fi

                echo -e "  ${GREEN}▶${NC} ${BOLD}${name}${NC}"
                echo -e "    Key:      ${CYAN}${prefix}_${name}${NC} (${key_type_str:-unknown})"
                echo -e "    Fingerprint: ${fingerprint:-N/A}"
                echo -e "    Comment:  ${comment:-N/A}"
                echo -e "    Host:     ${YELLOW}${host_from_comment}-${name}${NC}"
                if [ -n "$clone_url" ]; then
                    echo -e "    Clone:    ${GREEN}git clone ${clone_url}${NC}"
                fi
                echo ""
                found=true
                ((count++))
            fi
        done
    done

    if [ "$found" = false ]; then
        print_warning "No SSH keys found (id_ed25519_* or id_rsa_*)"
        echo ""
    else
        print_success "Found $count key(s)"
        echo ""
    fi
}

# List all entries in SSH config managed by this script
# (matches Host entries whose alias contains a '-' prefix from provider detection)
list_ssh_config_entries() {
    print_header "SSH Config Entries"

    if [ ! -f "$SSH_CONFIG_FILE" ]; then
        print_warning "SSH config file does not exist yet."
        echo ""
        return
    fi

    local count=0
    local in_block=false
    local current_host=""
    local current_file=""

    while IFS= read -r line; do
        # Match Host entries where the IdentityFile points to a managed key
        # (i.e. contains id_ed25519_ or id_rsa_ in the SSH dir)
        if [[ "$line" =~ ^Host[[:space:]]+([a-zA-Z0-9]+-[a-zA-Z0-9].*)$ ]]; then
            current_host="${BASH_REMATCH[1]}"
            in_block=true
            current_file=""
        elif [[ "$line" =~ ^Host[[:space:]]+ ]]; then
            # Emit any pending entry before switching to a new Host block
            if $in_block && [ -n "$current_host" ] && [ -n "$current_file" ]; then
                local is_managed=false
                local p
                for p in "${SUPPORTED_KEY_PREFIXES[@]}"; do
                    if [[ "$current_file" == *"${SSH_DIR}/${p}_"* ]]; then
                        is_managed=true
                        break
                    fi
                done
                if [ "$is_managed" = true ]; then
                    echo -e "  ${GREEN}▶${NC} ${BOLD}${current_host}${NC}"
                    echo -e "    IdentityFile: ${current_file:-N/A}"
                    echo ""
                    ((count++))
                fi
            fi
            in_block=false
            current_host=""
            current_file=""
        elif $in_block && [[ "$line" =~ IdentityFile[[:space:]]+(.+) ]]; then
            current_file=$(echo "$line" | awk '{print $2}')
        elif $in_block && [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
            if [ -n "$current_host" ] && [ -n "$current_file" ]; then
                # Only show if the IdentityFile matches a managed key pattern
                local is_managed=false
                local p
                for p in "${SUPPORTED_KEY_PREFIXES[@]}"; do
                    if [[ "$current_file" == *"${SSH_DIR}/${p}_"* ]]; then
                        is_managed=true
                        break
                    fi
                done
                if [ "$is_managed" = true ]; then
                    echo -e "  ${GREEN}▶${NC} ${BOLD}${current_host}${NC}"
                    echo -e "    IdentityFile: ${current_file:-N/A}"
                    echo ""
                    ((count++))
                fi
            fi
            in_block=false
            current_host=""
            current_file=""
        fi
    done < "$SSH_CONFIG_FILE"

    if [ -n "$current_host" ] && [ -n "$current_file" ]; then
        local is_managed=false
        local p
        for p in "${SUPPORTED_KEY_PREFIXES[@]}"; do
            if [[ "$current_file" == *"${SSH_DIR}/${p}_"* ]]; then
                is_managed=true
                break
            fi
        done
        if [ "$is_managed" = true ]; then
            echo -e "  ${GREEN}▶${NC} ${BOLD}${current_host}${NC}"
            echo -e "    IdentityFile: ${current_file:-N/A}"
            echo ""
            ((count++))
        fi
    fi

    if [ "$count" -eq 0 ]; then
        print_warning "No managed entries found in SSH config."
        echo ""
    else
        print_success "Found $count managed host entr(y/ies)"
        echo ""
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# SSH CONFIG MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════

# Check if a host alias already exists in SSH config
host_alias_exists() {
    local host_alias="$1"
    if [ -f "$SSH_CONFIG_FILE" ]; then
        grep -q "^Host ${host_alias}$" "$SSH_CONFIG_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

# Check if a host entry is a bare provider host (github.com, bitbucket.org, gitlab.com, etc.)
# These are the original host entries — we never delete them to avoid breaking existing setup.
is_original_host() {
    local host_alias="$1"
    # Bare hosts are single-part names (no dash) like "github.com", "bitbucket.org"
    [[ "$host_alias" != *"-"* ]]
}

# Add an SSH config entry for a host alias
add_ssh_config_entry() {
    local repo_name="$1"
    local key_path="$2"
    local host_alias
    host_alias=$(get_host_alias "$repo_name")

    ensure_ssh_config

    # Backup config
    backup_ssh_config > /dev/null

    # Check if host alias already exists
    if host_alias_exists "$host_alias"; then
        print_warning "Host alias '${host_alias}' already exists in SSH config."
        echo ""
        read -r -p "  Overwrite it? (y/N): " -n 1
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_step "Skipped updating SSH config entry '${host_alias}'"
            return 0
        fi
        awk -v host="${host_alias}" '
          $0 ~ "^Host " host "$" { skip = 1; next }
          skip && /^$/ { skip = 0; next }
          skip && /^Host / { skip = 0 }
          skip { next }
          { print }
        ' "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp" && mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
        print_step "Removed old entry for '${host_alias}'"
    fi

    # Append new entry
    {
        echo ""
        echo "Host ${host_alias}"
        printf "\tHostName %s\n" "${PROVIDER_HOST}"
        printf "\tUser git\n"
        printf "\tIdentityFile %s\n" "${key_path}"
        printf "\tAddKeysToAgent yes\n"
        printf "\tIdentitiesOnly yes\n"
        echo ""
    } >> "$SSH_CONFIG_FILE"

    chmod 600 "$SSH_CONFIG_FILE" 2>/dev/null || true
    print_success "SSH config updated: added host '${host_alias}' (${PROVIDER_HOST})"
}

# Remove a host entry from SSH config
remove_ssh_config_entry() {
    local host_alias="$1"

    if [ -z "$host_alias" ]; then
        return 1
    fi

    if ! host_alias_exists "$host_alias"; then
        return 1
    fi

    if is_original_host "$host_alias"; then
        print_error "Refusing to remove original host entry '${host_alias}'. Use --remove only for aliases like '<provider>-<name>'."
        return 1
    fi

    backup_ssh_config > /dev/null

    awk -v host="${host_alias}" '
      $0 ~ "^Host " host "$" { skip = 1; next }
      skip && /^$/ { skip = 0; next }
      skip && /^Host / { skip = 0 }
      skip { next }
      { print }
    ' "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp" && mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE" || {
        print_error "Failed to remove host entry '${host_alias}' from SSH config"
        return 1
    }

    chmod 600 "$SSH_CONFIG_FILE" 2>/dev/null || true
    print_success "Removed host '${host_alias}' from SSH config"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# SSH KEY OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════

# Generate SSH key for a single repository
generate_key_for_repo() {
    local repo_url="$1"
    local repo_name repo_full key_path host_alias

    # Detect provider (github, bitbucket, gitlab, etc.) from URL
    detect_provider "$repo_url"

    repo_name=$(parse_repo_name "$repo_url")
    repo_full=$(parse_repo_full "$repo_url")
    key_path=$(get_key_path "$repo_name")
    host_alias=$(get_host_alias "$repo_name")

    print_subheader "Repository: ${repo_full}  (${PROVIDER})"

    # Check if key already exists
    if [ -f "$key_path" ]; then
        print_warning "SSH key already exists: ${key_path}"
        local fingerprint
        fingerprint=$(ssh-keygen -lf "$key_path" 2>/dev/null | awk '{print $2}')
        echo -e "  Fingerprint: ${fingerprint:-N/A}"
        echo ""
        read -r -p "  Overwrite this key? (y/N): " -n 1
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_step "Keeping existing key for '${repo_name}'"
            if ! host_alias_exists "$host_alias"; then
                add_ssh_config_entry "$repo_name" "$key_path"
            fi
            add_key_to_agent "$key_path"
            show_result "$repo_url" "$repo_name" "$key_path" "$host_alias"
            return 0
        fi
        rm -f "$key_path" "$key_path.pub" 2>/dev/null || true
        print_step "Old key removed"
    fi

    # Generate new key
    local key_bits_args=()
    [ "$KEY_TYPE" = "rsa" ] && key_bits_args=("-b" "4096")

    print_step "Generating ${KEY_TYPE^^} SSH key: ${KEY_PREFIX}_${repo_name}"
    echo ""

    if ! ssh-keygen -t "$KEY_TYPE" "${key_bits_args[@]}" -f "$key_path" -N "" -C "$repo_url" 2>&1; then
        print_error "ssh-keygen failed!"
        print_error "Try: apt-get update && apt-get install openssh-client -y"
        exit 1
    fi

    print_success "SSH key pair generated: ${KEY_PREFIX}_${repo_name}"

    # Set proper permissions
    chmod 600 "$key_path" 2>/dev/null || true
    chmod 644 "$key_path.pub" 2>/dev/null || true

    # Add to SSH config
    add_ssh_config_entry "$repo_name" "$key_path"

    # Add to SSH agent
    add_key_to_agent "$key_path"

    # Show result
    show_result "$repo_url" "$repo_name" "$key_path" "$host_alias"
}

# Add SSH key to SSH agent
add_key_to_agent() {
    local key_path="$1"

    print_step "Adding SSH key to SSH agent..."
    if command -v ssh-add &> /dev/null; then
        if [ -z "$SSH_AGENT_PID" ] && [ -z "$SSH_AUTH_SOCK" ]; then
            print_warning "SSH agent is not running. Starting SSH agent..."
            eval "$(ssh-agent -s 2>/dev/null)" > /dev/null 2>&1 || true
            if [ -z "$SSH_AUTH_SOCK" ]; then
                print_warning "Could not start SSH agent. Skipping ssh-add."
                return 0
            fi
        fi

        if ssh-add "$key_path" 2>/dev/null; then
            print_success "SSH key added to agent"
        else
            print_warning "Could not add key to agent (not critical)"
        fi
    else
        print_warning "ssh-add command not found (SSH agent may not be available)"
    fi
}

# Display result for a generated key
show_result() {
    local repo_url="$1"
    local repo_name="$2"
    local key_path="$3"
    local host_alias="$4"
    local repo_full public_key clone_url
    repo_full=$(parse_repo_full "$repo_url")

    echo ""

    clone_url="git@${host_alias}:${repo_full}.git"

    if [ -f "${key_path}.pub" ]; then
        public_key=$(cat "${key_path}.pub")
    else
        public_key="[public key file not found]"
    fi

    print_header "SSH Public Key"

    echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
    echo "$public_key"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
    echo ""

    print_header "Clone Command (using host alias)"

    echo -e "  ${GREEN}git clone ${clone_url}${NC}"
    echo ""

    echo -e "  ${CYAN}📝 Add this public key to your git provider (${PROVIDER}):${NC}"
    echo -e "     Repository → Settings → Deploy keys → Add deploy key"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# REMOVE KEY
# ═══════════════════════════════════════════════════════════════════════════

remove_key() {
    local repo_name="$1"
    local host_alias

    # Validate repo name — reject empty, path separators, relative paths, or grep-unsafe chars
    if [ -z "$repo_name" ] || [[ "$repo_name" == *"/"* ]] || [[ "$repo_name" == *"\\"* ]] || [[ "$repo_name" == *".."* ]] || [[ "$repo_name" =~ [^a-zA-Z0-9_-] ]]; then
        print_error "Invalid repository name: '${repo_name}'"
        print_error "Repository name must be alphanumeric, may contain hyphens or underscores (e.g., 'my-app')."
        return 1
    fi

    print_header "Removing SSH Key for: ${repo_name}"

    local found=false
    local prefix kp

    # Remove key files first
    for prefix in "${SUPPORTED_KEY_PREFIXES[@]}"; do
        kp="$SSH_DIR/${prefix}_${repo_name}"

        # Remove from SSH agent BEFORE deleting the file
        if [ -f "$kp" ] && command -v ssh-add &> /dev/null; then
            ssh-add -d "$kp" 2>/dev/null && print_success "Removed ${prefix}_${repo_name} from SSH agent" || true
        fi

        if [ -f "$kp" ]; then
            rm -f "$kp" 2>/dev/null || true
            found=true
            print_success "Removed private key: ${prefix}_${repo_name}"
        fi

        if [ -f "${kp}.pub" ]; then
            rm -f "${kp}.pub" 2>/dev/null || true
            found=true
            print_success "Removed public key: ${prefix}_${repo_name}.pub"
        fi
    done

    # Now remove SSH config entries — there might be multiple providers for the same repo name
    if [ -f "$SSH_CONFIG_FILE" ]; then
        local host_aliases
        host_aliases=$(grep -E "^Host [a-zA-Z0-9]+-${repo_name}$" "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}')
        if [ -n "$host_aliases" ]; then
            while IFS= read -r ha; do
                if remove_ssh_config_entry "$ha"; then
                    found=true
                fi
            done <<< "$host_aliases"
        fi
    fi

    echo ""
    if [ "$found" = true ]; then
        print_success "Successfully removed key '${repo_name}'"
    else
        print_warning "Nothing to remove for '${repo_name}'"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# INTERACTIVE MENU
# ═══════════════════════════════════════════════════════════════════════════

show_interactive_menu() {
    while true; do
        print_header "SSH Key Manager — Interactive Menu"

        echo -e "  ${BOLD}1.${NC} Generate new SSH key(s) for repository URL(s)"
        echo -e "  ${BOLD}2.${NC} List all existing SSH keys"
        echo -e "  ${BOLD}3.${NC} Remove an existing SSH key"
        echo -e "  ${BOLD}q.${NC} Quit"
        echo ""
        read -r -p "  Select an option [1/2/3/q]: " menu_choice
        echo ""

        case "$menu_choice" in
            1)
                print_step "Enter git repository URL(s) (space-separated for multiple):"
                echo ""
                read -r -p "  URL(s): " repo_input
                echo ""
                if [ -z "$repo_input" ]; then
                    print_error "No URL entered."
                    echo ""
                    continue
                fi
                detect_key_type
                ensure_ssh_config
                # Disable pathname expansion to prevent glob characters in URL from expanding
                set -f
                # shellcheck disable=SC2086
                process_repos $repo_input
                set +f
                ;;
            2)
                list_all
                ;;
            3)
                print_step "Enter the repository name to remove (e.g., 'dudu-bot'):"
                echo ""
                read -r -p "  Name: " remove_name
                echo ""
                if [ -z "$remove_name" ]; then
                    print_error "No name entered."
                    echo ""
                    continue
                fi
                remove_key "$remove_name"
                ;;
            q|Q)
                print_step "Goodbye!"
                echo ""
                exit 0
                ;;
            *)
                print_error "Invalid option."
                echo ""
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# PROCESS REPOSITORY URLS
# ═══════════════════════════════════════════════════════════════════════════

process_repos() {
    if [ $# -eq 0 ]; then
        print_error "No repository URLs provided."
        exit 1
    fi

    print_header "SSH Key Generation"

    echo -e "  ${BLUE}Started:$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""
    print_step "Processing $# repository URL(s)..."
    echo ""

    local count=0
    for repo_url in "$@"; do
        ((count++))
        echo -e "${BOLD}[${count}/$#]${NC} ${repo_url}"
        generate_key_for_repo "$repo_url"
        echo ""
        echo -e "${CYAN}────────────────────────────────────────────────────────────${NC}"
        echo ""
    done

    print_success "All done! Processed $# repository/repos."
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# LIST ALL
# ═══════════════════════════════════════════════════════════════════════════

list_all() {
    list_existing_keys
    list_ssh_config_entries
}

# ═══════════════════════════════════════════════════════════════════════════
# USAGE / HELP
# ═══════════════════════════════════════════════════════════════════════════

show_usage() {
    echo ""
    echo -e "${BLUE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║  SSH Key Generator — Multi-Repository / Multi-Provider     ║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Usage:"
    echo "  ./ssh-tools.sh                          Interactive mode"
    echo "  ./ssh-tools.sh <url>                    Generate key for one repository"
    echo "  ./ssh-tools.sh <url1> <url2> ...        Generate keys for multiple repositories"
    echo "  ./ssh-tools.sh --list                   List all existing keys and config entries"
    echo "  ./ssh-tools.sh --remove <repo_name>     Remove a key and its SSH config entry"
    echo "  ./ssh-tools.sh --help                   Show this help message"
    echo ""
    echo "Supported providers: GitHub, GitLab, Bitbucket, any custom SSH git host"
    echo ""
    echo "Examples:"
    echo "  ./ssh-tools.sh git@github.com:user/My-App.git"
    echo "  ./ssh-tools.sh git@gitlab.com:group/project.git"
    echo "  ./ssh-tools.sh git@bitbucket.org:team/repo.git"
    echo "  ./ssh-tools.sh git@github.com:user/repo-a.git git@bitbucket.org:team/repo-b.git"
    echo "  ./ssh-tools.sh --list"
    echo "  ./ssh-tools.sh --remove my-app"
    echo ""
    echo "Key naming:  ~/.ssh/id_ed25519_<repo_name> or ~/.ssh/id_rsa_<repo_name>"
    echo "             (auto-detects supported key type, prefers ED25519)"
    echo "Host alias:  <provider>-<repo_name>  (e.g. github-my-app, in ~/.ssh/config)"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

# Ensure SSH directory exists
ensure_ssh_dir

# Parse arguments
case "$1" in
    --help|-h)
        show_usage
        exit 0
        ;;
    --list|-l)
        list_all
        exit 0
        ;;
    --remove|-r)
        if [ -z "$2" ]; then
            print_error "Missing repository name. Usage: ./ssh-tools.sh --remove <repo_name>"
            exit 1
        fi
        shift
        for repo_name in "$@"; do
            remove_key "$repo_name"
        done
        exit 0
        ;;
    "")
        # No arguments — show interactive menu
        show_interactive_menu
        exit 0
        ;;
    *)
        # One or more repository URLs
        detect_key_type
        ensure_ssh_config
        process_repos "$@"
        exit 0
        ;;
esac