#!/bin/bash
# Linux installer: download the launcher directly; no Windows bootstrapper needed.
set -euo pipefail
umask 022

if [[ -t 1 ]]; then B=$'\033[1m' G=$'\033[32m' R=$'\033[31m' N=$'\033[0m'; else B='' G='' R='' N=''; fi
die() { printf '\n%sОшибка:%s %s\n' "$R$B" "$N" "$*" >&2; exit 1; }
step() { printf '\n%s[%s/3] %s%s\n' "$B" "$1" "$2" "$N"; }
ok() { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
[[ "$(uname -s)" == Linux ]] || die 'Этот установщик предназначен для Linux.'
[[ $# == 0 ]] || die 'Запуск: bash install-loliland.sh'
[[ $EUID != 0 ]] || die 'Не запускайте установщик через sudo: LoliLand ставится для текущего пользователя.'
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
APP="$SHARE/loliland-launcher"
DESKTOP="$SHARE/applications/loliland.desktop"
for tool in curl tar unzip sha512sum sha256sum od stat grep awk; do
  command -v "$tool" >/dev/null || die "Не найдена системная утилита: $tool"
done
# Never replace the app while it is running.
check_old_app() {
  [[ -e "$APP" ]] || return 0
  local procs; procs="$(ps -eo args=)"
  [[ "$procs" != *"$APP/"* ]] || die 'LoliLand сейчас запущен. Закройте его и повторите установку.'
}
check_old_app
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) die "Неподдерживаемая архитектура: $(uname -m). Нужна x86_64 или aarch64." ;;
esac

# Work on the same filesystem; publish only a fully verified application.
mkdir -p "$SHARE/applications"
WORK="$(mktemp -d "$SHARE/.loliland-install.XXXXXX")"
cleanup() { [[ -z "${WORK:-}" ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# download URL FILE [--progress-bar]; small files download silently.
download() {
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 300 --retry 2 --show-error "${3:---silent}" \
    --output "$2" "$1"
}

# Public launcher endpoint, verified independently of the Windows bootstrapper.
SOURCE='https://klauncher.loliland.pro'

BUNDLE="$WORK/loliland-launcher"
mkdir -p "$BUNDLE/runtimes"
printf '%sУстановщик LoliLand для Linux%s\n' "$B" "$N"
step 1 'Лаунчер LoliLand'
download "$SOURCE/api/updater/win64" "$WORK/manifest.json" \
  || die 'Не удалось получить манифест LoliLand. Проверьте сеть и доступность сервера.'
# The manifest is flat JSON: {"launcher":{"hash":"…","size":N},…}
SIZE="$(grep -o '"launcher":{[^}]*}' "$WORK/manifest.json" | grep -o '"size":[0-9]*' | cut -d: -f2)" \
  || die 'Сервер вернул некорректный манифест лаунчера.'
[[ "$SIZE" =~ ^[0-9]+$ && "$SIZE" -gt 0 ]] || die 'Некорректный размер лаунчера в манифесте.'
ok 'Манифест получен'
printf '  Скачиваю launcher.jar (%s МБ)…\n' "$((SIZE / 1048576))"
download "$SOURCE/api/updater/load/launcher" "$BUNDLE/launcher.jar" --progress-bar \
  || die 'Не удалось скачать launcher.jar. Проверьте сеть и доступность сервера.'
[[ "$(stat -c %s "$BUNDLE/launcher.jar")" == "$SIZE" ]] || die 'Размер launcher.jar не совпадает с манифестом.'
ok 'Размер совпадает с манифестом'
unzip -tq "$BUNDLE/launcher.jar" >/dev/null || die 'Архив launcher.jar повреждён.'
unzip -p "$BUNDLE/launcher.jar" META-INF/MANIFEST.MF | tr -d '\r' | grep -x 'Main-Class: loliland.launcher.app.Main' >/dev/null \
  || die 'В JAR не найден основной класс лаунчера LoliLand.'
ok 'Архив цел, лаунчер на месте'

step 2 "Java (JetBrains Runtime с JCEF, $ARCH)"
RUNTIME="jbr_jcef-17.0.11-linux-$ARCH-b1312.2"
URL="https://cache-redirector.jetbrains.com/intellij-jbr/$RUNTIME.tar.gz"
printf '  Скачиваю %s…\n' "$RUNTIME"
download "$URL" "$WORK/$RUNTIME.tar.gz" --progress-bar \
  || die 'Не удалось скачать Java с сервера JetBrains. Проверьте сеть.'
download "$URL.checksum" "$WORK/checksum" \
  || die 'Не удалось скачать контрольную сумму Java.'
EXPECTED="$(awk 'NR == 1 {print $1}' "$WORK/checksum")"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{128}$ ]] || die 'Некорректная контрольная сумма JetBrains.'
ACTUAL="$(sha512sum "$WORK/$RUNTIME.tar.gz" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || die 'SHA-512 архива Java не совпадает. Установка остановлена.'
ok 'SHA-512 совпадает с JetBrains'
printf '  Распаковываю…\n'
tar -xzf "$WORK/$RUNTIME.tar.gz" -C "$BUNDLE/runtimes"
JAVA_HOME_LOCAL="$BUNDLE/runtimes/$RUNTIME"
"$JAVA_HOME_LOCAL/bin/java" -version >/dev/null 2>&1 || die 'Скачанная Java не запускается.'
"$JAVA_HOME_LOCAL/bin/java" --list-modules | grep -E '^jcef(@|$)' >/dev/null || die 'В Java отсутствует JCEF.'
ok 'Java запускается, JCEF на месте'

step 3 'Сборка LoliLand'
printf '%s\n' "$RUNTIME" > "$BUNDLE/runtime-name.txt"
cat > "$BUNDLE/loliland" <<'LAUNCH'
#!/bin/bash
set -euo pipefail
APP="$(dirname -- "$(readlink -f -- "$0")")"
RUNTIME="$(< "$APP/runtime-name.txt")"
export JAVA_HOME="$APP/runtimes/$RUNTIME"
export PATH="$JAVA_HOME/bin:$PATH"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/loliland"
LOG="$DATA/linux-app.log"
mkdir -p "$DATA"
cd -- "$DATA"
# Keep only the current and the previous launch.
[[ ! -f "$LOG" ]] || mv -f -- "$LOG" "$LOG.1"
exec "$JAVA_HOME/bin/java" -jar "$APP/launcher.jar" "$@" > "$LOG" 2>&1
LAUNCH
chmod +x "$BUNDLE/loliland"
bash -n "$BUNDLE/loliland"

# The launcher's favicon.ico ends with a 256px PNG entry; desktops load PNG everywhere, ICO not always.
unzip -p "$BUNDLE/launcher.jar" loliland/application/public/favicon.ico > "$WORK/favicon.ico"
ico_u() { od -An -t "u$1" -j "$2" -N "$1" "$WORK/favicon.ico" | tr -d ' '; }
COUNT="$(ico_u 2 4)"
ENTRY=$((6 + 16 * (COUNT - 1)))
tail -c +"$(( $(ico_u 4 $((ENTRY + 12))) + 1 ))" "$WORK/favicon.ico" | head -c "$(ico_u 4 $((ENTRY + 8)))" > "$BUNDLE/loliland.png"
if [[ "$(od -An -tx1 -N4 "$BUNDLE/loliland.png" | tr -d ' ')" != 89504e47 ]]; then
  rm -f "$BUNDLE/loliland.png"
  cp "$WORK/favicon.ico" "$BUNDLE/loliland.ico"
fi
ICON="$(ls "$BUNDLE"/loliland.png "$BUNDLE"/loliland.ico 2>/dev/null | head -1)"
ICON="$APP/${ICON##*/}"

printf 'Launcher source: %s/api/updater/load/launcher\nRuntime source: %s\nRuntime SHA-512: %s\n' \
  "$SOURCE" "$URL" "$ACTUAL" > "$BUNDLE/install-info.txt"
sha256sum "$BUNDLE/launcher.jar" | awk '{print "Launcher SHA-256: " $1}' >> "$BUNDLE/install-info.txt"
cat > "$WORK/loliland.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=LoliLand
Comment=Лаунчер LoliLand
Exec="$APP/loliland"
Icon=$ICON
Terminal=false
Categories=Game;
DESK
! command -v desktop-file-validate >/dev/null || desktop-file-validate "$WORK/loliland.desktop"
ok 'Приложение собрано'
check_old_app
# The old app goes into WORK, so the EXIT trap deletes it after a successful swap.
if [[ -e "$APP" ]]; then
  mv -- "$APP" "$WORK/old"
  ok 'Предыдущая версия LoliLand заменена'
fi
mv -- "$BUNDLE" "$APP" || { mv -- "$WORK/old" "$APP" 2>/dev/null; die 'Не удалось установить новое приложение; старое восстановлено.'; }
mv -f -- "$WORK/loliland.desktop" "$DESKTOP"
! command -v update-desktop-database >/dev/null || update-desktop-database "$SHARE/applications" 2>/dev/null || true

printf '\n%s%s✓ Готово:%s %s\n\n' "$G" "$B" "$N" "$APP"
printf 'LoliLand появился в меню приложений (раздел «Игры»).\n'
printf 'Запуск из терминала: %s/loliland\n\n' "$APP"
