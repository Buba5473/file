#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Конфигурация
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${SCRIPT_DIR}/build"
SRC_DIR="${BUILD_ROOT}/src"
STATIC_LIBS_DIR="${BUILD_ROOT}/static_libs"

# ============================================================================
# Вспомогательные функции
# ============================================================================
# Генерирует C-файл с массивом байтов: unsigned char <var>[] и unsigned int <var>_len.
# Использует od (coreutils) — xxd не требуется.
generate_c_array() {
    local input="$1" output="$2" var="$3" size
    size=$(stat -c%s "$input")
    {
        echo "/* Generated from $(basename "$input") — do not edit */"
        echo "#include <stddef.h>"
        echo ""
        echo "unsigned int ${var}_len = ${size}u;"
        echo "unsigned char ${var}[] = {"
        od -An -v -tu1 "$input" | awk '{
            for (i = 1; i <= NF; i++) {
                printf "0x%02x,", $i
                if (++n % 16 == 0) printf "\n"
            }
        }'
        echo ""
        echo "};"
    } > "$output"
}

# ============================================================================
# Проверка окружения MSYS2 UCRT64
# ============================================================================
if [ "${MSYSTEM:-}" != "UCRT64" ]; then
  echo "❌ Скрипт рассчитан на MSYS2 UCRT64 (MSYSTEM=UCRT64)." >&2
  echo "   Текущее окружение: MSYSTEM=${MSYSTEM:-<не задано>}" >&2
  echo "   Запустите через C:\\msys64\\ucrt64.exe или выставьте MSYSTEM=UCRT64." >&2
  exit 1
fi

command -v pacman >/dev/null 2>&1 || { echo "❌ pacman не найден" >&2; exit 1; }

# ============================================================================
# Проверка и установка зависимостей
# ============================================================================
REQUIRED_PKGS=(
  "mingw-w64-ucrt-x86_64-toolchain"
  "mingw-w64-ucrt-x86_64-pkg-config"
  "mingw-w64-ucrt-x86_64-zlib-ng-compat"
  "mingw-w64-ucrt-x86_64-bzip2"
  "mingw-w64-ucrt-x86_64-xz"
  "mingw-w64-ucrt-x86_64-zstd"
  "mingw-w64-ucrt-x86_64-libtre"
  "mingw-w64-ucrt-x86_64-gettext"
  "mingw-w64-ucrt-x86_64-libiconv"
  "autoconf"
  "automake"
  "libtool"
  "autoconf-archive"
  "gettext"          # msys/gettext — даёт autopoint для autoreconf
  "mingw-w64-ucrt-x86_64-git"
  "mingw-w64-ucrt-x86_64-curl"
  "patch"
  "mingw-w64-ucrt-x86_64-pkgconf"
)

echo "🔄 Полный апгрейд MSYS2 (pacman -Syu)..."
pacman -Syu --noconfirm || pacman -Syu --noconfirm

echo "🔎 Проверка зависимостей..."
set +e
PACMAN_OUT=$(pacman -T "${REQUIRED_PKGS[@]}" 2>&1)
PACMAN_RC=$?
set -e

if [ "$PACMAN_RC" -eq 0 ]; then
  MISSING_PKGS=""
elif [ "$PACMAN_RC" -eq 127 ]; then
  MISSING_PKGS="$PACMAN_OUT"
else
  echo "❌ Ошибка pacman -T (код $PACMAN_RC):" >&2
  echo "$PACMAN_OUT" >&2
  exit 1
fi

