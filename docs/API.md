# Katana API — контракт Connector

> Статус: pairing (v1) проверен end-to-end; маршруты 3–5 зафиксированы в KC-005 и ждут проверки с реальным Katana API. Все адреса ниже — плейсхолдеры.

## Общие правила

- Транспорт: только HTTPS. Базовый адрес — `base_url` из pairing QR, сохраняется в Keychain вместе с токеном (D-020).
- Формат: JSON, UTF-8. Время — ISO 8601 в UTC (`2026-10-02T12:34:56Z`).
- Идентификаторы, создаваемые клиентом (`event_id`, `session_id`, `installation_id`), — UUID v4.
- Авторизация после pairing: device token в заголовке (например, `Authorization: Bearer <device_token>`). Токен хранится только в Keychain и никогда не логируется.
- Версия контракта передаётся клиентом (например, поле или заголовок `api_version`) — точный механизм TBD.
- В API **никогда** не передаются: изображения, превью, хэши изображений, `PHAsset.localIdentifier`, имена файлов, даты отдельных снимков, EXIF, геоданные.

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
| `id` | `photos`, `camera`, `vision_ocr`, `files`, `current_location`, `background_location`, `motion`, `local_notifications`, `bluetooth`, `local_network`, `contacts`, `calendar`, `reminders`, `face_id`, `microphone`, `speech`, `health_kit`, `core_nfc` |
| `availability` | `available`, `planned`, `missing_entitlement`, `unsupported_device` |
| `authorization` | `unknown`, `not_required`, `not_requested`, `granted`, `limited`, `denied`, `restricted` |
| `probe_state` | `not_run`, `passed`, `failed` |
| `checked_at` | время последней проверки, опускается, если нет |
| `detail` | безопасный код результата Capability Lab, опускается, если нет: `camera_frame_received`, `location_fix_received`, `motion_sample_received`, `test_notification_scheduled`, `permission_denied`, `permission_restricted`, `unavailable`, `timed_out`, `cancelled`, `system_error` (D-035). Никогда не локализованный текст и не сырая ошибка |

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
