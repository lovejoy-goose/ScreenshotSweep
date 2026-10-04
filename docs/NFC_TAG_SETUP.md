# Постоянная NFC-метка через HTTPS-мост (D-054)

Для наклеек ISO 14443-4 / Type A / IsoDep, которые iPhone читает (например, в NFC Tools), но автоматизация «Команд» по UID не запускает. Работает с уже установленным Katana Connector v0.3 — новая сборка и Universal Links не нужны.

```
касание метки → iOS читает NDEF URI https://<katana-host>/c/nfc/<action_id>
  → баннер «Открыть в Safari» → страница-мост Katana (ничего не выполняет)
  → katana-connector://open?v=3&feature=nfc_action&action_id=<action_id>
  → Connector: preview → «Выполнить» → nfc.action.completed → очередь → Katana
```

На метке — только HTTPS-адрес с непрозрачным `action_id`. Ни UID, ни названия действия, ни токенов. Katana не получает UID метки, Connector — тоже.

## 1. Создать действие в Katana

1. Katana → Devices → iPhone → «NFC-действие» → название, например **«Коту воду заменили»** → создать.
2. Katana показывает ссылку/QR на черновик (`katana-connector://open?v=3&feature=action&draft_id=…`) и — после регистрации на iPhone — HTTPS-адрес и QR для метки: `https://<katana-host>/c/nfc/<action_id>`.

## 2. Зарегистрировать действие на iPhone

1. Открыть ссылку/QR черновика на iPhone → Connector «Действие из Katana» → «Загрузить действие».
2. Проверить название «Коту воду заменили» → «Выполнить» → подтвердить.
3. Connector → «NFC-действия»: действие появилось, «Активно». В Katana — `action_draft.accepted`.

## 3. Записать метку в NFC Tools

1. Скопировать HTTPS-адрес из Katana Devices (или отсканировать QR камерой и скопировать адрес из баннера).
2. NFC Tools → **Write** → **Add a record** → **URL / URI** → выбрать префикс `https://` и вставить остаток адреса (или вставить адрес целиком без префикса) → OK.
3. Проверить: одна запись, ровно `https://<katana-host>/c/nfc/<action_id>`, без других записей.
4. **Write / 1 record** → поднести метку к верхней части iPhone → «Write complete».
5. **Не включать** «Lock tag / Make read-only» и пароли: метка остаётся перезаписываемой.
6. Проверка: NFC Tools → Read → запись `URI: https://…/c/nfc/<action_id>`.

Если NFC Tools пишет, что на метке нет NDEF-области, — метку нужно отформатировать под NDEF в NFC Tools (Other → Format memory). Если формат не поддерживается, эта наклейка не подходит для фонового открытия ссылки iPhone.

## 4. Проверка (первый E2E — «Коту воду заменили»)

1. iPhone разблокирован, экран включён (фоновое чтение NFC — iPhone XS и новее; не срабатывает, пока открыты Wallet или камера). Для открытия страницы-моста нужна сеть.
2. Коснуться метки → баннер → открыть → страница «Katana Connector» → «Открыть в Katana Connector?» → «Открыть».
3. Connector показывает preview «Коту воду заменили». Ничего ещё не выполнено (в Katana нет события).
4. «Выполнить» → в Katana одно `nfc.action.completed`: `source: shortcut`, `result: confirmed`, `interrupted: false`, без названия, UID и NDEF.
5. Коснуться метки дважды подряд → один и тот же запуск, одно событие.
6. Offline: коснуться метки при наличии сети → preview → включить авиарежим → «Выполнить» → «ждёт отправки» → закрыть и открыть Connector → выключить авиарежим → «Синхронизировать» → в Katana ровно одно событие.
7. Выключить действие в Connector → касание → «выключено», события нет.

## Что проверяет сервер (контракт, API.md маршрут 10)

- `GET /c/nfc/{uuid}` — публично, без cookies, одинаковая страница для любого корректного UUID, `404` для остального.
- `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex`, CSP только с хешем встроенного скрипта (`docs/nfc-bridge-reference.html`).
- GET ничего не выполняет и не пишет событий; `action_id` не попадает в аналитику; в логах путь `/c/nfc/:id`.
