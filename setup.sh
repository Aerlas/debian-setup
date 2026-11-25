#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  setup.sh — Debian bootstrap interactif (convention homelab)
#  Usage : sudo bash setup.sh
#  Idempotent : peut être relancé sans risque.
#  Journal : /var/log/debian-setup.log
# ═══════════════════════════════════════════════════════════════════
set -e -o pipefail

# ── Paramètres de la convention (à adapter si besoin) ─────────────
ADMIN_USER="aerlas"                       # compte admin (sudo, accès direct via tailnet)
ADMIN_PUBKEY=""                           # clé publique 1Password (sinon demandée)
WARPGATE_PUBKEY=""                        # clé publique de Warpgate (sinon demandée)
SSH_PORT="722"                            # port SSH de la convention
STYX_IP="85.215.212.0"                    # IP publique de Styx (source Warpgate → VPS)
LAN_ROUTERS="10.7.70.42,10.7.70.43"       # routeurs de sous-réseau (source Warpgate → LAN)
LAN_NET="10.7.70.0/24"                    # LAN (accès direct aerlas à la maison)
TAILNET_NET="100.64.0.0/10"               # tailnet (accès direct aerlas)
PATCHMON_HOSTS_LINE="100.98.245.127 pireus.tail95de78.ts.net"   # résolution PatchMon sans MagicDNS
DOCKHAND_URL="wss://dockhand.aernas.eu/api/hawser/connect"

LOG=/var/log/debian-setup.log
TS=$(date +%Y%m%d-%H%M)

# ── Fonctions utilitaires ──────────────────────────────────────────
log()  { echo -e "\n── $* ──" | tee -a "$LOG"; }
info() { echo "→ $*" | tee -a "$LOG"; }
ok()   { echo "✔ $*" | tee -a "$LOG"; }
warn() { echo "⚠️  $*" | tee -a "$LOG"; }
backup() { [ -e "$1" ] && cp -a "$1" "$1.bak-$TS" && info "sauvegarde : $1.bak-$TS" || true; }
ask()  { whiptail --title "$1" --inputbox "$2" 12 78 "$3" 3>&1 1>&2 2>&3; }
yesno(){ whiptail --title "$1" --yesno "$2" 14 78; }
TODO=()

# ── Vérifications ─────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "Lance ce script en root (sudo bash setup.sh)"
  exit 1
fi
command -v whiptail >/dev/null || { apt-get update -qq && apt-get install -y whiptail; }
echo "=== Exécution du $(date) ===" >> "$LOG"

# ── Menu ──────────────────────────────────────────────────────────
CHOICES=$(whiptail --title "Debian Bootstrap — convention homelab" \
  --checklist "\nModules à installer (ESPACE pour cocher, ENTRÉE pour valider) :" \
  20 78 9 \
  "HOSTNAME"  "Nom de machine + protection cloud-init"           OFF \
  "BASE"      "Outils de base + fail2ban + accueil fastfetch"    ON  \
  "ADMIN"     "Compte admin ${ADMIN_USER} + clé 1Password"       ON  \
  "BASH"      "Bash amélioré (ble.sh, fzf, complétion)"          ON  \
  "TAILSCALE" "Tailscale + résolution PatchMon"                  OFF \
  "DOCKER"    "Docker CE + Compose v2 + live-restore"            OFF \
  "HAWSER"    "Agent Hawser Edge (Dockhand)"                     OFF \
  "SSH"       "Convention SSH (port ${SSH_PORT}, clés, AllowUsers)" OFF \
  3>&1 1>&2 2>&3) || { echo "Installation annulée."; exit 0; }

has() { echo "$CHOICES" | grep -q "\"$1\""; }

echo ""
echo "════════════════════════════════════════"
echo "  Démarrage de l'installation"
echo "════════════════════════════════════════"
apt-get update -qq

# ═══ MODULE : HOSTNAME ═════════════════════════════════════════════
if has HOSTNAME; then
  log "[HOSTNAME] Nom de machine"
  NEW_HOST=$(ask "Nom de machine" "Nom court de la machine (minuscules, ex. greyserver) :" "$(hostname -s)") || NEW_HOST=""
  if [ -n "$NEW_HOST" ]; then
    OLD_HOST=$(hostname -s)
    hostnamectl set-hostname "$NEW_HOST"
    backup /etc/hosts
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${NEW_HOST}/" /etc/hosts
    else
      echo "127.0.1.1 ${NEW_HOST}" >> /etc/hosts
    fi
    [ "$OLD_HOST" != "$NEW_HOST" ] && sed -i "s/\b${OLD_HOST}\b/${NEW_HOST}/g" /etc/hosts
    if [ -d /etc/cloud/cloud.cfg.d ]; then
      echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
      info "cloud-init : preserve_hostname activé"
    fi
    ok "Nom de machine : ${NEW_HOST}"
  fi
