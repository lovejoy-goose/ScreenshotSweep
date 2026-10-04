# Очередь задач

Правила (см. `CLAUDE.md`): брать одну задачу; не переходить к следующей самостоятельно; после выполнения — обновить статус и acceptance criteria здесь.

Статусы: `planned` → `in progress` → `in review` (код готов, ждёт CI/устройства) → `done` (или `blocked`).

| ID | Задача | Статус | Зависит от |
|---|---|---|---|
| KC-001 | Repository foundation | **done** | — |
| KC-002 | Rename and modular structure | **done** | KC-001 |
| KC-003 | Connector Core models and Capability Registry | **done** | KC-002 |
| KC-004 | QR pairing and Keychain | **done** | KC-003 |
| KC-005 | Persistent event queue and authenticated API client | **done** | KC-003, KC-004 |
| KC-006 | Screenshot Cleanup event integration | **done** | KC-005 |
| KC-007 | Custom URL scheme | **done** | KC-002, KC-004 |
| KC-008 | Capability Lab | **done** | KC-003, KC-005 |
| KC-009 | End-to-end validation and v0.1 release preparation | **done** | KC-004 … KC-008 |

Release **v0.1.0** опубликован 2026-10-04: tag `v0.1.0` → merge commit `1ea20c11f5385801c45c27bcf77e65c87bfb8d6b`, IPA из post-merge CI run 37159436900.

### Milestone v0.2 — Context & Actions (один Draft PR, D-037)

| ID | Задача | Статус | Зависит от |
|---|---|---|---|
| V2-001 | Product / API / security decisions | **done** | v0.1.0 |
| V2-002 | Shared models and storage | **done** | V2-001 |
| V2-003 | Activity Journal | **done** | V2-002 |
| V2-004 | Location Check-in | **done** | V2-002 |
| V2-005 | Local reminders from Katana drafts | **done** | V2-002 |
| V2-006 | Integration / regression / release validation | **done** (E2E на iPhone и Katana пройден; 2 post-merge проверки открыты) | V2-003 … V2-005 |

