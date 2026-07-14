#!/bin/bash
# ============================================================
#   DNS Server: Unbound + AdGuard Home
#   Клиент → AGH:53 → Unbound:5353 → корневые серверы
#   Поддержка: Ubuntu/Debian, Fedora/RHEL, Arch
#   Опции: --dry-run  --uninstall
# ============================================================

set -euo pipefail

# ─── Диагностика падений ────────────────────────────────────
# Раньше любая ошибка под set -e просто обрывала вывод без объяснений
# (пример: скрипт падал в блоке AdGuard Home, а в логе это выглядело
# так, будто установка "сама собой" закончилась после сертификата).
# Теперь при любом ненулевом коде возврата печатаем номер строки и
# команду, на которой всё остановилось.
trap 'echo -e "\033[0;31m❌  Скрипт остановлен: ошибка на строке ${LINENO}, команда: ${BASH_COMMAND}\033[0m" >&2' ERR

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

run() {
  if [[ $DRY -eq 1 ]]; then
    echo -e "${Y}[dry] $*${X}"
  else
    eval "$*"
  fi
}

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
    DEBIAN_FRONTEND=noninteractive apt-get remove -y unbound unbound-anchor unbound-host 2>/dev/null || true
  command -v dnf &>/dev/null && \
    dnf remove -y unbound 2>/dev/null || true
  command -v pacman &>/dev/null && \
    pacman -Rns --noconfirm unbound 2>/dev/null || true
  rm -f /etc/unbound/unbound.conf
  rm -rf /etc/systemd/system/unbound.service.d
  ok "Unbound удалён"

  if [[ -f /etc/dns_setup/failsafe_job ]]; then
    atrm "$(cat /etc/dns_setup/failsafe_job)" 2>/dev/null || true
  fi

  systemctl disable --now dns-setup-healthcheck.timer 2>/dev/null || true
  rm -f /etc/systemd/system/dns-setup-healthcheck.service /etc/systemd/system/dns-setup-healthcheck.timer
  systemctl disable dns-setup-firewall.service 2>/dev/null || true
  rm -f /etc/systemd/system/dns-setup-firewall.service
  rm -f /usr/local/bin/dns_setup_healthcheck.sh /usr/local/bin/dns_setup_restore_fw.sh /usr/local/bin/dns_setup_manage.sh
  rm -f /etc/sysctl.d/99-dns_setup.conf
  rm -f /etc/ssh/sshd_config.d/99-dns_setup.conf
  systemctl daemon-reload
  ok "Watchdog, firewall-restore, sysctl-hardening и SSH-override удалены"

  if [[ -f /etc/fail2ban/jail.d/99-dns_setup.conf ]]; then
    rm -f /etc/fail2ban/jail.d/99-dns_setup.conf
    systemctl restart fail2ban 2>/dev/null || systemctl disable --now fail2ban 2>/dev/null || true
    ok "fail2ban jail удалён"
  fi

  iptables -F; iptables -X
  iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
  if command -v ip6tables &>/dev/null; then
    ip6tables -F; ip6tables -X
    ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
  fi
  ok "iptables/ip6tables → ACCEPT"

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
  for o in "${oct[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    # 10#$o форсирует десятичную интерпретацию — иначе "008" трактуется
    # bash как некорректное восьмеричное число и валит скрипт под set -e
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

DNS_SETUP_CONF=/etc/dns_setup/config.conf
AGH_YAML=/opt/AdGuardHome/AdGuardHome.yaml

# ─── Пересборка iptables из текущих ALLOWED_IPS/ALLOWED_PORTS ─
# (та же модель, что при установке: белый список = ACCEPT на всё,
# иначе — порты открыты всем, остальное — DROP)
menu_apply_firewall() {
  local ssh_port=22
  [[ -f /etc/ssh/sshd_config.d/99-dns_setup.conf ]] && \
    ssh_port=$(grep -oP '^Port\s+\K[0-9]+' /etc/ssh/sshd_config.d/99-dns_setup.conf 2>/dev/null || echo 22)

  iptables -F; iptables -X
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
  iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,SYN FIN,SYN -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,ACK FIN -j DROP
  iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP

  if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
    for IP in "${ALLOWED_IPS[@]}"; do iptables -A INPUT -s "$IP" -j ACCEPT; done
  else
    for PORT in "${ALLOWED_PORTS[@]}"; do
      iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
      iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
    done
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    warn "Белый список пуст — сервисные порты и SSH открыты всем"
  fi

  iptables -A INPUT -p udp --dport 53 -m conntrack --ctstate NEW -m recent --set --name DNSQF --rsource
  iptables -A INPUT -p udp --dport 53 -m conntrack --ctstate NEW -m recent --update --seconds 1 --hitcount 70 --name DNSQF --rsource -j DROP
  iptables -A INPUT -p tcp --syn --dport 53 -m conntrack --ctstate NEW -m recent --set --name DNSTCPF --rsource
  iptables -A INPUT -p tcp --syn --dport 53 -m conntrack --ctstate NEW -m recent --update --seconds 1 --hitcount 70 --name DNSTCPF --rsource -j DROP
  iptables -A INPUT -p tcp --syn -m hashlimit --hashlimit-above 200/sec --hashlimit-burst 100 --hashlimit-mode srcip --hashlimit-name synflood -j DROP

  command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null || true
  ok "iptables пересобран (${#ALLOWED_IPS[@]} IP в белом списке, ${#ALLOWED_PORTS[@]} публичных портов)"
}

# ─── Обновление allowed_clients + самолечение TLS-полей в AdGuardHome.yaml ──
# ВАЖНО: перезапуск AdGuardHome ниже выполняется, только если YAML реально
# изменился (сравнение md5 до/после). Раньше systemctl restart AdGuardHome
# вызывался безусловно при каждом заходе в меню (см. вызов menu_apply_agh
# сразу после source config.conf) — из-за этого диагностика (пункт 7),
# выбранная сразу после открытия меню, гарантированно попадала в окно,
# когда DNS-сокет AGH на :53 ещё не поднялся (веб-порт 443/3000 стартует
# раньше), и показывала ложное "не отвечает". Теперь лишний рестарт просто
# не происходит, если конфиг не менялся.
menu_apply_agh() {
  [[ -f "$AGH_YAML" ]] || { warn "Не найден $AGH_YAML — пропускаю обновление AGH"; return; }
  local _agh_before _agh_after
  _agh_before=$(md5sum "$AGH_YAML" 2>/dev/null | awk '{print $1}')
  AGH_YAML="$AGH_YAML" AGH_IPS="$(printf '%s\n' "${ALLOWED_IPS[@]}")" \
  TLS_DOMAIN="${TLS_DOMAIN:-}" python3 - <<'PYEOF'
import yaml, os
conf = os.environ["AGH_YAML"]
tls_domain = os.environ.get("TLS_DOMAIN", "")
ips = [x for x in os.environ.get("AGH_IPS", "").splitlines() if x.strip()]
if ips:
    for lo in ("127.0.0.1", "::1"):
        if lo not in ips:
            ips.append(lo)
with open(conf) as f:
    cfg = yaml.safe_load(f)
cfg.setdefault("dns", {})["allowed_clients"] = ips

# Самолечение TLS: старые/битые конфиги (например, от ручного
# редактирования через веб-панель или от версий скрипта до фикса)
# иногда кладут путь к файлу в certificate_chain/private_key — AGH
# ждёт там PEM-содержимое, а путь — только в certificate_path/
# private_key_path. Если видим такую путаницу — переносим сами.
tls = cfg.setdefault("tls", {})
def looks_like_path(v):
    return isinstance(v, str) and v.startswith("/") and "-----BEGIN" not in v

if looks_like_path(tls.get("certificate_chain", "")):
    tls["certificate_path"] = tls["certificate_chain"]
    tls["certificate_chain"] = ""
if looks_like_path(tls.get("private_key", "")):
    tls["private_key_path"] = tls["private_key"]
    tls["private_key"] = ""

# Если путь всё ещё не задан, но домен известен и сертификат Let's
# Encrypt для него существует — подставляем стандартный путь.
if tls_domain and not tls.get("certificate_path") and not tls.get("certificate_chain"):
    cert = f"/etc/letsencrypt/live/{tls_domain}/fullchain.pem"
    key = f"/etc/letsencrypt/live/{tls_domain}/privkey.pem"
    if os.path.exists(cert) and os.path.exists(key):
        tls["certificate_path"] = cert
        tls["private_key_path"] = key
        tls["enabled"] = True

with open(conf, "w") as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
PYEOF
  _agh_after=$(md5sum "$AGH_YAML" 2>/dev/null | awk '{print $1}')
  if [[ "$_agh_before" != "$_agh_after" ]]; then
    systemctl restart AdGuardHome 2>/dev/null || true
    ok "AdGuard Home перезапущен (allowed_clients обновлён, TLS-пути проверены/исправлены)"
  else
    info "Конфигурация AdGuard Home не изменилась — перезапуск не требуется"
  fi
}

# ─── Сохранение ALLOWED_IPS/ALLOWED_PORTS обратно в config.conf ─
menu_save_conf() {
  local tmp; tmp=$(mktemp)
  grep -vE '^ALLOWED_IPS=\(\)|^ALLOWED_PORTS=\(\)|^ALLOWED_IPS\+=|^ALLOWED_PORTS\+=' "$DNS_SETUP_CONF" > "$tmp"
  {
    cat "$tmp"
    echo "ALLOWED_IPS=()"
    echo "ALLOWED_PORTS=()"
    for ip in "${ALLOWED_IPS[@]}"; do printf 'ALLOWED_IPS+=(%q)\n' "$ip"; done
    for p in "${ALLOWED_PORTS[@]}"; do printf 'ALLOWED_PORTS+=(%q)\n' "$p"; done
  } > "${DNS_SETUP_CONF}.new"
  mv "${DNS_SETUP_CONF}.new" "$DNS_SETUP_CONF"
  rm -f "$tmp"
}

