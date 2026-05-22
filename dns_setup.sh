#!/bin/bash
# ============================================================
#   DNS Server: Unbound + AdGuard Home
#   Клиент → AGH:53 → Unbound:5353 → корневые серверы
#   Поддержка: Ubuntu/Debian, Fedora/RHEL, Arch
#   Опции: --dry-run  --uninstall
# ============================================================

set -euo pipefail

# ─── Цвета ──────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
C='\033[0;36m' B='\033[1m'   X='\033[0m'

ok()   { echo -e "${G}✅  $*${X}"; }
warn() { echo -e "${Y}⚠️   $*${X}"; }
err()  { echo -e "${R}❌  $*${X}"; }
info() { echo -e "${C}ℹ️   $*${X}"; }
hdr()  {
  echo -e "\n${B}${C}════════════════════════════════════════════════${X}"
  echo -e "${B}${C}  $1${X}"
  echo -e "${B}${C}════════════════════════════════════════════════${X}\n"
}
ask()  { echo -en "${B}  $*${X}"; }   # для read без read -p

# ─── Флаги ──────────────────────────────────────────────────
DRY=0; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
  esac
done

run() { [[ $DRY -eq 1 ]] && echo -e "${Y}[dry] $*${X}" || eval "$*"; }

# ─── Root ───────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { err "Запускать от root: sudo bash $0"; exit 1; }

# ════════════════════════════════════════════════════════════
#  УДАЛЕНИЕ
# ════════════════════════════════════════════════════════════
if [[ $UNINSTALL -eq 1 ]]; then
  hdr "Удаление AdGuard Home + Unbound"
  warn "Будут удалены: AdGuardHome, Unbound, правила iptables."
  ask "Продолжить? (y/n): "; read -r yn
  [[ ! "$yn" =~ ^[Yy]$ ]] && { warn "Отменено."; exit 0; }

  systemctl stop AdGuardHome 2>/dev/null || true
  systemctl disable AdGuardHome 2>/dev/null || true
  [[ -x /opt/AdGuardHome/AdGuardHome ]] && \
    /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
  rm -rf /opt/AdGuardHome
  ok "AdGuard Home удалён"

  systemctl stop unbound 2>/dev/null || true
  systemctl disable unbound 2>/dev/null || true
  command -v apt-get &>/dev/null && \
    apt-get remove -y unbound unbound-anchor 2>/dev/null || true
  rm -f /etc/unbound/unbound.conf
  rm -rf /etc/systemd/system/unbound.service.d
  ok "Unbound удалён"

  iptables -F; iptables -X
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
  ok "iptables → ACCEPT"

  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || \
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
  systemctl enable --now systemd-resolved 2>/dev/null || true
  ok "resolv.conf восстановлен"

  rm -f /etc/logrotate.d/unbound /etc/logrotate.d/adguardhome
  rm -rf /etc/dns_setup
  ok "Удаление завершено"
  exit 0
fi

# ─── Архитектура ────────────────────────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64)        echo "linux_amd64" ;;
    aarch64|arm64) echo "linux_arm64" ;;
    armv7l)        echo "linux_armv7" ;;
    armv6l)        echo "linux_armv6" ;;
    *) err "Неизвестная архитектура: $(uname -m)"; exit 1 ;;
  esac
}
AGH_ARCH=$(detect_arch)

# ─── Валидация IP / CIDR ────────────────────────────────────
valid_ip() {
  local i="$1"
  [[ "$i" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]] || return 1
  local ip="${i%%/*}"; local IFS='.'
  read -ra oct <<< "$ip"
  for o in "${oct[@]}"; do [[ $o -le 255 ]] || return 1; done
  return 0
}

# ════════════════════════════════════════════════════════════
#  WIZARD
# ════════════════════════════════════════════════════════════
clear
echo -e "${B}${C}"
cat <<'BANNER'
  ____  _   _ ____    ____       _
 |  _ \| \ | / ___|  / ___|  ___| |_ _   _ _ __
 | | | |  \| \___ \  \___ \ / _ \ __| | | | '_ \
 | |_| | |\  |___) |  ___) |  __/ |_| |_| | |_) |
 |____/|_| \_|____/  |____/ \___|\__|\__,_| .__/
                                           |_|
      Unbound (рекурсия) + AdGuard Home — установщик