fi

# ═══ MODULE : BASE ═════════════════════════════════════════════════
if has BASE; then
  log "[BASE] Outils de base"
  apt-get install -y micro btop bat duf ncdu sysstat fastfetch fail2ban curl ca-certificates
  apt-get install -y du-dust || warn "du-dust indisponible dans apt (ignoré)"

  systemctl enable --now fail2ban

  # Accueil : fastfetch seul, uniquement en session interactive
  cat > /etc/profile.d/fastfetch.sh <<'EOF'
# Accueil fastfetch — convention homelab
case $- in *i*) ;; *) return 0 ;; esac
command -v fastfetch >/dev/null && fastfetch
EOF
  chmod 644 /etc/profile.d/fastfetch.sh

  # Accueil épuré : pas de texte légal Debian ni de ligne « Linux … »
  if [ -s /etc/motd ]; then backup /etc/motd; truncate -s 0 /etc/motd; fi
  [ -x /etc/update-motd.d/10-uname ] && chmod -x /etc/update-motd.d/10-uname

  ok "Outils de base installés, accueil fastfetch en place."
fi

# ═══ MODULE : ADMIN ════════════════════════════════════════════════
if has ADMIN; then
  log "[ADMIN] Compte ${ADMIN_USER}"
  [ -n "$ADMIN_PUBKEY" ] || ADMIN_PUBKEY=$(ask "Clé publique 1Password" \
    "Colle la clé publique de ta clé SSH 1Password\n(1Password → clé SSH → « Copier la clé publique ») :" "") || ADMIN_PUBKEY=""
  case "$ADMIN_PUBKEY" in ssh-*) ;; *) warn "Clé publique absente ou invalide : module ADMIN ignoré."; ADMIN_PUBKEY="";; esac

  if [ -n "$ADMIN_PUBKEY" ]; then
    apt-get install -y sudo
    id "$ADMIN_USER" &>/dev/null || adduser --disabled-password --gecos "" "$ADMIN_USER"

    # Droits sudo uniquement via sudoers.d (pas de groupe sudo : évite le piège de « sudo -v »)
    echo "${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${ADMIN_USER}"
    chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"
    visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}"
    id -nG "$ADMIN_USER" | grep -qw sudo && gpasswd -d "$ADMIN_USER" sudo || true

    HOME_ADMIN=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$HOME_ADMIN/.ssh"
    touch "$HOME_ADMIN/.ssh/authorized_keys"
    grep -qF "$ADMIN_PUBKEY" "$HOME_ADMIN/.ssh/authorized_keys" || echo "$ADMIN_PUBKEY" >> "$HOME_ADMIN/.ssh/authorized_keys"
    chown "$ADMIN_USER:$ADMIN_USER" "$HOME_ADMIN/.ssh/authorized_keys"
    chmod 600 "$HOME_ADMIN/.ssh/authorized_keys"
    ssh-keygen -lf "$HOME_ADMIN/.ssh/authorized_keys" | tee -a "$LOG"
    ok "Compte ${ADMIN_USER} prêt (sudo sans mot de passe, connexion par clé uniquement)."

    # Mot de passe root : uniquement pour la console de l'hébergeur (le SSH par mot de passe sera fermé)
    if passwd -S root | awk '{exit ($2=="P")?0:1}'; then
      info "root a déjà un mot de passe (vérifie qu'il est dans 1Password)."
    elif yesno "Mot de passe root" "root n'a pas de mot de passe utilisable.\n\nEn définir un MAINTENANT, pour la console de l'hébergeur uniquement ?\n(Le SSH par mot de passe sera désactivé : il ne servira qu'en local.)"; then
      passwd root
    else
      TODO+=("Définir un mot de passe root pour la console (passwd root), à stocker dans 1Password")
    fi
  fi
fi