# ─── Логи и диагностика одной кнопкой ─────────────────────────
# ВАЖНО: эта функция ТОЛЬКО ЧИТАЕТ состояние системы. Ни одна команда
# здесь не должна перезапускать/перезагружать/менять что-либо (никаких
# systemctl restart|reload|start|stop, никаких iptables -F/-A, никакой
# записи в файлы) — иначе один заход в диагностику снова начнёт менять
# состояние сервисов и создавать те же гонки условий, что и раньше.
# Порядок секций соответствует порядку установки в мастере, чтобы по
# одному прогону можно было понять, что именно из всего скрипта живо,
# а что — нет.
menu_diagnostics() {
  clear
  hdr "Диагностика dns_setup"
  local svc fw key val exp
  local check_ports ports_pattern CRON_LIST LAST_RESULT LAST_RUN IPT_POLICY IPT6_POLICY

  echo -e "${B}── Конфигурация (config.conf) ──${X}"
  info "SSH-порт: ${SSH_PORT:-22}  (ограничен белым списком: $([[ "${SSH_RESTRICTED:-0}" -eq 1 ]] && echo да || echo нет))"
  info "AGH логин: ${AGH_USER:-неизвестно}"
  info "TLS-домен: ${TLS_DOMAIN:-не задан}"
  info "IP в белом списке: ${#ALLOWED_IPS[@]}  /  публичных портов: ${#ALLOWED_PORTS[@]}"
  echo

  echo -e "${B}── SSH ──${X}"
  if [[ -f /etc/ssh/sshd_config.d/99-dns_setup.conf ]]; then
    ok "Override /etc/ssh/sshd_config.d/99-dns_setup.conf присутствует"
  elif [[ "${SSH_PORT:-22}" != "22" ]]; then
    warn "Порт настроен как ${SSH_PORT}, но override-файл отсутствует — sshd может слушать 22"
  fi
  if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT:-22} "; then
    ok "sshd слушает порт ${SSH_PORT:-22}"
  else
    err "sshd НЕ слушает порт ${SSH_PORT:-22} — проверьте: systemctl status sshd"
  fi
  echo

  echo -e "${B}── Службы ──${X}"
  for svc in unbound AdGuardHome fail2ban; do
    if systemctl is-active --quiet "$svc"; then
      ok "$svc: активна"
    else
      err "$svc: НЕ активна ($(systemctl is-active "$svc" 2>&1))"
    fi
  done
  if systemctl is-enabled --quiet dns-setup-healthcheck.timer 2>/dev/null; then
    if systemctl is-active --quiet dns-setup-healthcheck.timer; then
      ok "dns-setup-healthcheck.timer: включён и активен (watchdog каждые 2 минуты)"
    else
      err "dns-setup-healthcheck.timer: включён, но НЕ активен"
    fi
    LAST_RESULT=$(systemctl show dns-setup-healthcheck.service -p Result --value 2>/dev/null || echo "н/д")
    LAST_RUN=$(systemctl show dns-setup-healthcheck.timer -p LastTriggerUSec --value 2>/dev/null || echo "н/д")
    info "Последний запуск healthcheck: ${LAST_RUN:-н/д}  (результат: ${LAST_RESULT:-н/д})"
  else
    err "dns-setup-healthcheck.timer НЕ включён — автолечение unbound/AGH/firewall не работает"
  fi
  if systemctl is-enabled --quiet dns-setup-firewall.service 2>/dev/null; then
    ok "dns-setup-firewall.service: включён (восстановление iptables при загрузке)"
  else
    warn "dns-setup-firewall.service не включён — правила не восстановятся автоматически после ребута"
  fi
  if systemctl is-active --quiet atd 2>/dev/null; then
    ok "atd: активна (нужна для аварийного отката iptables через 'at')"
  else
    warn "atd не активна — если снова понадобится аварийный откат iptables через 'at', он не сработает"
  fi
  echo

  echo -e "${B}── Слушающие порты ──${X}"
  local ss_dump
  ss_dump=$(ss -tulnp 2>/dev/null) || true
  check_ports=(53 853 784 443 3000)
  [[ -n "${SSH_PORT:-}" ]] && check_ports+=("${SSH_PORT}")
  # Проверяем КАЖДЫЙ порт по отдельности — раньше был один общий grep по
  # всем портам сразу, и если слушались хотя бы некоторые (например, только
  # веб-панель 443/3000), отсутствие конкретно DNS-порта 53 просто молча
  # терялось внутри одной строки предупреждения "не слушается ни один".
  for p in "${check_ports[@]}"; do
    if echo "$ss_dump" | grep -q ":${p} "; then
      ok "порт ${p}: слушается"
    else
      err "порт ${p}: НЕ слушается"
    fi
  done
  echo -e "  ${C}Подробности (ss -tulnp):${X}"
  ports_pattern=$(printf ':%s |' "${check_ports[@]}"); ports_pattern=${ports_pattern%|}
  echo "$ss_dump" | grep -E "$ports_pattern" | sed 's/^/    /' || echo "    (нет строк)"
  echo

  echo -e "${B}── DNS-проверки ──${X}"
  if command -v dig &>/dev/null; then
    if dig @127.0.0.1 -p 5353 google.com +short +timeout=3 &>/dev/null; then
      ok "Unbound (127.0.0.1:5353) отвечает"
    else
      err "Unbound (127.0.0.1:5353) НЕ отвечает"
    fi
    if dig +short +timeout=3 +tries=1 google.com @127.0.0.1 &>/dev/null; then
      ok "AdGuard Home (127.0.0.1:53) отвечает"
    else
      err "AdGuard Home (127.0.0.1:53) НЕ отвечает"
    fi
    DNSSEC_FLAGS=$(dig +dnssec +noall +comments sigok.verteiltesysteme.net @127.0.0.1 2>/dev/null | grep '^;; flags:' || true)
    if echo "$DNSSEC_FLAGS" | grep -qE '\bad\b'; then
      ok "DNSSEC подтверждён (флаг AD)"
    else
      warn "DNSSEC не подтверждён (может ещё строиться цепочка доверия)"
    fi
  else
    warn "dig не установлен — пропускаю DNS-проверки"
  fi
  echo

  echo -e "${B}── Конфигурация AdGuard Home (AdGuardHome.yaml) ──${X}"
  if [[ -f "$AGH_YAML" ]]; then
    if python3 -c "import yaml; yaml.safe_load(open('${AGH_YAML}'))" 2>/dev/null; then
      ok "AdGuardHome.yaml: валидный YAML"
    else
      err "AdGuardHome.yaml повреждён или содержит синтаксическую ошибку!"
    fi
  else
    err "$AGH_YAML не найден"
  fi
  echo

  echo -e "${B}── TLS-сертификат ──${X}"
  # shellcheck disable=SC2153
  if [[ -n "${TLS_DOMAIN:-}" && -f "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" ]]; then
    exp=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem" 2>/dev/null | cut -d= -f2) || true
    ok "Сертификат ${TLS_DOMAIN} действителен до: ${exp:-неизвестно}"
    if [[ -f "$AGH_YAML" ]] && grep -q "^\s*enabled: true" "$AGH_YAML" 2>/dev/null; then
      ok "TLS в AdGuardHome.yaml: enabled"
    else
      warn "TLS в AdGuardHome.yaml не включён либо не найден"
    fi
  else
    warn "TLS-домен не настроен или сертификат не найден"
  fi
  echo

  echo -e "${B}── Firewall (iptables/ip6tables) ──${X}"
  IPT_POLICY=$(iptables -S INPUT 2>/dev/null | head -1) || true
  info "Политика INPUT (IPv4): ${IPT_POLICY:-неизвестно}"
  info "Правил в INPUT: $(iptables -S INPUT 2>/dev/null | wc -l)"
  info "IP в белом списке: ${#ALLOWED_IPS[@]}"
  if iptables -S INPUT 2>/dev/null | grep -q 'DNSQF'; then
    ok "Rate-limit DNS (UDP/53) активен"
  else
    warn "Rate-limit DNS (UDP/53) не найден в текущих правилах"
  fi
  if command -v ip6tables &>/dev/null; then
    IPT6_POLICY=$(ip6tables -S INPUT 2>/dev/null | head -1) || true
    if [[ "$IPT6_POLICY" == "-P INPUT DROP" ]]; then
      ok "Политика INPUT (IPv6): DROP"
    else
      err "Политика INPUT (IPv6): ${IPT6_POLICY:-неизвестно} — ожидался DROP"
    fi
  else
    warn "ip6tables не установлен — IPv6-трафик не фильтруется этим скриптом"
  fi
  if [[ -f /etc/dns_setup/iptables.rules ]]; then
    ok "Канонический набор правил сохранён (/etc/dns_setup/iptables.rules)"
  else
    warn "/etc/dns_setup/iptables.rules не найден — восстановление после сброса iptables не сработает"
  fi
  for fw in ufw firewalld; do
    if systemctl is-active --quiet "$fw" 2>/dev/null; then
      err "$fw активен — может конфликтовать/перебивать наши правила iptables"
    fi
  done
  if [[ -f /etc/dns_setup/failsafe_job ]]; then
    local FJ_ID
    FJ_ID=$(cat /etc/dns_setup/failsafe_job 2>/dev/null || true)
    if command -v atq &>/dev/null && atq 2>/dev/null | awk '{print $1}' | grep -qx "${FJ_ID}"; then
      warn "Аварийный откат iptables ещё РЕАЛЬНО стоит в очереди at (job #${FJ_ID}) — если доступ работает, отмените: atrm ${FJ_ID}"
    else
      info "Файл /etc/dns_setup/failsafe_job указывает на job #${FJ_ID}, но в очереди at его уже нет (выполнен или удалён ранее) — можно удалить файл, угрозы нет: rm -f /etc/dns_setup/failsafe_job"
    fi
  fi
  echo

  echo -e "${B}── Сетевой hardening (sysctl) ──${X}"
  if [[ -f /etc/sysctl.d/99-dns_setup.conf ]]; then
    ok "/etc/sysctl.d/99-dns_setup.conf присутствует"
  else
    warn "/etc/sysctl.d/99-dns_setup.conf не найден"
  fi
  for key in net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies \
             net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.accept_redirects \
             net.ipv6.conf.all.accept_redirects; do
    val=$(sysctl -n "$key" 2>/dev/null || echo "н/д")
    echo "    ${key} = ${val}"
  done
  echo

  echo -e "${B}── fail2ban (защита SSH от перебора) ──${X}"
  if systemctl is-active --quiet fail2ban 2>/dev/null && command -v fail2ban-client &>/dev/null; then
    fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || warn "Не удалось получить статус jail sshd"
  else
    err "fail2ban не активен — SSH не защищён от перебора паролей"
  fi
  echo

  echo -e "${B}── Автообновления (cron) ──${X}"
  CRON_LIST=$(crontab -l 2>/dev/null || true)
  if echo "$CRON_LIST" | grep -qF "root.hints"; then
    ok "Обновление root.hints запланировано (1-го числа каждого месяца)"
  else
    warn "Задача обновления root.hints не найдена в crontab"
  fi
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    if echo "$CRON_LIST" | grep -qF "certbot renew"; then
      ok "Автообновление сертификата (certbot renew) запланировано"
    else
      warn "TLS настроен, но задача certbot renew не найдена в crontab"
    fi
  fi
  echo

  echo -e "${B}── Logrotate ──${X}"
  for f in /etc/logrotate.d/unbound /etc/logrotate.d/adguardhome; do
    if [[ -f "$f" ]]; then ok "$f присутствует"; else warn "$f отсутствует"; fi
  done
  echo

  echo -e "${B}── /etc/resolv.conf ──${X}"
  if [[ -f /etc/resolv.conf ]]; then
    info "Содержимое:"
    sed 's/^/    /' /etc/resolv.conf
    if command -v lsattr &>/dev/null; then
      if lsattr /etc/resolv.conf 2>/dev/null | cut -d' ' -f1 | grep -q 'i'; then
        ok "Защищён от перезаписи (chattr +i)"
      else
        warn "Не защищён атрибутом immutable — resolved/NetworkManager может перезаписать"
      fi
    fi
  else
    err "/etc/resolv.conf отсутствует"
  fi
  echo

  echo -e "${B}── root.hints / DNSSEC trust anchor ──${X}"
  if [[ -s /var/lib/unbound/root.hints ]]; then
    ok "root.hints присутствует ($(wc -l < /var/lib/unbound/root.hints) строк, обновлён: $(stat -c %y /var/lib/unbound/root.hints 2>/dev/null | cut -d. -f1))"
  else
    err "root.hints отсутствует или пуст"
  fi
  if [[ -s /var/lib/unbound/root.key ]]; then
    ok "root.key (DNSSEC trust anchor) присутствует"
  else
    warn "root.key отсутствует — DNSSEC-валидация может не работать"
  fi
  echo

  echo -e "${B}── Последние ошибки в логах (journald, по 5 строк на службу) ──${X}"
  # ВАЖНО: AdGuardHome.yaml задаёт log_file, а unbound.conf — logfile,
  # то есть обе службы пишут СВОЙ рабочий лог в файл, а не в stdout/journald.
  # journalctl -u AdGuardHome / -u unbound здесь почти всегда покажет
  # только служебные сообщения systemd (старт/стоп), а не реальные ошибки
  # приложения (например, отказ забиндить порт 53) — "ошибок не найдено"
  # в этом блоке НЕ означает, что служба здорова. Реальные логи — в
  # следующем разделе ниже.
  for svc in unbound AdGuardHome fail2ban; do
    echo -e "  ${C}$svc:${X}"
    journalctl -u "$svc" --no-pager -p err -n 5 2>/dev/null | sed 's/^/    /' || true
    if [[ -z "$(journalctl -u "$svc" --no-pager -p err -n 5 2>/dev/null)" ]]; then
      echo "    (ошибок не найдено — но см. файловые логи ниже, AGH/unbound логируют в файл)"
    fi
  done
  echo

  echo -e "${B}── Файловые логи AGH/Unbound (последние 15 строк) ──${X}"
  if [[ -f /var/log/AdGuardHome/AdGuardHome.log ]]; then
    echo -e "  ${C}/var/log/AdGuardHome/AdGuardHome.log:${X}"
    tail -n 15 /var/log/AdGuardHome/AdGuardHome.log 2>/dev/null | sed 's/^/    /' || true
  else
    warn "/var/log/AdGuardHome/AdGuardHome.log не найден"
  fi
  echo
  if [[ -f /var/log/unbound/unbound.log ]]; then
    echo -e "  ${C}/var/log/unbound/unbound.log:${X}"
    tail -n 15 /var/log/unbound/unbound.log 2>/dev/null | sed 's/^/    /' || true
  else
    warn "/var/log/unbound/unbound.log не найден"
  fi
  echo

  echo -e "  ${C}watchdog (dns_setup_healthcheck):${X}"
  journalctl -t dns_setup_healthcheck --no-pager -n 10 2>/dev/null | sed 's/^/    /' || echo "    (нет записей)"

  echo
  ask "Enter для возврата в меню..."; read -r _
}

