# Katana API — контракт Connector

> Статус: v0.1 проверен end-to-end (release v0.1.0). v0.2 (маршрут 7, ссылки v2, пять событий) развёрнут в Katana и проверен; открыты post-merge проверки баннера напоминания и `reminder.local.cancelled`. v0.3 (маршруты 8–9, ссылки v3, семь событий, новые capability ID) — клиентский контракт, который должна реализовать Katana. Все адреса ниже — плейсхолдеры.

## Общие правила

- Транспорт: только HTTPS. Базовый адрес — `base_url` из pairing QR, сохраняется в Keychain вместе с токеном (D-020).
- Формат: JSON, UTF-8. Время — ISO 8601 в UTC (`2026-10-02T12:34:56Z`).
- Идентификаторы, создаваемые клиентом (`event_id`, `session_id`, `installation_id`), — UUID v4.
- Авторизация после pairing: device token в заголовке (например, `Authorization: Bearer <device_token>`). Токен хранится только в Keychain и никогда не логируется.
- Версия контракта передаётся клиентом (например, поле или заголовок `api_version`) — точный механизм TBD.
- В API **никогда** не передаются: изображения, превью, хэши изображений, `PHAsset.localIdentifier`, имена файлов, даты отдельных снимков, EXIF, геоданные снимков, сырые данные движения (Motion samples, временные ряды), высота/скорость/курс/этаж/сырая точность геолокации, токены и коды.
- Координаты устройства передаются **только** в событиях `location.check_in.created` (D-040) и `geofence.created` (≤ 4 знаков, D-049) — только после предпросмотра и явного подтверждения и только округлёнными. Содержимое захвата (текст, URL, файлы) — только в теле `PUT /captures` после подтверждения (D-050), никогда в событиях.

## Операции

### 1. Pairing start (на стороне PWA)

Инициирует PWA от имени залогиненного пользователя Katana.

- Сервер выдаёт короткоживущий одноразовый `pairing_code` (TTL — минуты).
- PWA показывает QR-код формата v1 (ниже). Connector в этой операции не участвует, только сканирует QR.

#### QR payload v1

```
katana-connector://pair?v=1&base_url=<percent-encoded-url>&code=<one-time-code>
```

| Параметр | Правила |
|---|---|
| scheme / host | строго `katana-connector` и `pair`; путь пустой; без user/port/fragment |
| `v` | строго `1`; другие версии отклоняются |
| `base_url` | обязателен, percent-encoded; `https://host[:port][/path]`; без user/password, query и fragment; хост в punycode (только печатный ASCII) |
| `code` | обязателен; после trim не пустой; до 128 печатных ASCII-символов без пробелов |

- Весь payload — до 2048 печатных ASCII-символов; повторяющиеся параметры запрещены; неизвестные параметры игнорируются.
- QR **не** содержит постоянный device token — только одноразовый код.
- Схема `katana-connector` — только формат QR. Приложение не регистрирует её как URL handler (это KC-007).
- Release-сборка принимает только HTTPS. HTTP допустим только для локальной разработки (localhost, 127.0.0.1, ::1, `*.local`) в отдельной debug-конфигурации, которой пока нет (D-020).

### 2. Pairing complete (Connector → API) — предварительный контракт v1

```
POST {base_url}/api/connector/pairing/complete
Content-Type: application/json
Accept: application/json
```

Запрос:

```json
{
  "pairing_code": "<one-time-code>",
  "device": {
    "display_name": "iPhone",
    "platform": "ios",
    "app_version": "0.1.0",
    "system_version": "18.0"
  }
}
```

- `display_name` вводит пользователь перед подтверждением (по умолчанию `iPhone`, до 40 символов, `UIDevice.name` не используется — D-019).
- Код отправляется один раз, только после того, как пользователь увидел хост и нажал «Подключить». Редиректы не выполняются.

Успешный ответ (`2xx`):

```json
{
  "device_id": "<server-assigned>",
  "device_token": "<secret>",
  "display_name": "iPhone",
  "paired_at": "2026-10-02T12:00:00Z"
}
```

- `device_token` сразу сохраняется в Keychain и больше нигде не появляется (не логируется, не показывается в UI, не публикуется в состоянии).
- `paired_at` — ISO 8601, дробные секунды допустимы.
- Ответ больше 64 KiB, пустые `device_id`/`device_token` или невалидный JSON → `invalidResponse`.

Ожидаемые коды ошибок (клиентская интерпретация):

| HTTP | Ошибка клиента | Смысл |
|---|---|---|
| 410 | `expiredCode` | срок кода истёк |
| 400, 401, 403, 409, 422 | `rejected` | код неизвестен, уже использован или запрос отклонён |
| 408, 429, 5xx, сетевая ошибка, timeout (15 с) | `transport` | сервер недоступен, можно повторить с новым QR |
| 3xx, 404, прочие | `invalidResponse` | по этому адресу нет pairing endpoint |

Тело ошибки клиентом пока не разбирается. Реализовано в Katana и проверено end-to-end 2026-10-02 (сервер хранит только SHA-256-хеш токена).

### 2a. Revoke (локальный, KC-004)

«Отключить на этом iPhone» удаляет credentials из Keychain. Серверный revoke пока не вызывается (см. п. 6).

### Авторизованные запросы (KC-005)

Общие правила для маршрутов 3–5:

