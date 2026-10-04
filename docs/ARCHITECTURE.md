# Архитектура

## Текущее состояние (v0.3 — Physical Triggers & Capture)

Один application target `KatanaConnector` (Bundle ID `app.katana.connector`) и unit-test target `KatanaConnectorTests`, iOS 16+, SwiftUI, проект генерируется XcodeGen из `project.yml`. Модули — папки (D-013), границы фреймворков — D-024.

```
Sources/
├── App/
│   ├── KatanaConnectorApp.swift      @main: собирает SweepStore, CleanupSessionRecorder, PairingCoordinator, EventDeliveryCoordinator, CapabilityLabCoordinator,
│   │                                 ActivityJournalCoordinator, LocationCheckInCoordinator, ReminderCoordinator (один API-клиент);
│   │                                 scenePhase active → appBecameActive + refreshAuthorizations + activity resume + reminder events retry;
│   │                                 background → activity suspend + сброс неподтверждённого check-in
│   └── RootView.swift                NavigationStack(path: AppNavigator.path), onOpenURL; pairing connected → delivery.pairingDidConnect
├── Core/
│   ├── Capabilities/
│   │   ├── CapabilityID / CapabilityModels / CapabilityRegistry   каталог и модели состояния          (Foundation)
│   │   ├── CapabilityProbeModels.swift   коды detail, mapping статусов, протоколы адаптеров (Void-API) (Foundation)
│   │   ├── CapabilityProbes.swift        CameraProbe, CurrentLocationProbe, MotionProbe, LocalNotificationsProbe (Foundation)
│   │   ├── CapabilitySnapshotStore.swift JSON-файл snapshots; provider реестра                     (Foundation)
│   │   └── CapabilityLabCoordinator.swift один запуск на probe, таймаут, отмена, refresh без запросов (Combine)
│   ├── Connector/ConnectorModels.swift   ConnectorConnectionState, ConnectorDeviceSummary, ConnectorJSON (Foundation)
│   ├── Pairing/
│   │   ├── PairingModels.swift       секреты (redacted), policy, payload, request/response, PairingCredentials(+requires_repair) (Foundation)
│   │   ├── PairingPayloadParser.swift   QR v1                                               (Foundation)
│   │   ├── PairingClient.swift       POST …/pairing/complete                                 (Foundation)
│   │   └── PairingCoordinator.swift  unpaired / requiresRepair / reviewing / pairing / connected / failed (Combine)
│   ├── Security/
│   │   ├── SecureTokenStoring.swift  протокол хранилища                                      (Foundation)
│   │   └── KeychainTokenStore.swift  единственное место с Security
│   ├── API/
│   │   ├── ConnectorTransport.swift  URLSession: ephemeral, без редиректов, ≤ 64 KiB         (Foundation)
│   │   ├── ConnectorAPIError.swift   классификация статусов                                  (Foundation)
│   │   ├── ConnectorAPIModels.swift  check / capability report / event batch, строгая проверка results (Foundation)
│   │   └── ConnectorAPIClient.swift  протокол ConnectorAPI + Bearer-клиент                   (Foundation)
│   ├── Storage/VersionedJSONFileStore.swift  общий JSON-файл v0.2: атомарно, file protection, без backup, quarantine, миграции; WholeSeconds (Foundation)
│   ├── Activity/
│   │   ├── ActivityModels.swift      категории, классификатор, ActivitySystem, snapshot, сессия (целые секунды), summary, файл v1 (Foundation)
│   │   └── ActivityJournalCoordinator.swift  проверка по кнопке, сессия только в foreground, interrupted, подтверждение (Combine)
│   ├── LocationCheckIn/
│   │   ├── LocationCheckInModels.swift   точность, корзины, округление, LocationFix (redacted), CheckInPreview, история v1 (Foundation)
│   │   └── LocationCheckInCoordinator.swift  When In Use по кнопке, предпросмотр ≤ 5 мин, подтверждение, очистка координат (Combine)
│   ├── Reminders/
│   │   ├── ReminderModels.swift      ReminderDraft (+ проверка ответа), typed errors, ReminderNotificationSystem, ReminderRecord, файл v1 (Foundation)
│   │   └── ReminderCoordinator.swift загрузка по кнопке, создание по кнопке (разрешение только тут), отмена, повтор событий (Combine)
│   ├── Routing/
│   │   ├── ConnectorURLRouter.swift  AppRoute, URL v1 (screenshot_cleanup | pairing) и v2 (activity_journal | location_check_in | reminder + draft_id) (Foundation)
│   │   └── AppNavigator.swift        единое состояние навигации; ссылка → [route]                   (Combine)
│   ├── Cleanup/
│   │   ├── CleanupSessionSummary.swift   агрегат сессии + CleanupSessionTracker (ID снимков только в памяти) (Foundation)
│   │   └── CleanupSessionRecorder.swift  явное завершение → одно событие; без доступа к медиатеке (Combine)
│   └── Events/
│       ├── ConnectorEvent.swift      envelope + JSONValue, описания без payload               (Foundation)
│       ├── ContextEvents.swift       ContextEventType (5 типов v0.2), ContextEventSchema (точные ключи), ConnectorEventSink (Foundation)
│       ├── ConnectionScope.swift     канонический base_url + device_id                        (Foundation)
│       ├── EventQueueStore.swift     JSON-файл v2, миграция v1 → legacy, атомарная запись, quarantine (Foundation)
│       ├── EventQueue.swift          actor: FIFO по scope, дедупликация, batch ≤ 20, лимиты, rejected (Foundation)
│       └── EventDeliveryCoordinator.swift  single-flight flush, backoff, 401, статус для UI     (Combine)
├── Features/
│   ├── Dashboard/DashboardView.swift     подключение / повторное подключение, синхронизация, функции, возможности
│   ├── Pairing/                      PairingView, QRScannerView, PairingConfirmationView (предупреждение о замене)
│   ├── CapabilityLab/                CapabilityLabView + адаптеры: Camera (AVFoundation), Location (CoreLocation),
│   │                                 Motion (CoreMotion), Notification (UserNotifications), ProbeOneShot
│   ├── ScreenshotCleanup/            SweepStore (+ уведомления recorder), ScreenshotCleanupViews, CleanupCompletionView
│   ├── ActivityJournal/              ActivityJournalView + SystemActivityAccess (CoreMotion → 6 флагов и уверенность)
│   ├── LocationCheckIn/              LocationCheckInView + SystemCheckInLocationAccess (CoreLocation, requestLocation)
│   └── Reminders/                    RemindersView, ReminderDraftView + SystemReminderNotifications (UserNotifications)
└── Shared/                           MessageView, EventDeliveryStatusLabel («ждёт отправки» / «отправлено» / «не принято»)
Config/KatanaConnector-Info.plist     CFBundleURLTypes (katana-connector), объединяется с генерируемым Info.plist
Tests/KatanaConnectorTests/           XCTest без host app; mock URLProtocol/ConnectorAPI, in-memory token store, временные каталоги
```

