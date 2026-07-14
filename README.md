<div align="center">
  
# 🛡️ DNS Server: Unbound + AdGuard Home

[![Bash](https://img.shields.io/badge/Bash-4.0+-green?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/License-MIT-orange?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%2F%20Debian%20%2F%20Fedora%20%2F%20Arch-purple?style=for-the-badge&logo=linux)](https://ubuntu.com)
[![DNSSEC](https://img.shields.io/badge/DNSSEC-validated-blue?style=for-the-badge)](https://www.icann.org/resources/pages/dnssec-what-is-it-why-important-2019-03-05-en)
[![Firewall](https://img.shields.io/badge/Firewall-iptables%20%2B%20fail2ban-red?style=for-the-badge)](https://netfilter.org)

**Приватный DNS-сервер с блокировкой рекламы, DNSSEC и чистой рекурсией — один скрипт, никакой магии.**

*AdGuard Home (фильтрация) · Unbound (рекурсия от корней) · DNSSEC · iptables + fail2ban · sysctl hardening · watchdog самовосстановления · Let's Encrypt*

</div>

---

## 🤔 Зачем это нужно?

Обычный DNS-резолвер отправляет все запросы на `8.8.8.8` или `1.1.1.1` — провайдер, хостер или сам DNS-сервис видит каждый домен, который вы резолвите. Этот стек работает иначе:

- 🔒 **Рекурсия от корней** — Unbound сам обходит DNS-дерево от корневых серверов IANA, ни один запрос не форвардится третьей стороне
- 🛡️ **DNSSEC** — криптографическая проверка подписи каждого ответа, подмена данных обнаруживается и отклоняется
- 🚫 **Блокировка рекламы и малвари** — AdGuard Home с шестью независимыми списками блокировки
- 🔥 **Firewall по умолчанию DROP** — открыто только то, что вы явно разрешили
- 🩹 **Самовосстановление** — watchdog каждые 2 минуты чинит Unbound, AdGuard Home и firewall, если что-то упало или было сброшено
- ⚙️ **Один скрипт на всё** — установка, настройка, firewall, fail2ban, hardening, TLS, диагностика и удаление — из одного файла

---

## 🔗 Как это работает

```
Клиент
  └─→  AdGuard Home :53   (фильтрация рекламы/малвари, логи, allowed_clients)
         └─→  Unbound :5353  (DNSSEC-валидация, чистая рекурсия, без форвардинга)
                └─→  Корневые DNS-серверы (root.hints от IANA)
```

Никаких `8.8.8.8`, `1.1.1.1` или иных публичных резолверов в цепочке. Если Unbound недоступен — AdGuard Home возвращает `SERVFAIL`, а не тихо утекает запрос наружу (`fallback_dns` намеренно пуст).

---

## ✨ Возможности

### 🔐 DNSSEC

- Полная валидация цепочки доверия от корневой зоны (`harden-dnssec-stripped`, `harden-algo-downgrade`)
- `root.key` генерируется автоматически через `unbound-anchor`
- `root.hints` обновляется ежемесячно через cron (1-го числа)
- DNSSEC проверяется **дважды**: в Unbound (основная валидация) и повторно в AdGuard Home (`enable_dnssec: true`) как независимый второй слой

### 🚫 Блокировка рекламы и малвари

| Список                             | Назначение                                  |
| ----------------------------------- | -------------------------------------------- |
| AdGuard DNS filter                  | Реклама, трекеры                             |
| AdAway Default Blocklist            | Мобильная реклама                            |
| OISD Big                            | Расширенная блокировка (агрегированный лист) |
| HaGeZi Pro                          | Реклама, трекеры, телеметрия                 |
| HaGeZi Threat Intelligence Feeds    | Фишинг, малварь, C2-домены                   |
| Steven Black                        | Классический hosts-агрегатор                 |

### 🔥 Firewall (iptables) — модель «белый список = полный доступ»

- **`INPUT DROP` по умолчанию** — всё, что явно не разрешено, отбрасывается
- **Белый список IP получает полный доступ ко ВСЕМ портам и протоколам** одним правилом — это не «доступ только к DNS», а доверенный хост целиком
- Если белый список пуст — сервисные порты (DNS/DoT/DoH/DoQ) открываются всем, но включить этот режим можно только осознанно: скрипт требует ввести `ОТКРЫТЬ ВСЕМ` заглавными буквами, случайный Enter не сработает
- Панель AdGuard Home (`:3000`) **никогда** не входит в публично открываемые порты — доступ к ней только с доверенных IP или через SSH-туннель
- Анти-спуфинг и анти-скан на уровне пакетов: сброс `INVALID`-пакетов, блокировка NULL/XMAS/SYN-FIN сканов
- Rate-limit DNS: не более 70 новых запросов/сек с одного IP отдельно по UDP/53 и TCP/53
- Защита от SYN-флуда на прочих сервисных портах через `hashlimit` (200 соединений/сек)
- **IPv6 полностью заблокирован на вход** — весь стек сознательно IPv4-only, чтобы белый список нельзя было обойти через IPv6, если он включён на сервере
- Канонический набор правил сохраняется в `/etc/dns_setup/iptables.rules` и восстанавливается отдельным systemd-сервисом при загрузке — независимо от того, какой network-стек использует дистрибутив
- **Аварийный откат**: сразу после применения правил через `at` планируется сброс iptables в `ACCEPT` через 10 минут — если ошибка в белом списке отрежет вам SSH, доступ вернётся сам собой

### 🚓 fail2ban — защита SSH от перебора

- Jail `sshd` на настроенном порту, бан после 5 неудачных попыток
- Прогрессивный бан: 1ч → 4ч → 24ч (`bantime.increment`)
- IP из белого списка исключены из бана (`ignoreip`) — не заблокируете себя опечаткой в пароле

### 🧱 Сетевой hardening (sysctl)

- `rp_filter=1` (strict reverse path) — защита от IP-спуфинга на уровне маршрутизации ядра, а не только ACL iptables
- `tcp_syncookies=1`, отключены `accept_source_route`/`accept_redirects`/`send_redirects` для IPv4 и IPv6
- `log_martians=1` — подозрительные пакеты попадают в лог

### 🩹 Watchdog самовосстановления

Systemd-таймер каждые 2 минуты проверяет и лечит:

1. **Unbound** — не отвечает на `127.0.0.1:5353` → `systemctl restart unbound`
2. **AdGuard Home** — не отвечает на `127.0.0.1:53` → `systemctl restart AdGuardHome`
3. **Firewall** — если политика `INPUT` перестала быть `DROP` (кто-то поднял `ufw`/`firewalld` или выполнил `iptables -F`) → правила восстанавливаются из канонического набора, `fail2ban` перезапускается (иначе он ссылается на удалённые цепочки)

Плюс `Restart=always` в systemd-юнитах Unbound и AdGuard Home — падение процесса лечится немедленно, watchdog добавляет проверку самого DNS-ответа поверх этого.

### 🔒 TLS — Let's Encrypt

- Опциональный сертификат для DoT (`:853`), DoH (`:443`, `/dns-query`), DoQ (`:784`) и HTTPS-панели
- Получение через `certbot --standalone`, порт 80 открывается только на время выпуска/обновления сертификата
- Автообновление через cron ежемесячно, порт 80 открывается и закрывается автоматически вокруг `certbot renew`
- При наличии сертификата панель автоматически становится HTTPS-only (`force_https: true`)
- Обычный порт 53 (plain DNS) остаётся нешифрованным даже при включённом TLS — это локальный трафик до вашего резолвера; для end-to-end шифрования настройте клиентов на 853/443/784

### 🖥️ Меню управления существующей установкой

При повторном запуске на уже настроенном сервере вместо мастера открывается меню:

```
1) Добавить IP/CIDR в белый список
2) Удалить IP/CIDR из белого списка
3) Добавить публичный порт
4) Удалить публичный порт
5) Полная переустановка (обычный мастер)
6) Выход
7) Логи и диагностика (проверить всё разом)
```

Изменения сразу применяются к iptables и синхронизируются в `allowed_clients` AdGuard Home. При каждом входе в меню конфиг AGH дополнительно самовосстанавливается (исправляются перепутанные пути TLS-сертификата), а сам сервис перезапускается только если конфиг реально изменился — лишних рестартов нет.

### 🔍 Встроенная диагностика («логи и диагностика одной кнопкой»)

Только читает состояние системы, ничего не перезапускает и не меняет. Проверяет по порядку установки:

- конфигурацию (`config.conf`), SSH и его override
- статус служб `unbound`, `AdGuardHome`, `fail2ban`, таймера watchdog, `dns-setup-firewall.service`, `atd`
- прослушиваемые порты (53/853/784/443/3000/SSH) по отдельности
- ответы Unbound и AdGuard Home, флаг `AD` DNSSEC
- валидность `AdGuardHome.yaml`, срок действия TLS-сертификата
- политику и содержимое iptables/ip6tables, наличие конфликтующих `ufw`/`firewalld`, статус аварийного отката `at`
- sysctl-параметры hardening, статус jail `fail2ban`
- cron-задачи обновления `root.hints` и `certbot renew`
- `logrotate`, содержимое и защиту `/etc/resolv.conf`, наличие `root.hints`/`root.key`
- последние ошибки в journald и файловых логах Unbound/AdGuard Home/watchdog

---

## 📋 Требования

| Параметр        | Значение                                        |
| --------------- | ------------------------------------------------ |
| **ОС**          | Ubuntu/Debian (apt) · Fedora/RHEL (dnf) · Arch (pacman) |
| **Права**       | root                                              |
| **Bash**        | ≥ 4.0                                             |
| **Архитектура** | amd64 · arm64 · armv7 · armv6                     |
| **Сеть**        | Публичный IP (VPS / выделенный сервер)            |

**Устанавливается автоматически:** `unbound` `unbound-anchor` `unbound-host` · `iptables` `iptables-persistent`/`iptables-services` `netfilter-persistent` · `at` · `fail2ban` · `certbot` · `curl` `tar` · `python3` `python3-yaml` `python3-bcrypt` · `logrotate` · `dig`/`bind-utils`. AdGuard Home скачивается отдельно с `static.adguard.com` под определённую архитектуру.

---

## ⚡ Быстрый старт

### Установка

```bash
curl -fsSL https://raw.githubusercontent.com/avar-soft/adguardhome-unbound/main/dns_setup.sh \
  -o dns_setup.sh && chmod +x dns_setup.sh && sudo bash dns_setup.sh
```

Скрипт задаёт вопросы в 5 шагов и делает всё остальное сам.

### Dry-run (без записи на диск)

```bash
sudo bash dns_setup.sh --dry-run
```

Показывает все шаги, которые были бы выполнены, без реальных изменений.

### Удаление

```bash
sudo bash dns_setup.sh --uninstall
```

### Повторный запуск на уже настроенном сервере

```bash
sudo bash dns_setup.sh
```

Откроет меню управления (добавление/удаление IP и портов, диагностика, полная переустановка) вместо мастера.

---

## 📖 Мастер установки

```
════════════════════════════════════════════════
  1/5 — SSH
════════════════════════════════════════════════
  SSH-порт [22]:
  Ограничить SSH только доверенными IP? (y/n):

════════════════════════════════════════════════
  2/5 — AdGuard Home: учётные данные
════════════════════════════════════════════════
  Логин [admin]:
  Пароль: (ввод скрыт)
  Пароль ещё раз:

════════════════════════════════════════════════
  3/5 — Разрешённые IP-адреса
════════════════════════════════════════════════
  Ограничить доступ по IP? (y/n):
  IP / CIDR (или Enter для завершения):
  // пустой список требует явного подтверждения: ОТКРЫТЬ ВСЕМ

════════════════════════════════════════════════
  4/5 — Разрешённые порты
════════════════════════════════════════════════
  Порты по умолчанию: 53 853 80 443 784
  Добавить свои порты? (y/n):

════════════════════════════════════════════════
  5/5 — TLS-сертификат (необязательно)
════════════════════════════════════════════════
  Настроить TLS? (y/n):
  Домен (например dns.example.com):
  E-mail для Let's Encrypt:
```

Скрипт автоматически определяет IP текущей SSH-сессии и предлагает добавить его в белый список, чтобы вы не потеряли доступ.

---

## ✅ Проверка работы

### 1. Статус служб

```bash
systemctl status unbound AdGuardHome dns-setup-healthcheck.timer fail2ban
```

Все должны быть `active (running)`/`active (waiting)`.

### 2. Unbound отвечает напрямую

```bash
dig @127.0.0.1 -p 5353 google.com +short
```

### 3. Полная цепочка AGH → Unbound

```bash
dig @127.0.0.1 google.com +short
```

### 4. DNSSEC работает

```bash
dig +dnssec +noall +comments sigok.verteiltesysteme.net @127.0.0.1 | grep flags
```

Наличие флага `ad` (Authenticated Data) подтверждает валидацию DNSSEC.

### 5. Блокировка рекламы работает

```bash
dig +short doubleclick.net @127.0.0.1
```

### 6. resolv.conf защищён

```bash
cat /etc/resolv.conf        # nameserver 127.0.0.1
lsattr /etc/resolv.conf     # ----i--- = immutable
```

### 7. Порты слушаются

```bash
ss -tulnp | grep -E ':53 |:5353 |:3000 |:853 |:784 '
```

### 8. Firewall в ожидаемом состоянии

```bash
iptables -S INPUT | head -1     # -P INPUT DROP
iptables -S INPUT | grep DNSQF  # rate-limit DNS активен
```

### 9. Watchdog действительно работает

```bash
journalctl -t dns_setup_healthcheck -f
```

---

## 🔧 Полезные команды

```bash
# Статус
systemctl status unbound AdGuardHome dns-setup-healthcheck.timer fail2ban

# Логи в реальном времени
journalctl -u unbound -f
journalctl -u AdGuardHome -f
journalctl -t dns_setup_healthcheck -f

# Проверить конфиг Unbound
unbound-checkconf

# Обновить root.hints вручную
curl -fsSL https://www.internic.net/domain/named.cache \
  -o /var/lib/unbound/root.hints && systemctl restart unbound

# Забаненные по SSH
fail2ban-client status sshd

# Аварийный откат iptables ещё в очереди?
atq

# Отменить аварийный откат (если доступ уже подтверждён рабочим)
atrm <job_id>

# Диагностика одной командой
sudo bash dns_setup.sh   # → пункт 7 меню
```

---

## 📁 Структура файлов

```
/etc/unbound/unbound.conf                       # Конфигурация Unbound
/var/lib/unbound/root.key                       # DNSSEC trust anchor
/var/lib/unbound/root.hints                     # Корневые серверы IANA

/opt/AdGuardHome/AdGuardHome                    # Бинарник
/opt/AdGuardHome/AdGuardHome.yaml                # Конфигурация AGH

/etc/systemd/system/unbound.service.d/override.conf
/etc/systemd/system/AdGuardHome.service.d/override.conf
/etc/systemd/system/dns-setup-healthcheck.service   # Watchdog (oneshot)
/etc/systemd/system/dns-setup-healthcheck.timer     # Каждые 2 минуты
/etc/systemd/system/dns-setup-firewall.service      # Restore iptables при загрузке

/usr/local/bin/dns_setup_healthcheck.sh          # Логика watchdog
/usr/local/bin/dns_setup_restore_fw.sh           # Восстановление канонического firewall

/etc/dns_setup/config.conf                       # Параметры установки (белый список, порты и т.д.)
/etc/dns_setup/iptables.rules                    # Канонический набор правил IPv4
/etc/dns_setup/ip6tables.rules                   # Канонический набор правил IPv6
/etc/dns_setup/failsafe_job                      # ID job'а аварийного отката (at)

/etc/ssh/sshd_config.d/99-dns_setup.conf          # Override SSH-порта
/etc/fail2ban/jail.d/99-dns_setup.conf            # Jail sshd
/etc/sysctl.d/99-dns_setup.conf                   # rp_filter/syncookies/anti-spoof

/var/log/unbound/unbound.log                     # Логи Unbound (logrotate 14 дней)
/var/log/AdGuardHome/AdGuardHome.log             # Логи AGH (logrotate 14 дней)
/etc/logrotate.d/unbound
/etc/logrotate.d/adguardhome

/etc/resolv.conf                                 # → 127.0.0.1 (chattr +i)
```

---

## 🔐 Безопасность

- **`set -euo pipefail` + `trap ... ERR`** — при любой ошибке скрипт останавливается и печатает номер строки и упавшую команду вместо тихого обрыва
- **Валидация IP/CIDR и портов с защитой от октальной интерпретации** (`10#$o`) — значения вроде `008` не валят скрипт под `set -e`
- **Пароль AdGuard Home только в bcrypt**, вычисляется через `htpasswd`/`python3-bcrypt`, передаётся исключительно через переменные окружения/stdin — никогда не попадает в `ps aux` или в аргументы командной строки
- **`chattr +i /etc/resolv.conf`** — защита от перезаписи `systemd-resolved`/`NetworkManager`
- **Explicit-confirm gate** на пустой белый список IP — публичный доступ ко всему серверу невозможен по опечатке в y/n
- **IPv6 полностью заблокирован по умолчанию**, чтобы белый список нельзя было обойти по протоколу, который никто не настраивал
- **Приватные диапазоны (10.0.0.0/8 и т.п.) не получают неявного доступа** — только явно добавленные в белый список сети
- **Двойная DNSSEC-валидация** — в Unbound и повторно в AdGuard Home
- **Канонический firewall + watchdog** — правила переживают перезагрузку и восстанавливаются автоматически при сбросе

---

## 🧠 Модель прав доступа

> Белый список IP — это не «доступ к DNS», это доверенный хост с полным доступом ко всему серверу.

| Ситуация                                    | Результат                                                        |
| -------------------------------------------- | ------------------------------------------------------------------ |
| IP в белом списке                            | Полный доступ ко всем портам и протоколам                        |
| IP не в белом списке, список непуст          | Полный `DROP`, включая DNS и панель                               |
| Белый список пуст (осознанно подтверждено)   | Сервисные порты (DNS/DoT/DoH/DoQ) открыты всем; панель `:3000` — никому, только через SSH-туннель |
| SSH при `SSH_RESTRICTED=1`, но пустом списке | Скрипт не даст себя запереть — явно предложит добавить текущий IP |

Панель AdGuard Home (`:3000`) в любом сценарии не открывается публично — доступ только с доверенных IP или через:

```bash
ssh -L 3000:127.0.0.1:3000 -p <SSH_PORT> user@<IP_сервера>
# → http://127.0.0.1:3000
```

---

## 🗑️ Удаление

```bash
sudo bash dns_setup.sh --uninstall
```

Удаляет: AdGuard Home, Unbound, jail fail2ban, watchdog-таймер, firewall-restore сервис, override SSH-порта, sysctl hardening, аварийный `at`-job, все systemd-юниты и файлы конфигурации.
Восстанавливает: `iptables`/`ip6tables` в `ACCEPT`, `systemd-resolved`, `/etc/resolv.conf`.

---

## 📝 Основные технические решения (по комментариям в скрипте)

- Диагностика (пункт меню 7) **только читает** состояние — ни одна команда там не перезапускает службы и не меняет firewall, чтобы сам факт диагностики не создавал новых гонок условий
- Рестарт AdGuard Home при входе в меню — **условный**, по сравнению md5 конфига до/после, а не безусловный при каждом заходе
- Лог AGH в схеме ≥ v0.107.34 читается только из вложенной секции `log:` — плоские ключи `log_file`/`verbose` тихо игнорируются
- Файл `/var/log/unbound/unbound.log` создаётся заранее от root — профиль AppArmor `usr.sbin.unbound` разрешает запись в уже существующий inode, но не создание нового файла в каталоге
- Скачивание AdGuard Home — до 5 попыток с проверкой HTTP-кода и размера файла, а не одинарный `curl` без обработки сбоя
- `crontab` для `certbot renew` использует полные пути (`/usr/sbin/iptables`, `/usr/bin/certbot`) и `trap ... EXIT`, чтобы порт 80 гарантированно закрылся даже при падении `certbot`

---

## 🤝 Участие в разработке

Pull requests приветствуются. Для значительных изменений — открой Issue.

**Правила:**

- Bash через `set -euo pipefail` + `trap ERR`
- Любой пользовательский ввод — только с валидацией (IP/CIDR/порты через `10#` decimal-force)
- Изменения в firewall — только через пересборку из канонического набора, не точечными `-A`/`-D` в обход `menu_apply_firewall`

---

## 📄 Лицензия

MIT © [avar-soft](https://github.com/avar-soft)

---
<div align="center">
  
**Сделано с ❤️ для тех, кто ценит автоматизацию и чистые конфиги**

⭐ Если проект полезен — поставь звезду!

</div>