- Адрес: `{base_url}` из сохранённого подключения (Keychain), только HTTPS по `PairingSecurityPolicy`; редиректы не выполняются.
- Заголовки: `Authorization: Bearer <device_token>`, `Accept: application/json`; для POST дополнительно `Content-Type: application/json`. Токен никогда не передаётся в query.
- Токен читается из Keychain непосредственно перед каждым запросом. Подключение, помеченное после 401 (`requires_repair`), не используется — запрос не отправляется.
- Timeout запроса 15 с, ответ не больше 64 KiB, даты ISO 8601 (дробные секунды допустимы).

Классификация ответов клиентом:

| HTTP | Ошибка | Поведение Connector |
|---|---|---|
| 2xx | — | успех |
| 401 | `unauthorized` | сеть больше не используется, credentials помечаются `requires_repair`, очередь сохраняется, UI: «Подключите Katana заново» |
| 408, сетевая ошибка, timeout | `transport` | повтор с backoff |
| 429 | `rateLimited` | повтор с backoff |
| 5xx | `serverError` | повтор с backoff |
| прочие 4xx | `rejected` | без повторов до следующего триггера; события не удаляются |
| 3xx, иные коды, битое/слишком большое тело | `invalidResponse` | без повторов до следующего триггера; события не удаляются |

### 3. Capability report

```
POST {base_url}/api/connector/capabilities/report
```

Отправляется автоматически один раз за запуск приложения (при старте или возвращении в foreground), по кнопке «Синхронизировать» и после каждого завершённого probe Capability Lab (если Katana подключена; при ошибке сети результат остаётся на iPhone и уйдёт со следующим отчётом). Отправляются текущие значения `CapabilityRegistry`, включая сохранённые результаты Capability Lab (`camera`, `current_location`, `motion`, `local_notifications`). Никаких изображений, координат, данных движения, текста уведомлений и сырых ошибок. Тело ответа не разбирается; успешный ответ обновляет локальное «последняя синхронизация».

```json
{
  "reported_at": "2026-10-02T12:00:00Z",
  "device": {
    "device_id": "<server-assigned>",
    "display_name": "iPhone",
    "app_version": "0.1.0",
    "system_version": "18.0",
    "connection_state": "connected"
  },
  "capabilities": [
    { "id": "photos", "availability": "available", "authorization": "unknown", "probe_state": "not_run" },
    { "id": "health_kit", "availability": "missing_entitlement", "authorization": "unknown", "probe_state": "not_run" }
  ]
}
```

Каждая capability описывается тремя независимыми измерениями (D-016); wire values совпадают с моделями в `Sources/Core` и закреплены unit-тестами:

| Поле | Значения |
|---|---|
| `id` | `photos`, `camera`, `vision_ocr`, `files`, `current_location`, `background_location`, `motion`, `local_notifications`, `bluetooth`, `local_network`, `contacts`, `calendar`, `reminders`, `face_id`, `microphone`, `speech`, `health_kit`, `core_nfc`; с v0.3 также `core_nfc_write`, `app_group`, `share_extension`, `location_always`, `region_monitoring` (сервер должен принимать неизвестные ему id, не отклоняя отчёт) |
| `availability` | `available`, `planned`, `missing_entitlement`, `unsupported_device` |
| `authorization` | `unknown`, `not_required`, `not_requested`, `granted`, `limited`, `denied`, `restricted` |
| `probe_state` | `not_run`, `passed`, `failed` |
| `checked_at` | время последней проверки, опускается, если нет |
| `detail` | безопасный код результата Capability Lab, опускается, если нет: `camera_frame_received`, `location_fix_received`, `motion_sample_received`, `test_notification_scheduled`, `permission_denied`, `permission_restricted`, `unavailable`, `timed_out`, `cancelled`, `system_error` (D-035); с v0.3 — `always_authorized`, `region_monitoring_available`, `requires_settings`. Никогда не локализованный текст и не сырая ошибка |

`device` — `ConnectorDeviceSummary` (`last_seen_at` опускается, если нет); `connection_state`: `unpaired`, `pairing`, `connected`, `revoked`, `error`. Функции Connector (например, Screenshot Cleanup) — не capabilities; они сообщают о себе событиями.

### 4. Event batch

```
POST {base_url}/api/connector/events/batch
```

Запрос — до 20 событий из persistent-очереди, старые первыми:

```json
{
  "events": [
    {
      "event_id": "00000000-0000-4000-8000-000000000001",
      "type": "screenshot_cleanup.completed",
      "occurred_at": "2026-10-02T12:10:00Z",
      "session_id": "11111111-2222-3333-4444-555555555555",
      "payload": {}
    }
  ]
}
```

- UUID отправляются в нижнем регистре; `type` — `[a-z0-9._]`, до 100 символов; событие в JSON не больше 16 KiB; `payload` — произвольный JSON-объект/значение.
- Повторная отправка — те же `event_id` и `payload`.

Ответ:

```json
{
  "results": [
    { "event_id": "00000000-0000-4000-8000-000000000001", "status": "accepted" },
    { "event_id": "…", "status": "duplicate" },
    { "event_id": "…", "status": "rejected", "code": "unsupported_type" }
  ]
}
```

| `status` | Действие Connector |
|---|---|
| `accepted` | удалить из очереди |
| `duplicate` | уже принято ранее — удалить из очереди |
| `rejected` | окончательно отклонено — удалить из активной очереди, сохранить только метаданные (`event_id`, `type`, `code` ≤ 64 символа, время) в журнале отклонённых (до 100 записей), без payload (D-026) |
| нет результата | событие остаётся в очереди |