### Физические триггеры и захват v0.3 (D-045…D-053)

```
Sources/Core/ActionDrafts   ActionDraftModels (строгий парсер, TTL по server_time), ActionDraftCoordinator (один раз, обработчики по виду) (Combine)
Sources/Core/NFCActions     NFCActionModels (регистрация, ожидающие запуски, CoreNFCAvailability), NFCActionCoordinator  (Combine)
Sources/Core/Geofences      GeofenceRules (радиусы, 4 знака, лимит 20, префикс), GeofenceModels, GeofenceCoordinator     (Combine)
Sources/Core/Capture        CaptureKind, CaptureValidation (сигнатуры, лимиты, имена, SHA-256/CryptoKit), CaptureImageSanitizer (ImageIO),
                            CaptureInbox (manifest + payload, TTL, quarantine), CaptureEvents (upload API), CaptureCoordinator (Combine)
Sources/Features/ActionDrafts  ActionDraftView
Sources/Features/NFCActions    NFCActionsView, NFCActionPreviewView, SystemNFCTagAccess (CoreNFC, выключен без entitlement)
Sources/Features/Geofences     GeofencesView, SystemGeofenceAccess (единственное место с Always и регионами; также LocationAlwaysSystem)
Sources/Features/Capture       CaptureView (PhotosPicker, fileImporter, текст/URL)
Sources/ShareExtension         ShareViewController — target KatanaShareExtension (не встроен в IPA v0.3)

ссылка v3 → [actionDraft(id)] → «Загрузить» (GET action-drafts) → «Выполнить» → handler вида:
   nfc_action → NFCActionCoordinator (регистрация) | geofence_create → GeofenceCoordinator (Always → регион) |
   shared_capture → CaptureCoordinator (continuing → после загрузки completeDeferred) → action_draft.accepted
Команды/NFC → ссылка v3 nfc_action → [nfcActions, nfcActionPreview(id)] → open (без события) → «Выполнить»/«Отклонить» → nfc.action.completed
iOS region event (в т.ч. фоновый перезапуск) → SystemGeofenceAccess (delegate с запуска, буфер) → GeofenceCoordinator
   → pending transition на диск → geofence.transitioned (без координат)
Захват → CaptureValidator (+ очистка изображения) → inbox (pending_review) → preview → «Отправить» → повторная проверка
   → PUT /captures (отдельная upload-сессия 60/180 с) → object_ref → share.capture.created → файлы удалены
```

