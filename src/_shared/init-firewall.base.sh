#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# IPv6: deny by default; we do not allowlist any v6 traffic.
ip6tables -F
ip6tables -X
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS lockdown: allow only to nameservers actually in use according to
# /etc/resolv.conf. Different Docker setups use different DNS endpoints
# (Linux native uses 127.0.0.11 embedded resolver; Docker Desktop on
# macOS/Windows uses an internal forwarder like 192.168.65.7). For the
# 127.0.0.11 case Docker NATs the destination before the filter chain runs,
# so we also need a conntrack --ctorigdst match.
DNS_SERVERS=$(awk '/^nameserver / {print $2}' /etc/resolv.conf)
if [ -z "$DNS_SERVERS" ]; then
    echo "ERROR: No nameservers found in /etc/resolv.conf"
    exit 1
fi
for ns in $DNS_SERVERS; do
    echo "Allowing DNS to $ns"
    iptables -A OUTPUT -p udp --dport 53 -d "$ns" -j ACCEPT
    iptables -A INPUT  -p udp --sport 53 -s "$ns" -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -d "$ns" -j ACCEPT
    iptables -A INPUT  -p tcp --sport 53 -s "$ns" -j ACCEPT
    if [ "$ns" = "127.0.0.11" ]; then
        iptables -A OUTPUT -p udp --dport 53 -m conntrack --ctorigdst 127.0.0.11 -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -m conntrack --ctorigdst 127.0.0.11 -j ACCEPT
    fi
done
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

echo "Fetching AWS IP ranges..."
aws_ranges=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json)
if [ -z "$aws_ranges" ]; then
    echo "ERROR: Failed to fetch AWS IP ranges"
    exit 1
fi
if ! echo "$aws_ranges" | jq -e '.prefixes' >/dev/null; then
    echo "ERROR: AWS ip-ranges response missing .prefixes"
    exit 1
fi
echo "Processing AWS IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR from AWS ip-ranges: $cidr"
        exit 1
    fi
    ipset add -exist allowed-domains "$cidr"
done < <(echo "$aws_ranges" | jq -r '.prefixes[] | select(.service=="AMAZON") | .ip_prefix' | aggregate -q)

for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "api.openai.com" \
    "auth.openai.com" \
    "chatgpt.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    ; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# __TEMPLATE_DOMAINS_BLOCK_START__
# __TEMPLATE_DOMAINS_BLOCK_END__

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

if ! curl --connect-timeout 5 https://sts.amazonaws.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://sts.amazonaws.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://sts.amazonaws.com as expected"
fi
