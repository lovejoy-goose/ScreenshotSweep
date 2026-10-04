# Решения (ADR-лог)

Формат: номер, статус (`accepted` / `proposed` / `deferred` / `superseded`), контекст, решение, последствия. Новые решения добавляются в конец; принятые не переписываются — заменяются новой записью.

---

## D-001 Одно приложение Katana Connector

- **Статус:** accepted (KC-001)
- **Контекст:** нужно несколько нативных функций для Katana PWA. Отдельные приложения усложняют установку, pairing и поддержку.
- **Решение:** одно приложение Katana Connector. Все функции (Screenshot Cleanup, Capability Lab, будущие) — модули внутри него. Текущий ScreenshotSweep эволюционирует в Connector, а не заменяется.
- **Последствия:** одна установка, один pairing, один device token, один реестр capabilities.

## D-002 Один стабильный Bundle ID

- **Статус:** accepted (KC-001); конкретное значение — proposed, выбирается в KC-002
- **Контекст:** Keychain, данные приложения, URL scheme и привязка на сервере зависят от Bundle ID. Смена Bundle ID = новое приложение для iOS: device token и очередь событий теряются, нужна повторная установка и pairing.
- **Решение:** у приложения ровно один Bundle ID. Текущий `local.sweep.ScreenshotSweep` — временный. Окончательное значение выбирается в KC-002 и **не меняется** после KC-004 (появление Keychain). Display name можно менять свободно.
- **Последствия:** KC-002 — последняя точка, где Bundle ID меняется. При sideload-переподписи team prefix может меняться — учесть при выборе Keychain access group (KC-004).

## D-003 Screenshot Cleanup — первая законченная функция

- **Статус:** accepted (KC-001)
- **Решение:** первой доводится до конца (UI + событие + доставка в API) функция Screenshot Cleanup на основе текущего ScreenshotSweep. Её пользовательское поведение при рефакторинге не меняется (кроме явно согласованного переноса запроса разрешения, см. D-006).
- **Последствия:** вся инфраструктура (очередь, API, pairing) проверяется на реальной функции до Capability Lab.

## D-004 Фото не загружаются в Katana

- **Статус:** accepted (KC-001)
- **Решение:** изображения, превью, хэши, `localIdentifier`, имена файлов, даты отдельных снимков, EXIF и геоданные не покидают устройство. Сервер получает только итоги cleanup-сессии: `viewed`, `kept`, `deleted`, `started_at`, `completed_at` (+ `session_id`, `event_id`).
- **Последствия:** API-контракт не содержит полей для медиа. Любое расширение payload требует новой записи в этом файле.

## D-005 Persistent и идемпотентная очередь событий

- **Статус:** accepted (KC-001); способ хранения — KC-005
- **Решение:** каждое событие сначала атомарно записывается в локальную persistent-очередь, затем отправляется. Удаляется из очереди только после ответа сервера `accepted`/`duplicate`. У каждого события клиентский `event_id` (UUID); сервер дедуплицирует по нему. Для сессионных событий есть `session_id`.
- **Последствия:** офлайн, падение приложения, ретраи не теряют и не дублируют события. Требуется поддержка дедупликации на стороне Katana API.

## D-006 Разрешения — по одному, после явного действия

- **Статус:** accepted (KC-001)
- **Решение:** разрешения не запрашиваются все сразу и не запрашиваются на старте. Каждое — отдельно, после нажатия пользователем кнопки соответствующей функции.
- **Последствия:** текущий запрос доступа к фото в `RootView.onAppear` — известное отклонение. Перенос на явное действие («Начать разбор») планируется в KC-006 и меняет UX, поэтому требует подтверждения пользователя при выполнении задачи.

## D-007 Capability Lab — независимые ручные probes

- **Статус:** accepted (KC-001); состав probes — KC-008
- **Решение:** Capability Lab — набор независимых probes. Каждый запускается вручную, сам запрашивает нужное ему разрешение, не влияет на другие и возвращает только статус (`available`/`denied`/`unsupported`/`error`) без пользовательских данных.
- **Последствия:** probes можно добавлять и удалять по одному; отказ в одном разрешении не ломает остальное приложение.

## D-008 Отложенные возможности

- **Статус:** deferred (KC-001)
- **Решение:** не реализуются до отдельного решения: HealthKit, Core NFC, background location, app extensions, push-уведомления (APNs).
- **Причины:** требуют entitlements/платного Apple Developer аккаунта или ограничены при установке через Sideloadly с бесплатным Apple ID; повышают риски приватности; не нужны для первой функции.

## D-009 Без сторонних зависимостей

- **Статус:** accepted (KC-001)
- **Решение:** только фреймворки Apple (SwiftUI, Photos, Security, Foundation/URLSession, AVFoundation для QR и т.д.). Новая зависимость — только через новую запись здесь.

## D-010 Custom URL scheme как вход из PWA

- **Статус:** proposed (KC-001); имя схемы и формат — KC-007
- **Решение:** PWA открывает Connector через custom URL scheme. Любой URL — недоверенный ввод (любое приложение/сайт может его вызвать): whitelist действий, строгий парсинг, лимиты длины, никаких разрушительных действий и никакой передачи токена через URL.
- **Альтернатива на будущее:** Universal Links (требуют домен и `apple-app-site-association`, а также entitlement Associated Domains) — отложено.

## D-011 Device token только в Keychain

- **Статус:** accepted (KC-001); детали — KC-004
- **Решение:** токен хранится в Keychain с доступностью `AfterFirstUnlockThisDeviceOnly`, без синхронизации в iCloud. Никогда не пишется в `UserDefaults`, файлы, логи, URL.

## D-012 Bundle ID, имена и display name

- **Статус:** accepted (KC-002); закрывает Q-1, уточняет D-002
- **Решение:** Bundle ID — `app.katana.connector`; display name — «Katana Connector»; target, scheme, product и XcodeGen-проект — `KatanaConnector`; `@main` — `KatanaConnectorApp`; CI-артефакт — `KatanaConnector.ipa` в workflow artifact `katana-connector-unsigned-ipa`.
- **Последствия:** iOS устанавливает Katana Connector как отдельное приложение рядом со старым ScreenshotSweep (`local.sweep.ScreenshotSweep`); данные не переносятся. Bundle ID больше не меняется (см. D-002). Имя GitHub-репозитория (`ScreenshotSweep`) пока не меняется.

## D-013 Один application target, модули — папки

- **Статус:** accepted (KC-002); закрывает Q-2
- **Решение:** один application target `KatanaConnector`. Модули — папки внутри `Sources/`: `App/`, `Features/<Feature>/`, `Shared/` (только для реально общих компонентов). Локальные SPM-пакеты не создаются. Пустые placeholder-файлы и абстракции «на будущее» не создаются.
- **Последствия:** границы модулей соблюдаются соглашением (см. `ARCHITECTURE.md`), а не компилятором. Пересмотр — отдельной записью.

## D-014 Dashboard как стартовый экран; PhotoKit — только в Screenshot Cleanup

