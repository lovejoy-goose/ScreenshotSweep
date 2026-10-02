# Архитектура

## Текущее состояние (на момент KC-001)

Один target `ScreenshotSweep`, iOS 16+, SwiftUI, проект генерируется XcodeGen из `project.yml`.

| Файл | Роль |
|---|---|
| `Sources/ScreenshotSweepApp.swift` | `@main`, создаёт `SweepStore` и `RootView` |
| `Sources/SweepStore.swift` | Состояние разбора: авторизация PhotoKit, выборка скриншотов, решения, undo, удаление, наблюдение за изменениями медиатеки |
| `Sources/Views.swift` | Все экраны: `RootView`, `SweepView`, `SwipeCard`, `ReviewView`, `AssetImage` и др. |

Ключевые свойства, которые нужно сохранить:

- **Инвариант `SweepStore`:** `assets[0..<history.count]` — уже решённые, в порядке решений; `assets[history.count]` — текущий скриншот. `reload()` поддерживает инвариант при изменениях медиатеки.
- **Единственная точка изменения медиатеки:** `deleteCandidates()` → `PHPhotoLibrary.performChanges` → `PHAssetChangeRequest.deleteAssets`.
- **Подтверждения:** `ReviewView` → `confirmationDialog` → системный диалог iOS. `userCancelled` обрабатывается как «ничего не изменилось».
- Выборка: `mediaType == image` и `mediaSubtypes` содержит `photoScreenshot` (с повторной проверкой в коде), сортировка по `creationDate` по возрастанию.
- Каждые `batchSize = 30` решений открывается экран проверки (если есть кандидаты).

Известное отклонение от целевых правил: доступ к фото запрашивается в `RootView.onAppear` (при старте), а не по явному действию. Исправление запланировано в KC-006.

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

### Модули (логические; физическая структура — KC-002)

| Модуль | Ответственность | Зависит от |
|---|---|---|
| `App` | Точка входа, навигация, композиция зависимостей | все |
| `ConnectorCore` | Модели: `Capability`, `CapabilityStatus`, `ConnectorEvent`, `PairingState`, `DeviceInfo`; протоколы сервисов | — |
| `Pairing` | Разбор QR-payload, обмен pairing-кода на device token, revoke | `ConnectorCore`, `APIClient`, `Keychain` |
| `Keychain` | Обёртка над Security framework для device token | — |
| `EventQueue` | Persistent-очередь событий: запись до отправки, повтор, дедупликация по `event_id` | `ConnectorCore` |
| `APIClient` | HTTPS-запросы к Katana API, авторизация токеном, разбор ответов | `ConnectorCore`, `Keychain` |
| `URLRouter` | Разбор и валидация входящих URL, маршрутизация в функции | `ConnectorCore` |
| `Features/ScreenshotCleanup` | Текущий ScreenshotSweep + формирование итогов сессии | `ConnectorCore`, `EventQueue` (через протокол) |
| `Features/CapabilityLab` | Независимые probes, отчёт о capabilities | `ConnectorCore` |

Правила зависимостей:

- Функции (`Features/*`) не знают про `APIClient` и сеть — они только кладут события в очередь через протокол.
- `ConnectorCore` не импортирует UIKit/Photos/SwiftUI.
- PhotoKit используется только в `Features/ScreenshotCleanup`.
- Нет сторонних зависимостей. Форма модульности (папки в одном target или локальные SPM-пакеты) решается в KC-002.

### Поток данных Screenshot Cleanup

1. Пользователь открывает Screenshot Cleanup (из главного экрана или по URL из PWA).
2. Пользователь нажимает «Начать» → запрашивается доступ к фото (только сейчас).
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
