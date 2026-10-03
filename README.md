# Katana Connector

Нативное iOS-приложение-компаньон для Katana PWA: даёт Katana доступ к функциям iPhone, которых нет в браузере, и возвращает в Katana только агрегированные результаты. Продукт, архитектура, решения и план — в [`docs/`](docs/), правила работы — в [`CLAUDE.md`](CLAUDE.md).

```
Katana PWA → QR pairing → credentials в Keychain → katana-connector:// ссылка → Screenshot Cleanup
           → persistent очередь (по подключению) → authenticated API → результат в Katana
```

## Что входит в v0.1

- **Dashboard** — состояние подключения и синхронизации, функции, возможности устройства. Ничего не запрашивает при запуске.
- **Подключение к Katana по QR** — Katana показывает одноразовый QR; Connector показывает адрес Katana и имя iPhone до подтверждения; токен устройства хранится только в Keychain (на сервере — только его хеш). «Отключить на этом iPhone» удаляет локальные данные подключения. Если Katana отозвала устройство (401), Connector перестаёт использовать токен и предлагает подключиться заново.
- **Screenshot Cleanup** — разбор скриншотов (оставить / на удаление / отменить / проверка / удаление с подтверждением в приложении и системным диалогом iOS). По кнопке «Завершить разбор» в Katana уходит одно событие `screenshot_cleanup.completed` с семью полями: `session_id`, `started_at`, `completed_at`, `reviewed_count`, `kept_count`, `deletion_requested_count`, `deletion_completed`.
- **Ссылки из Katana** — `katana-connector://open?v=1&feature=screenshot_cleanup` и `katana-connector://open?v=1&feature=pairing` только открывают экран: без разрешений, удаления, подключения и сети.
- **Offline-очередь** — событие сначала записывается на iPhone, потом отправляется; переживает перезапуск и отсутствие сети; отправляется только тому подключению, для которого записано; повторная отправка использует тот же `event_id`, сервер отбрасывает дубликаты.
- **Capability Lab** — четыре ручные проверки: камера (один кадр, сразу отброшен), текущая геолокация (только «При использовании», координаты отброшены), датчики движения (данные отброшены), локальное тестовое уведомление. Каждая — только своей кнопкой и только со своим разрешением; в Katana уходят лишь состояния и безопасные коды.

## Граница приватности

- В Katana **никогда** не уходят: фото, кадры, миниатюры, идентификаторы и имена файлов, EXIF, даты и геоданные снимков, координаты, данные движения, текст системных ошибок, токены и коды подключения.
- Токен — только в Keychain; в логи, файлы, UI и URL не попадает.
- Разрешения запрашиваются только кнопкой внутри соответствующей функции, по одному.
- Медиатека меняется только после экрана проверки, подтверждения в приложении и системного диалога iOS; файлы уходят в «Недавно удалённые».

## Ограничения v0.1

- Нет фоновой доставки (BackgroundTasks, push): события отправляются при запуске, возврате в приложение, после нового события и по «Синхронизировать».
- «Отключить на этом iPhone» не отзывает устройство на сервере — его нужно удалить в Katana вручную.
- Одно активное подключение на iPhone; события другого или прежнего подключения хранятся и автоматически не отправляются.
- Нет HealthKit, NFC, Bluetooth, фоновой геолокации и геозон, микрофона и речи, Share Extension, Universal Links.
- Распространение — unsigned IPA + Sideloadly; с бесплатным Apple ID подпись действует 7 дней.

## Постоянный Bundle ID

Bundle ID — **`app.katana.connector`**, он не меняется. На нём держатся данные, которые обязаны пережить установку новой версии поверх старой:

| Данные | Где |
|---|---|
| Подключение (токен + адрес, id, имя, время) | Keychain, service `app.katana.connector.pairing`, account `device-credentials` |
| Очередь событий | `Application Support/KatanaConnector/EventQueue/event-queue.json` |
| Результаты Capability Lab | `Application Support/KatanaConnector/Capabilities/capability-snapshots.json` |
| Время последней синхронизации | `UserDefaults`, ключ `connector.lastSuccessfulSyncAt` |

Эти идентификаторы закреплены unit-тестами. Старое приложение ScreenshotSweep (`local.sweep.ScreenshotSweep`) — отдельное приложение; данные из него не переносятся.

## Сборка (без локального Xcode)

1. Запушьте изменения в GitHub (`lovejoy-goose/ScreenshotSweep`).
2. GitHub → Actions → **Build iOS (unsigned)** запускается на push в `main`, на pull request или вручную (Run workflow / `gh workflow run build-ios.yml --ref <ветка>`).
3. Когда сборка зелёная, откройте run → Artifacts → скачайте `katana-connector-unsigned-ipa` (zip) и распакуйте — внутри `KatanaConnector.ipa`.

Workflow: `xcodegen generate` → unit-тесты на iOS Simulator → `xcodebuild -scheme KatanaConnector -sdk iphoneos CODE_SIGNING_ALLOWED=NO` → проверка URL-схемы и usage descriptions в Info.plist → `KatanaConnector.ipa`.

## Установка через Sideloadly

1. Установите [Sideloadly](https://sideloadly.io) (и iTunes/iCloud с сайта Apple на Windows).
2. Подключите iPhone кабелем, нажмите «Доверять этому компьютеру».
3. Перетащите `KatanaConnector.ipa` в Sideloadly, введите свой Apple ID (сам Sideloadly подписывает приложение; пароль вводится только в нём), нажмите **Start**.
4. На iPhone: Настройки → Основные → VPN и управление устройством → ваш Apple ID → «Доверять».
5. iOS 16+: Настройки → Конфиденциальность и безопасность → **Режим разработчика** → включить, перезагрузить.
6. С бесплатным Apple ID подпись живёт 7 дней — потом переустановите через Sideloadly.

### Обновление поверх установленной версии

- **Не удаляйте** приложение: установите новый `KatanaConnector.ipa` через Sideloadly поверх — тем же Apple ID.
- Подключение, очередь событий и результаты Capability Lab сохраняются (тот же Bundle ID).
- Если подпись сделана другим Apple ID, iOS может не дать прочитать прежнюю запись Keychain: Connector покажет «Сохранённое подключение недоступно» и предложит подключиться заново, без падения. Очередь при этом сохраняется.

## Проверка

- Автоматические проверки — unit-тесты в CI (`Tests/KatanaConnectorTests`).
- Полный ручной release checklist v0.1 (pairing, ссылки, cleanup, offline, kill, revoke, обновление, Capability Lab, приватность, smoke) — [`docs/TESTING.md`](docs/TESTING.md#release-checklist-v01).
