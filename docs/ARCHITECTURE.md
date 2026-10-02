# Архитектура

## Текущее состояние (после KC-003)

Один application target `KatanaConnector` (Bundle ID `app.katana.connector`) и unit-test target `KatanaConnectorTests`, iOS 16+, SwiftUI, проект генерируется XcodeGen из `project.yml`. Модули — папки (D-013).

```
Sources/
├── App/
│   ├── KatanaConnectorApp.swift      @main, создаёт SweepStore и CapabilityRegistry, RootView
│   └── RootView.swift                NavigationStack, AppRoute → экраны функций
├── Core/                             только Foundation; без UI, PhotoKit, сети, Keychain
│   ├── Capabilities/
│   │   ├── CapabilityID.swift        18 стабильных идентификаторов (snake_case wire values)
│   │   ├── CapabilityModels.swift    Availability / Authorization / ProbeState, Category, Descriptor, Snapshot
│   │   └── CapabilityRegistry.swift  каталог + CapabilitySnapshotProviding + статический provider
│   └── Connector/
│       └── ConnectorModels.swift     ConnectorConnectionState, ConnectorDeviceSummary, ConnectorJSON
└── Features/
    ├── Dashboard/
    │   └── DashboardView.swift       подключение, «Разобрать скриншоты», возможности из registry, техблок
    └── ScreenshotCleanup/
        ├── SweepStore.swift          авторизация PhotoKit, выборка, решения, undo, удаление
        └── ScreenshotCleanupViews.swift  ScreenshotCleanupView (вход в функцию), SweepView, ReviewView и др.
Tests/
└── KatanaConnectorTests/             XCTest; компилирует Sources/Core напрямую, без host app (D-018)
```

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
| `ConnectorCore` (`Sources/Core`) | Есть: capability-модели, `CapabilityRegistry`, `ConnectorConnectionState`, `ConnectorDeviceSummary`. Будут: `ConnectorEvent`, протоколы сервисов | — |
| `Pairing` | Разбор QR-payload, обмен pairing-кода на device token, revoke | `ConnectorCore`, `APIClient`, `Keychain` |
| `Keychain` | Обёртка над Security framework для device token | — |
| `EventQueue` | Persistent-очередь событий: запись до отправки, повтор, дедупликация по `event_id` | `ConnectorCore` |
| `APIClient` | HTTPS-запросы к Katana API, авторизация токеном, разбор ответов | `ConnectorCore`, `Keychain` |
| `URLRouter` | Разбор и валидация входящих URL, маршрутизация в функции | `ConnectorCore` |
| `Features/ScreenshotCleanup` | Исходный ScreenshotSweep (`SweepStore`, views) + формирование итогов сессии | `ConnectorCore`, `EventQueue` (через протокол) |
| `Features/CapabilityLab` | Независимые probes, отчёт о capabilities | `ConnectorCore` |

Правила зависимостей:

- Функции (`Features/*`) не знают про `APIClient` и сеть — они только кладут события в очередь через протокол.
- `ConnectorCore` не импортирует UIKit/Photos/SwiftUI.
- PhotoKit используется только в `Features/ScreenshotCleanup`.
- Нет сторонних зависимостей. Модули — папки `Sources/App`, `Sources/Features/<Feature>`, `Sources/Shared` (только реально общее); новые папки создаются вместе с кодом, без пустых заготовок.

### Поток данных Screenshot Cleanup

1. Пользователь открывает Screenshot Cleanup с Dashboard (позже — и по URL из PWA, KC-007).
2. При входе в функцию запрашивается доступ к фото (только сейчас, не при запуске).
3. Создаётся `session_id`, фиксируется `started_at`.
4. Разбор как сейчас; удаление — только через `deleteCandidates()` с двойным подтверждением.
5. По завершении сессии формируется событие `screenshots.cleanup.completed` (только счётчики и время) и **атомарно** пишется в очередь.
6. `EventQueue` отправляет пакет через `APIClient`, когда устройство спарено и есть сеть; удаляет событие из очереди только после подтверждения сервера (`accepted` или `duplicate`).

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