Весь milestone v0.2 — **done** (слит в `main` 2026-10-04, merge `43b4ca8`, post-merge CI run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37219737432); открытые post-merge проверки: баннер напоминания и `reminder.local.cancelled` (Release checklist v0.3, L). Ранее — код и CI зелёные (commit `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503, 244 unit-теста, IPA `katana-connector-unsigned-ipa`); `done` — только после одной итоговой проверки на реальном iPhone и Katana (`TESTING.md`, Release checklist v0.2).

---

## KC-001 Repository foundation

- **Статус:** done
- **Цель:** зафиксировать продукт, архитектуру, решения, API-контракт, правила работы и очередь задач до изменения кода.
- **Scope:** `CLAUDE.md`, `docs/PRODUCT.md`, `docs/ARCHITECTURE.md`, `docs/API.md`, `docs/TASKS.md`, `docs/DECISIONS.md`, `docs/TESTING.md`. Без изменений Swift-кода, `project.yml`, Bundle ID, target, CI, зависимостей.
- **Документы:** все вышеперечисленные, `README.md`.
- **Зависимости:** —
- **Acceptance criteria:**
  - [x] `CLAUDE.md` содержит постоянные правила работы (одна задача, без секретов, без логирования чувствительных данных, разрешения по действию, безопасное удаление PhotoKit, проверки и отчёт).
  - [x] Созданы шесть документов в `docs/`.
  - [x] Зафиксированы: один Bundle ID, одно приложение, Screenshot Cleanup первой функцией, Capability Lab как независимые probes, фото не загружаются, только итоги сессии, persistent и идемпотентная очередь, разрешения не все сразу, deferred-список.
  - [x] API описан концептуально, без окончательных URL.
  - [x] Swift-файлы, `project.yml`, Bundle ID и поведение приложения не изменены.
- **Заметки:** обнаружено отклонение — доступ к фото запрашивается при старте (`RootView.onAppear`); устранено в KC-002 (D-014).

## KC-002 Rename and modular structure

- **Статус:** done
- **Цель:** превратить проект в Katana Connector структурно: переименование, папки-модули, стартовый Dashboard; поведение Screenshot Cleanup не меняется.
- **Scope:**
  - Bundle ID `app.katana.connector`, display name «Katana Connector», target/scheme/product `KatanaConnector`, `@main` `KatanaConnectorApp` (D-012);
  - один target, модули — папки `App/`, `Features/Dashboard/`, `Features/ScreenshotCleanup/` (D-013);
  - Dashboard: «Katana не подключена», «Разобрать скриншоты», техблок Connector Core / Capability Lab — planned;
  - PhotoKit запрашивается только при входе в Screenshot Cleanup (D-014); кнопка «Главная» для возврата;
  - CI: `KatanaConnector.xcodeproj`, scheme `KatanaConnector`, `KatanaConnector.ipa`, artifact `katana-connector-unsigned-ipa`;
  - README и документация.
- **Вне scope:** сеть, pairing, новые разрешения, новые функции, изменения `SweepStore` и модели удаления.
- **Документы:** `DECISIONS.md` (D-012…D-015), `ARCHITECTURE.md`, `PRODUCT.md`, `TESTING.md`, `README.md`.
- **Зависимости:** KC-001.
- **Acceptance criteria:**
  - [x] Bundle ID выбран (`app.katana.connector`), записан в `DECISIONS.md` (D-012) и больше не планируется к изменению.
  - [x] Структура `Sources/` соответствует D-013, без пустых заготовок и SPM-пакетов.
  - [x] Dashboard не запрашивает разрешений и не обращается к сети; фиктивных подключений и токенов нет.
  - [x] PhotoKit запрашивается только при входе в Screenshot Cleanup.
  - [x] Логика `SweepStore` и модель удаления не изменены (файл только перемещён).
  - [x] `rg "ScreenshotSweep\|local\.sweep"` — только исторические упоминания и имя GitHub-репозитория.
  - [x] Проект генерируется XcodeGen и собирается в CI; артефакт `KatanaConnector.ipa` создаётся — оба CI-run на `1aeb84f` успешны (workflow_dispatch 37036895892, pull_request 37036928677).
  - [x] Ручная проверка на реальном iPhone (подтверждено пользователем): Katana Connector установлен; Dashboard открывается и не запрашивает PhotoKit; Screenshot Cleanup запрашивает PhotoKit только после входа; существующий cleanup-сценарий работает.
- **Заметки:** при входе в Screenshot Cleanup стандартная кнопка «Назад» скрыта и заменена на «Главная» (кнопка «Отменить» остаётся рядом); жест свайпа назад из-за этого недоступен. Состояние разбора живёт на уровне приложения и сохраняется при возврате на Dashboard.

## KC-003 Connector Core models and Capability Registry

- **Статус:** done
- **Цель:** типизированное ядро Connector и реестр capabilities без pairing, сети, Keychain, persistent queue и новых запросов разрешений.
- **Scope:**
  - `Sources/Core/Capabilities`: `CapabilityID` (18 id), `CapabilityAvailability`, `CapabilityAuthorization`, `CapabilityProbeState`, `CapabilityCategory`, `CapabilityDescriptor`, `CapabilitySnapshot`, `CapabilityRegistry`, `CapabilitySnapshotProviding`, `StaticCapabilitySnapshotProvider` (D-016, D-017);
  - `Sources/Core/Connector`: `ConnectorConnectionState`, `ConnectorDeviceSummary`, `ConnectorJSON` (ISO 8601);
  - Dashboard: блок «Возможности устройства» из registry (Фото, Текущая геолокация, Движение, Локальные уведомления, Фоновая геолокация, HealthKit);
  - target `KatanaConnectorTests` без host app (D-018); шаг unit-тестов в CI на динамически выбранном iPhone Simulator до device-сборки.
- **Вне scope:** QR pairing, Keychain, API client, URLSession, event queue и `ConnectorEvent`/`EventSink` (перенесены в KC-005), `CleanupSessionSummary` (KC-006), URL scheme, запросы разрешений, импорты HealthKit/Core NFC, Bluetooth.
- **Документы:** `DECISIONS.md` (D-016…D-018), `ARCHITECTURE.md`, `API.md` (capability report), `TESTING.md`.
- **Зависимости:** KC-002.
- **Acceptance criteria:**
  - [x] `Sources/Core` импортирует только Foundation (на момент KC-003; см. D-022).
  - [x] Модели Codable, Equatable, Sendable; стабильные snake_case wire values.
  - [x] Registry — единственный упорядоченный каталог; не singleton; provider подменяем.
  - [x] Начальные состояния: photos available/unknown/not_run; healthKit и coreNFC missing_entitlement; остальные planned.
  - [x] Unit-тесты: уникальность id, каждый id ровно один раз, стабильный порядок, round-trip snapshot, точные wire values, начальные состояния, round-trip `ConnectorDeviceSummary`, подмена provider.
  - [x] Dashboard берёт данные из registry и не запрашивает разрешений.
  - [x] Тесты и device-сборка зелёные в CI: commit `215d3a2890a8368c1a83252863c3ba9d8dce69d4`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37039526493 (11 unit-тестов, unsigned device build, `KatanaConnector.ipa`).

## KC-004 QR pairing and Keychain

- **Статус:** done
- **Цель:** безопасная клиентская часть QR pairing: сканирование → проверка QR → подтверждение хоста и имени → обмен одноразового кода → device token в Keychain.
- **Scope:**
  - `Core/Pairing`: `PairingCode`/`DeviceToken` (redacted), `PairingSecurityPolicy`, `PairingPayloadParser` (QR v1), `PairingClient` + `URLSessionPairingClient`, `PairingCoordinator`;
  - `Core/Security`: `SecureTokenStoring`, `KeychainTokenStore`;
  - `Features/Pairing`: `PairingView`, `QRScannerView` (AVFoundation), `PairingConfirmationView`; `MessageView` перенесён в `Shared/`;
  - Dashboard: «Подключить Katana» / connected-карточка / «Отключить на этом iPhone»;
  - `NSCameraUsageDescription`; решения D-019…D-022; предварительный контракт v1 в `API.md`.
- **Вне scope:** серверный revoke, event queue, capability probes, Screenshot Cleanup events, URL handler, OAuth, background tasks, серверные изменения.
- **Документы:** `API.md` (QR v1, pairing complete), `DECISIONS.md` (D-019…D-022), `ARCHITECTURE.md`, `TESTING.md`.
- **Зависимости:** KC-003.
- **Acceptance criteria:**
  - [x] QR v1 валидируется строго: схема/хост/версия, код, `base_url` (HTTPS, без credentials/query/fragment); ошибки различимы.
  - [x] Хост и редактируемое имя устройства показываются до отправки кода; код отправляется один раз.
  - [x] Токен хранится только в Keychain (`AfterFirstUnlockThisDeviceOnly`), не попадает в логи/UserDefaults/`@Published`/UI; описания моделей редактированы (тест).
  - [x] Отсутствующий/нечитаемый Keychain → `unpaired` с предложением подключиться заново.
  - [x] «Отключить на этом iPhone» удаляет локальные credentials после подтверждения; текст честно говорит, что сервер не уведомляется.
  - [x] Камера запрашивается только по «Сканировать QR»; добавлен `NSCameraUsageDescription`; других entitlements нет.
  - [x] Unit-тесты (mock URLProtocol, in-memory store) — 15 обязательных сценариев.
  - [x] Тесты и device-сборка зелёные в CI: commit `bef08be70f9d86421131ea2c618c54e28544c170`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37041865982 (35 unit-тестов).
  - [x] End-to-end pairing с реальным Katana endpoint выполнен 2026-10-02 (подтверждено пользователем): Katana создала устройство со статусом active, сервер хранит только SHA-256-хеш device token, Connector сохранил credentials в Keychain и показывает connected.
  - [x] Ручной чек-лист Pairing на устройстве (подтверждено пользователем вместе с e2e).

## KC-005 Persistent event queue and authenticated API client

- **Статус:** done
- **Цель:** надёжный авторизованный API-клиент и постоянная идемпотентная очередь событий без интеграции со Screenshot Cleanup.
- **Scope:**
  - `Core/API`: `ConnectorTransport` (без редиректов, ≤ 64 KiB), `ConnectorAPIError`, модели check / capability report / event batch, `URLSessionConnectorAPIClient` (Bearer из Keychain перед каждым запросом);
  - `Core/Events`: `ConnectorEvent` + `JSONValue`, `EventQueueStore` (JSON-файл, атомарно, file protection, без backup, quarantine), `EventQueue` (actor, FIFO, дедупликация, лимиты, rejected-журнал), `EventDeliveryCoordinator` (триггеры, single-flight, backoff, 401);
  - `PairingCredentials.requires_repair`, `PairingCoordinator.requiresRepair` и повторное pairing с подтверждением замены;
  - Dashboard: статус подключения/повторного подключения, последняя синхронизация, очередь, «Проверить соединение», «Синхронизировать»;
  - решения D-023…D-028, маршруты в `API.md`.
- **Вне scope:** Screenshot Cleanup и реальные события, URL scheme, Capability Lab, HealthKit/Core NFC/Bluetooth, BackgroundTasks/background URLSession, серверный revoke, новые разрешения, зависимости.
- **Документы:** `API.md`, `ARCHITECTURE.md`, `DECISIONS.md` (D-023…D-028), `TESTING.md`.
- **Зависимости:** KC-003, KC-004.
- **Acceptance criteria:**
  - [x] Очередь: один файл, атомарная запись, actor, FIFO, уникальный `event_id`, batch ≤ 20, удаление только после accepted/duplicate/rejected, retryable-ошибки сохраняют события, повреждённый файл сохраняется (quarantine) с typed error, без backup, file protection, без токенов, лимиты зафиксированы и протестированы.
  - [x] API client: три маршрута, Bearer, Accept/Content-Type, HTTPS по policy, без редиректов, timeout 15 с, ответ ≤ 64 KiB, ISO 8601 с дробными секундами, typed errors, строгая проверка results.
  - [x] 401: сеть прекращается, credentials помечаются и больше не используются, очередь сохраняется, UI «Подключите Katana заново».
  - [x] Доставка: триггеры launch/foreground/новое событие/кнопка; один flush; backoff с cap и jitter через injectable sleeper; отмена не удаляет события; без BackgroundTasks.
  - [x] Dashboard показывает честный статус без токена и сырых ошибок; новых разрешений нет.
  - [x] Unit-тесты по 26 обязательным сценариям.
  - [x] Тесты и device-сборка зелёные в CI: commit `bc9155df1edccf1db30c1c5c51e022013bc093de`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37049709345 (74 unit-теста).
  - [x] Проверка на реальном iPhone 2026-10-02 (подтверждено пользователем): connection/check успешно; capability report принят, сервер получил все 18 capabilities; lastSeen обновился; persistent queue отображается (0 событий). Event batch и 401 проверяются вместе с KC-006 на настоящем событии.
- **Заметки:** Q-5 (события после повторного pairing) закрыт в KC-006, D-029.

## KC-006 Screenshot Cleanup event integration

- **Статус:** done
- **Цель:** подключить Screenshot Cleanup к persistent event queue и впервые доставить реальное пользовательское событие в Katana; привязать очередь к подключению (Q-5).
- **Scope:**
  - `ConnectionScope`, очередь v2 со scope, миграция v1 → `legacy_events`, flush только текущего scope, проверка scope в API-клиенте (D-029, D-030);
  - `CleanupSessionSummary`, `CleanupSessionTracker`, `CleanupSessionRecorder`; событие `screenshot_cleanup.completed` (D-031);
  - `SweepStore`: только уведомления recorder (решение, undo, toggle, начало/итог удаления, изменение медиатеки); модель удаления не изменена;
  - UI: «Завершить разбор», экран итога со статусом Katana; Dashboard — события текущего подключения и «ждут решения».
- **Вне scope:** новые разрешения, BackgroundTasks, WebSocket, push, deep links/remote commands, загрузка изображений, зависимости, изменения серверного API, KC-007.
- **Документы:** `API.md` (событие), `ARCHITECTURE.md`, `DECISIONS.md` (D-029…D-031), `TESTING.md`.
- **Зависимости:** KC-005.
- **Acceptance criteria:**
  - [x] Событие записывается со scope текущего подключения; flush отправляет только его; чужие scope и legacy не отправляются и не удаляются; повторное pairing к тому же scope сохраняет очередь.
  - [x] Миграция `event-queue.json` v1 → v2 без потери событий (legacy + backup исходного файла).
  - [x] `CleanupSessionSummary` только с агрегатами; инварианты проверяются; недостоверные значения не отправляются.
  - [x] Событие только после явного завершения; один `session_id` → максимум одно событие; отмена/выход ничего не создают; сначала очередь, потом flush; offline/ошибка очереди не мешают завершению и не влияют на PhotoKit.
  - [x] UI: «Результат сохранён для Katana» / «Результат отправлен в Katana» / безопасная ошибка; без event_id, scope, токенов и сырых ошибок.
  - [x] Unit-тесты по 18 обязательным сценариям.
  - [x] Тесты и device-сборка зелёные в CI: commit `920dd82d8817dd19ae630e9c9a130a724c5cfc20`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37054897708 (95 unit-тестов).
  - [x] Настоящее событие доставлено с реального iPhone 2026-10-03 (подтверждено пользователем): Katana получила ровно одно `screenshot_cleanup.completed` с `reviewed_count=5`, `kept_count=5`, `deletion_requested_count=0`, `deletion_completed=true`; payload содержал только 7 разрешённых полей; фото, PHAsset identifiers и метаданные не передавались; результат виден в Settings → Devices → iPhone Connector.

## KC-007 Custom URL scheme

- **Статус:** done
- **Цель:** безопасно открывать разрешённые экраны Connector из Katana PWA.
- **Scope:**
  - `CFBundleURLTypes` (`katana-connector`) в `Config/KatanaConnector-Info.plist`, `INFOPLIST_FILE` в `project.yml`, проверка схемы в CI;
  - `Core/Routing`: `AppRoute`, `ConnectorURLFeature`, `ConnectorURLAction`, `ConnectorURLError`, `ConnectorURLRouter` (строгий парсер v1), `AppNavigator` (единое состояние навигации);
  - `RootView`: `NavigationStack(path:)` + `onOpenURL` (холодный и тёплый старт);
  - Screenshot Cleanup: PhotoKit только по кнопке «Разрешить доступ к фото» (D-033), чтобы вход по ссылке ничего не запрашивал;
  - решения D-032, D-033; формат в `API.md`.
- **Вне scope:** Universal Links, Associated Domains, remote commands, автоматический pairing, передача секретов, новые разрешения, зависимости, изменения event queue и PhotoKit deletion flow, KC-008.
- **Документы:** `API.md`, `ARCHITECTURE.md`, `DECISIONS.md` (D-032, D-033), `TESTING.md`.
- **Зависимости:** KC-002, KC-004.
- **Acceptance criteria:**
  - [x] Схема зарегистрирована; `open?v=1&feature=screenshot_cleanup|pairing` открывает те же экраны, что Dashboard.
  - [x] Строгая валидация (длина, ASCII, scheme/host/path, без user/password/port/fragment, `v` и `feature` ровно по разу, без других параметров и пустых значений); pairing QR роутером не принимается.
  - [x] Ссылка не удаляет, не начинает pairing, не передаёт credentials, не запрашивает разрешения, не отправляет события и не запускает flush.
  - [x] Единое состояние навигации; повтор ссылки не дублирует экран; невалидная ссылка ничего не меняет; поведение при открытом modal детерминировано.
  - [x] Unit-тесты по 25 обязательным сценариям.
  - [x] Тесты и device-сборка (с проверкой схемы в Info.plist) зелёные в CI: commit `ba3d5c28b98920cd793503a5854f7cbd6131ed2b`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37153466168 (110 unit-тестов).
  - [x] Обе ссылки проверены на реальном iPhone 2026-10-04 (подтверждено пользователем): `screenshot_cleanup` открывает Screenshot Cleanup, `pairing` — безопасный экран подключения; холодный и тёплый запуск работают; камера, PhotoKit, pairing, удаление и отправка событий автоматически не запускаются; кнопка и QR развёрнуты в Katana.

## KC-008 Capability Lab

- **Статус:** done
- **Цель:** четыре независимых ручных probes — Camera, Current Location (When In Use), Motion, Local Notifications (Q-8, D-034).
- **Scope:**
  - Core (Foundation): `CapabilityProbeDetail`, `CapabilityProbeError`, нейтральные статусы и `CapabilityAuthorizationMapping`, протоколы адаптеров с Void-API, `CameraProbe`/`CurrentLocationProbe`/`MotionProbe`/`LocalNotificationsProbe`, `CapabilitySnapshotStore`; `CapabilityLabCoordinator` (Combine);
  - Features: адаптеры AVFoundation/CoreLocation/CoreMotion/UserNotifications, `CapabilityLabView`;
  - Dashboard: кнопка «Capability Lab», состояния четырёх probes; `AppRoute.capabilityLab` (без URL);
  - `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`, обновлённый текст камеры; проверки ключей в CI;
  - capability report после probe; refresh статусов при запуске/foreground без запросов.
- **Вне scope:** Bluetooth, микрофон/речь, фоновая геолокация, геозоны, HealthKit, Core NFC, Contacts/Calendar/Reminders, Local Network, Share Extension, push/APNs, BackgroundTasks, зависимости, URL для Capability Lab, KC-009.
- **Документы:** `PRODUCT.md`, `API.md`, `ARCHITECTURE.md`, `DECISIONS.md` (D-034, D-035), `TESTING.md`.
- **Зависимости:** KC-003, KC-005.
- **Acceptance criteria:**
  - [x] Четыре probe; каждый — своей кнопкой, своё разрешение, один запуск одновременно, таймаут, отмена, обновляет только свой snapshot.
  - [x] Единое строгое отображение статусов; wire values `CapabilityAuthorization` не изменены; `detail` — только коды `CapabilityProbeDetail`.
  - [x] Persistent store: только snapshots и версия, атомарно, без падений на битых данных, переживает перезапуск; реестр — единственный каталог.
  - [x] Foreground: только availability/authorization, без запросов и probes, без подделки результатов.
  - [x] Privacy: кадры, координаты, данные движения и текст уведомлений не сохраняются, не показываются и не отправляются; Always-геолокации нет.
  - [x] Report после probe; ошибка сети не теряет результат; probes не создают событий.
  - [x] Dashboard: кнопка и состояния, без запросов и запуска probes; HealthKit/Core NFC — missing_entitlement; background_location — planned.
  - [x] Unit-тесты по 40 обязательным сценариям (mocks, без hardware).
  - [x] Тесты и device-сборка (с проверкой usage descriptions) зелёные в CI: commit `4a5c33ffcea9897f7f375f01afa6de871f3a3a6c`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37155488985; исправление гонки `e37dbbb6ba5735da20ece8d3c11e88d44b0b2210`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37156582212 (149 unit-тестов).
  - [x] Ручная проверка на реальном iPhone 2026-10-04 (подтверждено пользователем): камера, текущая геолокация, Motion и локальные уведомления прошли; Katana получила только безопасные состояния, время и allowlisted detail-коды; координаты, кадры, Motion samples и сырые ошибки не передавались; после исправления и foreground-проверки сервер подтвердил `current_location`: `available / granted / passed / location_fix_received`.
- **Заметки:** на iPhone найдена гонка: foreground-refresh, начавший читать статусы до probe, после завершения probe записал устаревшее `authorization = not_requested` поверх `granted/passed` (current_location). Исправлено в `fix: prevent stale capability refresh overwrite`: поколение (CAS) на каждую capability — увеличивается при старте probe и каждой записи; refresh пишет только если поколение не изменилось с начала чтения и probe не идёт; более поздний refresh обновляет статус честно.

## KC-009 End-to-end validation and v0.1 release preparation

- **Статус:** done — release validation v0.1 пройдена 2026-10-04
- **Цель:** подготовить и зафиксировать финальную проверку всей вертикали v0.1: Katana PWA → QR pairing → Keychain → custom URL → Screenshot Cleanup → persistent scoped queue → authenticated event API → результат в Katana.
- **Scope:** финальные регрессии (`ConnectorReleaseValidationTests`), запись запросов в mock-сети для побайтового privacy-аудита, стабильность идентификаторов хранения (D-036), README, release checklist A–J в `TESTING.md`. Исправление только реально найденных дефектов v0.1.
- **Вне scope:** новые capabilities, события, URL routes, BackgroundTasks, push, расширения, серверные изменения, зависимости, изменения API-контракта.
- **Документы:** `README.md`, `TESTING.md` (release checklist), `DECISIONS.md` (D-036), `CLAUDE.md`.
- **Зависимости:** KC-004 … KC-008.
- **Результат аудита кода:** блокирующих дефектов v0.1 не найдено (проверены: запись в очередь до отправки, повтор того же `event_id` после перезапуска, обработка отмены во время отправки, 401 → флаг в Keychain → отсутствие сети после перезапуска, состояние repair, scope при повторном pairing). Продуктовый код не менялся.
- **Acceptance criteria:**
  - [x] Автоматически: happy path; exact-once (двойное завершение, повторное открытие, `duplicate`, retryable с тем же `event_id`, тот же `event_id` после перезапуска); offline → online (диск, FIFO, только подтверждённое, scope); kill во время отправки; revoke/401 и повторное pairing к тому же и другому scope; стабильные идентификаторы хранения; ссылки; побайтовый privacy-аудит тел запросов; регрессии capabilities.
  - [x] README и release checklist A–J с полями для записи результата.
  - [x] Тесты и device-сборка зелёные в CI: commit `228bd640234759e0880df2bd2d8b060146a6a1f3`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37157879782 (162 unit-теста).
  - [x] A. Fresh pairing — повторное pairing после revoke успешно; новое устройство active, старое revoked (первичное pairing — KC-004).
  - [x] B. Deep links — проверены в KC-007 (2026-10-04); схема в финальной сборке не менялась.
  - [x] C. Screenshot Cleanup — по одному событию на сессию (2/2/0, 1/1/0), корректные счётчики.
  - [x] D. Offline → online — событие 2/2/0 создано offline, пережило перезапуск, принято после восстановления сети; `event_id` сохранился, дублей нет.
  - [x] E. Kill during delivery — перезапуск с неподтверждённым событием: без потерь, тот же `event_id`, одна запись в Katana.
  - [x] F. Revoke — 401 → `requires_repair`; после перезапуска отозванный токен не использовался; повторное pairing успешно.
  - [x] G. Update over existing app — финальный IPA поверх; Bundle ID `app.katana.connector` не изменился; Keychain, Capability Lab и локальные данные сохранились.
  - [x] H. Capability Lab — результаты сохранились; capability report содержит 18 capabilities (probes — KC-008).
  - [x] I. Privacy / network verification — подтверждено пользователем и Katana: ровно 7 разрешённых полей payload; фото, идентификаторы и метаданные не передавались.
  - [x] J. Final smoke test — ровно одно событие 1/1/0; повторная синхронизация без дубля.
- **Заметки:** ручная проверка 2026-10-04 подтверждена пользователем и Katana (детали — `TESTING.md`, Release checklist v0.1). После закрытия KC-009 Draft PR #1 переводится в Ready for review; слияние — отдельным решением.

---

# Milestone v0.2 — Context & Actions

Один Draft PR `Katana Connector v0.2 — Context & Actions` из ветки `feature/katana-connector-v0.2-context-actions` (D-037). Внутренние задачи коммитятся отдельно, но промежуточные IPA не устанавливаются: ручная проверка одна — в конце (`TESTING.md`, Release checklist v0.2).

## V2-001 Product / API / security decisions

- **Статус:** done
- **Цель:** до кода зафиксировать продукт, решения, wire formats, deep links, API черновиков и границы приватности v0.2.
- **Scope:** `DECISIONS.md` (D-037…D-044), `API.md` (маршрут 7, ссылки v2, пять событий, серверный контракт), `PRODUCT.md`, `TASKS.md`, `CLAUDE.md`.
- **Документы:** все `docs/`, `CLAUDE.md`.
- **Acceptance criteria:**
  - [x] Решения v0.2 записаны; v0.1 wire formats и storage identifiers не меняются.
  - [x] Точные wire formats пяти событий, ссылки v2, контракт `reminder-drafts`.
  - [x] Зелёный CI на коммите: `0110d9e`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37160530016.

## V2-002 Shared models and storage

- **Статус:** done
- **Цель:** общая инфраструктура для трёх функций без новой очереди.
- **Scope:** `VersionedJSONFileStore` (атомарно, file protection, без backup, quarantine, миграции); `ContextEventSchema` (точные ключи payload по типу, проверка до enqueue); `ConnectorEventSink` + статус доставки по `event_id` в `EventDeliveryCoordinator`; URL v2 и новые `AppRoute`.
- **Acceptance criteria:**
  - [x] Хранилище: missing → пусто, битый JSON / неизвестная версия → quarantine без удаления и падения, атомарная запись, file protection, без backup.
  - [x] Схема событий отклоняет лишние/недостающие ключи.
  - [x] Строгий парсер v2; v1 не изменился; ссылки только навигация.
  - [x] Зелёный CI (итог: `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503).