BANNER
echo -e "${X}"
[[ $DRY -eq 1 ]] && warn "Режим --dry-run: ничего не будет записано на диск"
info "Архитектура: $(uname -m) → ${AGH_ARCH}"
echo

# ────────────────────────────────────────────────────────────
# 1/5  SSH
# ────────────────────────────────────────────────────────────
hdr "1/5 — SSH"

ask "SSH-порт [22]: "; read -r SSH_PORT
SSH_PORT=${SSH_PORT:-22}
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || \
  { err "Некорректный порт"; exit 1; }
ok "SSH-порт: ${SSH_PORT}"

echo
ask "Ограничить SSH только доверенными IP? (y/n): "; read -r yn
SSH_RESTRICTED=0
[[ "$yn" =~ ^[Yy]$ ]] && SSH_RESTRICTED=1
[[ $SSH_RESTRICTED -eq 1 ]] && \
  info "SSH будет разрешён только с IP из белого списка" || \
  warn "SSH открыт для всех IP — рекомендуется настроить fail2ban"

# ────────────────────────────────────────────────────────────
# 2/5  AdGuard Home: логин и пароль
# ────────────────────────────────────────────────────────────
hdr "2/5 — AdGuard Home: учётные данные"

ask "Логин [admin]: "; read -r AGH_USER
AGH_USER=${AGH_USER:-admin}

while true; do
  ask "Пароль: "; read -rs AGH_PASS; echo
  [[ -z "$AGH_PASS" ]] && { warn "Пароль не может быть пустым"; continue; }
  ask "Пароль ещё раз: "; read -rs AGH_PASS2; echo
  [[ "$AGH_PASS" == "$AGH_PASS2" ]] && break
  warn "Пароли не совпадают, повторите"
done
ok "Логин: ${AGH_USER} / пароль задан"

# ────────────────────────────────────────────────────────────
# 3/5  Разрешённые IP
# ────────────────────────────────────────────────────────────
hdr "3/5 — Разрешённые IP-адреса"
info "Только эти IP получат доступ к DNS-портам и панели AdGuard."
info "Если пропустить — порты будут открыты для всех (только для публичного DNS)."
echo

ALLOWED_IPS=()
ask "Ограничить доступ по IP? (y/n): "; read -r yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  echo -e "\n  Вводите IP или CIDR по одному. Пустая строка — завершить."
  while true; do
    ask "  IP / CIDR (или Enter для завершения): "; read -r NEW_IP
    [[ -z "$NEW_IP" ]] && break
    if valid_ip "$NEW_IP"; then
      ALLOWED_IPS+=("$NEW_IP")
      ok "Добавлен: $NEW_IP"
    else
      warn "Некорректный формат — ожидается 1.2.3.4 или 1.2.3.0/24"
    fi
  done
  if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    warn "Список пуст — доступ будет открыт для всех IP"
  else
    echo -e "\n  ${B}Белый список (${#ALLOWED_IPS[@]} записей):${X}"
    printf "    %s\n" "${ALLOWED_IPS[@]}"
  fi
else
  warn "Белый список IP не задан — доступ открыт для всех"
fi

# ────────────────────────────────────────────────────────────
# 4/5  Порты
# ────────────────────────────────────────────────────────────
hdr "4/5 — Разрешённые порты"

# Дефолт — только DNS-related
ALLOWED_PORTS=(53 853 80 443 784 5443)
echo -e "  ${B}Порты по умолчанию:${X} ${ALLOWED_PORTS[*]}"
info "53=DNS  853=DoT  80/443=HTTPS  784=DoQ  5443=DoH"
info "Порт 3000 (панель AGH) добавлен автоматически."
echo