if [[ -n "$MISSING_PKGS" ]]; then
  echo "⚠️  Отсутствуют следующие пакеты:"
  echo "$MISSING_PKGS" | sed 's/^/   - /'

  if [ "${ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    answer="y"
    echo "   (неинтерактивный режим — устанавливаем автоматически)"
  else
    read -r -p "Установить их сейчас? [y/N] " answer
  fi

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    # shellcheck disable=SC2086
    pacman -S --needed --noconfirm $MISSING_PKGS
  else
    echo "❌ Сборка невозможна без указанных пакетов." >&2
    exit 1
  fi
else
  echo "✅ Все зависимости установлены."
fi

for tool in git curl patch sed make gcc strip objdump sha256sum autoreconf pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ Не найден обязательный инструмент: $tool" >&2; exit 1; }
done

# ============================================================================
# Определение latest tag для file
# ============================================================================
if [ -n "${FILE_TAG:-}" ]; then
  LATEST_TAG="$FILE_TAG"
  echo "📌 Используется явно заданный тег: $LATEST_TAG"
else
  echo "🔍 Поиск последнего тега file..."
  # || true: pipefail не должен убить скрипт до if ниже.
  LATEST_TAG=$(git ls-remote --tags --refs https://github.com/file/file.git 2>/dev/null \
    | awk -F'/' '{print $NF}' \
    | grep -E '^FILE[0-9_]+$' \
    | sort -V \
    | tail -n1 || true)
fi

if [ -z "${LATEST_TAG:-}" ]; then
  echo "❌ Не удалось определить последний тег file." >&2
  echo "   Задайте его вручную: FILE_TAG=FILE5_48 $0" >&2
  exit 1
fi
echo "✅ Тег: $LATEST_TAG"

# ============================================================================
# Интеграция базы в исполняемый файл
# ============================================================================
INTEGRATE_DB="${INTEGRATE_DB:-}"
if [ -z "$INTEGRATE_DB" ]; then
  if [ ! -t 0 ]; then
    INTEGRATE_DB=0
  else
    read -r -p "Встроить magic.mgc в file.exe (автономный бинарник)? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      INTEGRATE_DB=1
    else
      INTEGRATE_DB=0
    fi
  fi
fi
if [ "$INTEGRATE_DB" = "1" ]; then
  echo "📦 Будет выполнена интеграция magic.mgc в file.exe"
else
  echo "📄 Обычная сборка (magic.mgc рядом с file.exe)"
fi

# ============================================================================
# Каталоги
# ============================================================================
if [ "$INTEGRATE_DB" = "1" ]; then
  OUT_DIR="${BUILD_ROOT}/out/${LATEST_TAG}-embedded"
else
  OUT_DIR="${BUILD_ROOT}/out/${LATEST_TAG}"
fi
rm -rf "$SRC_DIR" "$OUT_DIR" "$STATIC_LIBS_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR" "$STATIC_LIBS_DIR"

# ============================================================================
# Локальные статические библиотеки
# ============================================================================
# В MinGW-w64 -static не всегда исключает динамическую линковку: если в
# /ucrt64/lib есть только .dll.a, линкер может выбрать её. Копируем .a и
# добавляем -L, чтобы линкер взял именно статический архив.
echo "📚 Подготовка локальных статических библиотек..."
STATIC_LIBS=(libtre.a libintl.a libiconv.a libz.a libbz2.a liblzma.a libzstd.a)
for lib in "${STATIC_LIBS[@]}"; do
  if [[ -f "/ucrt64/lib/$lib" ]]; then
    cp -v "/ucrt64/lib/$lib" "$STATIC_LIBS_DIR/"
  else
    echo "❌ Не найден /ucrt64/lib/$lib" >&2
    echo "   Установите соответствующий mingw-w64-ucrt-x86_64-* пакет." >&2
    exit 1
  fi
done

# ============================================================================
# Загрузка исходников
# ============================================================================
echo "⬇️  Загрузка исходников..."
cd "$SRC_DIR"
ARCHIVE="file-${LATEST_TAG}.tar.gz"
curl -fL --retry 3 -o "$ARCHIVE" \
  "https://github.com/file/file/archive/refs/tags/${LATEST_TAG}.tar.gz"

if [ -n "${EXPECTED_SHA256:-}" ]; then
  echo "🔐 Проверка SHA256..."
  echo "${EXPECTED_SHA256}  ${ARCHIVE}" | sha256sum -c -
else
  echo "⚠️  SHA256 не указан (задайте EXPECTED_SHA256 для верификации)."
fi

mkdir -p source
tar -xzf "$ARCHIVE" -C source --strip-components=1
cd source

# ============================================================================
# Патчи: автоматическое извлечение из portfile.cmake vcpkg
# ============================================================================
# По умолчанию берём master vcpkg — он содержит актуальный набор патчей для
# последней версии file. Для воспроизводимости можно зафиксировать коммит,
# например: VCPKG_TAG=e1ddd4f ./build-file.sh
VCPKG_TAG="${VCPKG_TAG:-master}"
VCPKG_PORT_URL="https://raw.githubusercontent.com/microsoft/vcpkg/${VCPKG_TAG}/ports/libmagic/portfile.cmake"

echo "🩹 Загрузка portfile.cmake vcpkg (${VCPKG_TAG})..."
PORTFILE="${SRC_DIR}/portfile.cmake"
if ! curl -fsSL -o "$PORTFILE" "$VCPKG_PORT_URL"; then
  echo "❌ Не удалось скачать portfile.cmake: $VCPKG_PORT_URL" >&2
  exit 1
fi

# Извлекаем имена всех патчей в порядке появления в файле.
PATCHES=$(grep -oE '"[^"]+\.(patch|diff)"' "$PORTFILE" | sed 's/"//g' || true)

if [ -z "$PATCHES" ]; then
  echo "❌ В portfile.cmake не найдено ни одного патча. Проверьте VCPKG_TAG=${VCPKG_TAG}." >&2
  exit 1
fi

echo "📋 Найдены патчи:"
echo "$PATCHES" | sed 's/^/   - /'

PATCH_CACHE="${SRC_DIR}/patches"
mkdir -p "$PATCH_CACHE"
VCPKG_PATCH_BASE="https://raw.githubusercontent.com/microsoft/vcpkg/${VCPKG_TAG}/ports/libmagic"

while IFS= read -r patch; do
  [[ -z "$patch" ]] && continue
  patch_file="${PATCH_CACHE}/${patch}"
  if ! curl -fsSL -o "$patch_file" "${VCPKG_PATCH_BASE}/${patch}"; then
    echo "❌ Не удалось скачать патч: $patch" >&2
    exit 1
  fi
  echo "  → $patch"
  if ! patch -p1 --forward --batch < "$patch_file"; then
    echo "❌ Патч не применился: $patch" >&2
    echo "   Вероятно, VCPKG_TAG=${VCPKG_TAG} ещё не содержит патчей для ${LATEST_TAG}." >&2
    exit 1
  fi
done <<< "$PATCHES"

# ============================================================================
# Inline-исправления (с проверкой применения)
# ============================================================================
echo "🔧 Inline-исправление time_t в readcdf.c..."
sed -i 's/c = cdf_ctime(&ts\.tv_sec, tbuf);/{ const time_t tv_sec = (time_t)(ts.tv_sec); c = cdf_ctime(\&tv_sec, tbuf); }/' src/readcdf.c
if ! grep -q 'const time_t tv_sec = (time_t)(ts.tv_sec);' src/readcdf.c; then
  echo "❌ sed-патч readcdf.c не применился (исходник изменился?)" >&2
  exit 1
fi

echo "🔧 Inline-объявление wcwidth в file.c..."
sed -i '/^#include <wchar.h>/a extern int wcwidth(wchar_t);' src/file.c
if ! grep -q 'extern int wcwidth(wchar_t);' src/file.c; then
  echo "❌ sed-патч file.c (wcwidth) не применился" >&2
  exit 1
fi

# ============================================================================
# Генерация configure
# ============================================================================
echo "🔧 Генерация configure через autoreconf..."
autoreconf -fi

# ============================================================================
# Конфигурация сборки (native, без cross-compile)
# ============================================================================
echo "⚙️  Конфигурация..."
# -march=x86-64-v2 вместо native: бинарник должен запускаться не только на
# сборочной машине (SSE4.2/POPCNT поддерживаются всем x86-64 с 2009 г.).
# WIN32_LEAN_AND_MEAN НЕ передаётся: fsmagic.c определяет его сам, и
# дублирование через -D даёт warning о переопределении.
export CFLAGS="-O3 -march=x86-64-v2 -mtune=generic -m64 \
  -D_GNU_SOURCE -D_XOPEN_SOURCE=700 \
  -DNDEBUG -D_WIN32_WINNT=0x0A00 \
  -ffunction-sections -fdata-sections -flto"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L${STATIC_LIBS_DIR} -static \
  -static-libgcc -static-libstdc++ \
  -Wl,--gc-sections -flto"

# libtre.a(regerror.o) вызывает libintl_gettext, поэтому -lintl обязателен.
# -liconv добавлен на случай, если libintl собран с зависимостью от iconv.
# LIBS (а не LDFLAGS) — чтобы libtool гарантированно включил их в линковку
# file.exe и libmagic.la.
export LIBS="-lintl -liconv"

# --host совпадает с config.guess в UCRT64 → build == host, cross-compile
# выключен, тестовые программы autoconf запускаются как обычные Windows-exe.
# --build НЕ передаём намеренно.
# --with-libintl-prefix / --with-libiconv-prefix убраны: configure file(1)
# их не распознаёт.
./configure \
  --host=x86_64-w64-mingw32 \
  --prefix="${MINGW_PREFIX:-/ucrt64}" \
  --disable-shared \
  --enable-static \
  --disable-dependency-tracking \
  --disable-silent-rules \
  --disable-libseccomp

# ============================================================================
# Сборка (первый проход)
# ============================================================================
echo "🔨 Сборка..."
make -j"$(nproc)"

# ============================================================================
# Интеграция magic.mgc в file.exe (опционально)
# ============================================================================
if [ "$INTEGRATE_DB" = "1" ]; then
  echo "🔧 Интеграция magic.mgc в file.exe..."

  MAGIC_MGC="${PWD}/magic/magic.mgc"
  if [ ! -f "$MAGIC_MGC" ]; then
    echo "❌ Не найден $MAGIC_MGC после первой сборки" >&2
    exit 1
  fi
  echo "   Размер magic.mgc: $(stat -c%s "$MAGIC_MGC") байт"

  # 1. Сгенерировать src/magic_data.c
  generate_c_array "$MAGIC_MGC" "src/magic_data.c" "magic_mgc"

  # 2. Заменить magic_load на load_embedded_magic в src/file.c.
  # Матчим сам вызов, а не окружающий `if (...) {`: в FILE5_48
  # формулировка может отличаться. \b гарантирует, что
  # magic_load_buffers(...) не будет задет.
  if ! grep -q 'magic_load' src/file.c; then
    echo "❌ В file.c не найдено ни одного вызова magic_load" >&2
    exit 1
  fi
  sed -i 's/\bmagic_load(/load_embedded_magic(/g' src/file.c
  if ! grep -q 'load_embedded_magic' src/file.c; then
    echo "❌ Не удалось заменить magic_load на load_embedded_magic" >&2
    echo "🔍 Строки с 'magic_load' в file.c (${LATEST_TAG}):" >&2
    grep -n 'magic_load' src/file.c >&2 || echo "   (не найдено)" >&2
    exit 1
  fi

  # 3. Forward declaration — ПОСЛЕ #include "magic.h", где magic_t уже
  # определён. В file.c (FILE5_48) #include "magic.h" идёт после
  # #include "file.h", поэтому вставка после file.h ломалась
  # (unknown type name 'magic_t').
  if ! grep -q '^#include "magic.h"$' src/file.c; then
    echo "❌ В file.c не найдено #include \"magic.h\" — некуда вставить forward declaration" >&2
    exit 1
  fi
  sed -i '/^#include "magic.h"$/a\
\
/* BEGIN embedded magic database */\
static int load_embedded_magic(magic_t ck, const char *magicfile);\
/* END embedded magic database */' src/file.c
  if ! grep -q 'static int load_embedded_magic(magic_t ck' src/file.c; then
    echo "❌ Не удалось вставить forward declaration в file.c" >&2
    exit 1
  fi

  # 4. Тело функции — в конец file.c
  cat >> src/file.c <<'FILE_EOF'

/* BEGIN embedded magic database */
extern unsigned char magic_mgc[];
extern unsigned int magic_mgc_len;
static int
load_embedded_magic(magic_t ck, const char *magicfile)
{
	(void)magicfile;
	void *buf = (void *)magic_mgc;
	size_t sz = (size_t)magic_mgc_len;
	return magic_load_buffers(ck, &buf, &sz, 1);
}
/* END embedded magic database */
FILE_EOF

  # 5. Добавить magic_data.c в src/Makefile.am
  if ! grep -q '^file_SOURCES.*magic_data\.c' src/Makefile.am; then
    sed -i 's/^\(file_SOURCES[[:space:]]*=[[:space:]]*\)\(.*\)$/\1\2 magic_data.c/' src/Makefile.am
    if ! grep -q '^file_SOURCES.*magic_data\.c' src/Makefile.am; then
      echo "❌ Не удалось добавить magic_data.c в file_SOURCES" >&2
      exit 1
    fi
  fi

  # 6. Пересборка с интегрированной базой
  echo "🔄 Пересборка с встроенной базой..."
  autoreconf -fi >/dev/null 2>&1 || autoreconf -fi
  ./configure \
    --host=x86_64-w64-mingw32 \
    --prefix="${MINGW_PREFIX:-/ucrt64}" \
    --disable-shared \
    --enable-static \
    --disable-dependency-tracking \
    --disable-silent-rules \
    --disable-libseccomp >/dev/null
  make -j"$(nproc)" >/dev/null
  echo "✅ Пересборка с встроенной базой завершена"
fi

# ============================================================================
# Артефакты
# ============================================================================
echo "📦 Копирование артефактов..."
cp -v src/file.exe "$OUT_DIR/"
if [ "$INTEGRATE_DB" = "1" ]; then
  echo "   (magic.mgc не копируется — он встроен в file.exe)"
else
  cp -v magic/magic.mgc "$OUT_DIR/"
fi

# ============================================================================
# Стриппинг
# ============================================================================
if command -v strip >/dev/null 2>&1; then
  echo "✂️  Стриппинг..."
  strip --strip-all "$OUT_DIR/file.exe"
fi

# ============================================================================
# Проверка зависимостей
# ============================================================================
echo -e "\n🔎 Зависимости $OUT_DIR/file.exe:"
DEPS=$(objdump -p "$OUT_DIR/file.exe" | grep "DLL Name:" | awk '{print $3}' | sort -u)
echo "$DEPS" | sed 's/^/  /'

BAD_DEPS=$(echo "$DEPS" | grep -iE '^(lib(tre|intl|iconv|zstd|bz2|lzma|z|winpthread|gcc_s|stdc\+\+|ssp)|zlib)' || true)
if [ -n "$BAD_DEPS" ]; then
  echo "" >&2
  echo "❌ ОШИБКА: обнаружены динамические зависимости от пользовательских библиотек:" >&2
  echo "$BAD_DEPS" | sed 's/^/   - /' >&2
  echo "   Проверьте наличие статических архивов в /ucrt64/lib." >&2
  exit 1
fi
echo "✅ Все пользовательские библиотеки слинкованы статически."

# ============================================================================
# Smoke-тест
# ============================================================================
echo -e "\n🧪 Smoke-тест..."
"$OUT_DIR/file.exe" -v
if [ "$INTEGRATE_DB" = "1" ]; then
  # Встроенная база: проверяем БЕЗ --magic-file и без magic.mgc рядом
  if ! "$OUT_DIR/file.exe" "$OUT_DIR/file.exe" | grep -q 'PE32'; then
    echo "❌ file.exe (embedded) не распознаёт себя как PE32 без magic.mgc" >&2
    exit 1
  fi
  echo "✅ Smoke-тест (embedded, без внешнего magic.mgc) пройден."
else
  if ! "$OUT_DIR/file.exe" --magic-file "$OUT_DIR/magic.mgc" "$OUT_DIR/file.exe" | grep -q 'PE32'; then
    echo "❌ file.exe не распознаёт собственный бинарник как PE32" >&2
    exit 1
  fi
  echo "✅ Smoke-тест пройден."
fi

echo -e "\n✅ Готово. Артефакты в: $OUT_DIR"
ls -la "$OUT_DIR"
