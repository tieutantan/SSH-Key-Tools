#!/bin/bash

################################################################################
# SSH Key Generation Script
# Purpose: Generate SSH key pairs for multiple GitHub repositories
# Usage:
#   Interactive mode:        ./ssh-keygen.sh
#   Single repository:       ./ssh-keygen.sh git@github.com:user/repo.git
#   Multiple repositories:   ./ssh-keygen.sh repo1.git repo2.git repo3.git
#   List all keys:           ./ssh-keygen.sh --list
#   Remove a key:            ./ssh-keygen.sh --remove <repo_name>
#   Show help:               ./ssh-keygen.sh --help
#
# Each repository gets its own key: ~/.ssh/id_ed25519_<repo_name>
# SSH config uses Host aliases: Host github-<repo_name>
# The original github.com entry is never overwritten.
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
HOST_PREFIX="github"

# These are set by detect_key_type()
KEY_TYPE=""
KEY_PREFIX=""

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
    test_dir="/tmp/ssh-keygen-test.$$"
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

# Extract repo name from a GitHub SSH URL
# Input:  git@github.com:user/My-Repo.git
# Output: my-repo
parse_repo_name() {
    local url="$1"
    local repo_full
    repo_full="${url#*github.com:*}"
    repo_full="${repo_full%.git}"
    echo "$repo_full" | sed 's/.*\///' | tr '[:upper:]' '[:lower:]'
}

# Extract full owner/repo from URL (for clone command display)
# Input:  git@github.com:user/My-Repo.git
# Output: user/My-Repo
parse_repo_full() {
    local url="$1"
    local repo_full
    repo_full="${url#*github.com:*}"
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
# LIST FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Reconstruct clone command from a public key's comment + repo name
# Comment is usually the original SSH URL: git@github.com:user/repo.git
make_clone_command() {
    local name="$1"    # repo name (e.g. xep-hinh)
    local comment="$2" # comment from public key (original SSH URL)
    if [ -z "$comment" ]; then
        return 1
    fi
    local repo_path="${comment#*github.com:*}"
    repo_path="${repo_path%.git}"
    if [ -z "$repo_path" ] || [ "$repo_path" = "$comment" ]; then
        return 1
    fi
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

    for prefix in "id_ed25519" "id_rsa"; do
        for key_file in "$SSH_DIR"/"${prefix}"_*; do
            [ -f "$key_file" ] || continue
            local pub_file="${key_file}.pub"
            local name
            name="${key_file#"${SSH_DIR}/${prefix}"_}"
            # Strip leading underscore if any
            name="${name#_}"

            if [ -f "$pub_file" ]; then
                local comment fingerprint key_type_str clone_url
                comment=$(awk '{print $3}' "$pub_file" 2>/dev/null)
                fingerprint=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $2}')
                key_type_str=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $1}')

                clone_url=$(make_clone_command "$name" "$comment")

                echo -e "  ${GREEN}▶${NC} ${BOLD}${name}${NC}"
                echo -e "    Key:      ${CYAN}${prefix}_${name}${NC} (${key_type_str:-unknown})"
                echo -e "    Fingerprint: ${fingerprint:-N/A}"
                echo -e "    Comment:  ${comment:-N/A}"
                echo -e "    Host:     ${YELLOW}${HOST_PREFIX}-${name}${NC}"
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

# List all GitHub-related entries in SSH config
list_ssh_config_entries() {
    print_header "SSH Config Entries (GitHub)"

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
        if [[ "$line" =~ ^Host[[:space:]]+(github) ]]; then
            current_host=$(echo "$line" | awk '{print $2}')
            in_block=true
            current_file=""
        elif [[ "$line" =~ ^Host[[:space:]]+ ]]; then
            in_block=false
        elif $in_block && [[ "$line" =~ IdentityFile[[:space:]]+(.+) ]]; then
            current_file=$(echo "$line" | awk '{print $2}')
        elif $in_block && [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]]; then
            if [ -n "$current_host" ]; then
                echo -e "  ${GREEN}▶${NC} ${BOLD}${current_host}${NC}"
                echo -e "    IdentityFile: ${current_file:-N/A}"
                echo ""
                ((count++))
            fi
            in_block=false
            current_host=""
            current_file=""
        fi
    done < "$SSH_CONFIG_FILE"

    if [ -n "$current_host" ]; then
        echo -e "  ${GREEN}▶${NC} ${BOLD}${current_host}${NC}"
        echo -e "    IdentityFile: ${current_file:-N/A}"
        echo ""
        ((count++))
    fi

    if [ "$count" -eq 0 ]; then
        print_warning "No GitHub entries found in SSH config."
        echo ""
    else
        print_success "Found $count GitHub host entrie(s)"
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

# Check if a host entry matches github.com generic host
is_github_com_host() {
    local host_alias="$1"
    [ "$host_alias" = "github.com" ]
}