- **Статус:** accepted (KC-002); закрывает известное отклонение из D-006
- **Решение:** приложение открывается на Dashboard Connector. Screenshot Cleanup открывается отдельной кнопкой «Разобрать скриншоты». Dashboard не запрашивает разрешений и не обращается к сети. Доступ к фото запрашивается только при входе в Screenshot Cleanup (`ScreenshotCleanupView.onAppear` → `SweepStore.start()`); вход — явное действие пользователя.
- **Последствия:** запрос PhotoKit при запуске устранён уже в KC-002, а не в KC-006. Состояние разбора (`SweepStore`) живёт на уровне приложения, поэтому выход на Dashboard и повторный вход не сбрасывают прогресс — как и раньше, до перезапуска приложения.

## D-015 Ветка и коммиты v0.1

- **Статус:** accepted (KC-002)
- **Решение:** вся работа v0.1 ведётся в ветке `feature/katana-connector-v0.1`; каждая KC-задача — отдельный коммит; один Draft PR в `main`, который не сливается до выполнения критериев v0.1.

## D-016 Трёхмерная модель capability

- **Статус:** accepted (KC-003); уточняет формат статуса из D-007
- **Контекст:** одного поля `status` недостаточно: «фича ещё не реализована», «пользователь запретил» и «проверка упала» — независимые факты.
- **Решение:** состояние capability (`CapabilitySnapshot`) — три независимых измерения:
  - `availability` — может ли сборка предложить возможность: `available` / `planned` / `missing_entitlement` / `unsupported_device`;
  - `authorization` — системное разрешение: `unknown` (не проверялось) / `not_required` / `not_requested` / `granted` / `limited` / `denied` / `restricted`;
  - `probe_state` — результат ручного probe: `not_run` / `passed` / `failed`;
  - плюс `checked_at` и `detail` (без пользовательских данных).
  Wire values — стабильный snake_case; менять после релиза нельзя (закреплено тестами).
- **Последствия:** Dashboard и capability report выводят итоговый статус из трёх полей; Capability Lab (KC-008) меняет только `probe_state`/`checked_at`/`detail`, проверки разрешений — только `authorization`.

## D-017 CapabilityRegistry — единственный каталог

- **Статус:** accepted (KC-003)
- **Решение:** `CapabilityRegistry` — единственный упорядоченный каталог capabilities (`id`, пользовательское название, категория). Порядок стабилен и закреплён тестом. Состояние берётся из подменяемого `CapabilitySnapshotProviding`; сейчас — `StaticCapabilitySnapshotProvider` с декларированными начальными состояниями (photos — available; healthKit, coreNFC — missing_entitlement; остальные — planned; везде `authorization: unknown`, `probe_state: not_run`). Registry — значение (struct), создаётся в `KatanaConnectorApp` и передаётся вниз; не singleton. Не запрашивает разрешений, не вызывает системные API и сеть, не хранит токены.
- **Последствия:** добавление capability = case в `CapabilityID` + строка в каталоге + начальное состояние; тесты не дадут забыть одно из трёх.

## D-018 Unit-тесты ядра без host app

- **Статус:** accepted (KC-003)
- **Решение:** target `KatanaConnectorTests` (XCTest, `bundle.unit-test`) компилирует `Sources/Core` напрямую вместе с тестами — без host application и без зависимости от UI. Тесты запускаются в CI на iOS Simulator до unsigned device-сборки; симулятор выбирается динамически (новейший iOS runtime, первый iPhone из `xcrun simctl list devices available`).
- **Последствия:** `Sources/Core` обязан компилироваться без UIKit/SwiftUI/Photos. Тесты фич с UI/PhotoKit потребуют отдельного решения (host app).

## D-019 Имя устройства задаёт пользователь

- **Статус:** accepted (KC-004)
- **Решение:** перед подтверждением pairing пользователь видит редактируемое поле «Имя этого iPhone в Katana», по умолчанию `iPhone`. Значение нормализуется: убираются управляющие символы и пробелы по краям, длина ≤ 40, пустое → `iPhone`. `UIDevice.name` не используется (с iOS 16 без entitlement возвращает общее имя и считается персональными данными).

## D-020 Адрес Katana приходит в QR; только HTTPS

- **Статус:** accepted (KC-004); закрывает Q-3
- **Решение:** `base_url` приходит в pairing QR вместе с одноразовым кодом и после успешного pairing хранится в Keychain рядом с токеном. Хост показывается пользователю до отправки кода. Release-сборка принимает только HTTPS, без user/password, query и fragment; редиректы при pairing не выполняются. `PairingSecurityPolicy.localDevelopment` (HTTP только к localhost/127.0.0.1/::1/`*.local`) предусмотрена для отдельной debug-конфигурации, но ни к одной сборке не подключена. Глобальный `NSAllowsArbitraryLoads` не добавляется; для локального HTTP в будущем — только `NSAllowsLocalNetworking` в debug-конфигурации.
- **Последствия:** нет зашитых в сборку production URL; подключиться можно к любому HTTPS-хосту, который пользователь подтвердил, — поэтому хост показывается крупно и с предупреждением.

## D-021 Хранение credentials и восстановление после потери Keychain

- **Статус:** accepted (KC-004); уточняет D-011; закрывает Q-4
- **Решение:** один generic-password item: service `app.katana.connector.pairing`, account `device-credentials`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, без синхронизации. Содержимое — JSON с `device_token` и минимальными метаданными (`device_id`, `display_name`, `paired_at`, `base_url`). Повторное сохранение обновляет item. Одно подключение на устройство; чтобы подключиться к другому аккаунту, нужно сначала отключиться.
  Если item отсутствует или не читается (например, после переподписи Sideloadly с другим team prefix) — состояние `unpaired`, Dashboard объясняет причину и предлагает подключиться заново; приложение не падает и не показывает активную связь.
  Токен обёрнут в `DeviceToken` с редактированными `description`/`debugDescription`/mirror; не попадает в `UserDefaults`, `@Published`, UI и логи. Pairing code — в `PairingCode` с тем же поведением, хранится только в памяти до однократной отправки.
- **Последствия:** «Отключить на этом iPhone» удаляет только локальные credentials — серверный revoke появится позже, и UI честно об этом говорит.

## D-022 Core может использовать системные фреймворки без UI

- **Статус:** accepted (KC-004); уточняет D-018
- **Решение:** `Sources/Core` может импортировать Foundation, Security и Combine (для `ObservableObject` координатора). UIKit, SwiftUI, Photos и AVFoundation в Core запрещены; камера и экраны — в `Features/Pairing`. Unit-тесты не обращаются к реальному Keychain — используется in-memory `SecureTokenStoring`.

## D-023 Одно активное подключение; повторное pairing — только после подтверждения

