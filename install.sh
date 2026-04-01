#!/bin/bash
# install.sh — FSLB Client Installer / Upgrader  (script autocontenido)
#
# Uso:
#   sudo bash install.sh
#
# No requiere archivos adicionales: descarga el binario del servidor si no
# existe localmente y embebe todas las unidades systemd necesarias.
#
# Qué instala:
#   /usr/sap/02-FSLB/imountd        → daemon principal
#   /usr/sap/02-FSLB/imountd.conf   → configuración (si no existe)
#   /usr/local/bin/imountd-update   → script de auto-actualización
#   /etc/systemd/system/            → imountd@.service, imountd-update.{service,timer}

set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step() { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; }
warn() { echo -e "  ${YELLOW}!${NC}  $1"; }
fail() { echo -e "  ${RED}✗${NC}  $1"; }
die()  { fail "$1"; exit 1; }

# ── Rutas de instalación ─────────────────────────────────────────────────────
WORK_DIR="/usr/sap/02-FSLB"
INSTALL_BIN="${WORK_DIR}/imountd"
INSTALL_UPD="/usr/local/bin/imountd-update"
CONF_FILE="${WORK_DIR}/imountd.conf"
SYSTEMD_DIR="/etc/systemd/system"
LOG_FILE="/var/log/imountd.log"
FSLB_WEB_PORT=3000

# ── Header ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║     FSLB Client Installer  ·  v1.0          ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"

# ── Verificar root ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Ejecutar como root: sudo bash install.sh"

# ── Verificar dependencias ────────────────────────────────────────────────────
step "Verificando dependencias"
MISSING=false
for cmd in rsync ssh nc sha256sum curl; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd"
    else
        case "$cmd" in
            rsync)     HINT="rsync" ;;
            ssh)       HINT="openssh" ;;
            nc)        HINT="netcat-openbsd" ;;
            sha256sum) HINT="coreutils" ;;
            curl)      HINT="curl" ;;
        esac
        fail "$cmd no encontrado  →  zypper install ${HINT}  /  apt install ${HINT}"
        MISSING=true
    fi
done
[[ "$MISSING" == "true" ]] && die "Instala las dependencias faltantes."

# ── Configuración (se necesita SERVER_IP antes de descargar el binario) ──────
step "Configuración"
mkdir -p "$WORK_DIR"

if [[ -f "$CONF_FILE" ]]; then
    ok "Configuración existente conservada: $CONF_FILE"
    SERVER_IP=$(head -1 "$CONF_FILE" | tr -d '[:space:]')
    AUTH_KEY_VAL=$(sed -n '2p' "$CONF_FILE" | tr -d '[:space:]')
    ok "  Servidor: $SERVER_IP"
    CONF_EXISTED=true
else
    echo ""
    echo -e "  ${YELLOW}Configuración inicial requerida${NC}"
    echo ""
    while true; do
        read -rp "  IP o hostname del servidor FSLB: " SERVER_IP
        [[ -n "$SERVER_IP" ]] && break
        echo "  No puede estar vacío."
    done
    read -rp "  Auth key (UUID del cliente, Enter para omitir): " AUTH_KEY_VAL
    AUTH_KEY_VAL="${AUTH_KEY_VAL:-none}"
    CONF_EXISTED=false
fi

# ── Obtener binario (local o descarga desde el servidor) ─────────────────────
step "Binario imountd"
if [[ -f "./imountd" && -x "./imountd" ]]; then
    ok "Binario local encontrado"
    LOCAL_BIN="./imountd"