# ─── Меню управления существующей установкой ─────────────────
# Показывается вместо мастера, если находит /etc/dns_setup/config.conf
# (то есть dns_setup.sh уже устанавливался на этом сервере) и не был
# передан --uninstall. Позволяет добавлять/убирать IP и порты без
# полной переустановки; пункт "полная переустановка" проваливается
# дальше в обычный мастер.
if [[ -f "$DNS_SETUP_CONF" && $UNINSTALL -eq 0 ]]; then
  ALLOWED_IPS=(); ALLOWED_PORTS=()
  # shellcheck disable=SC1090
  source "$DNS_SETUP_CONF"

  # Самолечение при каждом заходе в меню — чинит TLS-конфиг (старые/битые
  # установки) и синхронизирует allowed_clients, даже если пользователь
  # просто зашёл посмотреть диагностику и ничего не менял руками.
  # Рестарт AdGuardHome внутри menu_apply_agh теперь условный (см. её
  # определение выше) — если конфиг не изменился, сервис не трогаем,
  # поэтому непосредственный переход в диагностику (пункт 7) больше не
  # ловит момент, когда DNS-сокет AGH ещё не поднялся после рестарта.
  menu_apply_agh

  while true; do
    clear
    hdr "dns_setup — управление существующей установкой"
    echo -e "  ${B}Белый список IP (${#ALLOWED_IPS[@]}):${X}"
    printf '    %s\n' "${ALLOWED_IPS[@]}"
    echo -e "  ${B}Публичные порты (${#ALLOWED_PORTS[@]}, работают только если белый список пуст):${X}"
    printf '    %s\n' "${ALLOWED_PORTS[@]}"
    echo
    echo "  1) Добавить IP/CIDR в белый список"
    echo "  2) Удалить IP/CIDR из белого списка"
    echo "  3) Добавить публичный порт"
    echo "  4) Удалить публичный порт"
    echo "  5) Полная переустановка (обычный мастер)"
    echo "  6) Выход"
    echo "  7) Логи и диагностика (проверить всё разом)"
    echo
    ask "Выбор: "; read -r MENU_CHOICE
    case "$MENU_CHOICE" in
      1)
        ask "  IP/CIDR: "; read -r NEW_IP
        if valid_ip "$NEW_IP"; then
          ALLOWED_IPS+=("$NEW_IP"); menu_save_conf; menu_apply_firewall; menu_apply_agh
          ok "Добавлен: $NEW_IP"
        else
          warn "Некорректный формат"
        fi
        ask "Enter для продолжения..."; read -r _
        ;;
      2)
        ask "  IP/CIDR для удаления: "; read -r DEL_IP
        NEW=(); for ip in "${ALLOWED_IPS[@]}"; do [[ "$ip" != "$DEL_IP" ]] && NEW+=("$ip"); done
        if [[ ${#NEW[@]} -eq ${#ALLOWED_IPS[@]} ]]; then
          warn "Не найден в списке: $DEL_IP"
        else
          ALLOWED_IPS=("${NEW[@]}"); menu_save_conf; menu_apply_firewall; menu_apply_agh
          ok "Удалён: $DEL_IP"
        fi
        ask "Enter для продолжения..."; read -r _
        ;;
      3)
        ask "  Порт: "; read -r NEW_PORT
        if valid_port "$NEW_PORT"; then
          ALLOWED_PORTS+=("$NEW_PORT"); menu_save_conf; menu_apply_firewall
          ok "Добавлен порт: $NEW_PORT"
        else
          warn "Некорректный порт"
        fi
        ask "Enter для продолжения..."; read -r _
        ;;
      4)
        ask "  Порт для удаления: "; read -r DEL_PORT
        NEW=(); for p in "${ALLOWED_PORTS[@]}"; do [[ "$p" != "$DEL_PORT" ]] && NEW+=("$p"); done
        if [[ ${#NEW[@]} -eq ${#ALLOWED_PORTS[@]} ]]; then
          warn "Не найден порт: $DEL_PORT"
        else
          ALLOWED_PORTS=("${NEW[@]}"); menu_save_conf; menu_apply_firewall
          ok "Удалён порт: $DEL_PORT"
        fi
        ask "Enter для продолжения..."; read -r _
        ;;
      5)
        break  # проваливаемся в обычный мастер ниже
        ;;
      6)
        exit 0
        ;;
      7)
        menu_diagnostics
        ;;
      *)
        warn "Неизвестный пункт"
        ask "Enter для продолжения..."; read -r _
        ;;
    esac
  done
fi

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

# Определяем IP текущей SSH-сессии, чтобы не заблокировать себе доступ
CURRENT_SSH_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CURRENT_SSH_IP="${SSH_CONNECTION%% *}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  CURRENT_SSH_IP="${SSH_CLIENT%% *}"
fi
if [[ -n "$CURRENT_SSH_IP" ]]; then
  info "IP текущей SSH-сессии: ${CURRENT_SSH_IP} (будет предложено добавить в белый список)"
else
  warn "Не удалось определить IP текущей SSH-сессии (локальная консоль?)"
fi

