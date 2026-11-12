#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build"; SRC_DIR="$BUILD_ROOT/src"; STATIC_LIBS_DIR="$BUILD_ROOT/static_libs"
die() { echo "❌ $*" >&2; exit 1; }

# C-файл с байтовым массивом: $1=вход, $2=выход, $3=имя переменной (od, xxd не нужен)
generate_c_array() {
    { echo "/* Generated from $(basename "$1") — do not edit */"
      echo "#include <stddef.h>"
      echo "unsigned int $3_len = $(stat -c%s "$1")u;"
      echo "unsigned char $3[] = {"
      od -An -v -tu1 "$1" | awk '{for(i=1;i<=NF;i++) printf "0x%02x,%s", $i, (++n%16?"":"\n")}'
      echo "};"
    } > "$2"
}

[ "${MSYSTEM:-}" = UCRT64 ] || die "Нужно MSYS2 UCRT64 (MSYSTEM=${MSYSTEM:-<не задано>}); запустите C:\\msys64\\ucrt64.exe"

# toolchain — группа пакетов, pacman -Q её не видит; отдельные утилиты
# (gcc, make, strip, objdump) проверяются ниже через command -v.
REQUIRED_PKGS=(mingw-w64-ucrt-x86_64-pkgconf
  mingw-w64-ucrt-x86_64-{zlib-ng-compat,bzip2,xz,zstd,libtre,gettext,libiconv,git,curl}
  autoconf automake libtool autoconf-archive gettext patch)

echo "🔄 pacman -Syu..."
pacman -Syu --noconfirm || pacman -Syu --noconfirm

MISSING=""
for p in "${REQUIRED_PKGS[@]}"; do
    pacman -Q "$p" &>/dev/null || MISSING+="$p "
done
if [ -z "$MISSING" ]; then
    echo "✅ Все зависимости установлены."
else
    echo "⚠️ Устанавливаю: $MISSING"
    if [ -t 0 ] && [ "${ASSUME_YES:-0}" != 1 ]; then
        read -r -p "Установить? [y/N] " a
        [[ $a =~ ^[Yy]$ ]] || die "Сборка невозможна без пакетов."
    fi
    # shellcheck disable=SC2086
    pacman -S --needed --noconfirm $MISSING
fi
for t in git curl patch make gcc strip objdump sha256sum autoreconf pkg-config; do
    command -v "$t" >/dev/null || die "Нет обязательного инструмента: $t"
done

# Тег file (для воспроизводимости можно задать FILE_TAG=FILE5_48)
LATEST_TAG="${FILE_TAG:-}"
if [ -z "$LATEST_TAG" ]; then
    LATEST_TAG="$(git ls-remote --tags --refs https://github.com/file/file.git 2>/dev/null \
        | awk -F/ '{print $NF}' | grep -E '^FILE[0-9_]+$' | sort -V | tail -n1 || true)"
    [ -n "$LATEST_TAG" ] || die "Не удалось определить тег file (нет доступа к GitHub?). Задайте вручную: FILE_TAG=FILE5_48 $0"
fi
echo "✅ Тег: $LATEST_TAG"

# Интеграция magic.mgc
if [ -z "${INTEGRATE_DB:-}" ]; then
    if [ ! -t 0 ]; then INTEGRATE_DB=0
    else read -r -p "Встроить magic.mgc в file.exe (автономный бинарник)? [y/N] " a
         INTEGRATE_DB=$([[ $a =~ ^[Yy]$ ]] && echo 1 || echo 0)
    fi
fi

OUT_DIR="$BUILD_ROOT/out/$LATEST_TAG$([ "$INTEGRATE_DB" = 1 ] && echo -embedded)"
rm -rf "$SRC_DIR" "$OUT_DIR" "$STATIC_LIBS_DIR"
mkdir -p "$SRC_DIR" "$OUT_DIR" "$STATIC_LIBS_DIR"

# Локальные статические .a: в MinGW-w64 -static не исключает dll.a — линкуем явно
for lib in libtre libintl libiconv libz libbz2 liblzma libzstd; do
    [ -f "/ucrt64/lib/$lib.a" ] || die "Нет /ucrt64/lib/$lib.a (установите mingw-w64-ucrt-x86_64-*)"
    cp -v "/ucrt64/lib/$lib.a" "$STATIC_LIBS_DIR/"
done

# Исходники
cd "$SRC_DIR"
curl -fsSL --retry 3 -o "file.tar.gz" \
    "https://github.com/file/file/archive/refs/tags/$LATEST_TAG.tar.gz" || die "Не скачался архив $LATEST_TAG"
if [ -n "${EXPECTED_SHA256:-}" ]; then echo "$EXPECTED_SHA256  file.tar.gz" | sha256sum -c -
else echo "⚠️ EXPECTED_SHA256 не задан — верификация пропущена."
fi
mkdir source && tar -xzf file.tar.gz -C source --strip-components=1
cd source

# Патчи из vcpkg (для воспроизводимости: VCPKG_TAG=<commit>)
VCPKG_TAG="${VCPKG_TAG:-master}"
BASE="https://raw.githubusercontent.com/microsoft/vcpkg/$VCPKG_TAG/ports/libmagic"
curl -fsSL -o "$SRC_DIR/portfile.cmake" "$BASE/portfile.cmake" || die "Нет portfile.cmake ($VCPKG_TAG)"
PATCHES=$(grep -oE '"[^"]+\.(patch|diff)"' "$SRC_DIR/portfile.cmake" | sed 's/"//g' || true)
[ -n "$PATCHES" ] || die "В portfile.cmake нет патчей (VCPKG_TAG=$VCPKG_TAG)"
mkdir -p "$SRC_DIR/patches"
for p in $PATCHES; do
    curl -fsSL -o "$SRC_DIR/patches/$p" "$BASE/$p" || die "Не скачался патч $p"
    echo "  → $p"
    patch -p1 --forward --batch < "$SRC_DIR/patches/$p" || die "Патч не применился: $p (vcpkg $VCPKG_TAG ≠ $LATEST_TAG?)"
