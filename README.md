# Katana Connector

Нативное iOS-приложение-компаньон для Katana PWA: даёт Katana доступ к функциям iPhone, которых нет в браузере, и возвращает в Katana только агрегированные результаты. Продукт, архитектура, решения и план — в [`docs/`](docs/), правила работы — в [`CLAUDE.md`](CLAUDE.md).

```
Katana PWA → QR pairing → credentials в Keychain → katana-connector:// ссылка → функция (по кнопке, с подтверждением)
           → persistent очередь (по подключению) → authenticated API → результат в Katana
```

Текущий релиз — **v0.1.0** ([GitHub Release](https://github.com/lovejoy-goose/ScreenshotSweep/releases/tag/v0.1.0)); v0.2 «Context & Actions» слит в `main`. В работе — **v0.3 «Physical Triggers & Capture»** (Draft PR, `docs/TASKS.md`).

## Что добавляет v0.2 — Контекст и действия

- **Activity Journal** — «Определить текущую активность» (ходьба, бег, велосипед, транспорт, неподвижно, неизвестно) и ручные сессии активности, пока приложение открыто. В Katana — только вид активности и длительности, после кнопки «Отправить в Katana». Время в фоне честно считается «неизвестно».
- **Location Check-in** — «Определить текущее место» (только «При использовании», одна фиксация) → предпросмотр → «Приблизительно» (≈1 км) или «Точно» → отдельное подтверждение. Координаты до подтверждения живут только в памяти и после отправки стираются с экрана; высота, скорость и сырая точность не отправляются.
- **Локальные напоминания из Katana** — ссылка `katana-connector://open?v=2&feature=reminder&draft_id=<uuid>` без текста; черновик загружается кнопкой по защищённому соединению, уведомление создаётся кнопкой «Создать напоминание» (только тогда — запрос разрешения). Повторы не создают дублей; любое напоминание Connector можно отменить. В Katana — только факты «запланировано»/«отменено», без текста.
- **История** — у каждой функции свои последние результаты со статусом «ждёт отправки» / «отправлено» / «не принято»; доставка — та же offline-очередь.
- Ссылки v2 `…v=2&feature=activity_journal` и `…v=2&feature=location_check_in` только открывают экраны.

## Что входит в v0.1

- **Dashboard** — состояние подключения и синхронизации, функции, возможности устройства. Ничего не запрашивает при запуске.
- **Подключение к Katana по QR** — Katana показывает одноразовый QR; Connector показывает адрес Katana и имя iPhone до подтверждения; токен устройства хранится только в Keychain (на сервере — только его хеш). «Отключить на этом iPhone» удаляет локальные данные подключения. Если Katana отозвала устройство (401), Connector перестаёт использовать токен и предлагает подключиться заново.
- **Screenshot Cleanup** — разбор скриншотов (оставить / на удаление / отменить / проверка / удаление с подтверждением в приложении и системным диалогом iOS). По кнопке «Завершить разбор» в Katana уходит одно событие `screenshot_cleanup.completed` с семью полями: `session_id`, `started_at`, `completed_at`, `reviewed_count`, `kept_count`, `deletion_requested_count`, `deletion_completed`.
- **Ссылки из Katana** — `katana-connector://open?v=1&feature=screenshot_cleanup` и `katana-connector://open?v=1&feature=pairing` только открывают экран: без разрешений, удаления, подключения и сети.
- **Offline-очередь** — событие сначала записывается на iPhone, потом отправляется; переживает перезапуск и отсутствие сети; отправляется только тому подключению, для которого записано; повторная отправка использует тот же `event_id`, сервер отбрасывает дубликаты.
- **Capability Lab** — четыре ручные проверки: камера (один кадр, сразу отброшен), текущая геолокация (только «При использовании», координаты отброшены), датчики движения (данные отброшены), локальное тестовое уведомление. Каждая — только своей кнопкой и только со своим разрешением; в Katana уходят лишь состояния и безопасные коды.

## Что добавляет v0.3 — Физические триггеры и захват

- **Действия из Katana** — ссылка `katana-connector://open?v=3&feature=action&draft_id=<uuid>` открывает экран; «Загрузить действие» показывает, что предлагается, «Выполнить» — делает один раз.
- **NFC-действия** — метка через Команды (NFC → «Открыть URL» с ссылкой `…v=3&feature=nfc_action&action_id=<uuid>`) открывает preview; выполнение — только «Выполнить». UID и содержимое меток не сохраняются. Сканирование/запись меток в приложении (Core NFC) — в коде, но выключено до NFC-entitlement.
- **Геозоны** — до 20 своих геозон: «Определить текущее место» → имя и радиус → подтверждение → «Всегда» (только тут). Katana получает вход/выход и время без координат. Фонового трекинга нет.
- **Поделиться с Katana** — текст, ссылка, изображение (без EXIF/GPS), PDF, текстовый файл → preview → «Отправить в Katana». Системный пункт «Поделиться» (Share Extension) собран, включится после проверки App Group.
- Capability Lab: проверки «Всегда» и геозон; NFC, App Group и Share Extension честно показаны как `requires_entitlement`.

## Граница приватности

- В Katana **никогда** не уходят: фото, кадры, миниатюры, идентификаторы и имена файлов, EXIF, даты и геоданные снимков, сырые данные движения и временные ряды, высота/скорость/курс/этаж, текст системных ошибок, токены и коды подключения, текст напоминаний обратно в событиях.
- Координаты уходят только в Location Check-in — после предпросмотра и подтверждения, округлёнными.
- Токен — только в Keychain; в логи, файлы, UI и URL не попадает.
- Разрешения запрашиваются только кнопкой внутри соответствующей функции, по одному; ссылки ничего не запрашивают и не выполняют.
- Медиатека меняется только после экрана проверки, подтверждения в приложении и системного диалога iOS; файлы уходят в «Недавно удалённые».

## Ограничения v0.1

- Нет фоновой доставки (BackgroundTasks, push): события отправляются при запуске, возврате в приложение, после нового события и по «Синхронизировать».
- «Отключить на этом iPhone» не отзывает устройство на сервере — его нужно удалить в Katana вручную.
- Одно активное подключение на iPhone; события другого или прежнего подключения хранятся и автоматически не отправляются.
- Нет HealthKit, Bluetooth, фоновой геолокации (UIBackgroundModes), микрофона и речи, push, Universal Links и entitlements. Core NFC и встроенный Share Extension в v0.3 изолированы до проверки подписи (D-046); «Всегда» — только для геозон.
- Распространение — unsigned IPA + Sideloadly; с бесплатным Apple ID подпись действует 7 дней.

## Постоянный Bundle ID

Bundle ID — **`app.katana.connector`**, он не меняется. На нём держатся данные, которые обязаны пережить установку новой версии поверх старой:

| Данные | Где |
|---|---|
| Подключение (токен + адрес, id, имя, время) | Keychain, service `app.katana.connector.pairing`, account `device-credentials` |
| Очередь событий | `Application Support/KatanaConnector/EventQueue/event-queue.json` |
| Результаты Capability Lab | `Application Support/KatanaConnector/Capabilities/capability-snapshots.json` |
| Время последней синхронизации | `UserDefaults`, ключ `connector.lastSuccessfulSyncAt` |
| Activity Journal (v0.2) | `Application Support/KatanaConnector/ActivityJournal/activity-journal.json` |
| История check-in без координат (v0.2) | `Application Support/KatanaConnector/LocationCheckIn/check-ins.json` |
| Напоминания Connector (v0.2) | `Application Support/KatanaConnector/Reminders/reminders.json` |
| Выполненные Action Drafts (v0.3) | `Application Support/KatanaConnector/ActionDrafts/action-drafts.json` |
| NFC-действия (v0.3) | `Application Support/KatanaConnector/NFCActions/nfc-actions.json` |
| Геозоны (v0.3, округлённые координаты) | `Application Support/KatanaConnector/Geofences/geofences.json` |
| Захват: inbox и история (v0.3) | `Application Support/KatanaConnector/CaptureInbox/` |

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
- Единая итоговая ручная проверка v0.2 — [`docs/TESTING.md`](docs/TESTING.md#release-checklist-v02-одна-итоговая-ручная-проверка).
- Единая итоговая ручная проверка v0.3 (A–L) — [`docs/TESTING.md`](docs/TESTING.md#release-checklist-v03-одна-итоговая-ручная-проверка). Промежуточные IPA v0.3 устанавливать не нужно.
