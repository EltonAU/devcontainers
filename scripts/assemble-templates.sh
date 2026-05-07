#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Assembles per-template .devcontainer directories under build/<template>/
# from src/_shared/ + src/<template>/ overlays.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_DIR="$REPO_ROOT/src/_shared"
SRC_DIR="$REPO_ROOT/src"
BUILD_DIR="$REPO_ROOT/build"

if [ ! -d "$SHARED_DIR" ]; then
    echo "ERROR: $SHARED_DIR not found" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

for template_dir in "$SRC_DIR"/*/; do
    template_name="$(basename "$template_dir")"
    [ "$template_name" = "_shared" ] && continue
    [ -f "$template_dir/devcontainer-template.json" ] || continue

    echo "Assembling $template_name..."

    out="$BUILD_DIR/$template_name"
    mkdir -p "$out/.devcontainer"

    cp "$template_dir/devcontainer-template.json" "$out/devcontainer-template.json"
    cp "$template_dir/.devcontainer/devcontainer.json" "$out/.devcontainer/devcontainer.json"
    cp "$SHARED_DIR/Dockerfile" "$out/.devcontainer/Dockerfile"
    cp "$SHARED_DIR/entrypoint.sh" "$out/.devcontainer/entrypoint.sh"
    chmod +x "$out/.devcontainer/entrypoint.sh"

    fragment="$template_dir/.devcontainer/init-firewall.fragment"
    if [ ! -f "$fragment" ]; then
        echo "ERROR: $fragment not found" >&2
        exit 1
    fi

    domain_block=""
    if [ -s "$fragment" ]; then
        NL=$'\n'
        BS_NL='\'$'\n'
        domain_block="for domain in ${BS_NL}"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            domain_block+="    \"${line}\" ${BS_NL}"
        done < "$fragment"
        domain_block+="    ; do${NL}"
        domain_block+="    echo \"Resolving \$domain...\"${NL}"
        domain_block+="    ips=\$(dig +noall +answer A \"\$domain\" | awk '\$4 == \"A\" {print \$5}')${NL}"
        domain_block+="    if [ -z \"\$ips\" ]; then${NL}"
        domain_block+="        echo \"ERROR: Failed to resolve \$domain\"${NL}"
        domain_block+="        exit 1${NL}"
        domain_block+="    fi${NL}"
        domain_block+="    while read -r ip; do${NL}"
        domain_block+='        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then'"${NL}"
        domain_block+="            echo \"ERROR: Invalid IP from DNS for \$domain: \$ip\"${NL}"
        domain_block+="            exit 1${NL}"
        domain_block+="        fi${NL}"
        domain_block+="        echo \"Adding \$ip for \$domain\"${NL}"
        domain_block+="        ipset add allowed-domains \"\$ip\"${NL}"
        domain_block+="    done < <(echo \"\$ips\")${NL}"
        domain_block+="done${NL}"
    fi

    block_file="$(mktemp)"
    printf '%s' "$domain_block" > "$block_file"

    awk -v block_file="$block_file" '
        /__TEMPLATE_DOMAINS_BLOCK_START__/ {
            print "# __TEMPLATE_DOMAINS_BLOCK_START__"
            while ((getline line < block_file) > 0) {
                print line
            }
            close(block_file)
            in_block = 1
            next
        }
        /__TEMPLATE_DOMAINS_BLOCK_END__/ {
            print "# __TEMPLATE_DOMAINS_BLOCK_END__"
            in_block = 0
            next
        }
        !in_block { print }
    ' "$SHARED_DIR/init-firewall.base.sh" > "$out/.devcontainer/init-firewall.sh"

    rm -f "$block_file"

    chmod +x "$out/.devcontainer/init-firewall.sh"

    echo "  -> $out"
done

echo "Done."