done

# Inline-исправления
sed -i 's/c = cdf_ctime(&ts\.tv_sec, tbuf);/{ const time_t tv_sec = (time_t)(ts.tv_sec); c = cdf_ctime(\&tv_sec, tbuf); }/' src/readcdf.c
grep -q 'const time_t tv_sec' src/readcdf.c || die "sed readcdf.c не применился (исходник изменился?)"
sed -i '/^#include <wchar.h>/a extern int wcwidth(wchar_t);' src/file.c
grep -q 'extern int wcwidth' src/file.c || die "sed file.c (wcwidth) не применился"

# Сборка
# -march=x86-64-v2 вместо native: бинарник запускается на любом x86-64 с 2009 г.
# WIN32_LEAN_AND_MEAN не задаём: fsmagic.c определяет его сам.
# --host совпадает с config.guess UCRT64 → build==host, кросс-компиляция выключена; --build не передаём.
export CFLAGS="-O3 -march=x86-64-v2 -mtune=generic -D_GNU_SOURCE -D_XOPEN_SOURCE=700 \
  -DNDEBUG -D_WIN32_WINNT=0x0A00 -ffunction-sections -fdata-sections -flto"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$STATIC_LIBS_DIR -static -static-libgcc -static-libstdc++ -Wl,--gc-sections -flto"
# libtre.a(regerror.o) зовёт libintl_gettext → -lintl обязателен; LIBS (не LDFLAGS), чтобы libtool включил их в линковку
export LIBS="-lintl -liconv"
configure() {
    ./configure --host=x86_64-w64-mingw32 --prefix="${MINGW_PREFIX:-/ucrt64}" \
        --disable-shared --enable-static --disable-dependency-tracking \
        --disable-silent-rules --disable-libseccomp "$@"
}

autoreconf -fi
echo "⚙️ Конфигурация..."; configure
echo "🔨 Сборка..."; make -j"$(nproc)"

# Встраивание magic.mgc в file.exe
if [ "$INTEGRATE_DB" = 1 ]; then
    MAGIC_MGC="$PWD/magic/magic.mgc"
    [ -f "$MAGIC_MGC" ] || die "Не найден $MAGIC_MGC после первой сборки"
    echo "🔧 Интеграция magic.mgc ($(stat -c%s "$MAGIC_MGC") байт)"
    generate_c_array "$MAGIC_MGC" src/magic_data.c magic_mgc

    # Заменяем только сам вызов magic_load( — граница слова не задевает magic_load_buffers(
    sed -i 's/\bmagic_load(/load_embedded_magic(/g' src/file.c
    grep -q 'load_embedded_magic' src/file.c || die "Не удалось заменить magic_load в file.c"
    # Forward declaration после #include "magic.h" (magic_t уже определён)
    sed -i '/^#include "magic.h"$/a\
\
static int load_embedded_magic(magic_t ck, const char *magicfile);' src/file.c
    grep -q 'static int load_embedded_magic' src/file.c || die "Нет #include \"magic.h\" в file.c"
    cat >> src/file.c <<'EOF'

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
EOF
    # Дописываем magic_data.c в конец строки file_SOURCES (без обратных ссылок)
    sed -i '/^file_SOURCES[[:space:]]*=/s/$/ magic_data.c/' src/Makefile.am
    grep -q 'magic_data\.c' src/Makefile.am || die "Не удалось добавить magic_data.c в file_SOURCES"

    echo "🔄 Пересборка..."
    autoreconf -fi; configure >/dev/null; make -j"$(nproc)" >/dev/null
fi

# Артефакты и проверка
cp -v src/file.exe "$OUT_DIR/"
[ "$INTEGRATE_DB" = 1 ] || cp -v magic/magic.mgc "$OUT_DIR/"
strip --strip-all "$OUT_DIR/file.exe"

DEPS=$(objdump -p "$OUT_DIR/file.exe" | awk '/DLL Name:/{print $3}' | sort -u)
echo -e "\n🔎 Зависимости: $(echo $DEPS)"
if BAD=$(echo "$DEPS" | grep -iE '^(lib(tre|intl|iconv|zstd|bz2|lzma|z|winpthread|gcc_s|stdc\+\+|ssp)|zlib)'); then
    die "Динамические зависимости: $(echo $BAD | tr '\n' ' ') — проверьте .a в /ucrt64/lib"
fi
echo "✅ Все пользовательские библиотеки статические."

# Smoke-тест
echo -e "\n🧪 Smoke-тест..."; "$OUT_DIR/file.exe" -v
if [ "$INTEGRATE_DB" = 1 ]; then
    "$OUT_DIR/file.exe" "$OUT_DIR/file.exe" | grep -q PE32 || die "embedded не распознаёт себя без magic.mgc"
    echo "✅ Smoke-тест (embedded, без внешнего magic.mgc) пройден."
else
    "$OUT_DIR/file.exe" --magic-file "$OUT_DIR/magic.mgc" "$OUT_DIR/file.exe" | grep -q PE32 || die "Не распознаёт PE32"
    echo "✅ Smoke-тест пройден."
fi

echo -e "\n✅ Готово: $OUT_DIR"; ls -la "$OUT_DIR"
