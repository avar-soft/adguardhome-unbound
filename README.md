<div align="center">

# 🛡️ DNS Server: Unbound + AdGuard Home

[![Bash](https://img.shields.io/badge/Bash-4.0+-green?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/Лицензия-MIT-orange?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/Платформа-Ubuntu%20%2F%20Debian%20%2F%20Arch-purple?style=for-the-badge&logo=linux)](https://ubuntu.com)
[![DNSSEC](https://img.shields.io/badge/DNSSEC-включён-blue?style=for-the-badge)](https://www.icann.org/resources/pages/dnssec-what-is-it-why-important-2019-03-05-en)

**Приватный DNS-сервер с блокировкой рекламы, DNSSEC и чистой рекурсией — один скрипт, никакой магии.**

*AdGuard Home (фильтрация) · Unbound (рекурсия от корней) · DNSSEC · iptables · Let's Encrypt*

---

</div>

## 🤔 Зачем это нужно?

Обычный DNS-резолвер отправляет все запросы на 8.8.8.8 или 1.1.1.1 — провайдер или хостер видит каждый сайт, который ты посещаешь. Этот стек работает иначе:

- 🔒 **Рекурсия от корней** — Unbound сам обходит DNS-дерево, запросы не уходят к третьим сторонам
- 🛡️ **DNSSEC** — криптографическая проверка ответов, подмена невозможна
- 🚫 **Блокировка рекламы** — AdGuard Home с 163 000+ правил блокировки
- 🔗 **Цепочка в одном скрипте** — установка, настройка, firewall, TLS — всё автоматически

---

## ✨ Возможности

### 🔗 Архитектура цепочки

```
Клиент
  └─→  AdGuard Home :53   (фильтрация рекламы, блокировка, логи)
         └─→  Unbound :5353  (DNSSEC, рекурсия без форвардинга)
                └─→  Корневые DNS-серверы (IANA root hints)
```

Никаких `8.8.8.8` и `1.1.1.1` в цепочке — только твой сервер и корневые серверы.

---

### 🔐 DNSSEC

- Полная валидация цепочки доверия от корневой зоны
- Автоматически генерируется `root.key` через `unbound-anchor`
- `root.hints` обновляется раз в месяц через cron
- Домены со сломанной подписью получают `SERVFAIL` — никаких подменных ответов

---

### 🚫 Блокировка рекламы и трекеров

| Список | Правил | Назначение |
|--------|--------|------------|
| AdGuard DNS filter | 163 000+ | Реклама, трекеры, вредоносное ПО |
| AdAway Default Blocklist | 6 500+ | Мобильная реклама |

Фильтры обновляются автоматически при старте AdGuard Home.

---

### 🔥 Firewall (iptables)

- `INPUT DROP` по умолчанию — закрыто всё, что не разрешено явно
- Белый список IP для доступа к панели и DNS-портам (опционально)
- SSH — отдельный порт, можно ограничить по IP
- Защита от DNS-флуда: не более 70 запросов/сек с одного IP
- Правила сохраняются через `netfilter-persistent` и выживают после перезагрузки

---

### 🌐 Поддержка протоколов

| Порт | Протокол | Описание |
|------|----------|----------|
| 53 | DNS (UDP/TCP) | Стандартный DNS |
| 853 | DoT | DNS-over-TLS |
| 443 | DoH | DNS-over-HTTPS |
| 784 | DoQ | DNS-over-QUIC |
| 5443 | DoH (alt) | Альтернативный порт |
| 3000 | HTTPS | Панель AdGuard Home |

---

### 🔒 TLS — Let's Encrypt

- Опциональный TLS-сертификат для DoT/DoH и HTTPS-панели
- Автоматическое получение через `certbot --standalone`
- Авто-обновление через cron раз в месяц
- Можно пропустить — сервер работает и без TLS

---

### 💾 Сохранение и восстановление

- Параметры установки сохраняются в `/etc/dns_setup/config.conf`
- Полное удаление: `sudo bash dns_setup.sh --uninstall`
- Восстанавливает `systemd-resolved` и `resolv.conf` при удалении

---

## 📋 Требования

| Параметр | Значение |
|----------|----------|
| **ОС** | Ubuntu 22.04+ · Debian 11+ · Fedora 38+ · Arch |
| **Права** | root |
| **Bash** | ≥ 4.0 |
| **Архитектура** | amd64 · arm64 · armv7 · armv6 |
| **RAM** | ≥ 256 MB |
| **Диск** | ≥ 512 MB свободного места |
| **Сеть** | Публичный IP (VPS / выделенный сервер) |

**Зависимости устанавливаются автоматически:**
`unbound` · `unbound-anchor` · `adguardhome` · `iptables` · `certbot` · `curl` · `python3` · `logrotate`

---

## ⚡ Быстрый старт

### Установка за 1 команду

```bash
curl -fsSL https://raw.githubusercontent.com/avar-soft/adguardhome-unbound/main/dns_setup.sh \
  -o dns_setup.sh && chmod +x dns_setup.sh && sudo bash dns_setup.sh
```

При первом запуске скрипт задаёт несколько вопросов и делает всё остальное сам.

**Весь процесс занимает ~3 минуты.**

### Dry-run (без записи на диск)

```bash
sudo bash dns_setup.sh --dry-run
```

Покажет все шаги без реальных изменений — удобно для проверки перед запуском.

### Удаление

```bash
sudo bash dns_setup.sh --uninstall
```

---

## 📖 Мастер установки

Скрипт задаёт вопросы в логичном порядке:

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
  Пароль:
  Пароль ещё раз:

════════════════════════════════════════════════
  3/5 — Разрешённые IP-адреса
════════════════════════════════════════════════
  Ограничить доступ по IP? (y/n):
  IP / CIDR (или Enter для завершения):

════════════════════════════════════════════════
  4/5 — Разрешённые порты
════════════════════════════════════════════════
  Порты по умолчанию: 53 853 80 443 784 5443 3000
  Добавить свои порты? (y/n):

════════════════════════════════════════════════
  5/5 — TLS (необязательно)
════════════════════════════════════════════════
  Настроить TLS? (y/n):
  Домен (например dns.example.com):
  E-mail для Let's Encrypt:
```

---

## ✅ Проверка работы

После установки убедись, что всё работает корректно:

### 1. Статус сервисов

```bash
systemctl status unbound AdGuardHome
```

Оба должны быть `active (running)`.

### 2. Unbound отвечает на своём порту

```bash
dig +short google.com @127.0.0.1 -p 5353
```

Должен вернуть IP-адрес — рекурсия от корней работает.

### 3. Полная цепочка AGH → Unbound

```bash
dig +short google.com @127.0.0.1
```

Тот же результат — AdGuard Home передаёт запросы в Unbound.

### 4. DNSSEC работает

```bash
# Валидная подпись — должен вернуть IP:
dig +short sigok.verteiltesysteme.net @127.0.0.1

# Сломанная подпись — должен вернуть SERVFAIL:
dig sigfail.verteiltesysteme.net @127.0.0.1 | grep "status:"
```

Если `sigfail` возвращает `SERVFAIL` — DNSSEC валидирует и отклоняет подделанные ответы. ✅

### 5. Блокировка рекламы работает

```bash
dig +short doubleclick.net @127.0.0.1
```

Должен вернуть `0.0.0.0` — домен заблокирован AdGuard Home.

### 6. resolv.conf защищён

```bash
cat /etc/resolv.conf
# nameserver 127.0.0.1

lsattr /etc/resolv.conf
# ----i--- означает immutable — файл защищён от перезаписи
```

### 7. Порты слушаются

```bash
ss -tulnp | grep -E ':53 |:5353 |:3000 |:853 '
```

Ожидаемый результат:

```
udp  UNCONN  127.0.0.1:5353   unbound       ← Unbound (рекурсия)
tcp  LISTEN  127.0.0.1:5353   unbound
udp  UNCONN  *:53             AdGuardHome   ← AGH (фильтрация)
tcp  LISTEN  *:53             AdGuardHome
tcp  LISTEN  *:3000           AdGuardHome   ← Панель управления
```

### 8. Рекурсия от корней (не форвардинг)

```bash
dig +short whoami.akamai.net @127.0.0.1 -p 5353
```

Вернёт IP твоего сервера — Unbound сам рекурсивно разрешает имена без промежуточных серверов.

### 9. Панель AdGuard Home

Открой в браузере:

```
http://<IP_сервера>:3000
```

В разделе **Dashboard** должны появляться DNS-запросы в реальном времени. В разделе **DNS settings** — upstream `127.0.0.1:5353`.

---

## 🔧 Полезные команды

```bash
# Статус сервисов
systemctl status unbound AdGuardHome

# Логи в реальном времени
journalctl -u unbound -f
journalctl -u AdGuardHome -f

# Проверить конфиг Unbound
unbound-checkconf

# Перезапуск
systemctl restart unbound AdGuardHome

# Обновить root.hints вручную
curl -fsSL https://www.internic.net/domain/named.cache \
  -o /var/lib/unbound/root.hints && systemctl restart unbound

# Посмотреть правила iptables
iptables -L INPUT -n --line-numbers
```

---

## 📁 Структура файлов

```
/etc/unbound/
└── unbound.conf                    # Конфигурация Unbound

/var/lib/unbound/
├── root.key                        # DNSSEC trust anchor
└── root.hints                      # Адреса корневых серверов IANA

/opt/AdGuardHome/
├── AdGuardHome                     # Бинарник
├── AdGuardHome.yaml                # Конфигурация
└── data/
    └── filters/                    # Кешированные списки блокировки

/etc/systemd/system/
├── unbound.service.d/override.conf
└── AdGuardHome.service.d/override.conf

/var/log/unbound/unbound.log        # Логи Unbound
/var/log/AdGuardHome/               # Логи AdGuard Home
/etc/logrotate.d/unbound            # Ротация логов Unbound
/etc/logrotate.d/adguardhome        # Ротация логов AGH
/etc/dns_setup/config.conf          # Параметры установки
/etc/resolv.conf                    # → 127.0.0.1 (защищён chattr +i)
```

---

## 🔐 Безопасность

- **`set -euo pipefail`** — остановка при ошибке или необъявленной переменной
- **Валидация IP/CIDR** — проверка каждого адреса перед добавлением в firewall
- **Bcrypt для паролей** — пароль AGH хешируется через `htpasswd -B` или `python3+bcrypt`
- **`chattr +i /etc/resolv.conf`** — защита от перезаписи системными сервисами
- **DNSSEC** — криптографическая верификация всех ответов
- **Пустой белый список** — нет захардкоженных IP, только то что ввёл пользователь
- **iptables INPUT DROP** — закрыто всё лишнее по умолчанию

---

## 🗑️ Удаление

```bash
sudo bash dns_setup.sh --uninstall
```

Удаляет: AdGuard Home, Unbound, правила iptables, systemd-сервисы, конфиги.  
Восстанавливает: `systemd-resolved`, `resolv.conf`, политики iptables `ACCEPT`.

---

## 📝 Changelog

**v1.0.0 — текущая версия**

- ✅ Wizard с логичным порядком: SSH → AGH → IP → Порты → TLS
- ✅ Пароль AGH с bcrypt-хешированием
- ✅ Белый список IP начинается пустым — никаких захардкоженных адресов
- ✅ `module-config: "validator iterator"` — убраны предупреждения subnetcache
- ✅ `Environment=DAEMON_OPTS=` — убрано предупреждение systemd
- ✅ `--dry-run` и `--uninstall` режимы
- ✅ Поддержка amd64 / arm64 / armv7 / armv6
- ✅ Авто-обновление root.hints через cron

---

## 🤝 Участие в разработке

Pull requests приветствуются. Для значительных изменений — открой Issue.

**Правила:**
- Bash через `set -euo pipefail`
- Пользовательский ввод — только с валидацией
- Временные файлы — через `mktemp` с `trap` на очистку

---

## 📄 Лицензия

MIT © [avar-soft](https://github.com/avar-soft)

---
<div align="center">

**Сделано с ❤️ для тех, кто ценит приватность**

⭐ Если проект полезен — поставь звезду!

</div>