- **Статус:** accepted (KC-005); уточняет D-021
- **Решение:** один экземпляр Connector хранит одно активное подключение; у одного аккаунта Katana может быть несколько подключённых устройств. Повторное pairing заменяет локальное подключение только после того, как пользователь увидел предупреждение «Текущее подключение к … будет заменено» и нажал «Подключить». Отмена или ошибка возвращают прежнее состояние.

## D-024 Границы фреймворков в Core

- **Статус:** accepted (KC-005); заменяет D-022
- **Решение:** чистые модели, парсеры и wire-контракты (`Capabilities`, `Connector`, `Pairing/PairingModels`, `PairingPayloadParser`, `API/*Models`, `Events/ConnectorEvent`, `EventQueue`) — только Foundation. Security — только в `KeychainTokenStore`. Combine — только в координаторах (`PairingCoordinator`, `EventDeliveryCoordinator`) ради `ObservableObject`. UIKit/SwiftUI/Photos/AVFoundation в Core запрещены.

## D-025 Persistent event queue — один JSON-файл

- **Статус:** accepted (KC-005)
- **Решение:** очередь — один файл `Application Support/KatanaConnector/EventQueue/event-queue.json` (`{"version":1,"events":[…],"rejected":[…]}`), запись через временный файл и атомарную замену (`Data.write(.atomic)`), `NSFileProtectionCompleteUntilFirstUserAuthentication`, каталог и файл исключены из iCloud backup. Доступ сериализован actor `EventQueue`; изменение видно только после успешной записи на диск. FIFO, `event_id` уникален в очереди, повторное добавление — no-op с исходным payload.
  Лимиты: 20 событий в batch, 500 событий в очереди (дальше `queueFull`, старые не вытесняются), 16 KiB на событие, 100 записей журнала отклонённых, `type` до 100 символов `[a-z0-9._]`.
  Повреждённый файл не удаляется: он переименовывается в `event-queue.corrupt-<время>-<id>.json` в том же каталоге, очередь сообщает `corruptedStore` и продолжает с пустым состоянием; Dashboard показывает предупреждение. Payload не логируется.
- **Последствия:** SQLite и зависимости не нужны; объём ограничен лимитами. Токенов в файле нет.

## D-026 Политика rejected

- **Статус:** accepted (KC-005)
- **Решение:** событие со статусом `rejected` удаляется из активной очереди; в том же файле сохраняется запись без payload (`event_id`, `type`, `code` до 64 символов, `rejected_at`), не больше 100 последних. UI показывает только количество отклонённых. Отклонение всего batch (4xx без результатов) событий не удаляет.

## D-027 Авторизованный API и 401

- **Статус:** accepted (KC-005)
- **Решение:** маршруты `GET /api/connector/connection/check`, `POST /api/connector/capabilities/report`, `POST /api/connector/events/batch` на `base_url` из Keychain; Bearer token читается перед каждым запросом и нигде не хранится вне Keychain. 401 → `PairingCredentials.requires_repair = true` в Keychain (токен больше не используется, в том числе после перезапуска), статус «Требуется повторное подключение», сетевые повторы прекращаются, очередь сохраняется. Очередь не удаляется ни при 401, ни при локальном отключении, ни при повторном pairing.
- **Последствия:** события, накопленные до повторного pairing, отправляются в новое подключение (см. Q-5).

## D-028 Доставка без background tasks

- **Статус:** accepted (KC-005)
- **Решение:** flush запускается при старте приложения, при возвращении в foreground, после нового события и по кнопке «Синхронизировать». Одновременно выполняется только один flush (повторный запрос перепроверяет очередь после текущего). Ретраи только внутри текущего жизненного цикла: экспоненциальный backoff 2 → 4 → 8 … с, не больше 60 с, jitter ±20 %, не больше 5 попыток за flush; sleeper, случайность и часы инжектируются. Отмена flush не удаляет событий. BackgroundTasks и background URLSession не используются. «Последняя успешная синхронизация» хранится локально (`UserDefaults`, не секрет). Проверка соединения — только по кнопке; capability report — автоматически один раз за запуск.

## D-029 Очередь привязана к подключению (connection scope)

- **Статус:** accepted (KC-006); закрывает Q-5, уточняет D-027
- **Решение:** каждое событие в очереди хранится вместе с `ConnectionScope` — каноническим `base_url` (нижний регистр схемы и хоста, без порта по умолчанию, завершающего `/`, user info, query и fragment) и `device_id` текущего подключения. Токен и любые его производные в scope не входят. Flush берёт только события текущего scope; перед отправкой API-клиент ещё раз сверяет scope сохранённых credentials и при расхождении ничего не отправляет (`scopeMismatch`). Повторное pairing с тем же `base_url` и `device_id` сохраняет доступ к своей очереди; другой аккаунт/устройство/хост старые события не получает. События чужих scope остаются локально, не удаляются и показываются на Dashboard как «ждут решения». Без подключения событие не создаётся.

## D-030 Формат очереди v2 и миграция

- **Статус:** accepted (KC-006); уточняет D-025
- **Решение:** `event-queue.json` v2: `{"version":2,"events":[{"scope":{…},"event":{…}}],"legacy_events":[…],"rejected":[…]}`. Файл v1 мигрируется при первом чтении: исходные байты сохраняются в `event-queue.v1-backup.json`, события v1 (без scope) переносятся в `legacy_events` и никогда не назначаются подключению автоматически; журнал rejected переносится как есть. Неизвестная версия или битый JSON — quarantine, как в D-025. `event_id` уникален во всём файле, включая legacy. Лимит 500 событий — суммарно по всем scope и legacy.

## D-031 Событие Screenshot Cleanup и privacy-модель

- **Статус:** accepted (KC-006); закрывает Q-6, заменяет черновик `screenshots.cleanup.completed`
- **Решение:** событие `screenshot_cleanup.completed` создаётся только по явному завершению разбора: «Завершить разбор» → экран итога → «Завершить». Сессия начинается с первого решения; после завершения закрывается до любого `await`, поэтому один `session_id` даёт максимум одно событие; повторное открытие итога ничего не создаёт; «Продолжить разбор» и выход из функции событие не создают. Событие сначала сохраняется в очередь, потом запускается flush; отсутствие сети или ошибка очереди не мешают завершению и не влияют на PhotoKit.
  Счётчики ведёт `CleanupSessionTracker` в памяти по уведомлениям `SweepStore` (решение, undo, переключение в review, начало и итог удаления, изменение медиатеки); локальные идентификаторы снимков живут только в памяти этого типа и не попадают ни в payload, ни в описания. Удаление учитывается только после успешного `performChanges`; отмена системного диалога оставляет скриншоты «отмеченными». `CleanupSessionRecorder` не имеет доступа к медиатеке (Core не импортирует Photos, D-024).
- **Последствия:** модель удаления PhotoKit не изменилась; в Katana уходят только 4 числа, флаг и 2 времени.

## D-032 Custom URL scheme v1 — только навигация

