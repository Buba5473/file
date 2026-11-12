# build-file.sh

Скрипт сборки `file(1)` (libmagic) для Windows в окружении **MSYS2 UCRT64**.
Собирает полностью статический `file.exe`, который не зависит от пользовательских DLL,
с автоматическим подхватом актуальной версии `file`, патчей vcpkg и опциональной
интеграцией базы `magic.mgc` прямо в исполняемый файл.

> 🇬🇧 [English version](#english)

---

## Содержание

- [Что делает скрипт](#что-делает-скрипт)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Артефакты](#артефакты)
- [Переменные окружения](#переменные-окружения)
- [Примеры](#примеры)
- [Портативное использование](#портативное-использование)
- [Как это работает](#как-это-работает)
- [Возможные проблемы](#возможные-проблемы)
- [Лицензии и источники](#лицензии-и-источники)

---

## Что делает скрипт

1. Проверяет, что запущен в **MSYS2 UCRT64** (`MSYSTEM=UCRT64`).
2. Проверяет и при необходимости доустанавливает зависимости через `pacman`.
3. Определяет **последний тег `file`** на GitHub (или берёт `FILE_TAG` из окружения).
4. Скачивает `portfile.cmake` из [vcpkg](https://github.com/microsoft/vcpkg/tree/master/ports/libmagic) и автоматически извлекает из него **актуальный список патчей** для Windows — не нужно вручную поддерживать список при обновлении `file`.
5. Скачивает и применяет патчи, делает несколько inline-правок (`readcdf.c`, `file.c`), при необходимости генерирует `configure` через `autoreconf`.
6. Собирает `file.exe` с **полностью статической линковкой** пользовательских библиотек: `libtre`, `libintl`, `libiconv`, `zlib`, `bzip2`, `liblzma`, `zstd`.
7. **Опционально** встраивает `magic.mgc` в `file.exe` (см. ниже).
8. Проверяет зависимости итогового `file.exe` через `objdump -p` — падает, если обнаружены динамические ссылки на пользовательские библиотеки.
9. Запускает smoke-тест: `file.exe` должен распознать сам себя как `PE32`.

---

## Требования

- Windows с установленным [MSYS2](https://www.msys2.org/).
- Запуск **из шелла UCRT64** (`C:\msys64\ucrt64.exe`).
- ~2 ГБ свободного места (toolchain + исходники + сборочные артефакты).
- Интернет: GitHub (исходники `file`), vcpkg (патчи), зеркала MSYS2 (`pacman`).

---

## Быстрый старт

```bash
# из C:\msys64\ucrt64.exe
cd /path/to/project
./build-file.sh
```

Скрипт интерактивно спросит:

1. Устанавливать ли отсутствующие пакеты (если чего-то не хватает).
2. Встраивать ли `magic.mgc` в `file.exe`.

---

## Артефакты

| Режим | Путь | Содержимое |
|---|---|---|
| Обычная сборка | `build/out/<TAG>/` | `file.exe` + `magic.mgc` |
| Со встроенной базой | `build/out/<TAG>-embedded/` | только `file.exe` |

---

## Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `FILE_TAG` | (последний тег) | Зафиксировать версию `file`, например `FILE5_48`. |
| `VCPKG_TAG` | `master` | Зафиксировать коммит/тег vcpkg для набора патчей. Пример: `e1ddd4f`. |
| `INTEGRATE_DB` | (спрашивать) | `1` — встроить `magic.mgc` в `file.exe`; `0` — обычная сборка. |
| `ASSUME_YES` | `0` | `1` — неинтерактивно устанавливать недостающие пакеты. |
| `EXPECTED_SHA256` | (не задано) | SHA256 архива исходников для верификации. |
| `MINGW_PREFIX` | `/ucrt64` | Значение `--prefix` для `configure` (вкомпилированный путь к `magic.mgc`). |

---

## Примеры

```bash
# Обычная сборка последней версии file
./build-file.sh

# Сборка конкретной версии с явным коммитом vcpkg (воспроизводимо)
FILE_TAG=FILE5_48 VCPKG_TAG=e1ddd4f ./build-file.sh

# Неинтерактивная сборка со встроенной базой (для CI)
FILE_TAG=FILE5_48 INTEGRATE_DB=1 ASSUME_YES=1 ./build-file.sh
```

---

## Портативное использование

При обычной сборке `magic.mgc` лежит рядом с `file.exe`. Укажите `file.exe`, где искать базу:

```cmd
:: cmd.exe
set MAGIC=%~dp0magic.mgc
file.exe some.bin
```

```powershell
# PowerShell
$env:MAGIC = "$PSScriptRoot\magic.mgc"
.\file.exe some.bin
```

Либо явно:

```bash
file.exe --magic-file magic.mgc some.bin
```

Если выбрана интеграция (`INTEGRATE_DB=1`), `magic.mgc` **не нужен** — база уже внутри `file.exe`.

---

## Как это работает

- **Патчи vcpkg.** Вместо жёсткого списка скрипт скачивает `portfile.cmake` из vcpkg и извлекает из него все имена `*.patch` / `*.diff` в порядке применения. Это автоматически подхватывает новые патчи, которые vcpkg добавляет при обновлении `libmagic`. При необходимости зафиксируйте `VCPKG_TAG` на конкретном коммите — получите воспроизводимую сборку.
- **Статическая линковка.** В MinGW-w64 `-static` не всегда исключает динамическую линковку, если в `/ucrt64/lib` есть только `.dll.a`. Скрипт копирует `.a` в `build/static_libs/` и передаёт `-L` в `LDFLAGS` и `LIBS`, чтобы линкер взял именно статические архивы. `-lintl` обязателен: `libtre.a(regerror.o)` вызывает `libintl_gettext`.
- **Встраивание базы.** После первой сборки `magic/magic.mgc` генерируется C-файл `src/magic_data.c` с массивом `magic_mgc[]`. В `src/file.c` вызов `magic_load()` заменяется на `load_embedded_magic()`, которая внутри вызывает штатную `magic_load_buffers()` из `libmagic`. `magic_data.c` добавляется в `src/Makefile.am`, затем выполняется пересборка.

---

## Возможные проблемы

### Патч не применился

Скорее всего, `VCPKG_TAG` не содержит патчей для скачанной версии `file`. Решения:

```bash
# 1. Зафиксировать VCPKG_TAG на коммите, где патчи уже обновлены
VCPKG_TAG=e1ddd4f ./build-file.sh

# 2. Или зафиксировать FILE_TAG на предыдущей версии
FILE_TAG=FILE5_48 ./build-file.sh
```

### `undefined reference to 'libintl_gettext'`

В `LIBS` не попало `-lintl`. Скрипт добавляет его по умолчанию; если патчите скрипт — не убирайте.

### `unknown type name 'magic_t'` при интеграции

Forward declaration вставлен не после того `#include`. Скрипт вставляет после `#include "magic.h"`; если в новом теге `file` этот include переехал — нужно адаптировать.

### Сборка падает с сообщением про динамические зависимости

Проверьте наличие `.a`:

```bash
ls /ucrt64/lib/{libtre,libintl,libiconv,libzstd,libbz2,liblzma,libz}.a
```

Если чего-то нет — установите соответствующий `mingw-w64-ucrt-x86_64-*` пакет.

### `pacman -Syu` ломает окружение в CI

Используйте готовый образ MSYS2 или задайте `ASSUME_YES=1` и обновляйтесь в отдельном шаге CI перед сборкой.

---

## Лицензии и источники

- `file(1)` / `libmagic` — [BSD-2-Clause](https://github.com/file/file/blob/master/COPYING).
- Патчи vcpkg — из репозитория [microsoft/vcpkg](https://github.com/microsoft/vcpkg) (MIT).

---

## English

A build script for `file(1)` (libmagic) on Windows under **MSYS2 UCRT64**.
Produces a fully static `file.exe` that does not depend on any user DLLs,
automatically picks up the latest `file` release, pulls the vcpkg patch set,
and can optionally embed the `magic.mgc` database right into the executable.



---

### Table of contents

- [What the script does](#what-the-script-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Artifacts](#artifacts)
- [Environment variables](#environment-variables)
- [Examples](#examples)
- [Portable usage](#portable-usage)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Licenses and sources](#licenses-and-sources)

---

### What the script does

1. Verifies it is running under **MSYS2 UCRT64** (`MSYSTEM=UCRT64`).
2. Checks and, if necessary, installs missing dependencies via `pacman`.
3. Determines the **latest `file` tag** on GitHub (or takes `FILE_TAG` from the environment).
4. Downloads `portfile.cmake` from [vcpkg](https://github.com/microsoft/vcpkg/tree/master/ports/libmagic) and extracts the **current patch list** for Windows automatically — no need to maintain the list manually when `file` is updated.
5. Downloads and applies patches, makes a few inline fixes (`readcdf.c`, `file.c`), and regenerates `configure` via `autoreconf` if needed.
6. Builds `file.exe` with **fully static linking** of user libraries: `libtre`, `libintl`, `libiconv`, `zlib`, `bzip2`, `liblzma`, `zstd`.
7. **Optionally** embeds `magic.mgc` into `file.exe` (see below).
8. Verifies the resulting `file.exe` dependencies via `objdump -p` — fails if any user library is linked dynamically.
9. Runs a smoke test: `file.exe` must recognize itself as `PE32`.

---

### Requirements

- Windows with [MSYS2](https://www.msys2.org/) installed.
- Run **from the UCRT64 shell** (`C:\msys64\ucrt64.exe`).
- ~2 GB of free disk space (toolchain + sources + build artifacts).
- Internet access: GitHub (for `file` sources), vcpkg (for patches), MSYS2 mirrors (`pacman`).

---

### Quick start

```bash
# from C:\msys64\ucrt64.exe
cd /path/to/project
./build-file.sh
```

The script interactively asks:

1. Whether to install missing packages (if any).
2. Whether to embed `magic.mgc` into `file.exe`.

---

### Artifacts

| Mode | Path | Contents |
|---|---|---|
| Normal build | `build/out/<TAG>/` | `file.exe` + `magic.mgc` |
| Embedded database | `build/out/<TAG>-embedded/` | `file.exe` only |

---

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FILE_TAG` | (latest tag) | Pin the `file` version, e.g. `FILE5_48`. |
| `VCPKG_TAG` | `master` | Pin the vcpkg commit/tag for the patch set. E.g. `e1ddd4f`. |
| `INTEGRATE_DB` | (prompt) | `1` — embed `magic.mgc` into `file.exe`; `0` — normal build. |
| `ASSUME_YES` | `0` | `1` — non-interactive installation of missing packages. |
| `EXPECTED_SHA256` | (unset) | SHA256 of the source archive for verification. |
| `MINGW_PREFIX` | `/ucrt64` | Value of `--prefix` for `configure` (compiled-in path to `magic.mgc`). |

---

### Examples

```bash
# Build the latest file version
./build-file.sh

# Build a specific version with an explicit vcpkg commit (reproducible)
FILE_TAG=FILE5_48 VCPKG_TAG=e1ddd4f ./build-file.sh

# Non-interactive build with embedded database (CI)
FILE_TAG=FILE5_48 INTEGRATE_DB=1 ASSUME_YES=1 ./build-file.sh
```

---

### Portable usage

In a normal build `magic.mgc` sits next to `file.exe`. Tell `file.exe` where to find it:

```cmd
:: cmd.exe
set MAGIC=%~dp0magic.mgc
file.exe some.bin
```

```powershell
# PowerShell
$env:MAGIC = "$PSScriptRoot\magic.mgc"
.\file.exe some.bin
```

Or explicitly:

```bash
file.exe --magic-file magic.mgc some.bin
```

If embedding was enabled (`INTEGRATE_DB=1`), **no `magic.mgc` is needed** — the database is inside `file.exe`.

---

### How it works

- **vcpkg patches.** Instead of a hard-coded list, the script downloads `portfile.cmake` from vcpkg and extracts every `*.patch` / `*.diff` in application order. This automatically picks up new patches that vcpkg adds when `libmagic` is updated. Pin `VCPKG_TAG` to a specific commit for reproducible builds.
- **Static linking.** In MinGW-w64 `-static` does not always prevent dynamic linking if `/ucrt64/lib` only contains `.dll.a`. The script copies `.a` archives to `build/static_libs/` and passes `-L` in `LDFLAGS` and `LIBS`, so the linker picks the static archives. `-lintl` is mandatory: `libtre.a(regerror.o)` calls `libintl_gettext`.
- **Embedding the database.** After the first build, the script turns `magic/magic.mgc` into `src/magic_data.c` with the `magic_mgc[]` array. In `src/file.c`, the `magic_load()` call is replaced with `load_embedded_magic()`, which calls the official `magic_load_buffers()` from `libmagic`. `magic_data.c` is added to `src/Makefile.am`, and the project is rebuilt.

---

### Troubleshooting

#### A patch fails to apply

Most likely `VCPKG_TAG` does not yet contain patches for the downloaded `file` version. Solutions:

```bash
# 1. Pin VCPKG_TAG to a commit where patches are already updated
VCPKG_TAG=e1ddd4f ./build-file.sh

# 2. Or pin FILE_TAG to the previous version
FILE_TAG=FILE5_48 ./build-file.sh
```

#### `undefined reference to 'libintl_gettext'`

`-lintl` missing in `LIBS`. The script adds it by default; if you patch the script, keep it.

#### `unknown type name 'magic_t'` during embedding

The forward declaration was inserted after the wrong `#include`. The script inserts it after `#include "magic.h"`; if that include moves in a future `file` tag, adapt accordingly.

#### The build fails with a dynamic-dependencies message

Check that `.a` archives exist:

```bash
ls /ucrt64/lib/{libtre,libintl,libiconv,libzstd,libbz2,liblzma,libz}.a
```

If something is missing, install the corresponding `mingw-w64-ucrt-x86_64-*` package.

#### `pacman -Syu` breaks the environment in CI

Use a prebuilt MSYS2 image, or set `ASSUME_YES=1` and run the upgrade as a separate CI step before building.

---

### Licenses and sources

- `file(1)` / `libmagic` — [BSD-2-Clause](https://github.com/file/file/blob/master/COPYING).
- vcpkg patches — from the [microsoft/vcpkg](https://github.com/microsoft/vcpkg) repository (MIT).