ask "SSH-порт [22]: "; read -r SSH_PORT
SSH_PORT=${SSH_PORT:-22}
# 10#$SSH_PORT форсирует десятичную интерпретацию — иначе порт вроде
# "099" валит скрипт ошибкой bash "value too great for base" (тот же
# класс бага, что и с восьмеричными IP-октетами в valid_ip() выше)
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || (( 10#$SSH_PORT < 1 || 10#$SSH_PORT > 65535 )); then
  err "Некорректный порт"; exit 1
fi
ok "SSH-порт: ${SSH_PORT}"

echo
ask "Ограничить SSH только доверенными IP? (y/n): "; read -r yn
SSH_RESTRICTED=0
[[ "$yn" =~ ^[Yy]$ ]] && SSH_RESTRICTED=1
if [[ $SSH_RESTRICTED -eq 1 ]]; then
  info "SSH будет разрешён только с IP из белого списка"
else
  warn "SSH открыт для всех IP — рекомендуется настроить fail2ban"
fi

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
info "Только эти IP получат доступ к серверу — и не только к DNS/панели,"
info "а КО ВСЕМ портам и протоколам (полный доступ). Всё, что не в списке,"
info "будет отброшено файрволом (кроме тех сервисов, что вы оставите открытыми ниже)."
info "Если пропустить — DNS-порты и панель будут открыты всем (публичный DNS)."
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
fi

# ── Жёсткий гейт против случайного публичного доступа ────────
# Модель безопасности этой установки: белый список = абсолютный полный
# доступ, все остальные = абсолютный полный DROP, без исключений.
# "Публичный резолвер" (пустой список → порты открыты всем) — это отход
# от этой модели, а не поведение по умолчанию по недосмотру. Поэтому
# пустой список требует явного, осознанного подтверждения текстом, а не
# случайного Enter/опечатки в y/n.
while [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; do
  echo
  err "Белый список пуст. По умолчанию это означает: сервер (DNS-порты,"
  err "панель AGH) будет доступен АБСОЛЮТНО ВСЕМ в интернете, а не только"
  err "доверенным IP. Это противоречит модели 'allowlist = всё, остальные = DROP'."
  ask "Введите заглавными ОТКРЫТЬ ВСЕМ, если это осознанный выбор, или Enter, чтобы вернуться к вводу IP: "
  read -r CONFIRM_OPEN
  if [[ "$CONFIRM_OPEN" == "ОТКРЫТЬ ВСЕМ" ]]; then
    warn "Подтверждено: доступ будет открыт всем IP (осознанный выбор)"
    break
  fi
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
done

if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  echo -e "\n  ${B}Белый список (${#ALLOWED_IPS[@]} записей):${X}"
  printf "    %s\n" "${ALLOWED_IPS[@]}"
fi

# Явно устраняем несостыковку: если пользователь просил ограничить SSH,
# но не добавил ни одного IP, раньше скрипт молча открывал SSH всем.
if [[ $SSH_RESTRICTED -eq 1 && ${#ALLOWED_IPS[@]} -eq 0 ]]; then
  err "Вы выбрали ограничить SSH по IP, но белый список пуст!"
  if [[ -n "$CURRENT_SSH_IP" ]]; then
    ask "Добавить IP текущей сессии (${CURRENT_SSH_IP}) в белый список? (y/n, при 'n' SSH откроется всем): "
    read -r yn2
    if [[ "$yn2" =~ ^[Yy]$ ]]; then
      ALLOWED_IPS+=("$CURRENT_SSH_IP")
      ok "Добавлен: ${CURRENT_SSH_IP}"
    else
      SSH_RESTRICTED=0
      warn "SSH-порт будет открыт для всех IP (явное решение пользователя)"
    fi
  else
    warn "IP текущей сессии не определён — SSH-порт будет открыт для всех IP"
    SSH_RESTRICTED=0
  fi
elif [[ $SSH_RESTRICTED -eq 1 && -n "$CURRENT_SSH_IP" ]]; then
  # Гарантируем, что текущая сессия не потеряет доступ, даже если
  # пользователь забыл вписать свой собственный IP в список
  found=0
  for _ip in "${ALLOWED_IPS[@]}"; do [[ "$_ip" == "$CURRENT_SSH_IP" ]] && found=1; done
  if [[ $found -eq 0 ]]; then
    ask "IP текущей сессии (${CURRENT_SSH_IP}) не в списке. Добавить, чтобы не потерять доступ? (y/n): "
    read -r yn3
    [[ "$yn3" =~ ^[Yy]$ ]] && { ALLOWED_IPS+=("$CURRENT_SSH_IP"); ok "Добавлен: ${CURRENT_SSH_IP}"; }
  fi
fi

# ────────────────────────────────────────────────────────────
# 4/5  Порты
# ────────────────────────────────────────────────────────────
hdr "4/5 — Разрешённые порты"

# Дефолт — только DNS-related
ALLOWED_PORTS=(53 853 80 443 784)
echo -e "  ${B}Порты по умолчанию:${X} ${ALLOWED_PORTS[*]}"
info "53=DNS  853=DoT  80=ACME-проверка certbot  443=HTTPS/DoH (/dns-query)  784=DoQ"
info "Панель AGH (3000) сюда НЕ входит: она будет доступна только с доверенных"
info "IP из белого списка (шаг 3/5), даже если сам DNS вы решите открыть всем."
echo

ask "Добавить свои порты? (y/n): "; read -r yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  ask "  Введите через пробел: "; read -r -a EXTRA_PORTS
  for p in "${EXTRA_PORTS[@]}"; do
    # 10#$p — та же защита от "value too great for base" на портах с
    # ведущим нулём (например "099"), что и для SSH-порта выше
    if [[ "$p" =~ ^[0-9]+$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
      ALLOWED_PORTS+=("$p")
    else
      warn "Пропускаю некорректный порт: $p"
    fi
  done
fi
echo -e "\n  ${B}Итоговые порты (DNS/сервисные):${X} ${ALLOWED_PORTS[*]}"

# Панель AGH (3000) НАМЕРЕННО не входит в ALLOWED_PORTS выше — она
# открывается отдельным правилом iptables ТОЛЬКО для ALLOWED_IPS, даже
# если сам DNS вы решите оставить публичным (см. блок iptables ниже).
if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
  warn "Белый список IP пуст — панель AGH (3000) НЕ будет открыта никому."
  warn "Заходить в панель нужно будет через SSH-туннель:"
  warn "  ssh -L 3000:127.0.0.1:3000 -p ${SSH_PORT} user@<IP_сервера>  →  http://127.0.0.1:3000"
  warn "Либо перезапустите установку и добавьте доверенные IP на шаге 3/5."
fi

# ────────────────────────────────────────────────────────────
# 5/5  TLS (необязательно)
# ────────────────────────────────────────────────────────────
hdr "5/5 — TLS-сертификат (необязательно)"
info "Нужен для DNS-over-TLS (853), DNS-over-HTTPS и HTTPS-панели AdGuard."
info "Требует: домен направлен на этот сервер, порт 80 открыт для certbot."
info "Если настроите — панель AGH автоматически станет HTTPS-only (force_https),"
info "а не HTTP+HTTPS одновременно. Сертификат при этом подставляется в конфиг"
info "автоматически, без ручного редактирования AdGuardHome.yaml."
echo

TLS_DOMAIN=""; TLS_EMAIL=""
ask "Настроить TLS? (y/n): "; read -r yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  ask "  Домен (например dns.example.com): "; read -r TLS_DOMAIN
  if [[ -n "$TLS_DOMAIN" ]]; then
    ask "  E-mail для Let's Encrypt: "; read -r TLS_EMAIL
    if [[ -n "$TLS_EMAIL" ]]; then
      ok "Домен: ${TLS_DOMAIN}  e-mail: ${TLS_EMAIL}"
    else
      warn "E-mail не указан — TLS пропущен (без него certbot не запустится)"
      TLS_DOMAIN=""
    fi
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
ALLOWED_IPS=()
ALLOWED_PORTS=()
CONF

# Безопасное сохранение массивов через printf %q — сохраняет CIDR и любые
# спецсимволы без риска расщепления по IFS.
if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  printf 'ALLOWED_IPS+=(%q)\n' "${ALLOWED_IPS[@]}" >> /etc/dns_setup/config.conf
fi
printf 'ALLOWED_PORTS+=(%q)\n' "${ALLOWED_PORTS[@]}" >> /etc/dns_setup/config.conf

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

# Временный резолвер на время установки (снимаем chattr +i, если он
# остался от предыдущего неудачного запуска скрипта)
run "chattr -i /etc/resolv.conf 2>/dev/null || true"
# rm -f обязателен: /etc/resolv.conf на Ubuntu — симлинк на
# /run/systemd/resolve/stub-resolv.conf; без rm запись пойдёт через симлинк
# и будет тут же перезаписана systemd-resolved.
run "rm -f /etc/resolv.conf"
run "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

if command -v apt-get &>/dev/null; then
  run "DEBIAN_FRONTEND=noninteractive apt-get update -qq"
  # Отключаем интерактивный вопрос "сохранить текущие правила IPv4/IPv6?"
  # от iptables-persistent — иначе apt-get -y может зависнуть в автопрогоне
  run "echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections"
  run "echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections"
  run "DEBIAN_FRONTEND=noninteractive apt-get install -y unbound unbound-anchor unbound-host \
    iptables iptables-persistent netfilter-persistent at fail2ban \
    curl tar certbot python3 python3-yaml python3-bcrypt logrotate dnsutils"
  run "systemctl enable --now atd 2>/dev/null || true"
elif command -v dnf &>/dev/null; then
  run "dnf install -y unbound iptables iptables-services at fail2ban fail2ban-firewalld \
    curl tar certbot python3 python3-pyyaml python3-bcrypt bind-utils"
  run "systemctl enable --now atd 2>/dev/null || true"
elif command -v pacman &>/dev/null; then
  run "pacman -Sy --noconfirm unbound iptables curl tar certbot python3 python-yaml python-bcrypt bind-tools at fail2ban"
  run "systemctl enable --now atd 2>/dev/null || true"
else
  err "Неизвестный пакетный менеджер. Установите unbound, iptables, certbot, python3, at, fail2ban вручную."; exit 1
fi
ok "Пакеты установлены"

# ════════════════════════════════════════════════════════════
#  SSH: реальная смена порта
# ════════════════════════════════════════════════════════════
# Раньше скрипт открывал SSH_PORT в iptables, но sshd продолжал слушать 22,
# из-за чего "смена порта" на самом деле ничего не меняла и молча вводила
# в заблуждение.
if [[ "$SSH_PORT" != "22" ]]; then
  hdr "Настройка SSH-порта"
  if [[ $DRY -eq 0 ]]; then
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-dns_setup.conf <<EOF
# Управляется dns_setup.sh
Port ${SSH_PORT}
EOF
    if sshd -t; then
      # Правило iptables для нового порта будет добавлено позже, в общем
      # блоке настройки iptables (использует ту же переменную SSH_PORT).
      if systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null; then
        ok "sshd теперь слушает порт ${SSH_PORT}"
        warn "Старое подключение на 22 может оборваться при следующем логине — переподключайтесь на ${SSH_PORT}"
      else
        err "Не удалось перезагрузить sshd — откатываю Port в sshd_config"
        rm -f /etc/ssh/sshd_config.d/99-dns_setup.conf
      fi
    else
      err "sshd -t не прошёл проверку конфига — Port НЕ изменён, оставляем 22"
      rm -f /etc/ssh/sshd_config.d/99-dns_setup.conf
      SSH_PORT=22
    fi
  else
    echo "[dry] /etc/ssh/sshd_config.d/99-dns_setup.conf → Port ${SSH_PORT}; sshd -t && systemctl reload sshd"
  fi
fi

# ════════════════════════════════════════════════════════════
#  FAIL2BAN: бан за перебор SSH
# ════════════════════════════════════════════════════════════
# Актуально в первую очередь при SSH_RESTRICTED=0 (SSH открыт всем IP).
# IP из белого списка (полный доступ по всем портам) в бан не попадают —
# ignoreip защищает доверенные хосты от случайной самоблокировки при
# опечатках в пароле/ключе.
hdr "fail2ban (защита SSH от перебора)"
if [[ $DRY -eq 0 ]]; then
  mkdir -p /etc/fail2ban/jail.d
  IGNORE_IPS="127.0.0.1/8 ::1"
  if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
    IGNORE_IPS="${IGNORE_IPS} ${ALLOWED_IPS[*]}"
  fi
  cat > /etc/fail2ban/jail.d/99-dns_setup.conf <<EOF
# Управляется dns_setup.sh
[DEFAULT]
banaction = iptables-multiport
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.factor = 4
bantime.maxtime = 24h
ignoreip = ${IGNORE_IPS}
EOF
  ok "fail2ban настроен: jail sshd на порту ${SSH_PORT}, белый список исключён из бана"
  info "Служба fail2ban будет включена после настройки iptables (иначе iptables -F снесёт её цепочки)"
else
  echo "[dry] fail2ban jail sshd (порт ${SSH_PORT}), ignoreip = белый список"
fi

# ════════════════════════════════════════════════════════════
#  SYSCTL: защита от спуфинга на уровне ядра
# ════════════════════════════════════════════════════════════
# iptables фильтрует ПО ЗАЯВЛЕННОМУ source IP пакета, а не проверяет,
# что пакет физически мог прийти оттуда. Без rp_filter атакующий может
# подделать (spoof) source IP из белого списка и обойти allow-list ACL.
# rp_filter отбрасывает пакет ещё на уровне маршрутизации, если ответ на
# него не пошёл бы через тот же интерфейс (strict reverse path check).
hdr "Hardening sysctl (защита от IP-спуфинга)"
if [[ $DRY -eq 0 ]]; then
  cat > /etc/sysctl.d/99-dns_setup.conf <<'EOF'
# Управляется dns_setup.sh — защита от спуфинга и флуда
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
EOF
  sysctl --system &>/dev/null || sysctl -p /etc/sysctl.d/99-dns_setup.conf &>/dev/null || true
  ok "rp_filter/syncookies/anti-redirect применены и переживут перезагрузку"
else
  echo "[dry] /etc/sysctl.d/99-dns_setup.conf → rp_filter, syncookies, anti-spoof"
fi

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
# ВАЖНО: AppArmor-профиль usr.sbin.unbound (пакет unbound на Debian/
# Ubuntu) разрешает unbound'у rw ТОЛЬКО на уже существующий файл
# /var/log/unbound/unbound.log, но не даёт права на создание новых
# файлов в каталоге (нет 'w' на саму директорию). Если файла ещё нет,
# open() падает с EACCES → "Could not open logfile ... Permission
# denied", хотя chown/chmod каталога выше выглядят корректными.
# Создаём файл заранее от root, чтобы unbound открывал уже
# существующий inode (это разрешено профилем).
run "touch /var/log/unbound/unbound.log"
run "chown unbound:unbound /var/log/unbound/unbound.log"
run "chmod 640 /var/log/unbound/unbound.log"

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

    # Unbound слушает только 127.0.0.1:5353, поэтому доступ извне
    # физически невозможен — фильтрация по IP делается на уровне
    # iptables и AdGuard Home (allowed_clients), не здесь.
    access-control: 0.0.0.0/0 refuse
    access-control: 127.0.0.0/8 allow

    # IPv6-резолвинг (AAAA) отключён ниже (do-ip6: no) — это осознанное
    # упрощение; при наличии IPv6-клиентов это может замедлять
    # соединения за счёт fallback IPv6→IPv4.
UBEOF
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

    # Логи: пишем в собственный файл (с ротацией через logrotate ниже).
    # use-syslog: yes перебивал бы logfile согласно unbound.conf(5)
    # ("logfile setting is overridden when use-syslog: yes is set"),
    # и лог-файл, для которого настроен logrotate, всегда был бы пуст.
    verbosity: 0
    logfile: "/var/log/unbound/unbound.log"
    log-replies: no
    use-syslog: no
UBEOF
  } > /etc/unbound/unbound.conf

  if unbound-checkconf; then
    ok "unbound.conf корректен"
  else
    err "Ошибка в unbound.conf!"; exit 1
  fi
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
    # create обязателен: без него после ротации новый файл может не
    # появиться до следующего запуска unbound, а AppArmor не даёт
    # unbound'у самому создать отсутствующий файл (см. комментарий
    # выше при первом touch) — HUP тогда снова упрётся в "Permission
    # denied". create здесь выполняется от root (logrotate), поэтому
    # AppArmor-профиль unbound тут не мешает.
    create 640 unbound unbound
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
  # ufw/firewalld управляют iptables/nftables сами и при своём рестарте
  # (или просто по таймеру) переписывают цепочки поверх наших правил —
  # отключаем их, чтобы наши iptables-правила пережили ребут.
  if command -v ufw &>/dev/null; then
    ufw disable 2>/dev/null || true
    systemctl disable --now ufw 2>/dev/null || true
    warn "ufw отключён — правила теперь только в iptables (см. ниже)"
  fi
  if command -v firewall-cmd &>/dev/null; then
    systemctl disable --now firewalld 2>/dev/null || true
    warn "firewalld отключён — правила теперь только в iptables (см. ниже)"
  fi

  # Аварийный откат: если после применения правил SSH станет недоступен
  # (ошибка в белом списке, другой исходящий IP через VPN/NAT и т.п.),
  # через 10 минут правила автоматически сбросятся обратно в ACCEPT.
  if command -v at &>/dev/null; then
    FAILSAFE_JOB=$(echo "iptables -F; iptables -X; iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; ip6tables -F 2>/dev/null; ip6tables -X 2>/dev/null; ip6tables -P INPUT ACCEPT 2>/dev/null; ip6tables -P FORWARD ACCEPT 2>/dev/null; ip6tables -P OUTPUT ACCEPT 2>/dev/null" \
      | at now + 10 minutes 2>&1 | grep -oE 'job [0-9]+' | awk '{print $2}' || true)
    if [[ -n "${FAILSAFE_JOB:-}" ]]; then
      echo "$FAILSAFE_JOB" > /etc/dns_setup/failsafe_job
      warn "Аварийный откат iptables запланирован через 10 минут (at job #${FAILSAFE_JOB})."
      warn "Если SSH после установки работает — отмените его: atrm ${FAILSAFE_JOB}"
    else
      warn "Не удалось запланировать аварийный откат — проверьте, что демон atd запущен"
    fi
  else
    warn "Команда 'at' недоступна — аварийный откат iptables НЕ запланирован. Убедитесь, что не потеряете доступ по SSH!"
  fi

  # Сброс
  iptables -F; iptables -X
  iptables -t nat -F; iptables -t mangle -F

  iptables -P INPUT   DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT  ACCEPT

  # Loopback + established
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # ── Анти-спуфинг / анти-скан на уровне пакетов ──────────────
  # INVALID: пакеты, не относящиеся ни к одному известному соединению
  # (частый признак спуфинга или сканирования) — дропаем сразу, до ACL.
  iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
  # NULL-скан (все флаги TCP сброшены) и XMAS-скан (FIN+PSH+URG без ACK/SYN) —
  # классические техники обхода файрвола/скрытого сканирования портов.
  iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,SYN FIN,SYN -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
  iptables -A INPUT -p tcp --tcp-flags FIN,ACK FIN -j DROP
  iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
  iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP

  # ── Белый список = полный доступ ко ВСЕМУ серверу ────────────
  # Раньше IP из белого списка получал доступ только к перечисленным
  # DNS/панель-портам, а не к серверу целиком. Теперь ACL работает
  # как ожидается: в списке — доверенный IP с полным доступом одним
  # правилом; не в списке — всё дропается политикой INPUT DROP.
  if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
    for IP in "${ALLOWED_IPS[@]}"; do
      iptables -A INPUT -s "$IP" -j ACCEPT
    done
    info "IP из белого списка (${#ALLOWED_IPS[@]}) получили полный доступ ко всем портам/протоколам"
  fi

  # SSH: доступ для белого списка уже открыт правилом выше. Если
  # пользователь осознанно НЕ ограничивал SSH (SSH_RESTRICTED=0) —
  # дополнительно открываем порт для всех остальных.
  if [[ $SSH_RESTRICTED -eq 1 ]]; then
    info "SSH разрешён только IP из белого списка"
  else
    iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
    info "SSH открыт для всех IP (явный выбор пользователя)"
  fi

  # Остальные сервисные порты (DNS/DoT/DoH/панель AGH): если белый
  # список не задан — открываем всем (сценарий публичного резолвера).
  # Если список задан — доступ уже выдан выше через blanket ACCEPT,
  # всем прочим IP порты не открываются (сработает default DROP).
  if [[ ${#ALLOWED_IPS[@]} -eq 0 ]]; then
    for PORT in "${ALLOWED_PORTS[@]}"; do
      iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
      iptables -A INPUT -p udp --dport "$PORT" -j ACCEPT
    done
    warn "Белый список пуст — DNS-порты и панель AGH открыты ВСЕМ. Прочие порты по-прежнему дропаются (default DROP)."
  fi

  # ВАЖНО: приватные диапазоны (10.0.0.0/8, 192.168.0.0/16 и т.п.)
  # БОЛЬШЕ НЕ получают безусловный полный доступ. Раньше это было
  # незаметным исключением из ACL: любой сосед по той же приватной
  # сети (например, в облаке/VPC с общим L2/VPN) получал полный
  # доступ к серверу, даже не будучи в белом списке. Если вам нужен
  # доступ из вашей локальной сети — добавьте её CIDR (например,
  # 192.168.1.0/24) в белый список на шаге 3/5, он тоже получит
  # полный доступ по правилу выше. Loopback (127.0.0.0/8) уже
  # разрешён отдельным правилом для трафика на lo.

  # Защита от DNS-флуда — UDP/53
  iptables -A INPUT -p udp --dport 53 -m conntrack --ctstate NEW \
           -m recent --set --name DNSQF --rsource
  iptables -A INPUT -p udp --dport 53 -m conntrack --ctstate NEW \
           -m recent --update --seconds 1 --hitcount 70 \
           --name DNSQF --rsource -j DROP

  # Защита от DNS-флуда — TCP/53 (раньше рейт-лимит был только на UDP,
  # TCP DNS оставался полностью открытым для флуда новыми соединениями)
  iptables -A INPUT -p tcp --syn --dport 53 -m conntrack --ctstate NEW \
           -m recent --set --name DNSTCPF --rsource
  iptables -A INPUT -p tcp --syn --dport 53 -m conntrack --ctstate NEW \
           -m recent --update --seconds 1 --hitcount 70 \
           --name DNSTCPF --rsource -j DROP

  # Общая защита от SYN-флуда для остальных сервисных TCP-портов
  # (панель 3000, DoT 853, HTTPS/DoH 443) — без неё DoS на них лежит
  # исключительно на syncookies из sysctl, чего недостаточно под нагрузкой.
  iptables -A INPUT -p tcp --syn -m hashlimit \
           --hashlimit-above 200/sec --hashlimit-burst 100 \
           --hashlimit-mode srcip --hashlimit-name synflood \
           -j DROP

  # ── IPv6: блокируем весь входящий трафик ────────────────────
  # Весь стек сознательно IPv4-only (unbound: do-ip6 no, AGH: bind_hosts
  # 0.0.0.0, valid_ip() принимает только IPv4/CIDR). Но если на сервере
  # включён IPv6, а ip6tables не настроен, его политика по умолчанию —
  # обычно ACCEPT: SSH, DNS и панель оказались бы полностью открыты
  # в обход всего белого списка выше. Поэтому глушим весь входящий IPv6.
  if command -v ip6tables &>/dev/null; then
    ip6tables -F; ip6tables -X
    ip6tables -P INPUT   DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT  ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    info "IPv6: весь входящий трафик заблокирован (сервис работает только по IPv4)"
  else
    warn "ip6tables не найден — если на сервере включён IPv6, белый список можно обойти по IPv6!"
  fi

  # Сохранение правил (способ зависит от дистрибутива — раньше единый
  # elif-фолбэк писал rules.v4, а restore-скрипт читал iptables.rules,
  # то есть правила НЕ переживали перезагрузку на Fedora/RHEL и Arch,
  # хотя скрипт после этого шага бодро рапортовал об успехе)
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
  elif command -v dnf &>/dev/null; then
    # Fedora/RHEL: пакет iptables-services
    mkdir -p /etc/sysconfig
    iptables-save  > /etc/sysconfig/iptables  2>/dev/null || true
    command -v ip6tables-save &>/dev/null && \
      { ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true; }
    systemctl enable --now iptables ip6tables 2>/dev/null || true
  elif command -v pacman &>/dev/null; then
    # Arch: встроенные iptables.service/ip6tables.service пакета iptables
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/iptables.rules  2>/dev/null || true
    command -v ip6tables-save &>/dev/null && \
      { ip6tables-save > /etc/iptables/ip6tables.rules 2>/dev/null || true; }
    systemctl enable iptables ip6tables 2>/dev/null || true
  elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    command -v ip6tables-save &>/dev/null && \
      { ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true; }
    mkdir -p /etc/network/if-pre-up.d/
    cat > /etc/network/if-pre-up.d/iptables <<'EOS'
#!/bin/sh
[ -f /etc/iptables/rules.v4 ] && iptables-restore  < /etc/iptables/rules.v4
[ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
EOS
    chmod +x /etc/network/if-pre-up.d/iptables
  else
    warn "Не удалось определить способ сохранения iptables — правила не переживут перезагрузку"
  fi

  # ── Универсальный restore, не зависящий от дистрибутива ─────
  # netfilter-persistent/iptables-services/if-pre-up.d работают только с
  # соответствующим network-стеком (ifupdown, NetworkManager, systemd-
  # networkd — по-разному на разных системах). Дублируем восстановление
  # через собственный systemd oneshot-юнит, который сработает при любом
  # раскладе и вернёт файрвол в исходное рабочее состояние после ребута.
  # Тот же файл использует healthcheck-watchdog ниже для самовосстановления
  # правил, если они будут случайно сброшены во время работы (ufw ожил,
  # кто-то выполнил iptables -F руками и т.п.).
  mkdir -p /etc/dns_setup
  iptables-save  > /etc/dns_setup/iptables.rules  2>/dev/null || true
  command -v ip6tables-save &>/dev/null && \
    { ip6tables-save > /etc/dns_setup/ip6tables.rules 2>/dev/null || true; }

  cat > /usr/local/bin/dns_setup_restore_fw.sh <<'EOS'
#!/bin/bash
# Управляется dns_setup.sh — восстанавливает канонический firewall
[ -f /etc/dns_setup/iptables.rules ]  && iptables-restore  < /etc/dns_setup/iptables.rules
[ -f /etc/dns_setup/ip6tables.rules ] && command -v ip6tables-restore &>/dev/null && \
  ip6tables-restore < /etc/dns_setup/ip6tables.rules
EOS
  chmod +x /usr/local/bin/dns_setup_restore_fw.sh

  cat > /etc/systemd/system/dns-setup-firewall.service <<'EOS'
[Unit]
Description=dns_setup: restore canonical iptables rules
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns_setup_restore_fw.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable dns-setup-firewall.service &>/dev/null || true
  ok "Универсальный restore firewall при загрузке настроен (dns-setup-firewall.service)"
else
  echo "[dry] iptables flush + rebuild (IPv4 + IPv6)"
fi
ok "iptables настроен и сохранён"

# fail2ban включаем только теперь: его цепочки должны накладываться на уже
# финальный iptables, иначе следующий iptables -F (если бы он ещё случился)
# снёс бы их. Дальше по скрипту iptables больше не флашится.
if [[ $DRY -eq 0 ]]; then
  systemctl enable --now fail2ban 2>/dev/null || true
  systemctl restart fail2ban 2>/dev/null || true
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "fail2ban запущен и следит за SSH (порт ${SSH_PORT})"
  else
    warn "fail2ban не запустился — проверьте: systemctl status fail2ban"
  fi
fi

# ════════════════════════════════════════════════════════════
#  TLS (certbot)
# ════════════════════════════════════════════════════════════
if [[ -n "$TLS_DOMAIN" && -n "$TLS_EMAIL" ]]; then
  hdr "TLS — ${TLS_DOMAIN}"
  if [[ $DRY -eq 0 ]]; then
    # certbot подтверждает владение доменом (HTTP-01), заходя на порт 80
    # С ЛЮБОГО IP серверов Let's Encrypt — они не входят и не могут
    # входить в белый список. Поэтому временно открываем 80/tcp на время
    # выпуска сертификата независимо от режима ACL — иначе certbot
    # стабильно проваливается всякий раз, когда белый список включён.
    iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT
    if certbot certonly --standalone \
         -d "${TLS_DOMAIN}" \
         --email "${TLS_EMAIL}" \
         --agree-tos --no-eff-email --non-interactive; then
      ok "Сертификат: /etc/letsencrypt/live/${TLS_DOMAIN}/"
    else
      warn "certbot не смог получить сертификат — продолжаем без TLS"
    fi
    iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true

    # Авто-обновление (grep -vF убирает старую строку при повторном
    # запуске скрипта, sort -u не используется — он мог бы переставить
    # служебные переменные PATH/MAILTO/SHELL ниже заданий, которые от
    # них зависят). Открытие/закрытие 80/tcp вокруг renew — по той же
    # причине, что и при первичном выпуске сертификата выше.
    ( crontab -l 2>/dev/null | grep -vF "certbot renew --quiet" || true
      # ВАЖНО: полные пути обязательны — у root-cron PATH=/usr/bin:/bin,
      # а iptables лежит в /usr/sbin и без пути не найдётся, из-за чего
      # порт 80 не откроется и certbot renew стабильно провалится.
      # Дополнительно задаём PATH и оборачиваем логику в bash -c с trap,
      # чтобы порт 80 закрывался даже при падении certbot.
      echo '0 3 1 * * PATH=/usr/sbin:/usr/bin:/bin bash -c "trap \"/usr/sbin/iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; /bin/systemctl restart AdGuardHome\" EXIT; /usr/sbin/iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT && /usr/bin/certbot renew --quiet"'
    ) | crontab -
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
  rm -f AdGuardHome.tar.gz

  # Раньше единственный curl без ретраев и без проверки итога: любой
  # временный сбой сети/DNS (а resolv.conf в этот момент ещё временный,
  # на 8.8.8.8) валил curl, и весь скрипт молча падал под set -e ровно
  # тут — без внятной причины в логе и без /opt/AdGuardHome на диске.
  # Теперь: до 5 попыток с задержкой, явная проверка HTTP-кода и
  # ненулевого размера файла, понятная ошибка при провале всех попыток.
  AGH_DL_OK=0
  for attempt in 1 2 3 4 5; do
    HTTP_CODE=$(curl -sSL -w '%{http_code}' -o AdGuardHome.tar.gz "${AGH_URL}" || echo "000")
    if [[ "$HTTP_CODE" == "200" && -s AdGuardHome.tar.gz ]]; then
      AGH_DL_OK=1
      break
    fi
    warn "Попытка ${attempt}/5 скачать AGH не удалась (HTTP ${HTTP_CODE}) — повтор через 5с"
    rm -f AdGuardHome.tar.gz
    sleep 5
  done
  if [[ $AGH_DL_OK -ne 1 ]]; then
    err "Не удалось скачать AGH с ${AGH_URL} после 5 попыток"
    err "Проверьте вручную: curl -v ${AGH_URL} -o /tmp/agh.tar.gz"
    exit 1
  fi

  if ! tar -xzf AdGuardHome.tar.gz; then
    err "Архив AdGuardHome.tar.gz скачан, но распаковка не удалась (повреждён/неполный файл)"
    exit 1
  fi
  rm -f AdGuardHome.tar.gz

  # Явная проверка, что бинарник реально появился — иначе все следующие
  # шаги (install/config) будут молча работать с несуществующим сервисом.
  if [[ ! -x /opt/AdGuardHome/AdGuardHome ]]; then
    err "После распаковки нет исполняемого файла /opt/AdGuardHome/AdGuardHome"
    err "Содержимое /opt/AdGuardHome:"; ls -la /opt/AdGuardHome 2>&1 || true
    exit 1
  fi
  ok "Распакован в /opt/AdGuardHome ($(/opt/AdGuardHome/AdGuardHome --version 2>&1 | head -1))"
else
  echo "[dry] curl AdGuardHome_${AGH_ARCH}.tar.gz → /opt/AdGuardHome"
fi

# Теперь глушим resolved и ставим AGH как сервис
run "systemctl stop    systemd-resolved 2>/dev/null || true"
run "systemctl disable systemd-resolved 2>/dev/null || true"

if [[ $DRY -eq 0 ]]; then
  cd /opt/AdGuardHome

  # Повторный запуск скрипта (или прошлая неудачная попытка) мог уже
  # оставить юнит AdGuardHome.service в systemd. "-s install" в этом
  # случае падает с "Init already exists", поэтому чистим перед
  # регистрацией нового.
  if systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome\.service' \
     || [[ -f /etc/systemd/system/AdGuardHome.service ]]; then
    warn "Юнит AdGuardHome.service уже существует — удаляю перед переустановкой"
    systemctl stop AdGuardHome 2>/dev/null || true
    ./AdGuardHome -s uninstall 2>/dev/null || true
    rm -f /etc/systemd/system/AdGuardHome.service
    systemctl daemon-reload
  fi

  if ! ./AdGuardHome -s install; then
    err "'AdGuardHome -s install' завершился с ошибкой — сервис НЕ зарегистрирован"
    err "Запустите вручную для диагностики: /opt/AdGuardHome/AdGuardHome -s install"
    exit 1
  fi
  # ВАЖНО: "-s install" не только создаёт unit-файл, но и сам стартует
  # службу в обход systemctl (видно в логе: "service_manager: starting
  # service"). Сразу после install кэш systemd (list-unit-files) может
  # ещё не знать о новом юните — без daemon-reload проверка ниже ложно
  # решает, что юнит не появился, и валит установку, хотя AGH уже
  # реально запущен. Сначала даём systemd перечитать unit-файлы.
  systemctl daemon-reload
  # -s install должен создать unit и включить его — проверяем явно,
  # а не верим на слово коду возврата. Проверяем и list-unit-files, и
  # сам файл на диске — на случай, если кэш всё ещё не обновился даже
  # после reload.
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome\.service' \
     && [[ ! -f /etc/systemd/system/AdGuardHome.service ]]; then
    err "AdGuardHome -s install вернул успех, но AdGuardHome.service не найден в systemd"
    exit 1
  fi
  # Служба уже запущена самим "-s install" (без конфига, в режиме
  # первого запуска) — останавливаем её, чтобы не мешала занять порт
  # 53/3000 во время генерации AdGuardHome.yaml ниже.
  systemctl stop AdGuardHome 2>/dev/null || true
  ok "AdGuard Home зарегистрирован как systemd-сервис"
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
  # Хешируем пароль (bcrypt через htpasswd или python3).
  # ВАЖНО: пароль передаётся через stdin/переменные окружения, а не как
  # аргумент командной строки или литерал в исходнике — иначе он был бы
  # виден в `ps aux` всем пользователям системы, а спецсимволы вроде
  # ' " \ ${...} в пароле могли бы сломать синтаксис или выполниться
  # как код внутри python -c "...${AGH_PASS}...".
  # ВАЖНО: AdGuard Home принимает ТОЛЬКО bcrypt-хеши пароля. Раньше при
  # отсутствии htpasswd и модуля bcrypt скрипт молча откатывался на
  # crypt(3)/SHA-512 — AGH такой хеш не распознаёт, и админ оказывался
  # залочен из панели без единого сообщения об ошибке при установке.
  # Теперь вместо тихого отката явно требуем bcrypt и останавливаемся
  # с понятной ошибкой, если его нет (пакет python3-bcrypt/python-bcrypt
  # уже ставится на этапе установки пакетов, так что это - подстраховка).
  if command -v htpasswd &>/dev/null; then
    AGH_HASH=$(printf '%s\n' "${AGH_PASS}" | htpasswd -inBC 10 "${AGH_USER}" | cut -d: -f2-) \
      || { unset AGH_PASS AGH_PASS2; err "htpasswd не смог захешировать пароль"; exit 1; }
  else
    AGH_HASH=$(AGH_PASS="${AGH_PASS}" python3 -c '
import os, sys
pw = os.environ["AGH_PASS"].encode()
try:
    import bcrypt
except ImportError:
    print("модуль python3-bcrypt не найден", file=sys.stderr)
    sys.exit(1)
print(bcrypt.hashpw(pw, bcrypt.gensalt(10)).decode())
') || { unset AGH_PASS AGH_PASS2; err "Не удалось захешировать пароль: нет ни htpasswd, ни python3-bcrypt"; exit 1; }
  fi
  # Пароль в открытом виде больше не нужен — сразу затираем переменные
  unset AGH_PASS AGH_PASS2

  mkdir -p /opt/AdGuardHome /var/log/AdGuardHome

  # ВАЖНО: heredoc с 'PYEOF' в кавычках — bash НЕ подставляет переменные
  # в код Python. Все значения (включая пароль/хеш/домен, которые могут
  # содержать ' " \ ${...}) передаются только через os.environ, что
  # исключает поломку синтаксиса или инъекцию произвольного кода.
  AGH_USER="${AGH_USER}" AGH_HASH="${AGH_HASH}" \
  TLS_DOMAIN="${TLS_DOMAIN:-}" TLS_CERT="${TLS_CERT:-}" TLS_KEY="${TLS_KEY:-}" \
  AGH_CONF="${AGH_CONF}" \
  AGH_ALLOWED_IPS="$(printf '%s\n' "${ALLOWED_IPS[@]}")" \
  python3 - <<'PYEOF'
import yaml, os

agh_user   = os.environ["AGH_USER"]
agh_hash   = os.environ["AGH_HASH"]
tls_domain = os.environ.get("TLS_DOMAIN", "")
tls_cert   = os.environ.get("TLS_CERT", "")
tls_key    = os.environ.get("TLS_KEY", "")
agh_conf   = os.environ["AGH_CONF"]
# Тот же белый список, что применяется в iptables — дублируем его на
# уровне AGH (allowed_clients) как defense-in-depth: даже если правила
# iptables будут случайно сброшены (например, ручным `iptables -F`),
# сам AdGuard Home продолжит отклонять запросы не из белого списка.
allowed_ips = [x for x in os.environ.get("AGH_ALLOWED_IPS", "").splitlines() if x.strip()]
# resolv.conf сервера указывает на 127.0.0.1 (сам AGH слушает :53), то есть
# сам сервер — это тоже DNS-клиент AGH, с исходным IP 127.0.0.1/::1. Без
# явного добавления loopback в allowed_clients AGH отклонял бы собственные
# запросы сервера (apt, curl, certbot renew и т.п.). Добавляем loopback
# ТОЛЬКО когда список уже ограничительный (непустой) — пустой список у
# AGH означает "доступ всем", и добавление туда 127.0.0.1/::1 случайно
# превратило бы его в "доступ только с localhost".
if allowed_ips:
    for _lo in ("127.0.0.1", "::1"):
        if _lo not in allowed_ips:
            allowed_ips.append(_lo)

tls_enabled = bool(tls_cert)

config = {
    "bind_host": "0.0.0.0",
    "bind_port": 3000,
    "users": [{"name": agh_user, "password": agh_hash}],
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
        # Никаких публичных DNS (Google/Cloudflare/Quad9) в конфиге —
        # вся суть схемы в рекурсии Unbound от корневых серверов (root.hints),
        # а не в форвардинге третьим лицам. bootstrap_dns тут не используется
        # вообще, т.к. апстрим задан IP-адресом (127.0.0.1:5353), а не
        # хостнеймом — бутстрап нужен AGH только для резолва хостнейма
        # DoH/DoT/DoQ-апстрима. fallback_dns оставлен пустым осознанно:
        # если Unbound упадёт, AGH должен вернуть SERVFAIL, а не тихо
        # утечь запросы на публичный резолвер. Отказоустойчивость Unbound
        # обеспечивается через Restart=always в systemd-юните ниже.
        "fallback_dns": [],
        "bootstrap_dns": ["127.0.0.1:5353"],
        "all_servers": False,
        "fastest_addr": False,
        "fastest_timeout": "1s",
        "allowed_clients": allowed_ips,
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
        # local_ptr_upstreams не задан, поэтому use_private_ptr_resolvers=True
        # заставлял AGH использовать системный резолвер для PTR — а тот
        # смотрит на 127.0.0.1 (сам AGH) → петля. Выключаем; при желании
        # резолвить приватные PTR через Unbound впишите
        # local_ptr_upstreams: ["127.0.0.1:5353"] и включите флаг обратно.
        "use_private_ptr_resolvers": False,
        "local_ptr_upstreams": [],
        # DNSSEC уже валидируется в Unbound (trust anchor + root.hints),
        # но включаем и здесь как второй независимый слой проверки —
        # если Unbound когда-нибудь будет заменён/обойдён, AGH всё равно
        # отклонит поддельные ответы.
        "enable_dnssec": True,
        "edns_client_subnet": {"custom_ip": "", "enabled": False, "use_custom": False},
        "max_goroutines": 300,
        "handle_ddr": True,
    },
    "tls": {
        "enabled": tls_enabled,
        "server_name": tls_domain,
        # Панель изначально спроектирована как HTTPS-only для доверенных
        # клиентов: если сертификат есть — принудительно редиректим с
        # HTTP на HTTPS, а не оставляем оба варианта доступными.
        "force_https": tls_enabled,
        "port_https": 443,
        "port_dns_over_tls": 853,
        "port_dns_over_quic": 784,
        "port_dnscrypt": 0,
        "dnscrypt_config_file": "",
        "allow_unencrypted_doh": False,
        "certificate_chain": "",
        "private_key": "",
        "certificate_path": tls_cert,
        "private_key_path": tls_key,
        "strict_sni_check": False,
    },
    "filters": [
        {"enabled": True, "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt", "name": "AdGuard DNS filter", "id": 1},
        {"enabled": True, "url": "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt", "name": "AdAway Default Blocklist", "id": 2},
        {"enabled": True, "url": "https://big.oisd.nl", "name": "OISD Big", "id": 3},
        {"enabled": True, "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt", "name": "HaGeZi Pro", "id": 4},
        # TIF = Threat Intelligence Feeds: фиды актуальных фишинговых/малварных/
        # C2-доменов, а не общий рекламный список — категория "антималварь",
        # которой раньше не было ни в одном из двух исходных фильтров.
        {"enabled": True, "url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt", "name": "HaGeZi Threat Intelligence Feeds", "id": 5},
        {"enabled": True, "url": "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts", "name": "Steven Black", "id": 6},
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
    # ВАЖНО: начиная с v0.107.34 AdGuard Home читает настройки логов
    # ТОЛЬКО из вложенной секции "log:" — старые плоские ключи
    # log_file/log_max_backups/.../verbose (это была схема < v0.107.34)
    # молча игнорируются и AGH продолжает писать в stdout (виден в
    # journalctl -u AdGuardHome), а не в файл, хотя конфиг выглядит
    # рабочим и без единой ошибки при старте.
    "log": {
        "file": "/var/log/AdGuardHome/AdGuardHome.log",
        "max_backups": 0,
        "max_size": 100,
        "max_age": 3,
        "compress": False,
        "local_time": False,
        "verbose": False,
    },
    "os": {"group": "", "user": "", "rlimit_nofile": 0},
    # schema_version соответствует AGH v0.107.x; при более новом AGH он
    # сам мигрирует конфиг вверх. При даунгрейде — удалите строку и дайте
    # AGH создать AdGuardHome.yaml с нуля.
    "schema_version": 28,
}

os.makedirs("/opt/AdGuardHome", exist_ok=True)
os.makedirs("/var/log/AdGuardHome", exist_ok=True)
with open(agh_conf, "w") as f:
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
  chattr -i /etc/resolv.conf 2>/dev/null || true
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
#  WATCHDOG: самовосстановление при отказе
# ════════════════════════════════════════════════════════════
# Идея: если Unbound или AGH зависли/упали — перезапустить именно их,
# не трогая второй сервис (он продолжает работать/отдавать SERVFAIL).
# Если firewall потерял наши правила (кто-то выполнил iptables -F,
# ожил ufw/firewalld и т.п.) — молча восстановить канонический набор
# из /etc/dns_setup/iptables.rules. Раз в 2 минуты, лог в journal.
hdr "Watchdog самовосстановления"

if [[ $DRY -eq 0 ]]; then
  cat > /usr/local/bin/dns_setup_healthcheck.sh <<'EOS'
#!/bin/bash
# Управляется dns_setup.sh
log() { logger -t dns_setup_healthcheck "$1"; }

# 1. Unbound жив?
if ! dig @127.0.0.1 -p 5353 +time=2 +tries=1 +short google.com &>/dev/null; then
  log "Unbound не отвечает — перезапуск"
  systemctl restart unbound
fi

# 2. AdGuard Home жив?
if ! dig @127.0.0.1 +time=2 +tries=1 +short google.com &>/dev/null; then
  log "AdGuard Home не отвечает — перезапуск"
  systemctl restart AdGuardHome
fi

# 3. Firewall не сброшен и не подменён? Признак нашей политики — DROP по
# умолчанию на INPUT. Если это не так (ufw/firewalld ожили, кто-то
# выполнил iptables -F) — восстанавливаем канонический набор правил.
POLICY=$(iptables -S INPUT 2>/dev/null | head -1)
if [[ "$POLICY" != "-P INPUT DROP" ]]; then
  log "Политика iptables INPUT изменилась ('${POLICY}') — восстанавливаю правила"
  /usr/local/bin/dns_setup_restore_fw.sh
  # iptables-restore полностью замещает таблицы, включая цепочки fail2ban —
  # без рестарта f2b будет ссылаться на удалённую цепочку и не сможет банить.
  systemctl restart fail2ban 2>/dev/null || true
fi
EOS
  chmod +x /usr/local/bin/dns_setup_healthcheck.sh

  cat > /etc/systemd/system/dns-setup-healthcheck.service <<'EOS'
[Unit]
Description=dns_setup: healthcheck & self-heal (unbound/AGH/firewall)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns_setup_healthcheck.sh
EOS

  cat > /etc/systemd/system/dns-setup-healthcheck.timer <<'EOS'
[Unit]
Description=dns_setup: healthcheck every 2 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOS

  systemctl daemon-reload
  systemctl enable --now dns-setup-healthcheck.timer &>/dev/null || true
  ok "Watchdog включён: проверка Unbound/AGH/firewall каждые 2 минуты (journalctl -t dns_setup_healthcheck)"
else
  echo "[dry] dns-setup-healthcheck.service + .timer каждые 2 минуты"
fi

# ════════════════════════════════════════════════════════════
#  Cron обновления root.hints
# ════════════════════════════════════════════════════════════
if [[ $DRY -eq 0 ]]; then
  ( crontab -l 2>/dev/null | grep -vF "named.cache -o /var/lib/unbound/root.hints" || true
    echo "0 4 1 * * curl -fsSL https://www.internic.net/domain/named.cache -o /var/lib/unbound/root.hints && systemctl restart unbound"
  ) | crontab -
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
  # Unbound: unbound-host не поддерживает dig-style "@server -p port",
  # поэтому проверяем демон напрямую через dig на 127.0.0.1:5353
  if command -v dig &>/dev/null; then
    if dig @127.0.0.1 -p 5353 google.com +short +timeout=3 &>/dev/null; then
      ok "Unbound (127.0.0.1:5353) отвечает"
    else
      warn "Unbound не ответил — проверьте: systemctl status unbound"
    fi
  elif command -v unbound-host &>/dev/null; then
    if unbound-host -C /etc/unbound/unbound.conf google.com &>/dev/null; then
      ok "Unbound отвечает"
    else
      warn "Unbound не ответил — проверьте: systemctl status unbound"
    fi
  fi

  # AGH
  if command -v dig &>/dev/null; then
    if dig +short +timeout=3 +tries=1 google.com @127.0.0.1 > /dev/null; then
      ok "AdGuard Home (127.0.0.1:53) отвечает"
    else
      warn "AdGuard Home не ответил — проверьте: systemctl status AdGuardHome"
    fi

    # DNSSEC: +short для домена sigok.verteiltesysteme.net не содержит
    # буквы "A" в IP-адресах (это была ложная проверка) — вместо этого
    # проверяем флаг AD ("Authenticated Data") в заголовке ответа dig
    DNSSEC_FLAGS=$(dig +dnssec +noall +comments sigok.verteiltesysteme.net @127.0.0.1 2>/dev/null | grep '^;; flags:' || true)
    if echo "$DNSSEC_FLAGS" | grep -qE '\bad\b'; then
      ok "DNSSEC работает (флаг AD подтверждён)"
    else
      warn "DNSSEC не подтверждён — цепочка доверия может ещё строиться"
    fi
  elif command -v nslookup &>/dev/null; then
    if nslookup google.com 127.0.0.1 &>/dev/null; then
      ok "AdGuard Home отвечает"
    else
      warn "AdGuard Home не ответил"
    fi
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
if [[ ${#ALLOWED_IPS[@]} -gt 0 ]]; then
  echo "  Доступ только с ${#ALLOWED_IPS[@]} доверенных IP из белого списка."
else
  echo -e "  ${Y}Доступ ЗАКРЫТ всем — белый список пуст. Используйте SSH-туннель:${X}"
  echo "  ssh -L 3000:127.0.0.1:3000 -p ${SSH_PORT} user@<IP_сервера>  →  http://127.0.0.1:3000"
fi
echo
echo -e "${B}Шифрование запросов:${X}"
if [[ -n "$TLS_DOMAIN" ]]; then
  echo -e "  ${C}DoT :853  DoH :443 (/dns-query)  DoQ :784${X} — шифрованы, panель на HTTPS"
  echo "  Обычный порт 53 (plain DNS) остаётся открыт для клиентов из белого"
  echo "  списка — это локальный трафик до вашего резолвера, но сам по себе"
  echo "  не шифрован. Настройте клиентов на 853/443/784, если нужен TLS end-to-end."
else
  echo "  TLS не настроен — все запросы идут по обычному plain DNS (порт 53)."
  echo "  Шифрование клиент→сервер (DoT/DoH/DoQ) требует сертификата и домена."
  echo "  Перезапустите установку и укажите домен на шаге 5/5, чтобы включить."
fi
echo
echo -e "${B}Самовосстановление:${X}"
echo "  Unbound/AGH: Restart=always в systemd (падение → рестарт сразу)"
echo "  Watchdog:    проверка + автолечение каждые 2 минуты (unbound/AGH/firewall)"
echo "  Firewall:    восстанавливается из /etc/dns_setup/iptables.rules при сбросе"
echo "  Лог watchdog: journalctl -t dns_setup_healthcheck -f"
echo
echo -e "${B}Защита от перебора и флуда:${X}"
echo "  fail2ban:     jail sshd, порт ${SSH_PORT}, бан после 5 попыток (белый список исключён)"
echo "  DNS rate-limit: UDP/53 и TCP/53 — до 70 новых соединений/сек с одного IP"
echo "  SYN-флуд:     до 200 новых TCP-соединений/сек с одного IP на прочих портах"
echo "  Проверить баны: fail2ban-client status sshd"
echo
echo -e "${B}Блок-листы AGH:${X} AdGuard DNS, AdAway, OISD Big, HaGeZi Pro, HaGeZi TIF (антималварь), Steven Black"
echo
echo -e "${B}Полезные команды:${X}"
echo "  systemctl status unbound AdGuardHome dns-setup-healthcheck.timer fail2ban"
echo "  journalctl -u unbound -f"
echo "  journalctl -u AdGuardHome -f"
echo "  dig +short google.com @127.0.0.1"
echo "  dig +dnssec sigok.verteiltesysteme.net @127.0.0.1"
echo
echo -e "${B}Удаление:${X}  sudo bash $0 --uninstall"
echo -e "${B}Dry-run:${X}   sudo bash $0 --dry-run"
echo

if [[ $DRY -eq 0 && -f /etc/dns_setup/failsafe_job ]]; then
  FJ=$(cat /etc/dns_setup/failsafe_job)
  warn "Аварийный откат iptables всё ещё запланирован (at job #${FJ})."
  warn "Если SSH и доступ по нужным портам работают — отмените его прямо сейчас: atrm ${FJ}"
  warn "Иначе через 10 минут после установки правила iptables сбросятся в ACCEPT."
  echo
fi

ok "Готово!"