Строгая проверка: результат с `event_id`, которого не было в запросе, повтор одного `event_id` или неизвестный `status` → весь ответ `invalidResponse`, очередь не меняется.

### 5. Check connection

```
GET {base_url}/api/connector/connection/check
```

Выполняется только по кнопке «Проверить соединение».

```json
{ "ok": true, "server_time": "2026-10-02T12:00:00Z", "account_label": "optional" }
```

`ok` должен быть `true`, иначе `invalidResponse`. `account_label` опционален и показывается на Dashboard.

### 6. Revoke

- **С устройства:** «Отключить на этом iPhone» удаляет credentials из Keychain; серверный revoke пока не вызывается. Очередь событий не удаляется.
- **С сервера/PWA:** токен отзывается на сервере; Connector узнаёт об этом по 401 и переходит в состояние «Требуется повторное подключение» (credentials помечаются и больше не используются, очередь сохраняется).

### 7. Reminder draft (v0.2, V2-005)

```
GET {base_url}/api/connector/reminder-drafts/{draft_id}
Authorization: Bearer <device_token>
Accept: application/json
```

Черновик напоминания, который Katana подготовила для этого устройства. `{draft_id}` — UUID из ссылки v2 в нижнем регистре; других параметров и query нет. Запрос выполняется **только** по кнопке «Загрузить напоминание» на экране черновика (ссылка сама сеть не запускает, D-041/D-042); автоматических повторов нет. Общие правила авторизованных запросов (Bearer из Keychain перед запросом, без редиректов, timeout 15 с, ответ ≤ 64 KiB, `requires_repair` → запрос не отправляется) действуют как для маршрутов 3–5.

Успешный ответ (`200`):

```json
{
  "draft_id": "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
  "title": "Позвонить в сервис",
  "body": "Уточнить время записи",
  "fire_at": "2026-10-05T09:00:00Z",
  "expires_at": "2026-10-04T23:59:00Z"
}
```

| Поле | Тип | Проверка клиентом |
|---|---|---|
| `draft_id` | UUID | совпадает с запрошенным (регистр не важен), иначе `invalidResponse` |
| `title` | string | 1…120 Unicode scalar values, не только пробелы, без управляющих символов |
| `body` | string \| null | ≤ 500 Unicode scalar values; управляющие символы запрещены, кроме перевода строки; пустая строка = `null` |
| `fire_at` | ISO 8601 | строго в будущем относительно часов iPhone и не дальше 366 дней, иначе `alreadyDue` / `invalidResponse` |
| `expires_at` | ISO 8601 | строго в будущем, иначе `expired` |

Неизвестные дополнительные ключи игнорируются. Черновик должен принадлежать устройству/аккаунту этого токена: для чужого черновика сервер отвечает как для несуществующего (`404`), не раскрывая его существование.

| HTTP / условие | Ошибка клиента | UI |
|---|---|---|
| 401 | `unauthorized` | «Требуется повторное подключение»; credentials помечаются `requires_repair`, повторов нет |
| 403, 404 | `notFound` | «Напоминание не найдено» |
| 409 | `consumed` | «Напоминание уже использовано» |
| 410 или `expires_at` ≤ сейчас | `expired` | «Срок действия ссылки истёк» |
| `fire_at` ≤ сейчас | `alreadyDue` | «Время напоминания уже наступило» |
| 408, сеть, timeout | `offline` | безопасная повторяемая ошибка «Нет соединения…», кнопка «Повторить» |
| 429 | `rateLimited` | повторяемая ошибка |
| 5xx | `serverError` | повторяемая ошибка |
| 3xx, прочие коды, битое/слишком большое тело, нарушение правил выше | `invalidResponse` | «Katana ответила неожиданно» |

Тело ошибки клиентом не разбирается. Ни при какой ошибке ничего не планируется.

### 8. Action draft (v0.3, D-047)

```
GET {base_url}/api/connector/action-drafts/{draft_id}
Authorization: Bearer <device_token>
Accept: application/json
```

Только по кнопке «Загрузить действие» на экране, открытом ссылкой v3 `feature=action`; без автоматических повторов. Общие правила авторизованных запросов (Bearer из Keychain, без редиректов, timeout 15 с, ответ ≤ 64 KiB, `requires_repair` → запрос не отправляется). Черновик принадлежит устройству токена; чужой — как несуществующий (`404`).

Ответ `200` — **строгая схема**: ровно эти ключи, лишние или недостающие → `invalidResponse`.

```json
{
  "draft_id": "0b9f6c1e-2d3a-4b5c-8d6e-7f8091a2b3c4",
  "kind": "geofence_create",
  "server_time": "2026-10-05T09:00:00Z",
  "expires_at": "2026-10-05T10:00:00Z",
  "payload": { "latitude": 55.7558, "longitude": 37.6173, "radius_m": 200, "name_suggestion": "Офис" }
}
```

| Поле | Правило |
|---|---|
| `draft_id` | UUID, совпадает с запрошенным |
| `kind` | `nfc_action`, `geofence_create`, `shared_capture` |
| `server_time`, `expires_at` | ISO 8601; действителен, если `server_time < expires_at` и `expires_at − server_time ≤ 7 дней` (часы iPhone не используются), иначе `expired` |
| `payload` для `nfc_action` | ровно `action_id` (UUID), `label` (1…60 Unicode scalars, без управляющих символов) |
| `payload` для `geofence_create` | ровно `latitude` (−90…90), `longitude` (−180…180), `radius_m` (100, 200, 500 или 1000), `name_suggestion` (1…40, без управляющих символов). Клиент округляет координаты до 4 знаков |
| `payload` для `shared_capture` | ровно `accepted_kinds` (непустой массив без повторов из `text`, `url`, `image`, `pdf`, `file`), `prompt` (1…200, без управляющих символов, кроме перевода строки) |