- **Статус:** accepted (KC-007); заменяет D-010
- **Решение:** схема `katana-connector` регистрируется через `CFBundleURLTypes` в `Config/KatanaConnector-Info.plist` (объединяется с генерируемым Info.plist). Формат v1: `katana-connector://open?v=1&feature=screenshot_cleanup|pairing`, строгий парсер `ConnectorURLRouter` (Foundation, без сети): длина ≤ 2048, печатный ASCII, точные scheme/host, путь пустой или `/`, без user/password/port/fragment, `v` и `feature` ровно по одному разу, другие параметры запрещены, пустые значения запрещены.
  Единственное возможное действие — `open(feature)`. Навигация — единое состояние `AppNavigator.path` (`NavigationStack(path:)`), общее для Dashboard и ссылок: валидная ссылка заменяет стек на `[route]` (открытые экраны и их sheet закрываются), повтор той же ссылки на уже открытом экране ничего не меняет, невалидная ссылка ничего не меняет. Холодный и тёплый старт — через SwiftUI `onOpenURL` (в SwiftUI-жизненном цикле он вызывается в обоих случаях).
  Граница безопасности: ссылка не может удалить фото, начать pairing, передать/принять token, code, base_url, device_id, запросить PhotoKit или камеру, отправить события или запустить flush. `AppNavigator` не имеет доступа ни к одному из этих сервисов. Pairing QR (`katana-connector://pair`) роутером не принимается.
- **Последствия:** любое приложение или сайт может открыть ссылку — поэтому она только показывает экран. Если ссылка приходит, когда приложение было в фоне, обычный lifecycle-триггер foreground (D-028) по-прежнему может запустить flush — это следствие возврата в foreground, а не ссылки. Universal Links и Associated Domains не используются.

## D-033 PhotoKit — по кнопке внутри Screenshot Cleanup

- **Статус:** accepted (KC-007); уточняет D-014
- **Решение:** вход в Screenshot Cleanup (с Dashboard или по ссылке) только читает статус доступа. Если он `notDetermined`, показывается экран «Доступ к скриншотам» с кнопкой «Разрешить доступ к фото»; системный запрос — только по ней. Уже выданный доступ ничего не запрашивает. Модель удаления не изменилась.

## D-034 Capability Lab — четыре ручных probes

- **Статус:** accepted (KC-008); закрывает Q-8, уточняет D-007
- **Решение:** Capability Lab содержит ровно четыре независимых probe: `camera` (один кадр), `current_location` (только When In Use, одна фиксация), `motion` (одно событие Motion & Fitness), `local_notifications` (одно локальное тестовое уведомление). Каждый запускается только своей кнопкой, запрашивает только своё разрешение (и только если оно ещё не запрашивалось), выполняется не более одного раза одновременно, ограничен таймаутом (камера 10 с, геолокация 20 с, движение 15 с, уведомления 10 с; системный диалог разрешения не ограничен), отменяется кнопкой «Отменить» и обновляет только свой snapshot. Открывается с Dashboard; URL для неё нет. Bluetooth, микрофон/речь, фоновая геолокация, геозоны, HealthKit, Core NFC, Contacts/Calendar/Reminders, Local Network, расширения, push и BackgroundTasks не входят.
  Отображение статусов — единая таблица `CapabilityAuthorizationMapping`: камера/движение `notDetermined→not_requested`, `authorized→granted`, `denied→denied`, `restricted→restricted`; геолокация `authorizedWhenInUse`/`authorizedAlways→granted`; уведомления `provisional`/`ephemeral→limited`. Выключенные системно Службы геолокации считаются `denied`.
  Начальная `availability` четырёх capabilities — `available`; проверка устройства (без запросов) может заменить её на `unsupported_device`.
- **Последствия:** новые Info.plist-ключи `NSLocationWhenInUseUsageDescription`, `NSMotionUsageDescription`; текст камеры охватывает QR и Capability Lab. Ключей Always-геолокации, background modes и entitlements нет.

## D-035 Privacy boundary и хранение результатов probes

- **Статус:** accepted (KC-008)
- **Решение:** адаптеры (`Features/CapabilityLab`) — единственное место с AVFoundation (для probe), CoreLocation, CoreMotion и UserNotifications; их методы, которые касаются данных, возвращают `Void` — кадр, координаты (а также высота, скорость, курс, точность) и данные движения физически не покидают адаптер и никогда не читаются. В snapshot попадают только `availability`, `authorization`, `probe_state`, `checked_at` и `detail` из фиксированного набора кодов (`CapabilityProbeDetail`); `localizedDescription` и сырые ошибки не сохраняются. Тестовое уведомление: идентификатор `app.katana.connector.capability-lab.test.<uuid>`, заголовок «Katana Connector», текст «Тестовое уведомление Capability Lab.», через 5 с; probe подтверждает разрешение и успешное планирование, но не показ.
  Хранение: `Application Support/KatanaConnector/Capabilities/capability-snapshots.json` — `{"version":1,"snapshots":[…]}`, атомарная запись, file protection until first unlock; неизвестная версия, битый JSON или неизвестный `CapabilityID` → файл переносится в `capability-snapshots.corrupt-…json`, используются значения по умолчанию, без падения. Store — provider реестра, поэтому реестр остаётся единственным каталогом; store не создаёт новых ID.
  После probe: snapshot сохраняется → Dashboard обновляется из того же store → если Katana подключена, отправляется capability report; ошибка сети не теряет результат. Probes не создают событий и не трогают очередь. При запуске и возврате в foreground обновляются только `availability` и `authorization` — без запросов, без probe, `probe_state`/`checked_at`/`detail` не меняются.

## D-036 Стабильные идентификаторы хранения и обновление поверх

- **Статус:** accepted (KC-009); уточняет D-002
- **Решение:** установка новой версии IPA поверх старой обязана сохранять подключение, очередь событий и результаты Capability Lab. Поэтому неизменны: Bundle ID `app.katana.connector`; Keychain service `app.katana.connector.pairing`, account `device-credentials`; `Application Support/KatanaConnector/EventQueue/event-queue.json` (формат v2, миграция с v1); `Application Support/KatanaConnector/Capabilities/capability-snapshots.json` (формат v1); ключ `UserDefaults` `connector.lastSuccessfulSyncAt`. Все закреплены unit-тестом `testStorageIdentifiersStayStable`; изменение любого из них — только новой записью здесь вместе с миграцией.
- **Последствия:** при переподписи другим Apple ID Keychain может стать недоступен — это уже обрабатывается как `unpaired` с предложением подключиться заново (D-021), очередь сохраняется.

## D-037 Milestone v0.2 «Context & Actions» — один PR