Приложение создаёт `SystemGeofenceAccess` в `init` (delegate назначен до любой сцены) и сразу вызывает `GeofenceCoordinator.start()`; Capability Lab использует тот же адаптер для probes `location_always`/`region_monitoring`. Координаторы v0.3 регистрируются в `ActionDraftCoordinator` как слабые обработчики.

### Контекст и действия v0.2 (D-037…D-044)

```
Dashboard «Функции» / ссылка v2 (только навигация) → экран функции
  Activity Journal:  «Определить текущую активность» → (Motion prompt, если не запрашивался) → одно чтение → категория
                     → «Отправить в Katana» → activity.snapshot.completed
                     «Начать сессию» → updates только в foreground → background: suspend (время → unknown)
                     → «Завершить» (summary + event_id, на диск) → «Отправить в Katana» → activity.session.completed
                     перезапуск с active-сессией → interrupted → «Завершить» / «Удалить без отправки»
  Location Check-in: «Определить текущее место» → (When In Use prompt) → одна фиксация → CheckInPreview (память, ≤ 5 мин)
                     → точность + label → «Отправить в Katana» → подтверждение → округление → location.check_in.created
                     → координаты стёрты из состояния; история без координат
  Reminders:         ссылка → [reminders, reminderDraft(id)] → «Загрузить напоминание» → GET reminder-drafts (Bearer)
                     → «Создать напоминание» → (Notifications prompt) → UNNotificationRequest app.katana.connector.reminder.<id>
                     → ReminderRecord (на диск) → reminder.local.scheduled; «Отменить» → reminder.local.cancelled
  все события: ContextEventSchema → ConnectorEventSink (EventDeliveryCoordinator) → EventQueue v2 (scope) → flush → events/batch
```

Адаптеры (`Features/*`) — единственные места с CoreMotion, CoreLocation и UserNotifications; в Core попадают только нейтральные значения: шесть флагов и уверенность активности (без времени и истории), широта/долгота/горизонтальная точность (без высоты, скорости, курса, этажа, времени фиксации). Координаторы v0.2 не знают про API-клиент событий, токен и scope — только `ConnectorEventSink`; `ReminderCoordinator` дополнительно получает `ReminderDraftFetching` (тот же `URLSessionConnectorAPIClient`). 401 при загрузке черновика → `sink.reportUnauthorized()` → тот же путь, что 401 при доставке (D-027).

### Capability Lab (D-034, D-035)

```
Dashboard «Capability Lab» → CapabilityLabView: 4 карточки, у каждой своя кнопка
  → CapabilityLabCoordinator.start(id)        (второй тап — ничего; другие probes не трогаются)
      availability (без запроса) → unsupported_device ⇒ failed/unavailable
      authorization (без запроса) → not_requested ⇒ свой системный запрос (только здесь)
      denied/restricted ⇒ failed/permission_*;  granted/limited ⇒ check() против таймаута
      адаптер: один кадр / одна фиксация / одно событие / одно уведомление → Void
  → CapabilitySnapshotStore.save (атомарно) → Dashboard (тот же store через registry)
  → onSnapshotsChanged → EventDeliveryCoordinator.reportCapabilities (если подключено)
Запуск / foreground → refreshAuthorizations: только availability + authorization, без запросов и probes
```

### Custom URL scheme (D-032)

```
Katana PWA → katana-connector://open?v=1&feature=… → iOS → SwiftUI onOpenURL (холодный и тёплый старт)
  → AppNavigator.handle → ConnectorURLRouter.parse (строго, offline)
      невалидно → ничего не меняется
      .open(feature) → path = [route] (если уже так — без изменений)
  → тот же экран, что с Dashboard: ScreenshotCleanupView / PairingView
     PhotoKit — только «Разрешить доступ к фото»; камера — только «Сканировать QR»
```

`AppNavigator` знает только про `path`: у него нет ссылок на pairing, очередь, API, PhotoKit или камеру.

### Screenshot Cleanup → Katana (D-031)

