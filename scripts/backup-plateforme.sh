#!/bin/sh
set -eu
export RESTIC_REPOSITORY=/var/backups/restic
export RESTIC_PASSWORD_FILE=/root/.restic-pass
cd /srv/plateforme
docker compose stop kuma
trap 'docker compose start kuma' EXIT
restic backup /srv/plateforme /etc
restic forget --keep-daily 7 --keep-weekly 4 --prune
