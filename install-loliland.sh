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
for tool in curl tar unzip sha512sum sha256sum od stat grep awk ps; do
  command -v "$tool" >/dev/null || die "Не найдена системная утилита $tool. Установите её через пакетный менеджер (например, sudo pacman -S $tool или sudo apt install $tool)."
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
# set -e exits silently; say where it happened.
trap 'die "Непредвиденная ошибка в строке $LINENO (код $?). Приложите это сообщение к issue."' ERR
# download URL FILE [--progress-bar]; small files download silently.
download() {
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --speed-limit 1024 --speed-time 60 --retry 2 --show-error "${3:---silent}" \
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
# The embedded Chromium needs desktop libraries (nss, gtk3, …) that minimal installs may lack;
# without them the launcher shows an empty window, so name them now.
if command -v ldd >/dev/null; then
  MISSING="$(LD_LIBRARY_PATH="$JAVA_HOME_LOCAL/lib:$JAVA_HOME_LOCAL/lib/server" ldd "$JAVA_HOME_LOCAL"/lib/{libcef,libjcef,libawt_xawt}.so 2>/dev/null | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ' || true)"
  [[ -z "$MISSING" ]] || die "Не хватает системных библиотек для лаунчера: $MISSING
Найдите пакеты, которые их содержат (Arch: pacman -F имя, Ubuntu: apt-file search имя), установите и повторите установку."
fi
ok 'Java запускается, JCEF на месте'

# Game clients ship LWJGL natives for linux/x64 only; on arm64 the game dies at
# startup with "Failed to locate library: liblwjgl.so". Supply the official ones.
if [[ "$ARCH" == aarch64 ]]; then
  printf '  Скачиваю LWJGL 3.3.3 для arm64…\n'
  mkdir -p "$BUNDLE/natives"
  for module in lwjgl lwjgl-glfw lwjgl-openal lwjgl-opengl lwjgl-stb lwjgl-tinyfd lwjgl-xxhash; do
    JAR="$module-3.3.3-natives-linux-arm64.jar"
    LURL="https://repo1.maven.org/maven2/org/lwjgl/$module/3.3.3/$JAR"
    download "$LURL" "$WORK/$JAR" && download "$LURL.sha512" "$WORK/$JAR.sha512" \
      || die "Не удалось скачать $JAR с Maven Central. Проверьте сеть."
    [[ "$(sha512sum "$WORK/$JAR" | awk '{print $1}')" == "$(awk 'NR == 1 {print $1}' "$WORK/$JAR.sha512")" ]] \
      || die "SHA-512 $JAR не совпадает. Установка остановлена."
    unzip -qjo "$WORK/$JAR" 'linux/arm64/*.so' -d "$BUNDLE/natives"
  done
  [[ -f "$BUNDLE/natives/liblwjgl.so" ]] || die 'В архивах LWJGL не найдены библиотеки.'
  ok 'LWJGL для arm64 на месте, SHA-512 совпадает с Maven Central'
fi

step 3 'Сборка LoliLand'
printf '%s\n' "$RUNTIME" > "$BUNDLE/runtime-name.txt"
cat > "$BUNDLE/loliland" <<'LAUNCH'
#!/bin/bash
set -euo pipefail
APP="$(dirname -- "$(readlink -f -- "$0")")"
RUNTIME="$(< "$APP/runtime-name.txt")"
export JAVA_HOME="$APP/runtimes/$RUNTIME"
export PATH="$JAVA_HOME/bin:$PATH"
# The launcher itself keeps its data in ~/.local/share/LoliLand.
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/LoliLand"
LOG="$DATA/linux-app.log"
# The game JVM inherits this from the launcher; LWJGL then loads our arm64 natives.
# shortcut: breaks if the install path has spaces, quote it if anyone hits that.
[[ ! -d "$APP/natives" ]] || export JAVA_TOOL_OPTIONS="-Dorg.lwjgl.librarypath=$APP/natives ${JAVA_TOOL_OPTIONS:-}"
mkdir -p "$DATA"
cd -- "$DATA"
# Keep only the current and the previous launch.
[[ ! -f "$LOG" ]] || mv -f -- "$LOG" "$LOG.1"
exec "$JAVA_HOME/bin/java" --add-opens jcef/org.cef=ALL-UNNAMED \
  -cp "$APP/classes:$APP/launcher.jar" LoliLand "$@" > "$LOG" 2>&1
LAUNCH
chmod +x "$BUNDLE/loliland"
bash -n "$BUNDLE/loliland"

# Keyboard fix, compiled here from source with the JBR's own javac.
cat > "$WORK/LoliLand.java" <<'JAVA'
import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.WindowEvent;
import javax.swing.SwingUtilities;
import java.lang.reflect.Field;
import java.util.Collection;
import java.util.Map;

/**
 * Starts the LoliLand launcher with a keyboard fix for Linux.
 *
 * The launcher embeds Chromium (JCEF) as a native child window. Under XWayland
 * the window manager focuses the Java window, Chromium never learns it has focus
 * and drops every key press. Telling the browser it is focused whenever the
 * window gains focus moves the X input focus to Chromium, and typing works.
 */
public final class LoliLand {
    public static void main(String[] args) throws Exception {
        Thread fix = new Thread(LoliLand::focusBrowserWithWindow, "keyboard-focus-fix");
        fix.setDaemon(true);
        fix.start();
        loliland.launcher.app.Main.main(args);
    }

    private static void focusBrowserWithWindow() {
        try {
            // Wait for the launcher to set up AWT and the browser first.
            while (browser() == null) Thread.sleep(500);
            Toolkit.getDefaultToolkit().addAWTEventListener(e -> {
                // Only for the browser's own window, so Java dialogs keep their focus.
                if (e.getID() == WindowEvent.WINDOW_GAINED_FOCUS && isBrowserWindow(((WindowEvent) e).getWindow())) focusBrowser();
            }, AWTEvent.WINDOW_FOCUS_EVENT_MASK);
            focusBrowser();
        } catch (Exception e) {
            System.err.println("Keyboard fix disabled:");
            e.printStackTrace();
        }
    }

    private static void focusBrowser() {
        try {
            Object browser = browser();
            if (browser != null) Class.forName("org.cef.browser.CefBrowser").getMethod("setFocus", boolean.class).invoke(browser, true);
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    private static boolean isBrowserWindow(Window window) {
        try {
            Object component = Class.forName("org.cef.browser.CefBrowser").getMethod("getUIComponent").invoke(browser());
            return SwingUtilities.getWindowAncestor((Component) component) == window;
        } catch (Exception e) {
            return false;
        }
    }

    // JCEF keeps its browsers private: CefApp.self -> clients_ -> browser_.
    private static Object browser() throws ReflectiveOperationException {
        Class<?> app = Class.forName("org.cef.CefApp");
        Object self = field(app, "self").get(null);
        if (self == null) return null;
        for (Object client : (Collection<?>) field(app, "clients_").get(self)) {
            for (Object browser : ((Map<?, ?>) field(client.getClass(), "browser_").get(client)).values()) return browser;
        }
        return null;
    }

    private static Field field(Class<?> type, String name) throws NoSuchFieldException {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }
}
JAVA
"$JAVA_HOME_LOCAL/bin/java" -m jdk.compiler/com.sun.tools.javac.Main -nowarn \
  -cp "$BUNDLE/launcher.jar" -d "$BUNDLE/classes" "$WORK/LoliLand.java" \
  || die 'Не удалось собрать исправление клавиатуры.'

# The launcher's favicon.ico ends with a 256px PNG entry; desktops load PNG everywhere, ICO not always.
unzip -p "$BUNDLE/launcher.jar" loliland/application/public/favicon.ico > "$WORK/favicon.ico"
ico_u() { od -An -t "u$1" -j "$2" -N "$1" "$WORK/favicon.ico" | tr -d ' '; }
COUNT="$(ico_u 2 4)"
ENTRY=$((6 + 16 * (COUNT - 1)))
PNG_SIZE="$(ico_u 4 $((ENTRY + 8)))"
# head reads the file itself and tail drains the pipe, so no SIGPIPE under pipefail.
head -c "$(( $(ico_u 4 $((ENTRY + 12))) + PNG_SIZE ))" "$WORK/favicon.ico" | tail -c "$PNG_SIZE" > "$BUNDLE/loliland.png"
ICON="$APP/loliland.png"
if [[ "$(od -An -tx1 -N4 "$BUNDLE/loliland.png" | tr -d ' ')" != 89504e47 ]]; then
  rm -f "$BUNDLE/loliland.png"
  cp "$WORK/favicon.ico" "$BUNDLE/loliland.ico"
  ICON="$APP/loliland.ico"
fi

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
StartupWMClass=LoliLand
DESK
! command -v desktop-file-validate >/dev/null || desktop-file-validate "$WORK/loliland.desktop" \
  || die 'Ярлык LoliLand получился некорректным (ошибки выше).'
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