## V2-003 Activity Journal

- **Статус:** done
- **Scope:** Core: категории, классификатор, `ActivitySystem` (Void-free, но без времени и истории), сессия (целые секунды, монотонно), `ActivityJournalStore` v1, `ActivityJournalCoordinator`; Features: адаптер CoreMotion, экран; события `activity.snapshot.completed`, `activity.session.completed`.
- **Acceptance criteria:**
  - [x] Разрешение только по кнопке; denied/restricted/unsupported честно.
  - [x] Детерминированное правило флагов; агрегаты и инварианты; double finish без дубля; interrupted после relaunch; удаление без события.
  - [x] Offline/retry с тем же `event_id`; нет raw samples.
  - [x] Зелёный CI (итог: `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503).

## V2-004 Location Check-in

- **Статус:** done
- **Scope:** Core: точность, корзины, округление, `CheckInLocationSystem`, `CheckInHistoryStore` v1, `LocationCheckInCoordinator`; Features: адаптер CoreLocation (только When In Use и `requestLocation`), экран; событие `location.check_in.created`.
- **Acceptance criteria:**
  - [x] When In Use только по кнопке; denied/restricted/services disabled.
  - [x] Предпросмотр и подтверждение до события; отмена без события; координаты очищаются; срок предпросмотра 5 минут.
  - [x] Округление 2/6 знаков; корзины точности; нет запрещённых полей; история без координат.
  - [x] Offline/relaunch/exact-once; scope isolation.
  - [x] Зелёный CI (итог: `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503).