- **Статус:** accepted (V2-001); для v0.2 заменяет правило «одна KC-задача = один коммит» из D-015
- **Контекст:** v0.2 — единый пользовательский набор «Контекст и действия»; промежуточные установки на iPhone не нужны, ручная проверка одна — в конце.
- **Решение:** ветка `feature/katana-connector-v0.2-context-actions`, один Draft PR в `main`, один финальный IPA и одна итоговая ручная проверка. Внутри — задачи V2-001…V2-006 (`docs/TASKS.md`) и несколько логических коммитов; каждая внутренняя задача отмечается done после зелёного CI, весь milestone остаётся `in review` до проверки на реальном iPhone и Katana. Версия приложения — `0.2.0` (`MARKETING_VERSION`), Bundle ID и все идентификаторы хранения v0.1 не меняются (D-036). PR не переводится в Ready и не сливается без решения пользователя; Release v0.2 не публикуется.
- **Последствия:** правила `CLAUDE.md` «одна задача» и «не коммитить без разрешения» для v0.2 действуют на уровне milestone: разрешение пользователя на коммиты, push и Draft PR получено для всего milestone.

## D-038 События v0.2: общие правила

- **Статус:** accepted (V2-001); расширяет D-005, D-029, D-031
- **Решение:** новые типы событий — `activity.snapshot.completed`, `activity.session.completed`, `location.check_in.created`, `reminder.local.scheduled`, `reminder.local.cancelled`. Используются существующие `ConnectorEvent`, `EventQueue` v2, `ConnectionScope`, `EventDeliveryCoordinator` и `POST /api/connector/events/batch`; отдельной очереди нет.
  - Событие создаётся только после явного подтверждения пользователя на экране предпросмотра; ни ссылка, ни сервер, ни lifecycle событий не создают.
  - `event_id` — новый UUID на каждое событие; создаётся один раз и хранится вместе с записью функции (сессия, check-in, напоминание), поэтому повтор после ошибки или перезапуска использует тот же `event_id`. `session_id` конверта — собственный идентификатор записи: `snapshot_id`, `session_id`, `check_in_id`, `draft_id`. `occurred_at` — время факта (проверка, завершение сессии, определение места, создание/отмена напоминания).
  - Payload строго проверяется до enqueue (`ContextEventSchema`): JSON-объект с точным набором ключей для типа, значения из закрытых наборов, инварианты; событие с нарушением не создаётся.
  - Сначала запись в очередь на диск (scope текущего подключения), потом flush. Без подключения событие в очередь не записывается; функция честно сообщает «Katana не подключена». Другой scope событие не получает (D-029).
  - Статус для UI («ждёт отправки» / «отправлено» / «отклонено») вычисляется по очереди и журналу rejected; `event_id`, scope и сырые ошибки в UI не показываются.
- **Последствия:** wire values новых событий закреплены тестами и после релиза не меняются.

## D-039 Activity Journal

- **Статус:** accepted (V2-001)
- **Решение:**
  - `CMMotionActivityManager` используется только в адаптере `Features/ActivityJournal`; Core получает лишь нейтральное чтение (шесть флагов и уверенность) без времени и без истории. Сырые Motion samples нигде не сохраняются и не отправляются.
  - Категории (wire): `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`; уверенность: `low`, `medium`, `high`. Детерминированное правило при нескольких флагах — приоритет `automotive` > `cycling` > `running` > `walking` > `stationary` > `unknown` (движение важнее неподвижности: iOS ставит `stationary` вместе с `automotive` в стоящей машине). Нет флагов → `unknown`.
  - «Определить текущую активность» — только кнопкой; разрешение Motion & Fitness запрашивается только если ещё не запрашивалось, в момент нажатия. Результат и время проверки показываются; в Katana уходит только после кнопки «Отправить в Katana».
  - Ручная сессия: «Начать сессию» → наблюдение только пока приложение активно → «Завершить» → предпросмотр агрегатов → «Отправить в Katana» (или «Удалить без отправки»). Время, когда приложение было в фоне или не получало данных, учитывается как `unknown_seconds` — Connector не утверждает, что iOS собирала данные в фоне, и UI говорит об этом прямо.
  - Все времена сессии — целые секунды, монотонно (время назад не идёт), поэтому сумма категорий равна `duration_seconds`; серверу документирован допуск 1 с.
  - `dominant_activity` — категория с наибольшим временем; при равенстве — по тому же приоритету; при нулевой длительности — `unknown`.
  - Kill/перезапуск во время сессии → сессия восстанавливается как `interrupted`; время после последней сохранённой точки не учитывается, `completed_at` = последняя точка; пользователь может завершить (с предпросмотром) или удалить её. Флаг `interrupted` в событии — `true`.
  - Двойное «Завершить»/«Отправить» не создаёт второго события: завершённая сессия получает `event_id` один раз и хранится до успешной записи в очередь.
- **Последствия:** `activity.session.completed` содержит только агрегаты (13 полей), без временного ряда и координат.

## D-040 Location Check-in

- **Статус:** accepted (V2-001); не меняет D-034 (Capability Lab по-прежнему отбрасывает координаты)
- **Решение:**
  - «Определить текущее место» — только кнопкой; разрешение — только When In Use и только в момент нажатия; одна фиксация (`requestLocation`), таймаут 20 с. Никакой фоновой геолокации, Always, significant-change, геозон и region monitoring; API для них в адаптерах нет.
  - После фиксации — предпросмотр: время, точность в виде корзины, выбор `approximate` / `precise`, переключатель «Определить название места в Katana» (`label_requested`), явная пометка, что координаты — чувствительные данные. «Отправить в Katana» → отдельное подтверждение → enqueue. «Отмена» не создаёт событие.
  - Координаты живут только в памяти координатора: до подтверждения не дольше 5 минут, сбрасываются при отмене, уходе с экрана и уходе приложения в фон; после enqueue сразу очищаются из состояния и UI. В локальной истории check-in координат нет. Неизбежное исключение — само событие в persistent-очереди до его доставки (как и любое событие, D-025).
  - Округление до enqueue: `approximate` — 2 знака после запятой (≈1 км), `precise` — не больше 6 знаков; округление «к ближайшему, половина от нуля».
  - Точность передаётся только корзиной `horizontal_accuracy_bucket`: `under_25m` (< 25 м), `under_100m` (< 100 м), `under_1km` (< 1000 м), `over_1km`, `unknown` (отрицательная/нечисловая точность). Высота, скорость, курс, этаж, сырая точность, время фиксации CLLocation не передаются и не покидают адаптер.
- **Последствия:** reverse geocoding и подпись места — на стороне Katana по `label_requested`.

## D-041 Локальные напоминания из Katana