```
SweepStore.decide/undo/toggle/delete ──уведомления──▶ CleanupSessionRecorder (tracker: счётчики, ID только в памяти)
«Завершить разбор» → CleanupCompletionView (превью итога) → «Завершить»
  → recorder.complete(): summary (инварианты) → сессия закрыта → event screenshot_cleanup.completed
  → EventDeliveryCoordinator.enqueueCleanupEvent → scope текущего подключения → EventQueue (на диск) → flush
  → UI: «Результат сохранён для Katana» → «Результат отправлен в Katana» (по deliveredEventIDs)
```

PhotoKit по-прежнему меняется только в `SweepStore.deleteCandidates()`; recorder лишь получает уведомления.

### Доставка событий (D-025…D-030)

```
Feature → EventDeliveryCoordinator.enqueue(scope = api.currentScope()) → EventQueue (actor) → event-queue.json v2 (atomic)
                                  │
     launch / foreground / новое событие / «Синхронизировать»
                                  ▼
       requestFlush (single-flight) → nextBatch(scope, ≤20) → ConnectorAPI.sendEventBatch(scope) — сверка scope, иначе scopeMismatch
                                  │                       │ Keychain → Bearer → HTTPS → events/batch
                                  ▼                       ▼
       apply(results): accepted/duplicate → удалить; rejected → журнал без payload; нет результата → остаётся
       transport/429/5xx → backoff (≤ 5 попыток, ≤ 60 с, jitter) ; 401 → requiresRepair → PairingCoordinator.markRequiresRepair
```

### Pairing (D-019…D-021, D-023)

```
Dashboard «Подключить Katana» (или «Подключить Katana заново» после 401) → PairingView (объяснение)
  → «Сканировать QR» → AVCaptureDevice.requestAccess (только здесь) → QRScannerView
  → PairingCoordinator.handleScannedCode → PairingPayloadParser (схема, версия, HTTPS, код)
  → PairingConfirmationView: хост + имя устройства (+ предупреждение о замене) → «Подключить»
  → PairingCoordinator.confirm → PairingClient.completePairing (один раз, без редиректов)
  → SecureTokenStoring.save(PairingCredentials) → status .connected(PairedDevice)
Запуск: store.load(): есть → connected; есть с requires_repair → requiresRepair; нет → unpaired; ошибка → unpaired + notice
```

Публикуется только несекретное состояние. Код живёт в памяти координатора до однократной отправки; токен идёт из ответа прямо в Keychain и читается API-клиентом только перед запросом.

### Capability model (D-016, D-017)

```
CapabilityRegistry (struct, создаётся в App)
├── catalog: [CapabilityDescriptor]        id + title + category, стабильный порядок
└── provider: CapabilitySnapshotProviding  сейчас Static…; позже — реальные проверки / Capability Lab
        └── snapshot(for:) → CapabilitySnapshot { availability × authorization × probe_state, checked_at, detail }
```

Dashboard показывает итоговый статус, выведенный из трёх измерений: `planned` / `missing entitlement` / `unsupported` по `availability`, а для `available` — `untested` / `passed` / `failed` по `probe_state`.

Навигация: `RootView` → `DashboardView` → `NavigationLink(value: AppRoute.screenshotCleanup)` → `ScreenshotCleanupView`. Возврат — кнопка «Главная» в навбаре.

Ключевые свойства, которые нужно сохранить:

- **Разрешения:** Dashboard не запрашивает разрешений. PhotoKit запрашивается только в `ScreenshotCleanupView.onAppear` → `SweepStore.start()`. Создание `SweepStore` (на уровне приложения) разрешений не запрашивает.
- **Инвариант `SweepStore`:** `assets[0..<history.count]` — уже решённые, в порядке решений; `assets[history.count]` — текущий скриншот. `reload()` поддерживает инвариант при изменениях медиатеки.
- **Единственная точка изменения медиатеки:** `deleteCandidates()` → `PHPhotoLibrary.performChanges` → `PHAssetChangeRequest.deleteAssets`.
- **Подтверждения:** `ReviewView` → `confirmationDialog` → системный диалог iOS. `userCancelled` обрабатывается как «ничего не изменилось».
- Выборка: `mediaType == image` и `mediaSubtypes` содержит `photoScreenshot` (с повторной проверкой в коде), сортировка по `creationDate` по возрастанию.
- Каждые `batchSize = 30` решений открывается экран проверки (если есть кандидаты).

## Целевая архитектура

