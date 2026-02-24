#!/usr/bin/env bash
set -euo pipefail

# Harden network exposure for Wialon receiver and PostgreSQL.
#
# Required env:
#   WIALON_ALLOW_CIDRS="192.168.1.230/32,10.10.0.0/16"
#   PG_ALLOW_CIDRS="203.0.113.10/32"
#
# Optional:
#   SSH_ALLOW_CIDRS="198.51.100.10/32"
#   SSH_PORT=22
#   WIALON_PORT=20332
#   PG_PORT=5432

WIALON_ALLOW_CIDRS="${WIALON_ALLOW_CIDRS:-}"
PG_ALLOW_CIDRS="${PG_ALLOW_CIDRS:-}"
SSH_ALLOW_CIDRS="${SSH_ALLOW_CIDRS:-}"
SSH_PORT="${SSH_PORT:-22}"
WIALON_PORT="${WIALON_PORT:-20332}"
PG_PORT="${PG_PORT:-5432}"

if [[ -z "$WIALON_ALLOW_CIDRS" || -z "$PG_ALLOW_CIDRS" ]]; then
  echo "ERROR: Set WIALON_ALLOW_CIDRS and PG_ALLOW_CIDRS"
  exit 1
fi

IFS=',' read -r -a wialon_cidrs <<< "$WIALON_ALLOW_CIDRS"
IFS=',' read -r -a pg_cidrs <<< "$PG_ALLOW_CIDRS"
IFS=',' read -r -a ssh_cidrs <<< "$SSH_ALLOW_CIDRS"

echo "Current UFW status:"
ufw status numbered || true

echo
if [[ -n "$SSH_ALLOW_CIDRS" ]]; then
  echo "Applying SSH restrictions on port $SSH_PORT"
  for cidr in "${ssh_cidrs[@]}"; do
    [[ -z "$cidr" ]] && continue
    ufw allow from "$cidr" to any port "$SSH_PORT" proto tcp
  done
else
  echo "Keeping SSH open on port $SSH_PORT"
  ufw allow "$SSH_PORT"/tcp
fi

echo "Applying Wialon ingress rules on port $WIALON_PORT"
for cidr in "${wialon_cidrs[@]}"; do
  [[ -z "$cidr" ]] && continue
  ufw allow from "$cidr" to any port "$WIALON_PORT" proto tcp
done

echo "Applying PostgreSQL rules on port $PG_PORT"
for cidr in "${pg_cidrs[@]}"; do
  [[ -z "$cidr" ]] && continue
  ufw allow from "$cidr" to any port "$PG_PORT" proto tcp
done

cat <<EOF

IMPORTANT:
1) Manually remove broad legacy rules like:
   ufw delete allow ${WIALON_PORT}/tcp
   ufw delete allow ${PG_PORT}/tcp
2) Re-check remote SSH access from your admin host before ending session.
3) Final check:
   ufw status numbered
EOF