- **Статус:** accepted (V2-001)
- **Решение:**
  - Текст напоминания не передаётся в ссылке: ссылка v2 несёт только непрозрачный `draft_id` (UUID) и только открывает экран черновика (D-042).
  - Черновик загружается по authenticated HTTPS `GET /api/connector/reminder-drafts/{draft_id}` только по кнопке «Загрузить напоминание» на этом экране — ссылка сама сеть не запускает (сохраняется граница D-032). Bearer, без редиректов, ответ ≤ 64 KiB, timeout 15 с; строгая проверка ответа (`draft_id` совпадает, `title` 1…120 Unicode scalars, `body` ≤ 500, `fire_at` в будущем и не дальше 366 дней, `expires_at` в будущем). Typed errors: not found / expired / consumed / уже наступило / нет связи / требуется повторное подключение / неожиданный ответ. 401 → `requires_repair` (как D-027), повторов со старым токеном нет.
  - Пользователь видит title/body/время → «Создать напоминание». Только после этой кнопки при необходимости запрашивается разрешение на уведомления. Создаётся одно локальное уведомление с детерминированным идентификатором `app.katana.connector.reminder.<draft_id>`; повторный tap или повторное открытие ссылки дубль не создают (запись по `draft_id` уже есть; системный идентификатор тот же).
  - Список «Локальные напоминания» показывает только напоминания Connector; «Отменить» (с подтверждением) удаляет только своё ожидающее уведомление. Чужие уведомления приложения и уведомления Capability Lab не трогаются.
  - События `reminder.local.scheduled` и `reminder.local.cancelled` не содержат `title`/`body` — Katana уже знает содержимое черновика.
  - Нет сети при загрузке → безопасная повторяемая ошибка, ничего не планируется.
- **Последствия:** серверу нужен маршрут черновиков с привязкой к устройству/аккаунту (`docs/API.md`).

## D-042 Custom URL scheme v2

- **Статус:** accepted (V2-001); дополняет D-032, ссылки v1 не меняются
- **Решение:** допустимы ровно три ссылки v2:
  `katana-connector://open?v=2&feature=activity_journal`,
  `katana-connector://open?v=2&feature=location_check_in`,
  `katana-connector://open?v=2&feature=reminder&draft_id=<uuid>`.
  Правила v1 (длина ≤ 2048, печатный ASCII, scheme/host/path, без user/password/port/fragment, каждый параметр ровно один раз, пустые значения запрещены) плюс: параметры — только `v`, `feature`, `draft_id`; `draft_id` обязателен для `reminder` и запрещён для остальных; `draft_id` — канонический UUID 8-4-4-4-12 (hex, регистр не важен, нормализуется в нижний); percent-encoding в query v2 запрещён; функции v1 (`screenshot_cleanup`, `pairing`) с `v=2` → `unsupportedVersion`; `token`, `code`, `base_url`, `device_id`, `title`, `body`, `fire_at` и любые другие параметры → `unknownParameter`.
  Навигация: `activity_journal` → `[activityJournal]`, `location_check_in` → `[locationCheckIn]`, `reminder` → `[reminders, reminderDraft(id)]`. Ссылка ничего не запрашивает, не планирует, не отправляет и не загружает.
- **Последствия:** `ConnectorURLFeature` (v1) не меняется; v2 — отдельный `ConnectorURLDestination`.

## D-043 Хранение v0.2

- **Статус:** accepted (V2-001); дополняет D-036
- **Решение:** три новых файла, общий `VersionedJSONFileStore` (атомарная запись через временный файл, `completeUntilFirstUserAuthentication`, исключение из iCloud backup, quarantine `<имя>.corrupt-<время>-<id>.json` при битом JSON или неизвестной версии — без удаления и без падения, приложение продолжает с пустым состоянием и показывает предупреждение):
  - `Application Support/KatanaConnector/ActivityJournal/activity-journal.json` — v1: активная/прерванная/ожидающая подтверждения сессия (только агрегаты и точки времени) и история итогов (до 50);
  - `Application Support/KatanaConnector/LocationCheckIn/check-ins.json` — v1: история check-in **без координат** (до 50);
  - `Application Support/KatanaConnector/Reminders/reminders.json` — v1: напоминания Connector (title/body — для списка в UI), статусы и `event_id` (до 100).
  Токенов, кодов, scope, сырых Motion samples и координат в этих файлах нет. Новые данные не пишутся в `UserDefaults`.
  Миграции: формат версии N читается только кодом версии N; переход N → N+1 — явная функция миграции с тестом и записью здесь; неизвестная (будущая) версия — quarantine. Для v0.2 все три формата — v1, миграций нет. Идентификаторы v0.1 (D-036) не меняются.
- **Последствия:** имена каталогов, файлов и версии закреплены тестом стабильности идентификаторов.

## D-044 Разрешения и Info.plist v0.2

- **Статус:** accepted (V2-001); дополняет D-006, D-034
- **Решение:** новых Info.plist-ключей, background modes и entitlements нет. Используются существующие `NSLocationWhenInUseUsageDescription` (Capability Lab + Location Check-in) и `NSMotionUsageDescription` (Capability Lab + Activity Journal) — их тексты обновлены и честно говорят, что именно уходит в Katana и только после подтверждения. Локальные уведомления ключа не требуют. Каждое разрешение — по своей кнопке внутри функции: Motion — «Определить текущую активность»/«Начать сессию»; геолокация — «Определить текущее место»; уведомления — «Создать напоминание». HealthKit, Core NFC, Bluetooth, фоновая геолокация, геозоны, push, Share Extension по-прежнему отложены (D-008).

## D-045 Milestone v0.3 «Physical Triggers & Capture» — один PR

- **Статус:** accepted (V3-001); для v0.3 действует как D-037
- **Решение:** ветка `feature/katana-connector-v0.3-physical-triggers-capture`, один Draft PR, один финальный IPA, одна итоговая ручная проверка. Внутренние задачи V3-001…V3-007 (`docs/TASKS.md`), логические коммиты. Версия `0.3.0`. Bundle ID основного приложения и все идентификаторы хранения v0.1/v0.2 не меняются. PR не переводится в Ready и не сливается, Release v0.3 не публикуется. Разрешение пользователя на ветку, коммиты, push и Draft PR, а также на замену D-008/D-034/D-040/D-044 в части, описанной ниже, получено 2026-10-04.
- **Открытые post-merge проверки v0.2** (не блокируют v0.3, в Release checklist v0.3, раздел L): фактический показ баннера локального напоминания и доставка `reminder.local.cancelled` на реальном iPhone.

## D-046 Provisioning spike v0.3 и изоляция entitlements

- **Статус:** accepted (V3-001); уточняет D-008
- **Что доказано (CI, unsigned сборка, без устройства):**
  - Core NFC (`NFCNDEFReaderSession`, чтение и запись NDEF через `NFCNDEFTag.queryNDEFStatus`/`writeNDEF`) компилируется и линкуется в unsigned IPA. Для работы на устройстве нужны entitlement `com.apple.developer.nfc.readersession.formats` (`NDEF`/`TAG`) и Info.plist-ключ `NFCReaderUsageDescription`; без ключа обращение к Core NFC завершает процесс, без entitlement сессия сразу инвалидируется. Блокировку метки (`writeLock`) Connector не вызывает.
  - Share Extension — отдельный target `KatanaShareExtension` (`app.katana.connector.share-extension`), собирается в CI отдельно. Передать данные основному приложению он может только через общий контейнер App Group (`com.apple.security.application-groups`); без него у extension и приложения разные песочницы.
  - Геозоны (`CLLocationManager` region monitoring, `CLCircularRegion`) **не требуют entitlement** и `UIBackgroundModes`: система сама будит/перезапускает приложение при пересечении. Нужны авторизация **Always** и ключ `NSLocationAlwaysAndWhenInUseUsageDescription`. Лимит — 20 регионов на приложение. После перезагрузки iOS восстанавливает зарегистрированные регионы; после перезапуска приложение должно сразу назначить delegate, чтобы получить событие.
  - Фоновая геолокация (`UIBackgroundModes: location`, `allowsBackgroundLocationUpdates`) для геозон не нужна и **не добавляется**.