# ═══ MODULE : BASH (bash amélioré) ═════════════════════════════════
install_better_bash() {   # $1 = utilisateur
  local user="$1" home
  home=$(getent passwd "$user" | cut -d: -f6)
  [ -d "$home" ] || return 0
  info "bash amélioré pour ${user}"

  # Shell de connexion : bash
  [ "$(getent passwd "$user" | cut -d: -f7)" = "/bin/bash" ] || chsh -s /bin/bash "$user"

  # ~/.bash_profile doit charger ~/.profile (qui charge ~/.bashrc)
  if [ -f "$home/.bash_profile" ] && ! grep -qE '\.profile|\.bashrc' "$home/.bash_profile"; then
    backup "$home/.bash_profile"
    echo '[ -f ~/.profile ] && . ~/.profile' > "$home/.bash_profile"
  fi
  [ -f "$home/.profile" ] || cp /etc/skel/.profile "$home/.profile"
  [ -f "$home/.bashrc" ]  || cp /etc/skel/.bashrc  "$home/.bashrc"

  # ble.sh dans ~/.local
  if [ ! -f "$home/.local/share/blesh/ble.sh" ]; then
    rm -rf "/tmp/ble.sh-$user"
    sudo -u "$user" -H bash -c "git clone --recursive --depth 1 --shallow-submodules \
      https://github.com/akinomyoga/ble.sh.git /tmp/ble.sh-$user \
      && make -C /tmp/ble.sh-$user install PREFIX=\$HOME/.local" \
      && rm -rf "/tmp/ble.sh-$user" || warn "installation de ble.sh échouée pour ${user}"
  fi

  # Bloc .bashrc (balisé, ajouté une seule fois)
  if ! grep -q '>>> bash amélioré >>>' "$home/.bashrc"; then
    backup "$home/.bashrc"
    cat >> "$home/.bashrc" <<'EOF'

# >>> bash amélioré >>>
[[ $- == *i* ]] && source ~/.local/share/blesh/ble.sh --noattach

HISTSIZE=50000
HISTFILESIZE=100000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend autocd cdspell globstar checkwinsize

[[ -r /usr/share/bash-completion/bash_completion ]] && . /usr/share/bash-completion/bash_completion
command -v batcat >/dev/null && alias bat='batcat'

if [[ ${BLE_VERSION-} ]]; then
  ble-import -d integration/fzf-completion
  ble-import -d integration/fzf-key-bindings
else
  command -v fzf >/dev/null && eval "$(fzf --bash)"
fi

[[ ${BLE_VERSION-} ]] && ble-attach
# <<< bash amélioré <<<
EOF
    chown "$user:$user" "$home/.bashrc"
  fi
  # Anciennes lignes fastfetch dans .bashrc (désormais gérées par /etc/profile.d/fastfetch.sh)
  sed -i '/command -v fastfetch.*&& fastfetch$/d; /^fastfetch$/d' "$home/.bashrc"
}

if has BASH; then
  log "[BASH] Bash amélioré"
  apt-get install -y bash-completion fzf git make gawk sudo
  install_better_bash root
  id "$ADMIN_USER" &>/dev/null && install_better_bash "$ADMIN_USER"

  # Ancienne config fish : retirer si plus aucun compte ne l'utilise
  if dpkg -s fish &>/dev/null && ! grep -q 'fish$' /etc/passwd; then
    if yesno "Fish" "fish est installé mais plus aucun compte ne l'utilise.\n\nLe désinstaller ?"; then
      apt-get purge -y fish fish-common
      rm -rf /root/.config/fish /root/.local/share/fish
    fi
  fi
  ok "Bash amélioré installé. Ferme TOUS les onglets vers cette machine puis reconnecte-toi."
fi

# ═══ MODULE : TAILSCALE ════════════════════════════════════════════
if has TAILSCALE; then
  log "[TAILSCALE] Tailscale"
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
  if ! tailscale status &>/dev/null; then
    info "Connexion au tailnet : ouvre l'URL affichée pour valider la machine."
    tailscale up --accept-dns=false
  fi
  tailscale set --accept-routes=false
  info "IP tailnet : $(tailscale ip -4 2>/dev/null | head -1)"

  # Résolution du nom de PatchMon sans MagicDNS
  grep -qF "${PATCHMON_HOSTS_LINE#* }" /etc/hosts || echo "$PATCHMON_HOSTS_LINE" >> /etc/hosts
  TODO+=("Console Tailscale : désactiver l'expiration de clé (Machines → $(hostname -s) → Disable key expiry)")
  ok "Tailscale opérationnel."
fi