## V2-005 Local reminders from Katana drafts

- **Статус:** done
- **Scope:** Core: `ReminderDraft` + проверка ответа, `GET reminder-drafts` в API-клиенте (typed errors), `ReminderNotificationSystem`, `ReminderStore` v1, `ReminderCoordinator`; Features: адаптер UserNotifications, экраны списка и черновика; события `reminder.local.scheduled`, `reminder.local.cancelled`.
- **Acceptance criteria:**
  - [x] Ссылка только открывает экран; загрузка — кнопкой; Bearer/size/redirect/ошибки.
  - [x] Разрешение только после «Создать напоминание»; детерминированный идентификатор; без дублей; отмена только своих уведомлений.
  - [x] События без title/body; persistence/relaunch; 401 → requires_repair без повторов.
  - [x] Зелёный CI (итог: `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503).

## V2-006 Integration / regression / release validation

- **Статус:** done — основной E2E на iPhone и Katana пройден (подтверждено пользователем 2026-10-04); post-merge: баннер напоминания и `reminder.local.cancelled`
- **Scope:** Dashboard «Функции», App-композиция и lifecycle, Info.plist-тексты, версия 0.2.0, сквозные тесты v0.2 (privacy request-body audit, scope, revoke/repair, стабильность идентификаторов), README/ARCHITECTURE/TESTING, единый ручной checklist v0.2.
- **Acceptance criteria:**
  - [x] Все тесты v0.1 зелёные; v1 ссылки, Screenshot Cleanup, Capability Lab не сломаны.
  - [x] Info.plist без Always/background modes; без entitlements; Core без hardware-фреймворков.
  - [x] Зелёный CI, финальный IPA: `be50195`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37162181503 (244 unit-теста).
  - [x] Итоговая ручная проверка на реальном iPhone и Katana — основной E2E пройден (подтверждено пользователем); открыты post-merge: фактический показ баннера и `reminder.local.cancelled`.

### Заметки v0.2

- **Найденные и исправленные дефекты:** (1) `NSDecimalNumber.doubleValue` неточен (55.76 → 55.760000000000005) — все check-in отклонялись проверкой payload; исправлено в `fix: round check-in coordinates exactly` (обнаружено тестами, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37161269327). (2) Нестабильный тест v0.1 `testCapabilityReportBodyIsClean`: отложенный capability report предыдущего теста попадал в общий mock — тест выбирает свой запрос (`test: isolate capability report audit…`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37161479330). (3) Ожидание теста: `{…}` в `draft_id` отклоняется ещё до проверки UUID (недопустимые символы URL) — тест уточнён (run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37161821500).
- **Вне scope (не делалось):** реальный foreground-показ уведомлений (без `UNUserNotificationCenterDelegate` iOS не показывает баннер, пока приложение открыто — честно сказано в checklist); серверная реализация Katana (контракт — `API.md`); ручная обработка событий чужих scope (Q-9).

---

# Milestone v0.3 — Physical Triggers & Capture

Один Draft PR `Katana Connector v0.3 — Physical Triggers & Capture` из ветки `feature/katana-connector-v0.3-physical-triggers-capture` (D-045). Промежуточные IPA не устанавливаются; ручная проверка одна (`TESTING.md`, Release checklist v0.3).

| ID | Задача | Статус |
|---|---|---|
| V3-001 | Spike, decisions, API contract | **done** |
| V3-002 | Action Draft infrastructure + URL v3 | **done** |
| V3-003 | NFC actions (Shortcuts + Core NFC за capability) | **done** |
| V3-004 | Local geofences | **done** |
| V3-005 | Capture: in-app + Share Extension target | **done** |
| V3-006 | Capability Lab, Dashboard, integration/regression | **done** |
| V3-007 | CI status, docs | **in review** |
| V3-009 | Opt-in «Выполнять сразу после открытия» для NFC-действий (D-055) | in progress |
| V3-008 | HTTPS-мост для постоянных NFC-меток (D-054) | in progress (клиент и контракт готовы; сервер Katana — ждёт доступа к репозиторию) |

Весь milestone v0.3 — **in review**: CI зелёный (commit `b9f6d73`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37223875825 — 307 unit-тестов, unsigned .app, отдельная сборка Share Extension, IPA `katana-connector-unsigned-ipa`). `done` — только после одной итоговой проверки на реальном iPhone и Katana (Release checklist v0.3) и реализации серверного контракта Katana.

## V3-001 Spike, decisions, API contract
- **Статус:** done
- **Acceptance criteria:**
  - [x] Результаты spike (Core NFC, Share Extension/App Group, region monitoring/Always/background) и изоляция entitlements — D-046.
  - [x] Решения D-045…D-053; контракт маршрутов 8–9, ссылок v3, семи событий, capability ID — `API.md`.
  - [x] Зелёный CI: `d47e442`, run https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37221644612.

## V3-002 Action Draft infrastructure + URL v3
- **Статус:** done
- **Acceptance criteria:** строгий парсер v3; `GET action-drafts` со строгой схемой, TTL по `server_time`, typed errors, redirect/size; локальная защита от повторного выполнения; `action_draft.accepted`; ссылка только открывает экран.

## V3-003 NFC actions
- **Статус:** done
- **Acceptance criteria:** регистрация из черновика; preview/«Выполнить»/«Отклонить»; disabled/expired/unknown; дубль касания; восстановление ожидающего запуска (`interrupted`); `nfc.action.completed`; Core NFC за `requires_entitlement`; нет UID/NDEF в событиях и файлах; настройка Shortcuts в документации и UI.

## V3-004 Local geofences
- **Статус:** done
- **Acceptance criteria:** When In Use → preview → подтверждение → Always только тут; округление 4 знака; лимит 20; включение/выключение/удаление; сверка с системой; enter/exit без координат, дедупликация, сохранение до enqueue; offline/relaunch; `geofence.created/transitioned/removed`.

## V3-005 Capture
- **Статус:** done
- **Acceptance criteria:** пять видов, allowlist и сигнатуры, лимиты, имена и path traversal, очистка метаданных изображений, inbox (TTL, лимиты, quarantine, восстановление), preview/подтверждение/отмена, `PUT captures`, события без содержимого, удаление временных файлов; Share Extension target собирается в CI и не встроен.

## V3-006 Capability Lab, Dashboard, integration/regression
- **Статус:** done
- **Acceptance criteria:** новые capability ID и два probe (Always, region monitoring) только по кнопке; Dashboard; сквозные тесты v0.3 (privacy byte audit, exact-once, 401/re-pair, scope, идентификаторы v0.1/v0.2/v0.3, Info.plist, entitlements, фреймворки, упаковка); все тесты v0.1/v0.2 зелёные.

## V3-007 CI status, docs
- **Статус:** in review — ждёт итоговой ручной проверки
- **Acceptance criteria:** README, ARCHITECTURE, TESTING (Release checklist v0.3 A–L), статусы и ссылки CI. Ручные пункты не отмечаются без проверки пользователя.

### Заметки v0.3

- **CI по коммитам:** `d47e442` docs ✅ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37221644612 (244); `d8d3809` action drafts ❌ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37221912886 (дефект теста 1); `04a3488`+`3d2bb54` NFC ✅ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37222274317 (268 тестов); `159cc93` geofences ✅ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37222825204 (280); `c83872e` capture ❌ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37223375461 (дефект теста 2); `1cd9cf0`+`b9f6d73` validation ✅ https://github.com/lovejoy-goose/ScreenshotSweep/actions/runs/37223875825 (307).
- **Найденные и исправленные дефекты:** (1) тест повтора `action_draft.accepted` создавал обработчик inline, а координатор держит обработчики слабо — объект освобождался (исправлен тест; поведение слабой ссылки задокументировано); (2) ожидание теста: URL длиннее 2048 байт отсекается лимитом размера (`tooLarge`) раньше разбора; (3) найдено при проектировании: `completeDeferred` требовал черновик в памяти — после перезапуска `shared_capture` не помечался бы выполненным; теперь достаточно `draft_id` и вида; (4) протокольный метод `requestAlwaysAuthorization()` в Core нарушал правило «Always только в адаптере» — переименован в `requestAlwaysPermission()`.
- **Изолировано из-за entitlement (D-046):** Core NFC чтение/запись (`requires_entitlement`), App Group и встроенный Share Extension. Работают: Shortcuts + NFC, геозоны (Always без entitlement), «Поделиться с Katana» в приложении.
- **Ручные пункты Release checklist v0.3 не отмечены** — только после проверки пользователем.

## V3-008 HTTPS-мост для постоянных NFC-меток (D-054)
- **Статус:** in progress — клиентская часть, контракт, эталонная страница и инструкция готовы; серверная реализация и деплой Katana не выполнены (нет доступа к серверному репозиторию).
- **Цель:** наклейки ISO 14443-4 / Type A / IsoDep, которые Команды не запускают по UID: на метке HTTPS-адрес `https://<katana-host>/c/nfc/<action_id>` → страница-мост → существующая ссылка v3 `nfc_action` → preview → «Выполнить».
- **Acceptance criteria:**
  - [x] Решение D-054 (без Universal Links, без новой IPA, без новых wire values).
  - [x] Контракт маршрута 10 (`API.md`), эталонная страница `docs/nfc-bridge-reference.html` (CSP с хешем скрипта), инструкция `docs/NFC_TAG_SETUP.md`.
  - [x] Тесты `NFCBridgeTests`: страница ведёт ровно на существующую ссылку, без внешних ресурсов; HTTPS-адрес и лишние параметры Connector не исполняет; preview и подтверждение; событие без названия/UID/NDEF; offline → relaunch → ровно одно событие.
  - [ ] Katana: маршрут `GET /c/nfc/{action_id}`, HTTPS-адрес и QR в Devices, деплой.
  - [ ] Первый E2E на iPhone: «Коту воду заменили».

## V3-009 Opt-in «Выполнять сразу после открытия» (D-055)
- **Статус:** in progress
- **Acceptance criteria:**
  - [x] Локальный флаг на регистрацию, по умолчанию `false`; старые `nfc-actions.json` читаются как `false`.
  - [x] Внешняя ссылка + enabled + не истекло + флаг → ровно одно `nfc.action.completed` через очередь; unknown/disabled/expired не выполняются.
  - [x] Wire contract не изменён, флаг не уходит в Katana; включение только в UI с предупреждением.
  - [ ] Зелёный CI.