- **Что не доказано и проверяется только на iPhone:** выдаёт ли подпись Sideloadly (особенно бесплатный Personal Team) entitlements NFC и App Group, и сколько App ID доступно для extension.
- **Решение (выбор пользователя «изолировать»):** основной IPA v0.3 **без новых entitlements** и **без встроенного extension** — он гарантированно устанавливается поверх v0.2.
  - Core NFC: код адаптера есть, но выключен статусом `requires_entitlement` (`CoreNFCAvailability`: entitlement не сконфигурирован, ключа `NFCReaderUsageDescription` нет) — кнопки сканирования/записи не активны. Работает гарантированный путь Shortcuts + NFC (D-048).
  - Share Extension: target собирается в CI (доказательство), но не встраивается в IPA; capability `share_extension` и `app_group` — `missing_entitlement`. Тот же конвейер захвата (валидация, inbox, preview, загрузка, события) доступен в приложении через экран «Поделиться с Katana» (выбор файла/фото, вставка текста/URL) — безопасный fallback (D-050).
  - Геозоны работают (entitlement не нужен), с Always только по кнопке (D-049).
  - Включение NFC/App Group/extension — отдельное решение после проверки подписи на iPhone: добавить entitlements, `NFCReaderUsageDescription`, встроить extension, переключить `CoreNFCAvailability`/`CaptureInboxLocation`.

## D-047 Action Draft и URL v3

- **Статус:** accepted (V3-001); обобщает подход D-041
- **Решение:**
  - Ссылка `katana-connector://open?v=3&feature=action&draft_id=<uuid>` только открывает экран черновика действия. Загрузка — кнопкой «Загрузить действие»: `GET /api/connector/action-drafts/{draft_id}`, Bearer, HTTPS без редиректов, ответ ≤ 64 KiB, timeout 15 с.
  - Строгая схема: точный набор ключей верхнего уровня и `payload` для каждого `kind`; **неизвестные поля отклоняются** (в отличие от reminder drafts v0.2). Виды: `nfc_action`, `geofence_create`, `shared_capture`.
  - TTL проверяется по **серверному** времени: ответ содержит `server_time`; черновик действителен, если `server_time < expires_at` и `expires_at − server_time ≤ 7 дней`. Часы iPhone для TTL не используются.
  - 401 → `requires_repair` (без повторов); 404/403 → не найден; 409 → уже использован; 410 → истёк.
  - Повторное выполнение запрещено: принятый черновик записывается локально (`action-drafts.json`) — повторное открытие показывает «уже выполнено» без сети. Сервер **атомарно** помечает черновик использованным, когда принимает итоговое событие `action_draft.accepted` (повтор того же `event_id` → `duplicate`, другое событие для того же черновика → `rejected` с кодом `draft_consumed`). Отдельного consume-запроса нет.
  - Ссылка `katana-connector://open?v=3&feature=nfc_action&action_id=<uuid>` только открывает preview локально зарегистрированного NFC-действия (D-048).
  - Правила URL v3 = v2 (длина, ASCII, scheme/host/path, каждый параметр один раз, без percent-encoding, канонический UUID), параметры только `v`, `feature`, `draft_id`, `action_id`; `draft_id` только для `action`, `action_id` только для `nfc_action`; функции v1/v2 с `v=3` → `unsupportedVersion`. В v1/v2 `action_id` по-прежнему неизвестный параметр.
  - **Trust boundary локальных черновиков захвата:** записи inbox, созданные Share Extension или экраном захвата, — недоверенный локальный ввод, а не серверный Action Draft. Они не содержат команд, никогда не исполняются автоматически, основное приложение заново проверяет каждую запись (размер, тип по сигнатуре, SHA-256) и показывает preview до любой загрузки.

## D-048 NFC-действия

- **Статус:** accepted (V3-001)
- **Решение:**
  - NFC-действие регистрируется только из Action Draft `nfc_action` (Katana знает `action_id`); локально хранятся только `action_id`, безопасное имя (метка от Katana, ≤ 60), время, включено/выключено, срок действия. Сырой UID и NDEF payload нигде не сохраняются.
  - Гарантированный путь — Shortcuts: автоматизация «NFC → Открыть URL» с ссылкой v3 `nfc_action`. Ссылка открывает preview; «Выполнить» (подтверждение) → событие `nfc.action.completed` с `result: confirmed`; «Отклонить» → то же событие с `result: declined`; уход с экрана — ничего.
  - Повторное касание метки в течение 120 с показывает тот же ожидающий запуск (тот же `execution_id`), дубля нет. Ожидающий запуск сохраняется на диск; после перезапуска приложения он показывается с `interrupted: true`; старше 10 минут — отбрасывается без события.
  - Выключенное, истёкшее и неизвестное действие показывается явно, событие не создаётся.
  - Native Core NFC (чтение одной метки, запись безопасной ссылки v3 с preview и подтверждением, проверка read-only/неподдерживаемой метки, без lock) — за `CoreNFCAvailability` (D-046); в этой сборке недоступен.

## D-049 Локальные геозоны

- **Статус:** accepted (V3-001); **заменяет** запрет Always/region monitoring из D-034, D-040, D-044 **только для геозон**; фоновая геолокация (`UIBackgroundModes`, `allowsBackgroundLocationUpdates`, significant-change) по-прежнему запрещена
- **Решение:**
  - Создание только пользователем (или из Action Draft `geofence_create` с подтверждением): «Определить текущее место» (When In Use, одна фиксация) или координаты черновика → имя (1…40, только локально) и радиус (100, 200, 500 или 1000 м) → preview → «Зарегистрировать геозону» → отдельное подтверждение → **только тут** запрос Always (если не выдан) → регистрация `CLCircularRegion` → событие `geofence.created`.
  - Без Always геозона не создаётся (не обещаем неработающий фоновый триггер); экран и Capability Lab объясняют, что нужно «Всегда» в Настройках.
  - Координаты округляются до **4 знаков** (≈11 м) до сохранения и отправки; хранятся только в `geofences.json` (file protection, без backup) — для повторной регистрации региона; в `geofence.created` уходят только после подтверждения; в событиях пересечения и удаления координат нет. Никаких location samples, маршрутов и трекинга.
  - Регионы Connector имеют идентификатор `app.katana.connector.geofence.<uuid>`; при запуске и возврате в приложение состояние сверяется с системой: чужие регионы с этим префиксом, которых нет среди включённых геозон, снимаются (скрытых геозон нет); отсутствующие в системе включённые регистрируются заново и помечаются `interrupted` до следующего пересечения. UI показывает реальное состояние: «активна» / «не зарегистрирована системой» / «нет разрешения Всегда» / «выключена».
  - Лимит: не больше 20 включённых геозон (лимит Core Location); всего хранится не больше 20.
  - Пересечения: событие `geofence.transitioned` создаётся автоматически — это прямое следствие подтверждённой пользователем геозоны, текст создания об этом говорит. Дубли (та же геозона и тот же переход в течение 120 с) отбрасываются. Запись пересечения сохраняется в файл до enqueue и повторяется с тем же `event_id`. `delivery_context`: `foreground` / `background`.
  - Выключение снимает системный регион (без события); удаление — с подтверждением, снимает регион, стирает координаты, событие `geofence.removed`.