else
    warn "Binario local no encontrado — descargando desde el servidor..."

    if ! timeout 5 bash -c "echo >/dev/tcp/${SERVER_IP}/${FSLB_WEB_PORT}" 2>/dev/null; then
        die "No se puede conectar a ${SERVER_IP}:${FSLB_WEB_PORT} — verifica la red y el servidor FSLB"
    fi

    DOWNLOAD_URL="http://${SERVER_IP}:${FSLB_WEB_PORT}/update/download"
    CHECKSUM_URL="http://${SERVER_IP}:${FSLB_WEB_PORT}/update/checksum"
    TMPBIN="/tmp/fslb_imountd_$$"

    HTTP_STATUS=$(curl -s -o "${TMPBIN}" -w "%{http_code}" \
        "${DOWNLOAD_URL}" --connect-timeout 10 2>/dev/null)

    if [[ "$HTTP_STATUS" != "200" ]]; then
        rm -f "$TMPBIN"
        die "No se pudo descargar el binario (HTTP ${HTTP_STATUS}). Publica uno desde la Web UI → Update Management."
    fi

    # Verificar SHA-256 si el servidor tiene checksum publicado
    CS_STATUS=$(curl -s -o "/tmp/fslb_checksum_$$" -w "%{http_code}" \
        "${CHECKSUM_URL}" --connect-timeout 5 2>/dev/null)
    if [[ "$CS_STATUS" == "200" ]]; then
        # El checksum está referenciado como "imountd" — adaptar al path temporal
        sed "s|imountd|${TMPBIN}|g" "/tmp/fslb_checksum_$$" > "/tmp/fslb_cs_check_$$"
        if sha256sum -c "/tmp/fslb_cs_check_$$" --status 2>/dev/null; then
            ok "SHA-256 verificado"
        else
            rm -f "$TMPBIN" "/tmp/fslb_checksum_$$" "/tmp/fslb_cs_check_$$"
            die "Verificación SHA-256 fallida — binario descargado corrupto"
        fi
        rm -f "/tmp/fslb_checksum_$$" "/tmp/fslb_cs_check_$$"
    else
        warn "Sin checksum publicado — omitiendo verificación SHA-256"
    fi

    chmod +x "$TMPBIN"
    LOCAL_BIN="$TMPBIN"
    ok "Descarga completada desde ${DOWNLOAD_URL}"
fi

NEW_VER=$("$LOCAL_BIN" -v 2>/dev/null | awk '{print $2}' || echo "?")
ok "imountd v${NEW_VER} listo para instalar"

# ── Estado de instalación actual ─────────────────────────────────────────────
step "Estado de instalación actual"
if [[ -x "$INSTALL_BIN" ]]; then
    CUR_VER=$("$INSTALL_BIN" -v 2>/dev/null | awk '{print $2}' || echo "?")
    if [[ "$CUR_VER" == "$NEW_VER" ]]; then
        warn "Misma versión ya instalada (v${CUR_VER}). Reinstalando de todas formas."
    else
        warn "Actualizando: v${CUR_VER} → v${NEW_VER}"
    fi
    IS_UPGRADE=true
else
    ok "Primera instalación de imountd"
    IS_UPGRADE=false
fi