| HTTP / условие | Ошибка | UI |
|---|---|---|
| 401 | `unauthorized` | «Требуется повторное подключение», без повторов |
| 403, 404 | `notFound` | «Действие не найдено» |
| 409 | `consumed` | «Действие уже выполнено» |
| 410 или TTL по `server_time` | `expired` | «Срок действия истёк» |
| 408, сеть | `offline` | повторяемая ошибка |
| 429 / 5xx | `rateLimited` / `serverError` | повторяемая ошибка |
| 3xx, прочее, > 64 KiB, нарушение схемы | `invalidResponse` | «Katana ответила неожиданно» |

**Consume:** отдельного запроса нет. Сервер атомарно помечает черновик использованным, когда принимает событие `action_draft.accepted` с этим `draft_id` (в одной транзакции с записью события). Повтор того же `event_id` → `duplicate`; другое событие для уже использованного черновика → `rejected` с `code: draft_consumed`; для истёкшего → `rejected` с `code: draft_expired`. После consume `GET` отвечает `409`.

### 9. Capture upload (v0.3, D-050)

```
PUT {base_url}/api/connector/captures/{capture_id}
Authorization: Bearer <device_token>
Content-Type: <allowlist>
X-Katana-Capture-Kind: text | url | image | pdf | file
X-Katana-Capture-SHA256: <64 hex, lowercase>
Accept: application/json
<тело — байты захвата>
```

Выполняется только основным приложением, только после «Отправить в Katana» на preview; Share Extension сеть не использует. `{capture_id}` — UUID в нижнем регистре. Timeout 60 с, без редиректов, ответ ≤ 64 KiB.

| `kind` | `Content-Type` | Тело | Лимит |
|---|---|---|---|
| `text` | `text/plain; charset=utf-8` | UTF-8 текст | 10 000 scalars (≤ 40 KiB) |
| `url` | `text/uri-list` | одна строка `http(s)://…` | 2048 байт |
| `image` | `image/jpeg`, `image/png`, `image/heic` | изображение без метаданных (кроме ориентации) | 10 MiB |
| `pdf` | `application/pdf` | документ как есть (метаданные PDF не очищаются) | 10 MiB |
| `file` | `text/plain; charset=utf-8`, `text/csv`, `application/json` | UTF-8 файл | 5 MiB |

Имя файла, локальный путь, PHAsset ID, EXIF/GPS и иные метаданные не передаются. Сервер обязан проверить `Content-Length`, SHA-256 тела и соответствие сигнатуры `Content-Type`.

Ответ `200`/`201`:

```json
{ "capture_id": "…", "object_ref": "cap_7Hq2x", "size_bytes": 1234, "sha256": "…" }
```

`object_ref` — непрозрачная ссылка `[A-Za-z0-9_-]{1,64}`, без содержимого и без URL. Идемпотентность: повтор того же `capture_id` с тем же SHA-256 → тот же `object_ref`; с другим SHA-256 → `409`. Ошибки: 401 → `requires_repair`; 409 → конфликт (захват отмечается неудачным, без повторов); 413/415/422 → отклонено, без повторов; 408/сеть/429/5xx → повтор при следующем запуске/«Синхронизировать»; 3xx/прочее → `invalidResponse`. Сервер хранит объект в истории без раскрытия содержимого в событиях и логах.

### 10. NFC HTTPS bridge (v0.3, D-054)

```
GET https://<katana-host>/c/nfc/{action_id}
```

Публичная страница для постоянных NFC-меток. Без авторизации, без cookies, без редиректов на другие хосты, без побочных эффектов: GET ничего не выполняет, не меняет и не создаёт событий.

| Правило | Значение |
|---|---|
| `{action_id}` | канонический UUID в нижнем регистре; иначе `404` с пустым телом |
| Ответ | `200 text/html; charset=utf-8`, одинаковый для любого корректного UUID (не раскрывает существование и название действия) |
| Заголовки | `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, `Content-Security-Policy: default-src 'none'; script-src 'sha256-…'; style-src 'unsafe-inline'`, `X-Content-Type-Options: nosniff` |
| Содержимое | кнопка «Открыть в Katana Connector» со ссылкой `katana-connector://open?v=3&feature=nfc_action&action_id={action_id}` и встроенный скрипт, который переходит по ней сразу; никаких внешних ресурсов, аналитики и параметров кроме `action_id` |
| Логи | путь логируется как `/c/nfc/:id`; `action_id`, User-Agent и IP моста в аналитику не попадают |
| Метка | единственная NDEF URI-запись с этим HTTPS-адресом; без UID, текста, токенов; метка не блокируется |

Эталонная страница — `docs/nfc-bridge-reference.html`; запись метки — `docs/NFC_TAG_SETUP.md`.

## Custom URL scheme v1 (PWA → Connector, KC-007)

Katana PWA может открыть экран Connector ссылкой. Это **только навигация**: в сеть ничего не уходит, данные и credentials не передаются.

```
katana-connector://open?v=1&feature=screenshot_cleanup
katana-connector://open?v=1&feature=pairing
```

