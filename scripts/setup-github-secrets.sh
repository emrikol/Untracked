#!/usr/bin/env bash
# One-time (and safely re-runnable) setup of the GitHub Actions secrets the
# release workflow depends on.
#
# Every value here is either a signing credential or a password, so the whole
# script is built around one rule: a secret value never appears as a command-
# line argument (this script's own, or gh's) and never gets printed. Argv
# would land in shell history and briefly in `ps`; printing would land in
# scrollback and any terminal logging. Values travel only through `read -rs`,
# a file the caller points at, or a pipe straight into `gh secret set`.
#
# Usage:
#   scripts/setup-github-secrets.sh                interactive menu
#   scripts/setup-github-secrets.sh --check         report present/missing; exits non-zero if any missing
#   scripts/setup-github-secrets.sh --all           walk through all seven
#   scripts/setup-github-secrets.sh <NAME>          set just that one
#   scripts/setup-github-secrets.sh <NAME> --file P read that one's value from PATH instead of prompting
set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# Fixed — the release workflow keys off these exact names. Don't rename.
SECRET_NAMES=(
    SPARKLE_ED_PRIVATE_KEY
    MACOS_CERTIFICATE
    MACOS_CERTIFICATE_PWD
    KEYCHAIN_PASSWORD
    NOTARY_APPLE_ID
    NOTARY_TEAM_ID
    NOTARY_PASSWORD
)

die() {
    echo -e "${RED}✗ $*${NC}" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: scripts/setup-github-secrets.sh [--check | --all | <SECRET_NAME> [--file PATH]]

  (no args)      interactive menu — pick one secret, or all seven
  --check        report which of the 7 secrets exist; exit non-zero if any are missing
  --all          walk through all 7 secrets interactively (asks before overwriting
                 any that are already set)
  <SECRET_NAME>  set just that one secret
  --file PATH    with a single SECRET_NAME, read its value from PATH instead of
                 prompting (the .p12 and Sparkle key still need real files anyway)

Secret names (fixed — the release workflow depends on them exactly):
  SPARKLE_ED_PRIVATE_KEY   MACOS_CERTIFICATE       MACOS_CERTIFICATE_PWD
  KEYCHAIN_PASSWORD        NOTARY_APPLE_ID         NOTARY_TEAM_ID
  NOTARY_PASSWORD
EOF
}

is_known_secret() {
    local name="$1" candidate
    for candidate in "${SECRET_NAMES[@]}"; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

describe() {
    case "$1" in
        SPARKLE_ED_PRIVATE_KEY) echo "Sparkle EdDSA private key (base64) — signs the appcast." ;;
        MACOS_CERTIFICATE) echo "Developer ID Application .p12, base64-encoded." ;;
        MACOS_CERTIFICATE_PWD) echo "Export password for that .p12." ;;
        KEYCHAIN_PASSWORD) echo "Ephemeral password for the throwaway CI keychain." ;;
        NOTARY_APPLE_ID) echo "Apple ID email used with notarytool." ;;
        NOTARY_TEAM_ID) echo "Apple Developer team ID." ;;
        NOTARY_PASSWORD) echo "App-specific password for notarytool." ;;
    esac
}

# --- gh preconditions --------------------------------------------------------
require_gh() {
    command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed — https://cli.github.com"
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login' first"
    gh repo view >/dev/null 2>&1 \
        || die "gh can't resolve a GitHub repo here — check the git remote"
}

existing_secret_names() {
    gh secret list --json name --jq '.[].name'
}

is_set() {
    grep -qx "$1" <<<"$EXISTING_SECRETS"
}

# --- value collection ---------------------------------------------------------
#
# Every branch below ends by writing the secret value, and ONLY the secret
# value, to stdout — callers capture it with `value=$(collect ...)`. `read -p`
# already sends its own prompt to stderr (verified: it does not pollute a
# command-substitution's stdout), but every plain `echo` note in these
# functions is deliberately `>&2` for the same reason.
prompt_silent() {
    local name="$1" value
    read -rs -p "$name (input hidden): " value
    echo >&2
    printf '%s' "$value"
}

prompt_visible() {
    local label="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " value
        printf '%s' "${value:-$default}"
    else
        read -r -p "$label: " value
        printf '%s' "$value"
    fi
}

read_file_value() {
    # Shared by every --file path below except MACOS_CERTIFICATE, which needs
    # base64 encoding instead of a trailing-newline trim. Checking existence
    # here (rather than letting `<"$file"` fail) keeps the error a clean `die`
    # instead of a raw bash redirection message.
    local file="$1"
    [[ -f "$file" ]] || { echo "not a file: $file" >&2; return 1; }
    tr -d '\n' <"$file"
}