ask "Добавить свои порты? (y/n): "; read -r yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  ask "  Введите через пробел: "; read -r -a EXTRA_PORTS
  for p in "${EXTRA_PORTS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] && \
      ALLOWED_PORTS+=("$p") || warn "Пропускаю некорректный порт: $p"
  done
fi
# Панель AGH всегда включена
ALLOWED_PORTS+=(3000)
echo -e "\n  ${B}Итоговые порты:${X} ${ALLOWED_PORTS[*]}"

# ────────────────────────────────────────────────────────────
# 5/5  TLS (необязательно)
# ────────────────────────────────────────────────────────────
hdr "5/5 — TLS-сертификат (необязательно)"
info "Нужен для DNS-over-TLS (853), DNS-over-HTTPS и HTTPS-панели AdGuard."
info "Требует: домен направлен на этот сервер, порт 80 открыт для certbot."
echo

TLS_DOMAIN=""; TLS_EMAIL=""
ask "Настроить TLS? (y/n): "; read -r yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  ask "  Домен (например dns.example.com): "; read -r TLS_DOMAIN
  if [[ -n "$TLS_DOMAIN" ]]; then
    ask "  E-mail для Let's Encrypt: "; read -r TLS_EMAIL
    ok "Домен: ${TLS_DOMAIN}  e-mail: ${TLS_EMAIL}"
  else
    warn "Домен не указан — TLS пропущен"
  fi
else
  warn "TLS пропущен — AdGuard будет доступен по HTTP на порту 3000"
fi

# ────────────────────────────────────────────────────────────
# Подтверждение
# ────────────────────────────────────────────────────────────
hdr "Подтверждение"
echo -e "  ${B}Архитектура      :${X} ${AGH_ARCH}"
echo -e "  ${B}SSH-порт         :${X} ${SSH_PORT}"
echo -e "  ${B}SSH только белый :${X} $([[ $SSH_RESTRICTED -eq 1 ]] && echo да || echo нет)"
echo -e "  ${B}AGH логин        :${X} ${AGH_USER}"
echo -e "  ${B}AGH пароль       :${X} (задан)"
if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  echo -e "  ${B}Белый список IP  :${X}"
  printf "    %s\n" "${ALLOWED_IPS[@]}"
else
  echo -e "  ${B}Белый список IP  :${X} не задан (открыто)"
fi
echo -e "  ${B}Порты            :${X} ${ALLOWED_PORTS[*]}"
echo -e "  ${B}TLS домен        :${X} ${TLS_DOMAIN:-не задан}"
[[ $DRY -eq 1 ]] && echo -e "  ${Y}${B}РЕЖИМ: dry-run${X}"
echo
ask "Всё верно? Начать установку? (y/n): "; read -r CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { warn "Отменено."; exit 0; }

# Сохраняем параметры
mkdir -p /etc/dns_setup
cat > /etc/dns_setup/config.conf <<CONF
# dns_setup — $(date)
TLS_DOMAIN="${TLS_DOMAIN}"
TLS_EMAIL="${TLS_EMAIL}"
SSH_PORT="${SSH_PORT}"
SSH_RESTRICTED="${SSH_RESTRICTED}"
AGH_USER="${AGH_USER}"
AGH_ARCH="${AGH_ARCH}"
ALLOWED_IPS=(${ALLOWED_IPS[*]+"${ALLOWED_IPS[*]}"})
ALLOWED_PORTS=(${ALLOWED_PORTS[*]})
CONF

# ════════════════════════════════════════════════════════════
#  ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
# ════════════════════════════════════════════════════════════
hdr "Предварительные проверки"

# Порт 53 — проверяем что занят и кем
if ss -tulnp 2>/dev/null | grep -q ':53 '; then
  OWNER=$(ss -tulnp 2>/dev/null | grep ':53 ' | awk '{print $NF}' | head -1)
  info "Порт 53 занят: ${OWNER}"
  info "systemd-resolved будет остановлен автоматически на этапе установки."
fi

command -v python3 &>/dev/null || warn "python3 не найден — будет установлен"
ok "Проверки пройдены"