| Часть | Правило |
|---|---|
| scheme / host | строго `katana-connector` и `open` |
| path | пустой или `/` |
| user, password, port, fragment | запрещены |
| `v` | ровно один раз, строго `1` |
| `feature` | ровно один раз: `screenshot_cleanup` или `pairing` |
| прочие параметры | запрещены (включая `token`, `code`, `base_url`, `device_id`) |
| значения | не пустые |
| вся ссылка | до 2048 символов, только печатный ASCII |

Невалидная ссылка игнорируется и не меняет текущий экран. Ссылка открывает тот же экран, что Dashboard, и с теми же подтверждениями:

- `screenshot_cleanup` — экран разбора; доступ к фото запрашивается только кнопкой «Разрешить доступ к фото» внутри него; удаление — только через экран проверки и два подтверждения.
- `pairing` — экран объяснения подключения; камера — только по «Сканировать QR»; ссылка не содержит кода и адреса и не создаёт подключение.

Формат pairing QR `katana-connector://pair?…` (см. выше) — только для QR-сканера; как ссылка он не обрабатывается.

## Custom URL scheme v2 (PWA → Connector, V2-001)

Ссылки v1 не меняются. Версия 2 добавляет ровно три ссылки — тоже **только навигация** (D-042):

```
katana-connector://open?v=2&feature=activity_journal
katana-connector://open?v=2&feature=location_check_in
katana-connector://open?v=2&feature=reminder&draft_id=<uuid>
```

