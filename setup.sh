#!/bin/bash
set -e

# ─────────────────────────────────────────
#  setup.sh — Debian bootstrap interactif
# ─────────────────────────────────────────

# Vérification root
if [ "$EUID" -ne 0 ]; then
  echo "Lance ce script en root (sudo bash setup.sh)"
  exit 1
fi

# Installer whiptail si absent
if ! command -v whiptail &> /dev/null; then
  apt-get update -qq && apt-get install -y whiptail
fi

# ── Menu de sélection ──────────────────────
CHOICES=$(whiptail --title "Debian Bootstrap" \
  --checklist "\nSélectionne les modules à installer :\n(ESPACE pour cocher, ENTRÉE pour valider)" \
  20 60 5 \
  "BASE"   "Outils de base (micro, btop, bat, dust, duf)" ON \
  "DOCKER" "Docker CE + Docker Compose v2"                OFF \
  "FISH"   "Fish shell + Fisher + plugins"                OFF \
  3>&1 1>&2 2>&3)

# Annulation
if [ $? -ne 0 ]; then
  echo "Installation annulée."
  exit 0
fi

echo ""
echo "════════════════════════════════════════"
echo "  Démarrage de l'installation"
echo "════════════════════════════════════════"

# ── MODULE : Outils de base ───────────────
if echo "$CHOICES" | grep -q "BASE"; then
  echo ""
  echo "── [BASE] Outils de base ──────────────"

  apt-get update -qq

  echo "→ Installation de micro..."
  apt-get install -y micro

  echo "→ Installation de btop..."
  apt-get install -y btop

  echo "→ Installation de bat..."
  apt-get install -y bat
  # Sur Debian, la commande s'appelle batcat
  if ! grep -q "alias bat='batcat'" ~/.bashrc; then
    echo "alias bat='batcat'" >> ~/.bashrc
    echo "  alias bat='batcat' ajouté dans ~/.bashrc"
  fi

  echo "→ Installation de du-dust..."
  apt-get install -y du-dust || {
    echo "  du-dust non trouvé dans apt, tentative via cargo..."
    apt-get install -y cargo
    cargo install du-dust
  }

  echo "→ Installation de duf..."
  apt-get install -y duf

  echo "→ Installation de fastfetch..."
  apt-get install -y fastfetch
  echo "fastfetch" > /etc/profile.d/fastfetch.sh
  chmod +x /etc/profile.d/fastfetch.sh

  echo "→ Installation de ncdu..."
  apt-get install -y ncdu
  
  echo "→ Installation de sysstat..."
  apt-get install -y sysstat
  
  echo "→ Installation de fail2ban..."
  apt-get install -y fail2ban
  systemctl enable fail2ban
  systemctl start fail2ban


  echo "✔ Outils de base installés."
fi

# ── MODULE : Docker ───────────────────────
if echo "$CHOICES" | grep -q "DOCKER"; then
  echo ""
  echo "── [DOCKER] Docker CE + Compose v2 ───"

  # Dépendances
  apt-get install -y ca-certificates curl gnupg lsb-release

  # Clé GPG officielle Docker
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Repo Docker (forky non supporté, on force bookworm)
  DEBIAN_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME}" | sed 's/forky/bookworm/g')
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    ${DEBIAN_CODENAME} stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Vérification
  docker --version
  docker compose version

  echo "✔ Docker CE + Compose v2 installés."
fi

# ── MODULE : Fish + Fisher ────────────────
if echo "$CHOICES" | grep -q "FISH"; then
  echo ""
  echo "── [FISH] Fish shell + Fisher + plugins ──"

  apt-get install -y fish

  # Script fish temporaire pour éviter les conflits avec bash
  cat > /tmp/fisher_setup.fish << 'EOF'
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher
fisher install edc/bass
EOF

  echo "→ Installation de Fisher + plugins..."
  fish /tmp/fisher_setup.fish
  rm /tmp/fisher_setup.fish

  # Fish comme shell par défaut (optionnel)
  FISH_PATH=$(which fish)
  if whiptail --title "Fish shell" \
    --yesno "Définir fish comme shell par défaut pour root ?" 8 50; then
    chsh -s "$FISH_PATH" root
    echo "✔ Fish défini comme shell par défaut."
  else
    echo "  Shell par défaut inchangé (bash)."
  fi

  echo "✔ Fish + Fisher + plugins installés."
fi

# ── Fin ───────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  ✔ Installation terminée !"
echo "  Recharge ton shell : source ~/.bashrc"
echo "════════════════════════════════════════"