# ═══ MODULE : DOCKER ═══════════════════════════════════════════════
if has DOCKER; then
  log "[DOCKER] Docker CE + Compose v2"
  if ! command -v docker >/dev/null; then
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}" | sed 's/forky/trixie/')
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  # live-restore : les conteneurs survivent au redémarrage du démon (mises à jour de docker-ce)
  DJ=/etc/docker/daemon.json
  mkdir -p /etc/docker
  if [ ! -s "$DJ" ]; then
    echo '{ "live-restore": true }' > "$DJ"
  elif ! grep -q '"live-restore": *true' "$DJ"; then
    backup "$DJ"
    apt-get install -y python3-minimal
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["live-restore"]=True; json.dump(d,open(p,"w"),indent=2)' "$DJ"
  fi
  dockerd --validate --config-file "$DJ"
  systemctl reload docker 2>/dev/null || systemctl restart docker
  docker info 2>/dev/null | grep -i 'live restore' | tee -a "$LOG"
  docker --version; docker compose version
  ok "Docker CE + Compose v2 installés, live-restore actif."
fi

# ═══ MODULE : HAWSER ═══════════════════════════════════════════════
if has HAWSER; then
  log "[HAWSER] Agent Hawser Edge"
  if ! command -v docker >/dev/null; then
    warn "Docker absent : module HAWSER ignoré (coche aussi DOCKER)."
  else
    HAWSER_TOKEN=$(ask "Jeton Hawser" "Dans Dockhand : Environnements → Ajouter → Hawser (Edge)\nColle le jeton généré :" "") || HAWSER_TOKEN=""
    if [ -n "$HAWSER_TOKEN" ]; then
      install -d /opt/docker/hawser
      cat > /opt/docker/hawser/docker-compose.yml <<'EOF'
services:
  hawser:
    image: ghcr.io/finsys/hawser:latest
    container_name: hawser
    restart: unless-stopped
    env_file: .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
      printf 'DOCKHAND_SERVER_URL=%s\nTOKEN=%s\n' "$DOCKHAND_URL" "$HAWSER_TOKEN" > /opt/docker/hawser/.env
      chmod 600 /opt/docker/hawser/.env
      (cd /opt/docker/hawser && docker compose up -d --force-recreate)
      info "Si les logs montrent « Rate limited », arrêter l'agent et attendre / redémarrer Dockhand."
      ok "Hawser démarré : vérifier « connected » dans Dockhand."
    else
      warn "Jeton vide : module HAWSER ignoré."
    fi
  fi
fi

# ═══ MODULE : SSH (convention) ═════════════════════════════════════
if has SSH; then
  log "[SSH] Convention d'accès SSH"
  SSH_OK=1

  # Garde-fous anti-blocage
  if systemctl is-active --quiet ssh.socket; then
    warn "ssh.socket est actif : la directive Port serait ignorée. Module SSH arrêté."; SSH_OK=0
  fi
  HOME_ADMIN=$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)
  if [ -z "$HOME_ADMIN" ] || [ ! -s "$HOME_ADMIN/.ssh/authorized_keys" ]; then
    warn "${ADMIN_USER} absent ou sans clé : module SSH arrêté (lance ADMIN d'abord)."; SSH_OK=0
  fi
  if [ "$SSH_OK" = 1 ] && ! tailscale status &>/dev/null; then
    yesno "Tailscale inactif" "Tailscale n'est pas actif : l'accès direct de ${ADMIN_USER} (via le tailnet) ne fonctionnera pas.\n\nContinuer quand même ?" || SSH_OK=0
  fi

  if [ "$SSH_OK" = 1 ]; then
    PROFILE=$(whiptail --title "Profil de la machine" --radiolist \
      "D'où Warpgate joint-il cette machine ?" 12 78 2 \
      "VPS" "par Internet, depuis Styx (${STYX_IP})"          ON \
      "LAN" "par le tailnet, via les routeurs (${LAN_ROUTERS})" OFF \
      3>&1 1>&2 2>&3) || PROFILE=""
    case "$PROFILE" in
      VPS) FROM="$STYX_IP"; ALLOW="root@${STYX_IP} ${ADMIN_USER}@${TAILNET_NET}" ;;
      LAN) FROM="$LAN_ROUTERS"
           ALLOW="${ADMIN_USER}@${TAILNET_NET} ${ADMIN_USER}@${LAN_NET}"
           for r in ${LAN_ROUTERS//,/ }; do ALLOW="root@${r} ${ALLOW}"; done ;;
      *)   SSH_OK=0; warn "Aucun profil choisi : module SSH arrêté." ;;
    esac
  fi

  if [ "$SSH_OK" = 1 ]; then
    [ -n "$WARPGATE_PUBKEY" ] || WARPGATE_PUBKEY=$(ask "Clé publique de Warpgate" \
      "Colle la clé publique ed25519 de Warpgate\n(interface Warpgate → Config → SSH → clés propres à Warpgate) :" "") || WARPGATE_PUBKEY=""
    case "$WARPGATE_PUBKEY" in ssh-*) ;; *) warn "Clé Warpgate invalide : module SSH arrêté."; SSH_OK=0;; esac
  fi

  if [ "$SSH_OK" = 1 ] && yesno "Confirmation" "Le compte root n'acceptera PLUS que la clé de Warpgate, depuis ${FROM}.\nToute autre clé de root sera retirée (sauvegarde conservée).\n\nGarde une session ouverte pendant les tests. Continuer ?"; then
    # 1. root : uniquement la clé Warpgate, limitée à sa source
    install -d -m 700 /root/.ssh
    backup /root/.ssh/authorized_keys
    echo "from=\"${FROM}\" ${WARPGATE_PUBKEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # 2. sshd : port 22 conservé pendant la transition
    KEEP22=""
    yesno "Transition" "Garder aussi le port 22 pendant la transition ?\n(À retirer après avoir validé Warpgate sur ${SSH_PORT} et le pare-feu.)" && KEEP22="Port 22                              # TEMPORAIRE : retirer après validation"
    CONF=/etc/ssh/sshd_config.d/00-homelab.conf
    backup "$CONF"
    cat > "$CONF" <<EOF