| Часть | Правило |
|---|---|
| scheme / host / path, user, password, port, fragment, длина, ASCII | как в v1 |
| `v` | ровно один раз, строго `2` |
| `feature` | ровно один раз: `activity_journal`, `location_check_in` или `reminder`; функции v1 с `v=2` отклоняются (`unsupportedVersion`) |
| `draft_id` | ровно один раз и только для `reminder`: канонический UUID `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (hex, регистр не важен); для других функций запрещён |
| percent-encoding | в query v2 запрещён (символ `%`) |
| прочие параметры | запрещены, в том числе `token`, `code`, `base_url`, `device_id`, `title`, `body`, `fire_at` |

- `activity_journal` / `location_check_in` — открывают экран функции; разрешения Motion и геолокации запрашиваются только кнопками внутри.
- `reminder` — открывает «Локальные напоминания» и поверх — экран черновика. Текст напоминания в ссылке **не передаётся**; черновик загружается только кнопкой «Загрузить напоминание» (маршрут 7); уведомление создаётся только кнопкой «Создать напоминание».
- Невалидная ссылка игнорируется и не меняет текущий экран. Ссылка не запрашивает разрешения, не планирует уведомления, не создаёт события и не обращается к сети.

## Custom URL scheme v3 (PWA / Shortcuts → Connector, V3-001)

Ссылки v1 и v2 не меняются. v3 добавляет две ссылки — **только навигация** (D-047):

```
katana-connector://open?v=3&feature=action&draft_id=<uuid>
katana-connector://open?v=3&feature=nfc_action&action_id=<uuid>
```

| Часть | Правило |
|---|---|
| scheme / host / path, user, password, port, fragment, длина, ASCII, percent-encoding | как в v2 |
| `v` | ровно один раз, строго `3` |
| `feature` | `action` или `nfc_action`; функции v1/v2 с `v=3` → `unsupportedVersion` |
| `draft_id` | ровно один раз и только для `action`, канонический UUID |
| `action_id` | ровно один раз и только для `nfc_action`, канонический UUID |
| прочие параметры | запрещены (`token`, `code`, `base_url`, `device_id`, `title`, `body`, `command`, `latitude`, `name`, `url`, …) |

- `action` → экран черновика действия; загрузка — кнопкой, выполнение — кнопкой с подтверждением.
- `nfc_action` → preview локально зарегистрированного NFC-действия; выполнение — только «Выполнить». Неизвестное/выключенное/истёкшее действие показывается явно.

### Настройка NFC через Shortcuts (гарантированный путь)

1. Connector → «NFC-действия» → действие → «Скопировать ссылку для Shortcuts» (ссылка содержит только `action_id`).
2. Команды → Автоматизация → «NFC» → отсканировать метку → действие «Открыть URL» → вставить ссылку → выключить «Спрашивать перед запуском» по желанию (подтверждение всё равно будет в Connector).
3. Касание метки открывает preview в Connector; ничего не выполняется без «Выполнить».

## События

### Идемпотентность и привязка к подключению

- `event_id` — уникален для каждого события, генерируется при создании и хранится вместе с ним в очереди. Повторные отправки используют тот же `event_id` и тот же `payload`. Сервер обязан дедуплицировать по `event_id`.
- `session_id` — идентификатор пользовательской сессии функции. Для `screenshot_cleanup.completed` одна сессия даёт максимум одно событие; сервер может дополнительно проверять уникальность пары (`type`, `session_id`).
- Каждое событие в локальной очереди привязано к подключению (`ConnectionScope` = канонический `base_url` + `device_id`, D-029) и отправляется только этому подключению. Scope в API не передаётся: сервер узнаёт устройство по Bearer token.

### `screenshot_cleanup.completed`

Создаётся один раз, когда пользователь явно завершает разбор («Завершить разбор» → «Завершить»). Выход из функции или «Продолжить разбор» событие не создают.

```json
{
  "event_id": "00000000-0000-4000-8000-000000000005",
  "type": "screenshot_cleanup.completed",
  "occurred_at": "2026-10-02T12:11:30Z",
  "session_id": "11111111-2222-3333-4444-555555555555",
  "payload": {
    "session_id": "11111111-2222-3333-4444-555555555555",
    "started_at": "2026-10-02T12:10:00Z",
    "completed_at": "2026-10-02T12:11:30Z",
    "reviewed_count": 3,
    "kept_count": 1,
    "deletion_requested_count": 2,
    "deletion_completed": false
  }
}
```

| Поле payload | Тип | Описание |
|---|---|---|
| `session_id` | UUID (lowercase) | Сессия разбора; совпадает с `session_id` конверта |
| `started_at` | ISO 8601 | Первое решение в сессии |
| `completed_at` | ISO 8601 | Явное завершение; совпадает с `occurred_at` |
| `reviewed_count` | int > 0 | Скриншоты, по которым в сессии принято решение |
| `kept_count` | int ≥ 0 | Оставлено |
| `deletion_requested_count` | int ≥ 0 | Отмечено на удаление (удалённые + ещё не удалённые) |
| `deletion_completed` | bool | Все отмеченные скриншоты действительно удалены (после подтверждения в приложении и системного диалога iOS) |

Инварианты (проверяются до отправки; событие с нарушением не создаётся): `reviewed_count = kept_count + deletion_requested_count`, `reviewed_count > 0`, `started_at <= completed_at`, при `deletion_requested_count = 0` — `deletion_completed = true`. `remaining_count` не передаётся: при ограниченном доступе к фото и изменениях медиатеки его нельзя определить достоверно.

**Не передаётся никогда:** изображения, миниатюры, `PHAsset.localIdentifier`, имена файлов, даты и геоданные отдельных снимков, размеры, список действий пользователя. Решения отменённые через undo в счётчики не входят; скриншоты, исчезнувшие из медиатеки вне приложения, не учитываются.

## События v0.2 (Context & Actions)

Общие правила (D-038): событие создаётся только после явного подтверждения пользователя; `event_id` — новый UUID, создаётся один раз и переиспользуется при повторах и после перезапуска; `session_id` конверта — собственный идентификатор записи; все UUID в нижнем регистре, времена ISO 8601 UTC с точностью до секунды; payload проверяется до enqueue на точный набор ключей и закрытые значения; очередь, scope и `events/batch` — те же, что в v0.1. Сервер дедуплицирует по `event_id`; дополнительно может проверять уникальность пары (`type`, `session_id`).

| `type` | `session_id` конверта | `occurred_at` | Ключи payload |
|---|---|---|---|
| `activity.snapshot.completed` | `snapshot_id` (UUID на проверку) | `checked_at` | 5 |
| `activity.session.completed` | `session_id` | `completed_at` | 13 |
| `location.check_in.created` | `check_in_id` | `occurred_at` (время фиксации) | 7 |
| `reminder.local.scheduled` | `draft_id` | `created_at` | 5 |
| `reminder.local.cancelled` | `draft_id` | `cancelled_at` | 3 |

### `activity.snapshot.completed`

Создаётся кнопкой «Отправить в Katana» после «Определить текущую активность».

```json
{
  "event_id": "00000000-0000-4000-8000-000000000101",
  "type": "activity.snapshot.completed",
  "occurred_at": "2026-10-04T10:00:00Z",
  "session_id": "aaaaaaaa-0000-4000-8000-000000000001",
  "payload": {
    "activity": "walking",
    "confidence": "high",
    "checked_at": "2026-10-04T10:00:00Z",
    "source": "motion_activity",
    "interrupted": false
  }
}
```

| Поле | Значения |
|---|---|
| `activity` | `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown` |
| `confidence` | `low`, `medium`, `high` |
| `checked_at` | время проверки; совпадает с `occurred_at` |
| `source` | всегда `motion_activity` |
| `interrupted` | всегда `false` |

Правило при нескольких флагах CMMotionActivity: `automotive` > `cycling` > `running` > `walking` > `stationary` > `unknown`; без флагов — `unknown`.

### `activity.session.completed`

Создаётся кнопкой «Отправить в Katana» на предпросмотре после «Завершить» (или после «Завершить» прерванной сессии).

```json
{
  "event_id": "00000000-0000-4000-8000-000000000102",
  "type": "activity.session.completed",
  "occurred_at": "2026-10-04T10:30:00Z",
  "session_id": "bbbbbbbb-0000-4000-8000-000000000002",
  "payload": {
    "session_id": "bbbbbbbb-0000-4000-8000-000000000002",
    "started_at": "2026-10-04T10:00:00Z",
    "completed_at": "2026-10-04T10:30:00Z",
    "duration_seconds": 1800,
    "dominant_activity": "walking",
    "stationary_seconds": 300,
    "walking_seconds": 1200,
    "running_seconds": 0,
    "cycling_seconds": 0,
    "automotive_seconds": 0,
    "unknown_seconds": 300,
    "interrupted": false
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `session_id` | UUID | совпадает с `session_id` конверта |
| `started_at` / `completed_at` | ISO 8601 | целые секунды; `started_at` ≤ `completed_at`; `completed_at` = `occurred_at` |
| `duration_seconds` | int ≥ 0 | `completed_at − started_at` |
| `dominant_activity` | категория | наибольшее время; при равенстве — приоритет как у snapshot; при нулевой длительности — `unknown` |
| `<category>_seconds` | int ≥ 0 | шесть категорий; время в фоне или без данных — `unknown_seconds` |
| `interrupted` | bool | сессия была восстановлена после завершения процесса (kill/relaunch); тогда `completed_at` — последняя сохранённая точка |

Инварианты (проверяются до enqueue): все секунды ≥ 0; сумма шести категорий ≤ `duration_seconds` + 1 (допуск 1 с; клиент формирует точное равенство); `dominant_activity` согласован со значениями. Временного ряда, сырых Motion samples и координат нет.

### `location.check_in.created`

Создаётся только после «Определить текущее место» → предпросмотр → выбор точности → «Отправить в Katana» → подтверждение.

```json
{
  "event_id": "00000000-0000-4000-8000-000000000103",
  "type": "location.check_in.created",
  "occurred_at": "2026-10-04T11:00:00Z",
  "session_id": "cccccccc-0000-4000-8000-000000000003",
  "payload": {
    "check_in_id": "cccccccc-0000-4000-8000-000000000003",
    "occurred_at": "2026-10-04T11:00:00Z",
    "latitude": 55.76,
    "longitude": 37.62,
    "precision": "approximate",
    "horizontal_accuracy_bucket": "under_100m",
    "label_requested": true
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `check_in_id` | UUID | совпадает с `session_id` конверта |
| `occurred_at` | ISO 8601 | время получения фиксации (целые секунды) |
| `latitude` | number | −90…90; `approximate` — округлено до 2 знаков, `precise` — не больше 6 знаков |
| `longitude` | number | −180…180; округление как у `latitude` |
| `precision` | string | `approximate`, `precise` |
| `horizontal_accuracy_bucket` | string | `under_25m` (< 25 м), `under_100m` (< 100 м), `under_1km` (< 1000 м), `over_1km`, `unknown` |
| `label_requested` | bool | пользователь попросил Katana подписать место (reverse geocoding на сервере) |

Не передаются: высота, скорость, курс, этаж, сырая точность числом, время CLLocation, EXIF и данные фотографий. Клиент гарантирует округлённое значение; сервер может дополнительно округлить до 2/6 знаков.

### `reminder.local.scheduled`

Создаётся после «Создать напоминание», выданного разрешения и успешного планирования локального уведомления.

```json
{
  "event_id": "00000000-0000-4000-8000-000000000104",
  "type": "reminder.local.scheduled",
  "occurred_at": "2026-10-04T12:00:00Z",
  "session_id": "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
  "payload": {
    "draft_id": "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
    "scheduled_for": "2026-10-05T09:00:00Z",
    "notification_id": "app.katana.connector.reminder.6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
    "authorization": "authorized",
    "created_at": "2026-10-04T12:00:00Z"
  }
}
```

| Поле | Описание |
|---|---|
| `draft_id` | UUID черновика; совпадает с `session_id` конверта |
| `scheduled_for` | `fire_at` черновика |
| `notification_id` | `app.katana.connector.reminder.<draft_id>` |
| `authorization` | `authorized`, `provisional`, `ephemeral` — с каким разрешением запланировано |
| `created_at` | время планирования; совпадает с `occurred_at` |

### `reminder.local.cancelled`

Создаётся, когда пользователь отменил ещё не сработавшее напоминание Connector (с подтверждением).

```json
{
  "event_id": "00000000-0000-4000-8000-000000000105",
  "type": "reminder.local.cancelled",
  "occurred_at": "2026-10-04T13:00:00Z",
  "session_id": "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
  "payload": {
    "draft_id": "6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
    "notification_id": "app.katana.connector.reminder.6f1c2d3e-4b5a-4c6d-8e7f-90a1b2c3d4e5",
    "cancelled_at": "2026-10-04T13:00:00Z"
  }
}
```

`title` и `body` в события напоминаний **не входят**: Katana уже знает содержимое черновика.

### Что должна реализовать Katana для v0.2

1. `GET /api/connector/reminder-drafts/{draft_id}` по контракту выше: Bearer-аутентификация, привязка черновика к устройству/аккаунту, `404` для чужих и несуществующих, `410` для истёкших, `409` для использованных, без редиректов, тело < 64 KiB.
2. Ссылку `katana-connector://open?v=2&feature=reminder&draft_id=<uuid>` без текста напоминания.
3. Приём пяти новых типов в `events/batch` (`accepted` / `duplicate` по `event_id`; `rejected` с кодом для неизвестных или невалидных), валидацию payload по таблицам выше, допуск 1 с для суммы секунд активности.
4. Для check-in — reverse geocoding по `label_requested` на сервере; хранение координат по политике Katana.
5. По желанию — пометку черновика consumed по `reminder.local.scheduled` (Q-10).

## События v0.3 (Physical Triggers & Capture)

Правила D-038 действуют без изменений (точные ключи, `event_id` один раз, `session_id` — собственный идентификатор записи, UUID в нижнем регистре, ISO 8601 UTC до секунды, существующая очередь и scope).

| `type` | `session_id` конверта | `occurred_at` | Ключи payload |
|---|---|---|---|
| `action_draft.accepted` | `draft_id` | `accepted_at` | `draft_id`, `kind`, `accepted_at`, `result_ref` |
| `nfc.action.completed` | `execution_id` | `confirmed_at` | `action_id`, `execution_id`, `source`, `confirmed_at`, `result`, `interrupted` |
| `geofence.created` | `geofence_id` | `created_at` | `geofence_id`, `latitude`, `longitude`, `radius_m`, `created_at`, `origin` |
| `geofence.transitioned` | `transition_id` | `occurred_at` | `geofence_id`, `transition_id`, `transition`, `occurred_at`, `delivery_context`, `interrupted` |
| `geofence.removed` | `geofence_id` | `removed_at` | `geofence_id`, `removed_at` |
| `share.capture.created` | `capture_id` | `created_at` | `capture_id`, `kind`, `size_bucket`, `created_at`, `upload_status`, `object_ref` |
| `share.capture.cancelled` | `capture_id` | `cancelled_at` | `capture_id`, `kind`, `size_bucket`, `cancelled_at`, `upload_status` |

Закрытые значения:

| Поле | Значения |
|---|---|
| `action_draft.accepted.kind` | `nfc_action`, `geofence_create`, `shared_capture` |
| `result_ref` | UUID результата: `action_id` (nfc_action), `geofence_id` (geofence_create), `capture_id` (shared_capture) |
| `nfc.action.completed.source` | `shortcut` (внешняя ссылка: Команды или HTTPS-мост с метки, D-054), `core_nfc` |
| `nfc.action.completed.result` | `confirmed` («Выполнить»), `declined` («Отклонить») |
| `interrupted` (nfc) | `true`, если ожидающий запуск был восстановлен после перезапуска приложения |
| `geofence.created.latitude/longitude` | числа, округлены до ≤ 4 знаков |
| `radius_m` | `100`, `200`, `500`, `1000` |
| `origin` | `user`, `action_draft` |
| `transition` | `enter`, `exit` |
| `delivery_context` | `foreground`, `background` |
| `interrupted` (geofence) | `true`, если системный регион пришлось зарегистрировать заново (после потери регистрации) до этого пересечения |
| `share.capture.*.kind` | `text`, `url`, `image`, `pdf`, `file` |
| `size_bucket` | `under_10kb`, `under_100kb`, `under_1mb`, `under_10mb` |
| `upload_status` | `uploaded` (created), `not_uploaded` (cancelled) |
| `object_ref` | значение из ответа маршрута 9 |

Порядок для черновиков: `geofence_create` → `geofence.created`, затем `action_draft.accepted`; `shared_capture` → `share.capture.created`, затем `action_draft.accepted`; `nfc_action` → только `action_draft.accepted` (регистрация на iPhone).

Примеры:

```json
{ "type": "nfc.action.completed", "session_id": "<execution_id>", "occurred_at": "2026-10-05T09:00:00Z",
  "payload": { "action_id": "<uuid>", "execution_id": "<uuid>", "source": "shortcut",
               "confirmed_at": "2026-10-05T09:00:00Z", "result": "confirmed", "interrupted": false } }
{ "type": "geofence.transitioned", "session_id": "<transition_id>", "occurred_at": "2026-10-05T18:30:00Z",
  "payload": { "geofence_id": "<uuid>", "transition_id": "<uuid>", "transition": "exit",
               "occurred_at": "2026-10-05T18:30:00Z", "delivery_context": "background", "interrupted": false } }
{ "type": "share.capture.created", "session_id": "<capture_id>", "occurred_at": "2026-10-05T12:00:00Z",
  "payload": { "capture_id": "<uuid>", "kind": "image", "size_bucket": "under_1mb",
               "created_at": "2026-10-05T12:00:00Z", "upload_status": "uploaded", "object_ref": "cap_7Hq2x" } }
```

**Не передаётся никогда:** UID метки, NDEF payload, текст, URL, имена файлов, пути, PHAsset ID, EXIF/GPS, координаты в пересечениях и удалении, location samples, маршруты, имя геозоны.

### Что должна реализовать Katana для v0.3

1. **Action drafts:** создание черновиков трёх видов (UI Katana), `GET /api/connector/action-drafts/{draft_id}` по строгой схеме выше (с `server_time`), привязка к устройству, 404 для чужих, 410 после TTL (≤ 7 дней), 409 после consume; атомарный consume при приёме `action_draft.accepted` (+ `rejected` `draft_consumed` / `draft_expired`).
2. **NFC action registry:** `action_id` + метка; регистрация на устройстве по `action_draft.accepted` (`result_ref` = `action_id`); приём `nfc.action.completed` (`rejected` с `action_unknown`/`action_disabled` для неизвестных/выключенных на сервере); идемпотентность по `event_id`, по `execution_id` — не больше одного события.
3. **Geofence registry:** `geofence.created` (координаты ≤ 4 знаков, радиус из набора; по политике Katana — reverse geocoding только для подписи места, без хранения истории перемещений), `geofence.transitioned` без координат, `geofence.removed`; `rejected` `geofence_unknown` для пересечений неизвестной геозоны.
4. **Capture upload lifecycle:** `PUT /api/connector/captures/{capture_id}` (allowlist типов, лимиты, проверка SHA-256 и сигнатуры, идемпотентность, 409 при другом хеше), хранение объекта, `object_ref`; `share.capture.created`/`cancelled` без содержимого; серверная история без утечки содержимого в события и логи; объекты без подтверждающего события через 24 ч можно удалять.
5. **Capability report:** принимать новые `id` и `detail` без отказа всего отчёта.
6. **Ссылки:** кнопки/QR Katana для `…v=3&feature=action&draft_id=<uuid>`; для NFC — показ ссылки `…v=3&feature=nfc_action&action_id=<uuid>` для Shortcuts.
7. **NFC HTTPS bridge (маршрут 10, D-054):** `GET /c/nfc/{action_id}` по `docs/nfc-bridge-reference.html`; в Katana Devices у каждого `nfc_action` — HTTPS-адрес и QR для записи через NFC Tools.