# Add an SSH config entry for a host alias
add_ssh_config_entry() {
    local repo_name="$1"
    local key_path="$2"
    local host_alias
    host_alias=$(get_host_alias "$repo_name")

    ensure_ssh_config

    # Backup config
    local backup_file
    backup_file="${SSH_CONFIG_FILE}.backup.$(date +%s)"
    cp "$SSH_CONFIG_FILE" "$backup_file" 2>/dev/null || true
    print_step "Backed up SSH config to: $backup_file"

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
        sed -i.bak "/^Host ${host_alias}$/,/^$/d" "$SSH_CONFIG_FILE" 2>/dev/null || true
        rm -f "$SSH_CONFIG_FILE.bak" 2>/dev/null || true
        print_step "Removed old entry for '${host_alias}'"
    fi

    # Append new entry
    {
        echo ""
        echo "Host ${host_alias}"
        printf "\tHostName github.com\n"
        printf "\tUser git\n"
        printf "\tIdentityFile %s\n" "${key_path}"
        printf "\tAddKeysToAgent yes\n"
        printf "\tIdentitiesOnly yes\n"
        echo ""
    } >> "$SSH_CONFIG_FILE"

    chmod 600 "$SSH_CONFIG_FILE" 2>/dev/null || true
    print_success "SSH config updated: added host '${host_alias}'"
}

# Remove a host entry from SSH config
remove_ssh_config_entry() {
    local host_alias="$1"

    if ! host_alias_exists "$host_alias"; then
        print_warning "Host alias '${host_alias}' not found in SSH config. Nothing to remove."
        return 1
    fi

    if is_github_com_host "$host_alias"; then
        print_error "Refusing to remove generic 'github.com' host entry. Use --remove only for aliases like 'github-<name>'."
        return 1
    fi

    local backup_file
    backup_file="${SSH_CONFIG_FILE}.backup.$(date +%s)"
    cp "$SSH_CONFIG_FILE" "$backup_file" 2>/dev/null || true
    print_step "Backed up SSH config to: $backup_file"

    sed -i.bak "/^Host ${host_alias}$/,/^$/d" "$SSH_CONFIG_FILE" 2>/dev/null || {
        print_error "Failed to remove host entry '${host_alias}' from SSH config"
        return 1
    }
    rm -f "$SSH_CONFIG_FILE.bak" 2>/dev/null || true

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
    repo_name=$(parse_repo_name "$repo_url")
    repo_full=$(parse_repo_full "$repo_url")
    key_path=$(get_key_path "$repo_name")
    host_alias=$(get_host_alias "$repo_name")

    print_subheader "Repository: ${repo_full}"

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

    print_header "SSH Public Key (Copy to GitHub Deploy Keys)"

    echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
    echo "$public_key"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────────${NC}"
    echo ""

    print_header "Clone Command (using host alias)"

    echo -e "  ${GREEN}git clone ${clone_url}${NC}"
    echo ""

    echo -e "  ${CYAN}📝 Add this public key to GitHub:${NC}"
    echo -e "     Repository → Settings → Deploy keys → Add deploy key"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# REMOVE KEY
# ═══════════════════════════════════════════════════════════════════════════

remove_key() {
    local repo_name="$1"
    local host_alias
    host_alias=$(get_host_alias "$repo_name")

    print_header "Removing SSH Key for: ${repo_name}"

    local found=false
    local prefix kp

    for prefix in "id_ed25519" "id_rsa"; do
        kp="$SSH_DIR/${prefix}_${repo_name}"

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

        if [ -f "$kp" ] && command -v ssh-add &> /dev/null; then
            ssh-add -d "$kp" 2>/dev/null && print_success "Removed ${prefix}_${repo_name} from SSH agent" || true
        fi
    done

    if remove_ssh_config_entry "$host_alias"; then
        found=true
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
            print_step "Enter GitHub repository URL(s) (space-separated for multiple):"
            echo ""
            read -r -p "  URL(s): " repo_input
            echo ""
            if [ -z "$repo_input" ]; then
                print_error "No URL entered."
                echo ""
                return
            fi
            # shellcheck disable=SC2086
            process_repos $repo_input
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
                return
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

    print_success "All done! Generated SSH keys for $# repository/repos."
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
    echo -e "${BLUE}${BOLD}║  SSH Key Generator — Multi-Repository Edition              ║${NC}"
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Usage:"
    echo "  ./ssh-keygen.sh                          Interactive mode"
    echo "  ./ssh-keygen.sh <url>                    Generate key for one repository"
    echo "  ./ssh-keygen.sh <url1> <url2> ...        Generate keys for multiple repositories"
    echo "  ./ssh-keygen.sh --list                   List all existing keys and config entries"
    echo "  ./ssh-keygen.sh --remove <repo_name>     Remove a key and its SSH config entry"
    echo "  ./ssh-keygen.sh --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./ssh-keygen.sh git@github.com:user/Pikatrue.git"
    echo "  ./ssh-keygen.sh git@github.com:user/repo-a.git git@github.com:user/repo-b.git"
    echo "  ./ssh-keygen.sh --list"
    echo "  ./ssh-keygen.sh --remove pikatrue"
    echo ""
    echo "Key naming:  ~/.ssh/id_ed25519_<repo_name> or ~/.ssh/id_rsa_<repo_name>"
    echo "             (auto-detects supported key type, prefers ED25519)"
    echo "Host alias:  ${HOST_PREFIX}-<repo_name>  (in ~/.ssh/config)"
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
            print_error "Missing repository name. Usage: ./ssh-keygen.sh --remove <repo_name>"
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