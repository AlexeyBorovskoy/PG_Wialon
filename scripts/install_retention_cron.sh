#!/usr/bin/env bash
set -euo pipefail

# Install daily retention job on Linux host.
# Usage:
#   sudo ./scripts/install_retention_cron.sh
# Optional env:
#   DB_NAME=wialon_wifi

DB_NAME="${DB_NAME:-wialon_wifi}"
TARGET="/etc/cron.daily/wialon-retention"

cat > /tmp/wialon-retention.cron <<EOF
#!/bin/sh
set -eu
su -s /bin/sh postgres -c '/usr/bin/psql -v ON_ERROR_STOP=1 -d ${DB_NAME} -c "SELECT * FROM wialon.run_retention(now());"'
EOF

install -o root -g root -m 0755 /tmp/wialon-retention.cron "$TARGET"
rm -f /tmp/wialon-retention.cron

echo "Installed: $TARGET"
"$TARGET"
