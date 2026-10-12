# Деплой TiredVPN на Fly.io

Файлы для Fly: `fly.toml`, `fly.Dockerfile`, `entrypoint.sh`, `.dockerignore`.
Исходный код TiredVPN не менялся.

## Что получится

- Сервер на TCP 443 (TLS), TUN-режим включён: подходит для клиента с `-tun` и для Android-приложения.
- Секрет и TLS-сертификат создаются при первом старте и хранятся на volume.
- QUIC/UDP выключен (`-no-quic`): у Fly для UDP нужен особый адрес привязки.

## Шаги

Нужен установленный [flyctl](https://fly.io/docs/flyctl/install/) и вход: `fly auth login`.

```bash
# 1. Придумай уникальное имя и впиши его в fly.toml (строка app = "...")
fly apps create my-tiredvpn

# 2. Volume для секрета и сертификата (регион как в fly.toml)
fly volumes create tiredvpn_data --size 1 --region fra

# 3. Деплой
fly deploy

# 4. Выделенный IPv4 (нужен для TCP без обработчиков Fly, платный)
fly ips allocate-v4

# 5. Секрет и команда для клиента печатаются в логах
fly logs
```

Клиент:

```bash
sudo tiredvpn client -server my-tiredvpn.fly.dev:443 -secret <секрет из логов> -tun -tun-routes 0.0.0.0/0
```

Только прокси (без TUN): `-listen 127.0.0.1:1080` вместо `-tun ...`.

## Секрет

- Если `TIREDVPN_SECRET` не задан, он генерируется и печатается в `fly logs`.
- Пока volume подключён, он не меняется.
- Свой секрет: `fly secrets set TIREDVPN_SECRET=...`, автогенерация отключится.
- Секрет видят все, у кого есть доступ к логам приложения.

## Переменные (`[env]` в fly.toml)

| Переменная | Назначение |
|---|---|
| `TIREDVPN_IP_POOL` | Пул адресов TUN-клиентов (по умолчанию `10.8.0.0/24`). Пустая строка = только прокси |
| `TIREDVPN_TUN_IP` | Адрес сервера в TUN (по умолчанию `10.8.0.1`) |
| `PORT` | Порт внутри VM (по умолчанию 443) |
| `TLS_CERT_B64`, `TLS_KEY_B64` | Свой сертификат и ключ (base64 от PEM), лучше через `fly secrets` |
| `TLS_CN` | CN самоподписанного сертификата (по умолчанию `<app>.fly.dev`) |
| `TIREDVPN_DEBUG=1` | Подробные логи |
| `TIREDVPN_EXTRA_ARGS` | Дополнительные флаги сервера |

## Если TUN не заработал

Сервер при старте сам включает forwarding и NAT через netlink/nftables; при ошибке он
пишет предупреждение и продолжает как прокси. Включи `TIREDVPN_DEBUG=1` и смотри `fly logs`:
ищи сообщения про `/dev/net/tun` и NAT. Это не проверялось на реальной машине Fly.