collect() {
    local name="$1" file="${2:-}"
    case "$name" in
        MACOS_CERTIFICATE)
            if [[ -z "$file" ]]; then
                echo "Path to the Developer ID Application .p12 (the raw file — this base64-encodes it):" >&2
                file=$(prompt_visible "  path")
            fi
            [[ -f "$file" ]] || { echo "not a file: $file" >&2; return 1; }
            # -A: single line, no 64-char wrapping — one less place that has to
            # remember to strip newlines when this gets decoded back in CI.
            openssl base64 -A -in "$file"
            ;;
        SPARKLE_ED_PRIVATE_KEY)
            if [[ -z "$file" ]]; then
                echo "Export it first (never printed or stored anywhere else):" >&2
                echo "  generate_keys -x /path/to/key.txt" >&2
                echo "(otherwise it lives only in the login keychain, item" >&2
                echo " \"Private key for signing Sparkle updates\")" >&2
                file=$(prompt_visible "  path to exported key file")
            fi
            # Unlike the .p12 above, generate_keys -x already writes base64
            # text — re-encoding it here would double-encode the secret.
            read_file_value "$file"
            ;;
        KEYCHAIN_PASSWORD)
            if [[ -n "$file" ]]; then
                read_file_value "$file"
            else
                local reply
                read -r -p "Generate a random keychain password? [Y/n] " reply
                if [[ -z "$reply" || "$reply" =~ ^[Yy] ]]; then
                    openssl rand -base64 24
                else
                    prompt_silent "$name"
                fi
            fi
            ;;
        NOTARY_TEAM_ID)
            if [[ -n "$file" ]]; then
                read_file_value "$file"
            else
                prompt_visible "$name" "3T9RX85H44"
            fi
            ;;
        NOTARY_APPLE_ID)
            if [[ -n "$file" ]]; then
                read_file_value "$file"
            else
                prompt_visible "$name (Apple ID email)"
            fi
            ;;
        *) # MACOS_CERTIFICATE_PWD, NOTARY_PASSWORD — plain passwords, always hidden
            if [[ -n "$file" ]]; then
                read_file_value "$file"
            else
                prompt_silent "$name"
            fi
            ;;
    esac
}

set_one() {
    local name="$1" file="${2:-}"
    if is_set "$name"; then
        local reply
        read -r -p "$name is already set — overwrite? [y/N] " reply
        if [[ ! "$reply" =~ ^[Yy] ]]; then
            echo "  skipped $name"
            return 0
        fi
    fi
    describe "$name"
    local value
    value=$(collect "$name" "$file") || die "could not read a value for $name"
    [[ -n "$value" ]] || die "empty value for $name — refusing to set an empty secret"
    # --body is deliberately omitted: gh reads the secret from stdin when it's
    # not given on argv, which is the only path a value can travel without
    # sitting in `ps` output for the moment gh is running. (`--body -` reads
    # as "stdin" by Unix convention, but gh's own docs say --body always takes
    # a literal string and stdin-reading only happens when --body is absent —
    # passing "-" would silently set the secret to the two-character string
    # "-". Confirmed against `gh secret set --help`, not assumed.)
    printf '%s' "$value" | gh secret set "$name" >/dev/null
    echo -e "${GREEN}  ✓ set $name${NC}"
}

show_status() {
    echo "Current status:"
    local name
    for name in "${SECRET_NAMES[@]}"; do
        if is_set "$name"; then
            echo -e "${GREEN}  ✓ $name${NC}"
        else
            echo -e "${YELLOW}  - $name (not set)${NC}"
        fi
    done
}

check_mode() {
    show_status
    local missing=0 name
    for name in "${SECRET_NAMES[@]}"; do
        is_set "$name" || missing=1
    done
    echo
    if [[ $missing -eq 1 ]]; then
        echo "Some secrets are missing."
        return 1
    fi
    echo "All secrets present."
}

interactive_menu() {
    show_status
    echo
    echo "Which secret to set?"
    local i=1 name
    for name in "${SECRET_NAMES[@]}"; do
        echo "  $i) $name"
        i=$((i + 1))
    done
    echo "  (or type 'all', or a secret name)"
    local choice
    read -r -p "> " choice
    if [[ "$choice" == "all" ]]; then
        for name in "${SECRET_NAMES[@]}"; do
            set_one "$name"
        done
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        [[ $idx -ge 0 && $idx -lt ${#SECRET_NAMES[@]} ]] || die "no such option: $choice"
        set_one "${SECRET_NAMES[idx]}"
    elif is_known_secret "$choice"; then
        set_one "$choice"
    else
        die "unknown choice: $choice"
    fi
}

# --- main ---------------------------------------------------------------------

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

require_gh
EXISTING_SECRETS=$(existing_secret_names)

case "${1:-}" in
    --check)
        check_mode
        ;;
    --all)
        for secret_name in "${SECRET_NAMES[@]}"; do
            set_one "$secret_name"
        done
        ;;
    --file)
        die "--file requires a preceding SECRET_NAME — see --help"
        ;;
    "")
        interactive_menu
        ;;
    *)
        is_known_secret "$1" || die "unknown secret: $1 (see --help)"
        arg_file=""
        if [[ "${2:-}" == "--file" ]]; then
            arg_file="${3:-}"
            [[ -n "$arg_file" ]] || die "--file requires a path"
        fi
        set_one "$1" "$arg_file"
        ;;
esac