# ── Detener instancias activas (solo si actualizamos) ────────────────────────
ACTIVE_UNITS=()
if [[ "$IS_UPGRADE" == "true" ]]; then
    step "Deteniendo instancias activas"
    mapfile -t ACTIVE_UNITS < <(systemctl list-units --type=service --state=active \
        --plain --no-legend 2>/dev/null | awk '{print $1}' | grep '^imountd@' || true)
    if [[ ${#ACTIVE_UNITS[@]} -gt 0 ]]; then
        systemctl stop "${ACTIVE_UNITS[@]}" 2>/dev/null || true
        ok "Detenidas: ${ACTIVE_UNITS[*]}"
    else
        ok "Sin instancias activas"
    fi
fi

# ── Instalar binario principal ────────────────────────────────────────────────
step "Instalando imountd"
install -m 755 "$LOCAL_BIN" "$INSTALL_BIN"
[[ "$LOCAL_BIN" == /tmp/* ]] && rm -f "$LOCAL_BIN"
ok "imountd v${NEW_VER}  →  ${INSTALL_BIN}"

# ── Escribir configuración si es nueva instalación ───────────────────────────
if [[ "$CONF_EXISTED" == "false" ]]; then
    printf '%s\n%s\n' "$SERVER_IP" "$AUTH_KEY_VAL" > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    ok "Configuración guardada: $CONF_FILE"
fi

# ── Instalar script de auto-actualización (embebido) ─────────────────────────
step "Instalando imountd-update"
cat > "$INSTALL_UPD" << 'UPDATER_EOF'
#!/bin/bash
# imountd-update — Auto-updater embebido por install.sh
set -euo pipefail

CONF_FILE="/usr/sap/02-FSLB/imountd.conf"
UPDATE_WORK="/tmp/fslb-update"
INSTALL_PATH="/usr/sap/02-FSLB/imountd"
FSLB_WEB_PORT=3000

[[ -f "$CONF_FILE" ]] || { logger -t imountd-update "ERROR: $CONF_FILE no encontrado"; exit 1; }
SERVER_IP=$(head -1 "$CONF_FILE" | tr -d '[:space:]')
[[ -n "$SERVER_IP" ]] || { logger -t imountd-update "ERROR: SERVER_IP vacío en $CONF_FILE"; exit 1; }

BASE_URL="http://${SERVER_IP}:${FSLB_WEB_PORT}"
mkdir -p "$UPDATE_WORK"

# Obtener versión disponible via HTTP
AVAILABLE_VER=$(curl -sf --connect-timeout 10 "${BASE_URL}/update/version" 2>/dev/null | tr -d '[:space:]') || true
if [[ -z "$AVAILABLE_VER" || "$AVAILABLE_VER" == "0" ]]; then
    logger -t imountd-update "WARN: no se pudo obtener versión disponible desde ${SERVER_IP} — omitiendo"
    exit 0
fi

CURRENT_VER=$([[ -x "$INSTALL_PATH" ]] && "$INSTALL_PATH" -v 2>/dev/null | awk '{print $2}' || echo "none")
[[ "$AVAILABLE_VER" == "$CURRENT_VER" ]] && exit 0

logger -t imountd-update "Actualización disponible: v${AVAILABLE_VER} (instalado: v${CURRENT_VER}) — descargando..."

TMPBIN="${UPDATE_WORK}/imountd"
HTTP_STATUS=$(curl -s -o "${TMPBIN}" -w "%{http_code}" \
    "${BASE_URL}/update/download" --connect-timeout 15 2>/dev/null)
if [[ "$HTTP_STATUS" != "200" ]]; then
    logger -t imountd-update "ERROR: descarga fallida (HTTP ${HTTP_STATUS}) — abortando"
    rm -f "$TMPBIN"
    exit 1
fi

# Verificar SHA-256 si está disponible
CS_STATUS=$(curl -s -o "${UPDATE_WORK}/checksum.sha256" -w "%{http_code}" \
    "${BASE_URL}/update/checksum" --connect-timeout 5 2>/dev/null)
if [[ "$CS_STATUS" == "200" ]]; then
    sed "s|imountd|${TMPBIN}|g" "${UPDATE_WORK}/checksum.sha256" > "${UPDATE_WORK}/cs_check"
    if ! sha256sum -c "${UPDATE_WORK}/cs_check" --status 2>/dev/null; then
        logger -t imountd-update "ERROR: SHA-256 inválido — abortando"
        rm -f "${TMPBIN}" "${UPDATE_WORK}/checksum.sha256" "${UPDATE_WORK}/cs_check"
        exit 1
    fi
    rm -f "${UPDATE_WORK}/checksum.sha256" "${UPDATE_WORK}/cs_check"
    logger -t imountd-update "SHA-256 verificado"
fi

chmod 755 "$TMPBIN"
mapfile -t ACTIVE_UNITS < <(systemctl list-units --type=service --state=active \
    --plain --no-legend 2>/dev/null | awk '{print $1}' | grep '^imountd@' || true)
[[ ${#ACTIVE_UNITS[@]} -gt 0 ]] && systemctl stop "${ACTIVE_UNITS[@]}" 2>/dev/null || true
cp "$TMPBIN" "$INSTALL_PATH"
rm -f "$TMPBIN"
[[ ${#ACTIVE_UNITS[@]} -gt 0 ]] && systemctl start "${ACTIVE_UNITS[@]}" 2>/dev/null || true

logger -t imountd-update "imountd actualizado a v${AVAILABLE_VER}"
UPDATER_EOF
chmod 755 "$INSTALL_UPD"
ok "imountd-update  →  ${INSTALL_UPD}"

# ── Crear log file ────────────────────────────────────────────────────────────
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
    ok "Log creado: $LOG_FILE"
else
    ok "Log existente conservado: $LOG_FILE"
fi

# ── Instalar unidades systemd (embebidas) ─────────────────────────────────────
step "Instalando unidades systemd"

cat > "${SYSTEMD_DIR}/imountd@.service" << 'UNIT1_EOF'
[Unit]
Description=imountd instance %i
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/sap/02-FSLB
ExecStartPre=/usr/bin/test -f /usr/sap/02-FSLB/imountd.conf
ExecStart=/usr/sap/02-FSLB/imountd %i --foreground
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=30
KillMode=process
KillSignal=SIGTERM
TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT1_EOF

cat > "${SYSTEMD_DIR}/imountd-update.service" << 'UNIT2_EOF'
[Unit]
Description=FSLB imountd auto-update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/imountd-update
WorkingDirectory=/usr/sap/02-FSLB
StandardOutput=journal
StandardError=journal
UNIT2_EOF

cat > "${SYSTEMD_DIR}/imountd-update.timer" << 'UNIT3_EOF'
[Unit]
Description=FSLB imountd auto-update timer

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
RandomizedDelaySec=300
Unit=imountd-update.service

[Install]
WantedBy=timers.target
UNIT3_EOF

chmod 644 "${SYSTEMD_DIR}/imountd@.service" \
          "${SYSTEMD_DIR}/imountd-update.service" \
          "${SYSTEMD_DIR}/imountd-update.timer"
ok "imountd@.service"
ok "imountd-update.service"
ok "imountd-update.timer"
systemctl daemon-reload

# ── Habilitar timer de actualización automática ───────────────────────────────
step "Habilitando timer de auto-actualización"
systemctl enable --now imountd-update.timer >/dev/null 2>&1
TIMER_STATUS=$(systemctl is-active imountd-update.timer 2>/dev/null || echo "unknown")
ok "imountd-update.timer  →  ${TIMER_STATUS}"

# ── Reiniciar instancias que estaban corriendo ────────────────────────────────
if [[ "${#ACTIVE_UNITS[@]}" -gt 0 ]]; then
    step "Reiniciando instancias anteriores"
    systemctl start "${ACTIVE_UNITS[@]}" 2>/dev/null || true
    ok "Reiniciadas: ${ACTIVE_UNITS[*]}"
fi

# ── Configuración SSH ─────────────────────────────────────────────────────────
step "Configuración SSH"
REMOTE_PORT=22225
REMOTE_USER="fslbcp"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_PUBKEY="${SSH_KEY}.pub"
CLIENT_NAME=$(hostname -s)

if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -C "${CLIENT_NAME}@fslb" -f "$SSH_KEY" -q
    ok "Clave SSH generada: ${SSH_KEY}"
else
    ok "Clave SSH existente: ${SSH_KEY}"
fi

PUBKEY_CONTENT=$(cat "$SSH_PUBKEY")
SSH_REGISTERED=false

if [[ -n "$AUTH_KEY_VAL" && "$AUTH_KEY_VAL" != "none" ]]; then
    if timeout 5 bash -c "echo >/dev/tcp/${SERVER_IP}/${FSLB_WEB_PORT}" 2>/dev/null; then
        HTTP_STATUS=$(curl -s -o /tmp/fslb_pubkey_resp.json -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${AUTH_KEY_VAL}" \
            -H "Content-Type: application/json" \
            -d "{\"ssh_pubkey\": \"${PUBKEY_CONTENT}\"}" \
            "http://${SERVER_IP}:${FSLB_WEB_PORT}/api/pubkey/${CLIENT_NAME}" \
            --connect-timeout 5 2>/dev/null)
        if [[ "$HTTP_STATUS" == "200" ]]; then
            ok "Clave SSH registrada en servidor FSLB (${SERVER_IP})"
            SSH_REGISTERED=true
        elif [[ "$HTTP_STATUS" == "401" ]]; then
            warn "auth_key inválida — registrar clave SSH manualmente desde la Web UI"
        elif [[ "$HTTP_STATUS" == "404" ]]; then
            warn "Cliente '${CLIENT_NAME}' no encontrado en el servidor — crear primero desde la Web UI"
        else
            warn "No se pudo registrar la clave SSH (HTTP ${HTTP_STATUS})"
        fi
    else
        warn "Puerto ${FSLB_WEB_PORT} no alcanzable — registrar clave manualmente"
    fi
else
    warn "auth_key no configurada — registrar clave SSH manualmente desde la Web UI"
fi

if timeout 5 bash -c "echo >/dev/tcp/${SERVER_IP}/${REMOTE_PORT}" 2>/dev/null; then
    ok "Puerto ${REMOTE_PORT} alcanzable en ${SERVER_IP}"
    if timeout 5 ssh -p "$REMOTE_PORT" -q -i "$SSH_KEY" \
                     -o BatchMode=yes \
                     -o StrictHostKeyChecking=accept-new \
                     -o ConnectTimeout=4 \
                     "${REMOTE_USER}@${SERVER_IP}" exit 2>/dev/null; then
        ok "SSH fslbcp@${SERVER_IP}:${REMOTE_PORT}  →  OK"
    else
        if [[ "$SSH_REGISTERED" == "true" ]]; then
            warn "SSH aún no funciona — puede tardar unos segundos"
        else
            warn "SSH falló — registra la clave pública en el servidor"
            warn "  Clave: ${SSH_PUBKEY}"
        fi
    fi
else
    warn "Puerto ${REMOTE_PORT} no alcanzable en ${SERVER_IP} — revisa firewall/red"
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║      Instalación completada ✓  v${NEW_VER}         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo "  Para iniciar el monitoreo (CLIENT_NAME = hostname de este servidor):"
echo -e "    ${CYAN}systemctl enable --now imountd@${CLIENT_NAME}${NC}"
echo ""
echo "  Log en tiempo real:"
echo -e "    ${CYAN}journalctl -u imountd@${CLIENT_NAME} -f${NC}"
echo ""
echo "  El timer de auto-actualización revisa cada hora via SSH al puerto ${REMOTE_PORT}."
echo ""