# ════════════════════════════════════════════════════════════
#  ПАКЕТЫ
# ════════════════════════════════════════════════════════════
hdr "Установка пакетов"

# Временный резолвер на время установки
run "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

if command -v apt-get &>/dev/null; then
  run "apt-get update -qq"
  run "apt-get install -y unbound unbound-anchor unbound-host \
    iptables iptables-persistent netfilter-persistent \
    curl tar certbot python3 logrotate dnsutils"
elif command -v dnf &>/dev/null; then
  run "dnf install -y unbound iptables iptables-services \
    curl tar certbot python3 bind-utils"
elif command -v pacman &>/dev/null; then
  run "pacman -Sy --noconfirm unbound iptables curl tar certbot python3 bind-tools"
else
  err "Неизвестный пакетный менеджер. Установите unbound, iptables, certbot, python3 вручную."; exit 1
fi
ok "Пакеты установлены"

# ════════════════════════════════════════════════════════════
#  DNSSEC + root.hints
# ════════════════════════════════════════════════════════════
hdr "DNSSEC / root.hints"

run "mkdir -p /var/lib/unbound"
run "chown -R unbound:unbound /var/lib/unbound 2>/dev/null || true"

if [[ $DRY -eq 0 ]]; then
  echo -e "  Загружаем root.hints от IANA..."
  if ! curl -fsSL https://www.internic.net/domain/named.cache \
       -o /var/lib/unbound/root.hints; then
    err "Не удалось загрузить root.hints — проверьте сеть"; exit 1
  fi
  [[ ! -s /var/lib/unbound/root.hints ]] && { err "root.hints пустой!"; exit 1; }
  chmod 644 /var/lib/unbound/root.hints
  ok "root.hints загружен ($(wc -l < /var/lib/unbound/root.hints) строк)"
else
  echo "[dry] curl root.hints от IANA → /var/lib/unbound/root.hints"
fi

run "unbound-anchor -a /var/lib/unbound/root.key || true"
run "chown unbound:unbound /var/lib/unbound/root.key /var/lib/unbound/root.hints 2>/dev/null || true"
ok "DNSSEC trust anchor готов"

# ════════════════════════════════════════════════════════════
#  UNBOUND CONFIG
# ════════════════════════════════════════════════════════════
hdr "Конфигурация Unbound"

run "mkdir -p /etc/unbound /var/log/unbound"
run "chown unbound:unbound /var/log/unbound 2>/dev/null || true"

if [[ $DRY -eq 0 ]]; then
  {
    cat <<'UBEOF'
server:
    interface: 127.0.0.1
    port: 5353
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    # Доступ: localhost всегда, остальные — по белому списку
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow
UBEOF

    for ip in "${ALLOWED_IPS[@]}"; do
      echo "    access-control: ${ip} allow"
    done

    cat <<'UBEOF'

    # Отключаем subnetcache (ECS) — конфликтует с prefetch и serve-expired
    module-config: "validator iterator"

    # Производительность
    num-threads: 2
    so-reuseport: yes
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    msg-cache-size: 96m
    rrset-cache-size: 192m
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    edns-buffer-size: 4096
    cache-min-ttl: 60
    cache-max-ttl: 86400

    # Безопасность
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-referral-path: yes
    harden-algo-downgrade: yes
    qname-minimisation: yes
    use-caps-for-id: yes

    # Блокировка rebinding-атак
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12
    private-address: 192.168.0.0/16
    private-address: 169.254.0.0/16

    # DNSSEC
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    val-clean-additional: yes

    # Rate limit
    ratelimit: 5000
    ratelimit-slabs: 8
    ratelimit-size: 8m

    # Рекурсия через корневые серверы (без форвардинга)
    root-hints: "/var/lib/unbound/root.hints"

    # Логи
    verbosity: 0
    logfile: "/var/log/unbound/unbound.log"
    log-replies: no
    use-syslog: yes
UBEOF
  } > /etc/unbound/unbound.conf

  unbound-checkconf && ok "unbound.conf корректен" || { err "Ошибка в unbound.conf!"; exit 1; }