```
┌──────────────┐  custom URL scheme  ┌────────────────────────── Katana Connector ──────────────────────────┐
│  Katana PWA  │ ──────────────────▶ │  URLRouter ─▶ Feature (Screenshot Cleanup / Capability Lab / Pairing) │
│ (браузер)    │                     │                    │                                                  │
│  QR-код      │ ◀── сканирование ── │  Pairing ──▶ Keychain (device token)                                 │
└──────────────┘                     │                    ▼                                                  │
                                     │            EventQueue (persistent, idempotent)                        │
                                     │                    ▼                                                  │
                                     │            APIClient (HTTPS) ───────────────────────▶ Katana API      │
                                     └──────────────────────────────────────────────────────────────────────┘
```

### Модули (логические; физически — папки в одном target, D-013)

| Модуль | Ответственность | Зависит от |
|---|---|---|
| `App` | Точка входа, навигация, композиция зависимостей | все |
| `ConnectorCore` (`Sources/Core`) | Есть: capabilities, connector-модели, pairing, secure storage, API client, event queue и доставка | — |
| `Pairing` | Разбор QR-payload, обмен pairing-кода на device token, revoke | `ConnectorCore`, `APIClient`, `Keychain` |
| `Keychain` | Обёртка над Security framework для device token | — |
| `EventQueue` | Persistent-очередь событий: запись до отправки, повтор, дедупликация по `event_id` | `ConnectorCore` |
| `APIClient` | HTTPS-запросы к Katana API, авторизация токеном, разбор ответов | `ConnectorCore`, `Keychain` |
| `Routing` (`Sources/Core/Routing`) | `ConnectorURLRouter` (разбор URL v1) и `AppNavigator` (единое состояние навигации) | — |
| `Features/ScreenshotCleanup` | Исходный ScreenshotSweep (`SweepStore`, views) + формирование итогов сессии | `ConnectorCore`, `EventQueue` (через протокол) |
| `Features/CapabilityLab` | Независимые probes, отчёт о capabilities | `ConnectorCore` |
| `Features/ActivityJournal`, `Features/LocationCheckIn`, `Features/Reminders` (v0.2) | Экраны и системные адаптеры функций «Контекст и действия» | `ConnectorCore` (координаторы, `ConnectorEventSink`) |

Правила зависимостей:

- Функции (`Features/*`) не знают про `APIClient` и сеть — они только кладут события в очередь через протокол.
- Границы фреймворков в `Sources/Core` — D-024.
- PhotoKit используется только в `Features/ScreenshotCleanup`.
- Нет сторонних зависимостей. Модули — папки `Sources/App`, `Sources/Features/<Feature>`, `Sources/Shared` (только реально общее); новые папки создаются вместе с кодом, без пустых заготовок.

### Поток данных Screenshot Cleanup

1. Пользователь открывает Screenshot Cleanup с Dashboard (позже — и по URL из PWA, KC-007).
2. Вход в функцию только читает статус доступа; системный запрос — по кнопке «Разрешить доступ к фото» (D-033).
3. Первое решение начинает сессию (`session_id`, `started_at`).
4. Разбор как раньше; удаление — только через `deleteCandidates()` с двойным подтверждением.
5. «Завершить разбор» → «Завершить» формирует `screenshot_cleanup.completed` (только счётчики и время) и **атомарно** пишет его в очередь текущего подключения (D-029, D-031).
6. `EventDeliveryCoordinator` отправляет пакет, когда устройство подключено и есть сеть; удаляет событие из очереди только после ответа сервера (`accepted`, `duplicate` или окончательный `rejected`).

### EventQueue

- Хранение: файл в Application Support (Codable, атомарная запись) или SQLite из SDK — решается в KC-005. Без сторонних библиотек.
- Файл с `NSFileProtectionCompleteUntilFirstUserAuthentication` (или строже), исключён из бэкапа iCloud — решается в KC-005.
- Семантика доставки: at-least-once от клиента + дедупликация на сервере по `event_id` = effectively-once.
- Событие неизменяемо после записи. Повтор отправляет тот же `event_id` и тот же payload.
- Ретраи с экспоненциальной задержкой; 4xx (кроме 408/429) — не ретраить, пометить как отклонённое; 401 — перевести pairing в состояние «нужно перепривязать», очередь не терять.
- Лимит размера очереди и политика при переполнении — KC-005.

### Безопасность

- Device token — только Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, без синхронизации в iCloud Keychain).
- Только HTTPS; ATS без исключений.
- Входящие URL (scheme) и QR-payload — недоверенные: строгий парсинг, whitelist действий, лимиты длины, никакого удаления по URL.
- Логи — только агрегаты и коды ошибок (см. `CLAUDE.md`).
