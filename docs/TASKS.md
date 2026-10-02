# Очередь задач

Правила (см. `CLAUDE.md`): брать одну задачу; не переходить к следующей самостоятельно; после выполнения — обновить статус и acceptance criteria здесь.

Статусы: `planned` → `in progress` → `in review` (код готов, ждёт CI/устройства) → `done` (или `blocked`).

| ID | Задача | Статус | Зависит от |
|---|---|---|---|
| KC-001 | Repository foundation | **done** | — |
| KC-002 | Rename and modular structure | **done** | KC-001 |
| KC-003 | Connector Core models and Capability Registry | **done** | KC-002 |
| KC-004 | QR pairing and Keychain | **in review** (ждёт e2e с реальным Katana endpoint) | KC-003 |
| KC-005 | Persistent event queue and API client | planned | KC-003, KC-004 |
| KC-006 | Screenshot Cleanup session integration | planned | KC-005 |
| KC-007 | Custom URL scheme | planned | KC-002, KC-004 |
| KC-008 | Capability Lab | planned | KC-003, KC-005 |
| KC-009 | End-to-end validation | planned | KC-004 … KC-008 |

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

- **Статус:** in review — клиентская часть, тесты и документация готовы; переводится в done после end-to-end pairing с реальным Katana endpoint
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
  - [ ] Тесты и device-сборка зелёные в CI.
  - [ ] End-to-end pairing с реальным Katana endpoint (нужен `POST /api/connector/pairing/complete` и QR из Katana).
  - [ ] Ручной чек-лист Pairing из `TESTING.md` на устройстве.

## KC-005 Persistent event queue and API client

- **Статус:** planned
- **Цель:** надёжная доставка событий в Katana API.
- **Scope:** `ConnectorEvent` (конверт `event_id`, `type`, `occurred_at`, `session_id`, `payload`) и протокол `EventSink` (перенесены из KC-003); выбор хранения (файл Codable / SQLite из SDK); `EventQueue` (атомарная запись, чтение пачками, удаление после `accepted`/`duplicate`); `APIClient` (event batch, capability report, check connection); backoff; обработка 401/4xx/5xx; экран статуса подключения; file protection и исключение из бэкапа.
- **Вне scope:** интеграция с Screenshot Cleanup UI.
- **Зависимости:** KC-003, KC-004.
- **Acceptance criteria:**
  - [ ] Событие, записанное в очередь, переживает kill приложения и отправляется после перезапуска.
  - [ ] Повторная отправка использует тот же `event_id` и payload.
  - [ ] Ответ `duplicate` удаляет событие из очереди.
  - [ ] 401 переводит pairing в «нужно перепривязать» без потери очереди.
  - [ ] Unit-тесты очереди и клиента на mock-транспорте (`URLProtocol`).
  - [ ] Логи не содержат токенов и payload.

## KC-006 Screenshot Cleanup session integration

- **Статус:** planned
- **Цель:** сделать Screenshot Cleanup первой законченной функцией Connector.
- **Scope:** решение Q-6 (семантика сессии); `CleanupSessionSummary` с проверкой инвариантов `kept + deleted <= viewed`, `started_at <= completed_at` (перенесено из KC-003); `session_id`, `started_at`/`completed_at`; подсчёт `viewed`/`kept`/`deleted` (deleted — только после успешного `performChanges`); запись `screenshots.cleanup.completed` в очередь. (Перенос запроса доступа к фото со старта выполнен в KC-002, D-014.)
- **Вне scope:** изменения модели удаления и подтверждений.
- **Зависимости:** KC-005.
- **Acceptance criteria:**
  - [ ] Одна сессия → не более одного события; повторная отправка не создаёт дублей.
  - [ ] Payload содержит только поля из `API.md`; нет идентификаторов и метаданных фото.
  - [ ] Отмена в системном диалоге → `deleted` не увеличивается.
  - [ ] Регрессионный чек-лист `TESTING.md` проходит; модель удаления не изменена.
  - [ ] Доступ к фото по-прежнему запрашивается только при входе в функцию (D-014).
  - [ ] Без pairing функция работает локально; события копятся в очереди (или не создаются — по решению Q-6).

## KC-007 Custom URL scheme

- **Статус:** planned
- **Цель:** открывать функции Connector из Katana PWA.
- **Scope:** имя схемы и формат (Q-7); регистрация `CFBundleURLTypes` в `project.yml`; `URLRouter` с whitelist действий (например, открыть Screenshot Cleanup, открыть экран подключения); строгая валидация; обработка URL при холодном и тёплом старте.
- **Вне scope:** Universal Links; любые разрушительные действия по URL.
- **Зависимости:** KC-002, KC-004.
- **Acceptance criteria:**
  - [ ] Известные действия открывают нужный экран; неизвестные/битые URL безопасно игнорируются.
  - [ ] URL не может инициировать удаление, pairing без подтверждения, или передать токен.
  - [ ] Unit-тесты парсера URL (валидные, невалидные, слишком длинные, лишние параметры).

## KC-008 Capability Lab

- **Статус:** planned
- **Цель:** набор независимых ручных probes для проверки возможностей устройства.
- **Scope:** утвердить список probes (Q-8, без deferred-возможностей из D-008); каркас probe (запуск по кнопке, своё разрешение, статус); экран Capability Lab; включение статусов в capability report.
- **Вне scope:** HealthKit, Core NFC, background location, extensions, push.
- **Зависимости:** KC-003, KC-005.
- **Acceptance criteria:**
  - [ ] Каждый probe запускается только вручную и запрашивает только своё разрешение.
  - [ ] Отказ/ошибка одного probe не влияет на другие.
  - [ ] Результат probe не содержит пользовательских данных.
  - [ ] Для каждого нового разрешения добавлен usage description и запись в `DECISIONS.md`.

## KC-009 End-to-end validation

- **Статус:** planned
- **Цель:** подтвердить сквозной сценарий на тестовом окружении.
- **Scope:** сценарий PWA → QR pairing → URL scheme → Screenshot Cleanup → очередь → API (тестовое окружение); офлайн → онлайн; kill во время отправки; revoke; переустановка поверх (тот же Bundle ID); обновление `README.md` и `TESTING.md`.
- **Зависимости:** KC-004 … KC-008.
- **Acceptance criteria:**
  - [ ] Сервер получает ровно одно событие на сессию с корректными счётчиками.
  - [ ] Никакие фото/метаданные не уходят в сеть (проверка по логам сервера/прокси на тестовом окружении).
  - [ ] Все ручные чек-листы `TESTING.md` пройдены, результаты записаны.