# Convention homelab — voir fiche Notion « Convention d'accès SSH »
${KEEP22}
Port ${SSH_PORT}
AddressFamily inet
AllowUsers ${ALLOW}
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    sed -i '/^$/d' "$CONF"
    if sshd -t; then
      systemctl reload ssh
      sshd -T | grep -E '^(port|addressfamily|allowusers|permitrootlogin|passwordauthentication) ' | tee -a "$LOG"
      ss -tlnp | grep sshd | tee -a "$LOG"
    else
      warn "Configuration sshd invalide : restauration de l'état précédent."
      if [ -f "$CONF.bak-$TS" ]; then mv "$CONF.bak-$TS" "$CONF"; else rm -f "$CONF"; fi
      SSH_OK=0
    fi

    # 3. fail2ban sur le bon port (Debian 13 : backend systemd)
    if [ "$SSH_OK" = 1 ] && command -v fail2ban-client >/dev/null; then
      printf '[sshd]\nport = %s\nbackend = systemd\n' "$SSH_PORT" > /etc/fail2ban/jail.d/sshd-homelab.local
      systemctl restart fail2ban
    fi

    if [ "$SSH_OK" = 1 ]; then
      ok "Convention SSH appliquée."
      TODO+=("Warpgate : cible $(hostname -s) → utilisateur root, port ${SSH_PORT} (Check host key)")
      TODO+=("Tester : connexion via Warpgate (root) ET ssh -p ${SSH_PORT} ${ADMIN_USER}@<IP tailnet> (Proton coupé)")
      [ "$PROFILE" = "VPS" ] && TODO+=("Pare-feu hébergeur : TCP ${SSH_PORT} depuis ${STYX_IP} uniquement, 22 fermé (OVH : règles Refuser explicites ; IONOS : liste d'autorisations)")
      [ "$PROFILE" = "VPS" ] && TODO+=("Contrôle externe (Proton coupé) : Test-NetConnection <IP publique> -Port ${SSH_PORT} → False")
      [ -n "$KEEP22" ] && TODO+=("Après validation : sed -i '/^Port 22/d' ${CONF} && sshd -t && systemctl reload ssh")
      TODO+=("Verrouiller l'ancien compte par défaut (ex. debian) : usermod -L -s /usr/sbin/nologin <compte>")
    fi
  fi
fi

# ── Fin ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  ✔ Installation terminée"
echo "  Journal : ${LOG}"
echo "════════════════════════════════════════"
TODO+=("PatchMon : ajouter l'hôte et lancer la commande d'installation de l'agent")
echo ""
echo "Reste à faire :"
for t in "${TODO[@]}"; do echo "  ☐ $t" | tee -a "$LOG"; done
echo ""
echo "Rappel : ferme TOUS les onglets vers cette machine avant de vérifier le shell (connexion SSH partagée)."
