#!/usr/bin/env bash
set -e
sudo /usr/local/bin/init-firewall.sh
exec "$@"
