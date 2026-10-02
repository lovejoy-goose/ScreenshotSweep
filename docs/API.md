# Katana API — концептуальный контракт

> Статус: **черновик**. Описаны операции, поля и семантика. Окончательные URL, методы, коды ответов и формат ошибок согласуются с бэкендом Katana и фиксируются в KC-004/KC-005. Все адреса ниже — плейсхолдеры.

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

Тело ошибки клиентом пока не разбирается. Не реализовано на сервере — нужен endpoint в Katana (KC-004 in review).

### 2a. Revoke (локальный, KC-004)

«Отключить на этом iPhone» удаляет credentials из Keychain. Серверный revoke пока не вызывается (см. п. 6).

### 3. Capability report (Connector → API)

Сообщает, какие функции есть на устройстве и в каком они состоянии. Отправляется после pairing и при изменении статусов.

```json
{
  "reported_at": "2026-10-02T12:00:00Z",
  "device": {
    "device_id": "<server-assigned>",
    "display_name": "iPhone",
    "app_version": "0.1.0",
    "system_version": "18.0",
    "connection_state": "connected",
    "last_seen_at": "2026-10-02T12:00:00Z"
  },
  "capabilities": [
    { "id": "photos", "availability": "available", "authorization": "granted", "probe_state": "passed", "checked_at": "2026-10-02T11:59:00Z" },
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
| `checked_at` | время последней проверки, опционально |
| `detail` | короткий технический код/пояснение без пользовательских данных, опционально |

`device` — `ConnectorDeviceSummary`; `connection_state`: `unpaired`, `pairing`, `connected`, `revoked`, `error`. Функции Connector (например, Screenshot Cleanup) — не capabilities; они сообщают о себе событиями.

### 4. Event batch (Connector → API)

Пакет событий из persistent-очереди.

```json
{
  "events": [
    {
      "event_id": "UUID",
      "type": "screenshots.cleanup.completed",
      "occurred_at": "2026-10-02T12:10:00Z",
      "session_id": "UUID",
      "payload": { }
    }
  ]
}
```

Ответ — статус по каждому событию:

| Статус | Действие клиента |
|---|---|
| `accepted` | Удалить из очереди |
| `duplicate` | Событие с этим `event_id` уже было принято — удалить из очереди |
| `rejected` | Невалидно, ретраить бессмысленно — удалить/пометить, залогировать только код |

Сетевая ошибка, 5xx, 408, 429 → весь пакет остаётся в очереди, повтор с backoff. 401 → токен недействителен, pairing помечается как «нужно перепривязать», очередь сохраняется.

### 5. Check connection (Connector → API)

Лёгкий авторизованный запрос для экрана «Статус подключения»: токен валиден, сервер доступен. Ответ: признак успеха, серверное время (для диагностики расхождения часов), опционально `account_label`.

### 6. Revoke

- **С устройства:** пользователь нажимает «Отвязать» → запрос на отзыв токена → токен удаляется из Keychain **независимо от ответа сервера**. Неотправленные события: политика (отправить перед отзывом / удалить) — TBD в KC-004/KC-005.
- **С сервера/PWA:** токен отзывается на сервере; Connector узнаёт об этом по 401 и переходит в состояние «не привязан».

## События

### Идемпотентность

- `event_id` — уникален для каждого события, генерируется при создании события и сохраняется вместе с ним в очереди. Повторные отправки используют тот же `event_id`. Сервер обязан дедуплицировать по `event_id`.
- `session_id` — идентификатор пользовательской сессии функции (например, одной cleanup-сессии). Для `screenshots.cleanup.completed` на одну сессию — максимум одно событие; сервер может дополнительно проверять уникальность пары (`type`, `session_id`).

### `screenshots.cleanup.completed`

| Поле | Тип | Описание |
|---|---|---|
| `session_id` | UUID | Идентификатор cleanup-сессии (дублируется в конверте) |
| `viewed` | int ≥ 0 | Сколько скриншотов пользователь просмотрел и принял по ним решение |
| `kept` | int ≥ 0 | Сколько оставлено |
| `deleted` | int ≥ 0 | Сколько **фактически удалено** (успешный `performChanges`) |
| `started_at` | datetime | Начало сессии |
| `completed_at` | datetime | Завершение сессии |

Инварианты: `kept + deleted <= viewed`, `started_at <= completed_at`.

Открытые вопросы по семантике (решаются в KC-006):

- Что считается завершением сессии: все скриншоты разобраны / выход из функции / уход приложения в фон / таймаут.
- Как учитывать кандидатов, отмеченных на удаление, но не удалённых (отмена в системном диалоге, выход без удаления): считать в `kept` или ввести отдельное поле.
- Учитывать ли решения, отменённые через undo (предложение: нет, считается только итоговое состояние).
- Отправлять ли событие для сессии с `viewed = 0`.
