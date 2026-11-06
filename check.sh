#!/usr/bin/env bash
# check.sh : repasse les checkpoints du cours.
#   sur srv-lab : lots 1 et 2   |   sur le VPS : lots 1, 3 et 4
# Usage : sudo ./check.sh        (DOMAIN=benjamin.lab-cesi.fr par défaut)
set -u

DOMAIN="${DOMAIN:-benjamin.lab-cesi.fr}"
PROJET="${PROJET:-/srv/plateforme}"
OK=0; KO=0

ok() { printf '  [OK] %s\n' "$1"; OK=$((OK+1)); }
ko() { printf '  [KO] %s\n' "$1"; KO=$((KO+1)); }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else ko "$label"; fi; }

if [ "$(id -u)" -ne 0 ]; then echo "Lancer avec sudo : sudo ./check.sh"; exit 2; fi

# ------------------------------------------------------------------ lot 1
lot1() {
  echo "== Lot 1 : machine propre et joignable ($(hostname))"
  local sshd; sshd="$(sshd -T 2>/dev/null)"
  check "SSH : mot de passe refusé"        grep -qx 'passwordauthentication no' <<<"$sshd"
  check "SSH : root refusé"                grep -qx 'permitrootlogin no' <<<"$sshd"
  check "SSH : clé publique acceptée"      grep -qx 'pubkeyauthentication yes' <<<"$sshd"
  check "unattended-upgrades installé"     dpkg -s unattended-upgrades
  check "mises à jour auto activées"       grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
  check "route par défaut présente"        bash -c 'ip r | grep -q "^default"'
  check "ping Internet (1.1.1.1)"          ping -c1 -W3 1.1.1.1
  check "résolution DNS (cesi.fr)"         bash -c '[ -n "$(getent ahostsv4 cesi.fr)" ]'
}

# ------------------------------------------------------------------ lot 2 (srv-lab)
lot2() {
  echo "== Lot 2 : services locaux"
  check "GLPI répond (glpi.lab)"           bash -c 'curl -s -o /dev/null -w "%{http_code}" -H "Host: glpi.lab" http://127.0.0.1/ | grep -Eq "^(200|302)$"'
  check "MariaDB n'écoute qu'en local"     bash -c '! ss -tlnH "sport = :3306" | grep -vqE "127\.0\.0\.1|\[::1\]"'
  if [ -f "$PROJET/compose.yaml" ]; then
    check "Kuma tourne en conteneur"       bash -c "cd $PROJET && docker compose ps --status running --services | grep -qx kuma"
    check "ntfy tourne en conteneur"       bash -c "cd $PROJET && docker compose ps --status running --services | grep -qx ntfy"
  else
    ko "pas de $PROJET/compose.yaml sur cette machine"
  fi
}

# ------------------------------------------------------------------ lot 3 (VPS)
lot3() {
  echo "== Lot 3 : VPS public mais fermé"
  local ports
  ports="$(ss -tlnH | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un | tr '\n' ' ')"
  if [ -z "$(tr ' ' '\n' <<<"$ports" | grep -vxE '22|80|443|')" ]; then ok "seuls 22/80/443 écoutent ($ports)"; else ko "ports exposés en trop : $ports"; fi
  check "nftables : policy drop en entrée" bash -c 'nft list chain inet filter input | grep -q "policy drop"'
  check "CrowdSec bloque déjà des IP"      bash -c '[ "$(cscli decisions list -a -o raw 2>/dev/null | wc -l)" -gt 1 ]'
  local ip; ip="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
  for n in status notif; do
    check "$n.$DOMAIN pointe vers mon IP ($ip)" bash -c "[ \"\$(getent ahostsv4 $n.$DOMAIN | awk 'NR==1{print \$1}')\" = '$ip' ]"
    check "https://$n.$DOMAIN répond"           bash -c "curl -s -o /dev/null -w '%{http_code}' https://$n.$DOMAIN | grep -Eq '^(200|302)$'"
    check "http://$n.$DOMAIN redirige en https" bash -c "curl -sI http://$n.$DOMAIN | grep -qi '^location: https://'"
  done
}

# ------------------------------------------------------------------ lot 4 (VPS)
lot4() {
  echo "== Lot 4 : supervision, sauvegarde, reconstruction"
  for s in caddy kuma ntfy; do
    check "conteneur $s en marche"         bash -c "cd $PROJET && docker compose ps --status running --services | grep -qx $s"
  done
  check "timer de sauvegarde actif"        systemctl is-active backup-plateforme.timer
  check "snapshot restic de moins de 26 h" bash -c 'export RESTIC_REPOSITORY=/var/backups/restic RESTIC_PASSWORD_FILE=/root/.restic-pass;
      t=$(restic snapshots --latest 1 --json | grep -o "\"time\":\"[^\"]*\"" | tail -1 | cut -d\" -f4);
      [ -n "$t" ] && [ $(( $(date +%s) - $(date -d "$t" +%s) )) -lt 93600 ]'
  check "playbook présent dans le dépôt"   test -f "$PROJET/ansible/site.yml"
}

case "$(hostname)" in
  srv-lab) lot1; lot2 ;;
  *)       lot1; lot3; lot4 ;;
esac

echo "== Bilan : $OK OK, $KO KO"
exit "$KO"