else
  echo "[dry] генерация /etc/unbound/unbound.conf"
fi

# systemd override
run "mkdir -p /etc/systemd/system/unbound.service.d"
if [[ $DRY -eq 0 ]]; then
  cat > /etc/systemd/system/unbound.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
# Убираем предупреждение о неустановленной переменной окружения
Environment=DAEMON_OPTS=
EOF
fi

run "systemctl daemon-reload"
run "systemctl enable --now unbound"
run "systemctl restart unbound"
ok "Unbound запущен на 127.0.0.1:5353"

# logrotate
if [[ $DRY -eq 0 ]]; then
  cat > /etc/logrotate.d/unbound <<'EOF'
/var/log/unbound/unbound.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP unbound 2>/dev/null || true
    endscript
}
EOF
fi

# ════════════════════════════════════════════════════════════
#  IPTABLES
# ════════════════════════════════════════════════════════════
hdr "Настройка iptables"

if [[ $DRY -eq 0 ]]; then
  # Сброс
  iptables -F; iptables -X
  iptables -t nat -F; iptables -t mangle -F

  iptables -P INPUT   DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT  ACCEPT

  # Loopback + established
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # SSH
  if [[ $SSH_RESTRICTED -eq 1 && ${#ALLOWED_IPS[@]} -gt 0 ]]; then
    for IP in "${ALLOWED_IPS[@]}"; do
      iptables -A INPUT -p tcp -s "$IP" --dport "${SSH_PORT}" -j ACCEPT
    done
    info "SSH разрешён только с белых IP"
  else
    iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
    info "SSH открыт для всех"
  fi

  # Порты: по белому списку или для всех
  if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
    for IP in "${ALLOWED_IPS[@]}"; do
      for PORT in "${ALLOWED_PORTS[@]}"; do
        iptables -A INPUT -p tcp -s "$IP" --dport "$PORT" -j ACCEPT
        iptables -A INPUT -p udp -s "$IP" --dport "$PORT" -j ACCEPT
      done
    done
    # Остальным — DROP на этих портах
    for PORT in "${ALLOWED_PORTS[@]}"; do
      iptables -A INPUT -p tcp --dport "$PORT" -j DROP
      iptables -A INPUT -p udp --dport "$PORT" -j DROP
    done
  else
    # Открытый режим: разрешаем всем на DNS-портах
    for PORT in "${ALLOWED_PORTS[@]}"; do
      iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
      iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
    done
  fi

  # Локальные сети
  iptables -A INPUT -s 127.0.0.0/8    -j ACCEPT
  iptables -A INPUT -s 10.0.0.0/8     -j ACCEPT
  iptables -A INPUT -s 192.168.0.0/16 -j ACCEPT

  # Защита от DNS-флуда
  iptables -A INPUT -p udp --dport 53 -m state --state NEW \
           -m recent --set --name DNSQF --rsource
  iptables -A INPUT -p udp --dport 53 -m state --state NEW \
           -m recent --update --seconds 1 --hitcount 70 \
           --name DNSQF --rsource -j DROP

  # Сохранение правил
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
  elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
      iptables-save > /etc/iptables.rules
    mkdir -p /etc/network/if-pre-up.d/
    cat > /etc/network/if-pre-up.d/iptables <<'EOS'
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOS
    chmod +x /etc/network/if-pre-up.d/iptables
  fi
else
  echo "[dry] iptables flush + rebuild"
fi
ok "iptables настроен и сохранён"

# ════════════════════════════════════════════════════════════
#  TLS (certbot)
# ════════════════════════════════════════════════════════════
if [[ -n "$TLS_DOMAIN" && -n "$TLS_EMAIL" ]]; then
  hdr "TLS — ${TLS_DOMAIN}"
  if [[ $DRY -eq 0 ]]; then
    certbot certonly --standalone \
      -d "${TLS_DOMAIN}" \
      --email "${TLS_EMAIL}" \
      --agree-tos --no-eff-email --non-interactive && \
      ok "Сертификат: /etc/letsencrypt/live/${TLS_DOMAIN}/" || \
      warn "certbot не смог получить сертификат — продолжаем без TLS"

    # Авто-обновление
    ( crontab -l 2>/dev/null
      echo "0 3 1 * * certbot renew --quiet && systemctl restart AdGuardHome"
    ) | sort -u | crontab -
    ok "Cron certbot добавлен (1-го числа каждого месяца)"
  else
    echo "[dry] certbot certonly --standalone -d ${TLS_DOMAIN}"
  fi
fi

# ════════════════════════════════════════════════════════════
#  ADGUARD HOME
# ════════════════════════════════════════════════════════════
hdr "Установка AdGuard Home"

# Сначала скачиваем — пока resolved ещё жив
if [[ $DRY -eq 0 ]]; then
  AGH_URL="https://static.adguard.com/adguardhome/release/AdGuardHome_${AGH_ARCH}.tar.gz"
  echo -e "  Загружаем AdGuard Home (${AGH_ARCH})..."
  cd /opt
  curl -sSL "${AGH_URL}" -o AdGuardHome.tar.gz || \
    { err "Не удалось скачать AGH с ${AGH_URL}"; exit 1; }
  tar -xzf AdGuardHome.tar.gz
  rm -f AdGuardHome.tar.gz
  ok "Распакован в /opt/AdGuardHome"
else
  echo "[dry] curl AdGuardHome_${AGH_ARCH}.tar.gz → /opt/AdGuardHome"
fi

# Теперь глушим resolved и ставим AGH как сервис
run "systemctl stop    systemd-resolved 2>/dev/null || true"
run "systemctl disable systemd-resolved 2>/dev/null || true"

if [[ $DRY -eq 0 ]]; then
  cd /opt/AdGuardHome
  ./AdGuardHome -s install
  ok "AdGuard Home зарегистрирован как systemd-сервис"
  systemctl stop AdGuardHome 2>/dev/null || true
else
  echo "[dry] AdGuardHome -s install"
fi

# ─── Генерация конфига AGH ───────────────────────────────────
hdr "Конфигурация AdGuard Home"

AGH_CONF="/opt/AdGuardHome/AdGuardHome.yaml"
TLS_CERT=""; TLS_KEY=""
if [[ -n "$TLS_DOMAIN" && -d "/etc/letsencrypt/live/${TLS_DOMAIN}" ]]; then
  TLS_CERT="/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem"
  TLS_KEY="/etc/letsencrypt/live/${TLS_DOMAIN}/privkey.pem"
fi

if [[ $DRY -eq 0 ]]; then
  # Хешируем пароль (bcrypt через htpasswd или python3)
  if command -v htpasswd &>/dev/null; then
    AGH_HASH=$(htpasswd -bnBC 10 "" "${AGH_PASS}" | tr -d ':\n' | sed 's/^!//')
  else
    AGH_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${AGH_PASS}', bcrypt.gensalt(10)).decode())" 2>/dev/null || \
               python3 -c "
import crypt, random, string
salt = crypt.mksalt(crypt.METHOD_SHA512)
print(crypt.crypt('${AGH_PASS}', salt))
")
  fi

  mkdir -p /opt/AdGuardHome /var/log/AdGuardHome

  python3 - <<PYEOF
import yaml, os

tls_enabled = bool("${TLS_CERT}")

config = {
    "bind_host": "0.0.0.0",
    "bind_port": 3000,
    "users": [{"name": "${AGH_USER}", "password": "${AGH_HASH}"}],
    "auth_attempts": 5,
    "block_auth_min": 15,
    "http_proxy": "",
    "language": "ru",
    "theme": "auto",
    "debug_pprof": False,
    "web_session_ttl": 720,
    "dns": {
        "bind_hosts": ["0.0.0.0"],
        "port": 53,
        "statistics_interval": 7,
        "querylog_enabled": True,
        "querylog_file_enabled": True,
        "querylog_interval": "7d",
        "querylog_size_memory": 1000,
        "anonymize_client_ip": False,
        "protection_enabled": True,
        "blocking_mode": "default",
        "blocking_ipv4": "",
        "blocking_ipv6": "",
        "blocked_response_ttl": 10,
        "upstream_dns": ["127.0.0.1:5353"],
        "upstream_dns_file": "",
        "fallback_dns": ["127.0.0.1:5353"],
        "bootstrap_dns": ["127.0.0.1:5353"],
        "all_servers": False,
        "fastest_addr": False,
        "fastest_timeout": "1s",
        "allowed_clients": [],
        "disallowed_clients": [],
        "blocked_hosts": [],
        "trusted_proxies": ["127.0.0.0/8"],
        "cache_size": 0,
        "cache_ttl_min": 0,
        "cache_ttl_max": 0,
        "cache_optimistic": False,
        "parental_enabled": False,
        "safebrowsing_enabled": False,
        "use_dns64": False,
        "dns64_prefixes": [],
        "filtering_enabled": True,
        "filters_update_interval": 24,
        "rewrites": [],
        "blocked_services": [],
        "local_domain_name": "lan",
        "resolve_clients": True,
        "use_private_ptr_resolvers": True,
        "local_ptr_upstreams": [],
        "enable_dnssec": False,
        "edns_client_subnet": {"custom_ip": "", "enabled": False, "use_custom": False},
        "max_goroutines": 300,
        "handle_ddr": True,
    },
    "tls": {
        "enabled": tls_enabled,
        "server_name": "${TLS_DOMAIN:-}",
        "force_https": False,
        "port_https": 443,
        "port_dns_over_tls": 853,
        "port_dns_over_quic": 784,
        "port_dnscrypt": 0,
        "dnscrypt_config_file": "",
        "allow_unencrypted_doh": False,
        "certificate_chain": "${TLS_CERT:-}",
        "private_key": "${TLS_KEY:-}",
        "certificate_path": "",
        "private_key_path": "",
        "strict_sni_check": False,
    },
    "filters": [
        {"enabled": True, "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt", "name": "AdGuard DNS filter", "id": 1},
        {"enabled": True, "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt", "name": "AdAway Default Blocklist", "id": 2},
    ],
    "whitelist_filters": [],
    "user_rules": [],
    "dhcp": {
        "enabled": False,
        "interface_name": "",
        "local_domain_name": "lan",
        "dhcpv4": {"gateway_ip": "", "subnet_mask": "", "range_start": "", "range_end": "", "lease_duration": 86400, "icmp_timeout_msec": 1000, "options": []},
        "dhcpv6": {"range_start": "", "lease_duration": 86400, "ra_slaac_only": False, "ra_allow_slaac": False},
    },
    "clients": {
        "runtime_sources": {"whois": True, "arp": True, "rdns": True, "dhcp": True, "hosts": True},
        "persistent": [],
    },
    "log_file": "/var/log/AdGuardHome/AdGuardHome.log",
    "log_max_backups": 0,
    "log_max_size": 100,
    "log_max_age": 3,
    "log_compress": False,
    "log_localtime": False,
    "verbose": False,
    "os": {"group": "", "user": "", "rlimit_nofile": 0},
    "schema_version": 28,
}

os.makedirs("/opt/AdGuardHome", exist_ok=True)
os.makedirs("/var/log/AdGuardHome", exist_ok=True)
with open("${AGH_CONF}", "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
print("  AdGuardHome.yaml записан")
PYEOF

  ok "AdGuardHome.yaml сгенерирован"
else
  echo "[dry] python3 генерирует AdGuardHome.yaml"
fi

# logrotate AGH
if [[ $DRY -eq 0 ]]; then
  cat > /etc/logrotate.d/adguardhome <<'EOF'
/var/log/AdGuardHome/AdGuardHome.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP AdGuardHome 2>/dev/null || true
    endscript
}
EOF
fi

# systemd override AGH
run "mkdir -p /etc/systemd/system/AdGuardHome.service.d"
if [[ $DRY -eq 0 ]]; then
  cat > /etc/systemd/system/AdGuardHome.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF
fi

run "systemctl daemon-reload"
run "systemctl restart AdGuardHome"
ok "AdGuard Home запущен"

# ════════════════════════════════════════════════════════════
#  resolv.conf
# ════════════════════════════════════════════════════════════
hdr "Настройка системного резолвера"

if [[ $DRY -eq 0 ]]; then
  rm -f /etc/resolv.conf
  cat > /etc/resolv.conf <<'EOF'
# Управляется dns_setup.sh
nameserver 127.0.0.1
EOF
  chattr +i /etc/resolv.conf
  ok "resolv.conf → 127.0.0.1 (защищён chattr +i)"
else
  echo "[dry] resolv.conf → 127.0.0.1"
fi

# ════════════════════════════════════════════════════════════
#  Cron обновления root.hints
# ════════════════════════════════════════════════════════════
if [[ $DRY -eq 0 ]]; then
  ( crontab -l 2>/dev/null
    echo "0 4 1 * * curl -fsSL https://www.internic.net/domain/named.cache -o /var/lib/unbound/root.hints && systemctl restart unbound"
  ) | sort -u | crontab -
  ok "Cron обновления root.hints добавлен (1-го числа каждого месяца)"
else
  echo "[dry] cron root.hints"
fi

# ════════════════════════════════════════════════════════════
#  ПРОВЕРКА
# ════════════════════════════════════════════════════════════
hdr "Проверка работы DNS"
sleep 2

if [[ $DRY -eq 0 ]]; then
  # Unbound
  if unbound-host -C /etc/unbound/unbound.conf -t A google.com \
       @127.0.0.1 -p 5353 &>/dev/null; then
    ok "Unbound (127.0.0.1:5353) отвечает"
  else
    warn "Unbound не ответил — проверьте: systemctl status unbound"
  fi

  # AGH
  if command -v dig &>/dev/null; then
    dig +short +timeout=3 google.com @127.0.0.1 > /dev/null && \
      ok "AdGuard Home (127.0.0.1:53) отвечает" || \
      warn "AdGuard Home не ответил — проверьте: systemctl status AdGuardHome"

    # DNSSEC
    if dig +dnssec +short sigok.verteiltesysteme.net @127.0.0.1 2>/dev/null | grep -q 'A'; then
      ok "DNSSEC работает"
    else
      warn "DNSSEC не подтверждён — цепочка доверия может ещё строиться"
    fi
  elif command -v nslookup &>/dev/null; then
    nslookup google.com 127.0.0.1 &>/dev/null && \
      ok "AdGuard Home отвечает" || warn "AdGuard Home не ответил"
  fi
fi

# ════════════════════════════════════════════════════════════
#  ИТОГ
# ════════════════════════════════════════════════════════════
hdr "Установка завершена!"

echo -e "${B}Схема:${X}"
echo -e "  Клиент  →  ${C}AdGuard Home :53${X}  (блокировка рекламы, фильтрация)"
echo -e "             └─→  ${C}Unbound :5353${X}  (DNSSEC, рекурсия)"
echo -e "                  └─→  ${C}Корневые DNS-серверы${X}"
echo
echo -e "${B}Панель AdGuard:${X}"
if [[ -n "$TLS_DOMAIN" ]]; then
  echo -e "  ${C}https://${TLS_DOMAIN}:3000${X}"
else
  echo -e "  ${C}http://<IP_сервера>:3000${X}  логин: ${AGH_USER}"
fi
echo
echo -e "${B}Полезные команды:${X}"
echo "  systemctl status unbound AdGuardHome"
echo "  journalctl -u unbound -f"
echo "  journalctl -u AdGuardHome -f"
echo "  dig +short google.com @127.0.0.1"
echo "  dig +dnssec sigok.verteiltesysteme.net @127.0.0.1"
echo
echo -e "${B}Удаление:${X}  sudo bash $0 --uninstall"
echo -e "${B}Dry-run:${X}   sudo bash $0 --dry-run"
echo
ok "Готово!"