## D-050 Захват «Поделиться с Katana» и Share Extension

- **Статус:** accepted (V3-001)
- **Решение:**
  - Типы (один attachment за операцию): `text` (UTF-8, ≤ 10 000 Unicode scalars, без NUL), `url` (только `http`/`https`, ≤ 2048, без user/password), `image` (JPEG/PNG/HEIC, ≤ 10 MiB), `pdf` (≤ 10 MiB), `file` — только allowlist: plain text `.txt`, CSV `.csv`, JSON `.json` (≤ 5 MiB, валидный UTF-8). Тип определяется по сигнатуре содержимого и сверяется с заявленным расширением/UTI; несовпадение → отказ. Фактический размер проверяется по байтам.
  - Имя файла нормализуется: только последний компонент, без `/`, `\`, `..`, управляющих символов и ведущих точек, ≤ 100 символов, расширение из allowlist. Имя показывается только в preview и **никуда не отправляется**.
  - Изображения перед сохранением в inbox перекодируются в тот же формат без метаданных (EXIF, GPS, TIFF, IPTC, XMP), сохраняется только ориентация; если перекодировать нельзя — захват отклоняется. PDF и прочие файлы не очищаются (ограничение v0.3, показывается в preview). OCR нет.
  - Inbox: версионированные записи (`manifest` + `payload`) в `Application Support/KatanaConnector/CaptureInbox/` (с App Group — в общем контейнере, D-046), атомарно, file protection, без backup; TTL 24 ч для неподтверждённых; не больше 10 записей и 50 MiB; битая/неизвестная запись → `quarantine/`.
  - Ничего не отправляется автоматически: preview → «Отправить в Katana» (подтверждение) → основное приложение заново проверяет запись → `PUT /api/connector/captures/{capture_id}` с существующей Bearer-аутентификацией → `object_ref` → событие `share.capture.created`. «Отменить» → `share.capture.cancelled` (без содержимого) и удаление файлов. Временные файлы удаляются после завершения или отмены; в истории остаются только вид, корзина размера и статус.
  - Extension не получает токен, не обращается к Katana и не исполняет команд; пишет только в inbox App Group.
  - Текст и URL уходят только в теле upload после подтверждения; в событиях нет содержимого, URL, имени файла, путей, PHAsset ID и метаданных.

## D-051 События и capabilities v0.3

- **Статус:** accepted (V3-001); расширяет D-038, D-016
- **Решение:** новые типы `action_draft.accepted`, `nfc.action.completed`, `geofence.created`, `geofence.transitioned`, `geofence.removed`, `share.capture.created`, `share.capture.cancelled` — по правилам D-038 (точные ключи, `event_id` один раз, существующая очередь и scope). Новые `CapabilityID` (wire values добавляются, существующие не меняются): `core_nfc_write`, `app_group`, `share_extension`, `location_always`, `region_monitoring`; существующий `core_nfc` = чтение NFC. Новые коды `detail`: `always_authorized`, `region_monitoring_available`, `requires_settings`. Capability Lab получает два ручных probe — `location_always` и `region_monitoring` (Always запрашивается только кнопкой); `core_nfc`, `core_nfc_write`, `app_group`, `share_extension` показываются как `missing_entitlement` без кнопки; `background_location` остаётся `planned` (не используется). Отдельные измерения availability / authorization / probe не смешиваются; «requires_settings» — подпись UI для `denied` и код `detail`.

## D-052 Хранение v0.3

- **Статус:** accepted (V3-001); дополняет D-043
- **Решение:** новые файлы, все v1, на `VersionedJSONFileStore` (атомарно, file protection, без backup, quarantine): `ActionDrafts/action-drafts.json` (принятые черновики), `NFCActions/nfc-actions.json` (регистрации и ожидающие запуски), `Geofences/geofences.json` (геозоны с округлёнными координатами, ожидающие события пересечений, последние переходы для дедупликации), `CaptureInbox/` (каталог записей `<capture_id>.json` + `<capture_id>.payload`, `history.json`, `quarantine/`). Идентификаторы v0.1/v0.2 не меняются; миграций нет.

## D-053 Границы фреймворков v0.3

- **Статус:** accepted (V3-001); уточняет D-024
- **Решение:** Core остаётся без UIKit/SwiftUI/Photos/AVFoundation/CoreLocation/CoreMotion/UserNotifications/CoreNFC. Исключения: `Core/Capture` может использовать `ImageIO`, `CoreGraphics` (очистка метаданных изображений) и `CryptoKit` (SHA-256). CoreNFC — только `Features/NFCActions`; CoreLocation для геозон и Always-probe — только `Features/Geofences/SystemGeofenceAccess.swift` (единственный файл с `requestAlwaysAuthorization` и регистрацией регионов). Share Extension использует только Core/Capture и UIKit/SwiftUI.

---

## Открытые вопросы

| # | Вопрос | Когда решить |
|---|---|---|
| Q-1 | ~~Окончательный Bundle ID и display name~~ — решено в D-012 | KC-002 |
| Q-2 | ~~Модульность: папки или SPM-пакеты~~ — решено в D-013 | KC-002 |
| Q-3 | ~~Откуда берётся адрес API~~ — из QR, только HTTPS (D-020) | KC-004 |
| Q-4 | ~~Несколько аккаунтов на устройстве~~ — одно подключение (D-021) | KC-004 |
| Q-5 | ~~Привязка событий к подключению~~ — решено в D-029 | KC-006 |
| Q-6 | ~~Семантика завершения cleanup-сессии~~ — решено в D-031 | KC-006 |
| Q-9 | Что делать с событиями чужих scope и legacy: ручная отправка после подтверждения или удаление по кнопке | после v0.1 |
| Q-7 | ~~Имя URL scheme и список действий~~ — решено в D-032 | KC-007 |
| Q-8 | ~~Состав probes Capability Lab~~ — решено в D-034 | KC-008 |
| Q-11 | Включать ли Core NFC, App Group и встроенный Share Extension после проверки подписи Sideloadly на iPhone (D-046) | после v0.3 |
| Q-10 | Нужен ли серверный endpoint «черновик использован» отдельно от события `reminder.local.scheduled` (сейчас Katana может считать черновик consumed по событию) | после v0.2 |
