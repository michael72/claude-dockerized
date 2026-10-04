#!/bin/bash
# Default-deny egress with a resolved-domain allowlist. Same approach as the
# init-firewall.sh in Anthropic's reference dev container.
#
# Caveat worth knowing before you rely on it: this resolves names to IPs once,
# at container start. api.anthropic.com and friends sit behind CDNs whose
# address sets rotate, so long-lived containers can lose connectivity, and any
# other tenant on the same CDN IP is reachable. It raises the cost of
# exfiltration; it is not an airtight boundary. A forward proxy that filters on
# SNI/Host is the stronger option if you need one.
set -euo pipefail

ALLOWLIST="${CLAUDE_ALLOWED_DOMAINS:-/etc/claude-dockerized/allowed-domains.txt}"

iptables -F || true
iptables -X || true
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net

# Loopback and established flows.
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS has to work for the rest to mean anything.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Keep the host<->container subnet reachable (editor, port forwards).
host_net="$(ip route | awk '/default/ {print $3}' | head -n1)"
if [ -n "$host_net" ]; then
    subnet="$(ip route | grep -v default | awk '/src/ {print $1}' | head -n1)"
    [ -n "$subnet" ] && iptables -A OUTPUT -d "$subnet" -j ACCEPT
fi

resolved=0
while read -r line || [ -n "$line" ]; do
    # Strip trailing comments: "api.anthropic.com   # why" -> "api.anthropic.com".
    domain="${line%%#*}"
    domain="${domain//[[:space:]]/}"
    [ -z "$domain" ] && continue
    ips="$(dig +short +time=3 +tries=2 A "$domain" | grep -E '^[0-9.]+$' || true)"
    for ip in $ips; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
        resolved=$((resolved + 1))
    done
done < "$ALLOWLIST"

if [ "$resolved" -eq 0 ]; then
    echo "init-firewall: nothing resolved from $ALLOWLIST" >&2
    exit 1
fi

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP

echo "init-firewall: $resolved addresses allowed"
