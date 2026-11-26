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
for tool in curl tar unzip sha512sum sha256sum stat grep awk ps; do
  command -v "$tool" >/dev/null || die "Не найдена системная утилита $tool. Установите её через пакетный менеджер (например, sudo pacman -S $tool или sudo apt install $tool)."
done
# Never replace the app while it is running.
check_old_app() {
  [[ -e "$APP" ]] || return 0
  local procs; procs="$(ps -eo args=)"
  [[ "$procs" != *"$APP/"* ]] || die 'LoliLand сейчас запущен. Закройте его и повторите установку.'
}
mkdir -p "$SHARE/applications"
check_old_app

case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) die "Неподдерживаемая архитектура: $(uname -m). Нужна x86_64 или aarch64." ;;
esac

# Work on the same filesystem; publish only a fully verified application.
WORK="$(mktemp -d "$SHARE/.loliland-install.XXXXXX")"
cleanup() { rm -rf -- "$WORK"; }
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
step 1 "Java (JetBrains Runtime с JCEF, $ARCH)"
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
    if ! download "$LURL" "$WORK/$JAR" || ! download "$LURL.sha512" "$WORK/$JAR.sha512"; then
      die "Не удалось скачать $JAR с Maven Central. Проверьте сеть."
    fi
    [[ "$(sha512sum "$WORK/$JAR" | awk '{print $1}')" == "$(awk 'NR == 1 {print $1}' "$WORK/$JAR.sha512")" ]] \
      || die "SHA-512 $JAR не совпадает. Установка остановлена."
    unzip -qjo "$WORK/$JAR" 'linux/arm64/*.so' -d "$BUNDLE/natives"
  done
  [[ -f "$BUNDLE/natives/liblwjgl.so" ]] || die 'В архивах LWJGL не найдены библиотеки.'
  ok 'LWJGL для arm64 на месте, SHA-512 совпадает с Maven Central'
fi

cat > "$WORK/Installer.java" <<'INSTALLER_JAVA'
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.Arrays;
import java.util.Comparator;
import java.util.regex.Pattern;
import java.util.zip.ZipFile;

class Installer {
    public static void main(String[] args) throws Exception {
        Path source = Path.of(args[1]);
        switch (args[0]) {
            case "manifest" -> System.out.println(new Manifest(Files.readString(source)).size());
            case "icon" -> {
                if (!extractIcon(source, Path.of(args[2]))) System.exit(1);
            }
            case "recover", "publish" -> update(source, args.length == 3 ? Path.of(args[2]) : null);
            default -> throw new IllegalArgumentException(args[0]);
        }
    }

    // Read JSON tokens and match only the root launcher.size path.
    private static final class Manifest {
        private static final Pattern TOKEN = Pattern.compile(
            "[ \\t\\r\\n]*(" +
            "\"(?:[^\"\\\\\\x00-\\x1f]|\\\\(?:[\"\\\\/bfnrt]|u[0-9a-fA-F]{4}))*+\"|" +
            "-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[{}\\[\\],:])");
        private final java.util.regex.Matcher tokens;
        private final String input;
        private int offset;
        private String token;
        private long size;
        private boolean launcherSeen;

        Manifest(String input) {
            this.input = input;
            tokens = TOKEN.matcher(input);
            advance();
        }

        long size() {
            require("{".equals(token));
            value(1, 0);
            require(token == null && offset == input.length() && size > 0);
            return size;
        }

        private void advance() {
            if (tokens.region(offset, input.length()).lookingAt()) {
                token = tokens.group(1);
                offset = tokens.end();
            } else {
                if (input.substring(offset).chars().allMatch(c -> c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
                    offset = input.length();
                }
                token = null;
            }
        }

        private boolean take(String expected) {
            if (!expected.equals(token)) return false;
            advance();
            return true;
        }

        private void value(int path, int depth) {
            require(depth < 64 && token != null);
            if (path == 3) {
                require(size == 0 && token.matches("[1-9][0-9]*"));
                size = Long.parseLong(token);
                advance();
            } else if (take("{")) {
                if (take("}")) return;
                do {
                    require(token != null && token.startsWith("\""));
                    String key = token;
                    advance();
                    require(take(":"));
                    if (path == 1 && key.equals("\"launcher\"")) {
                        require(!launcherSeen && "{".equals(token));
                        launcherSeen = true;
                        value(2, depth + 1);
                    } else {
                        value(path == 2 && key.equals("\"size\"") ? 3 : 0, depth + 1);
                    }
                } while (take(","));
                require(take("}"));
            } else if (take("[")) {
                if (take("]")) return;
                do {
                    value(0, depth + 1);
                } while (take(","));
                require(take("]"));
            } else {
                require(!",:]}".contains(token));
                advance();
            }
        }

        private static void require(boolean ok) {
            if (!ok) throw new IllegalArgumentException("Некорректный манифест лаунчера.");
        }
    }

    private static boolean extractIcon(Path jarPath, Path output) throws IOException {
        byte[] icon;
        try (ZipFile jar = new ZipFile(jarPath.toFile())) {
            var entry = jar.getEntry("loliland/application/public/favicon.ico");
            if (entry == null) return false;
            try (var stream = jar.getInputStream(entry)) {
                icon = stream.readAllBytes();
            }
        }
        if (icon.length < 6) return false;
        ByteBuffer data = ByteBuffer.wrap(icon).order(ByteOrder.LITTLE_ENDIAN);
        if (data.getShort(0) != 0 || data.getShort(2) != 1) return false;
        int count = Short.toUnsignedInt(data.getShort(4));
        if (6 + 16 * count > icon.length) return false;
        for (int i = count - 1; i >= 0; i--) {
            int entry = 6 + 16 * i;
            int length = data.getInt(entry + 8);
            int start = data.getInt(entry + 12);
            if (length < 8 || start < 0 || (long) start + length > icon.length) continue;
            if (data.getLong(start) != 0x0a1a0a0d474e5089L) continue;
            Files.write(output, Arrays.copyOfRange(icon, start, start + length));
            return true;
        }
        return false;
    }

    private static void update(Path share, Path work) throws IOException {
        Path app = share.resolve("loliland-launcher");
        Path desktop = share.resolve("applications/loliland.desktop");
        Path journal = share.resolve(".loliland-update");
        try (var channel = FileChannel.open(share.resolve(".loliland-install.lock"),
                StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                var lock = channel.tryLock()) {
            if (lock == null) throw new IOException("Другой установщик LoliLand уже публикует обновление.");
            recover(journal, app, desktop);
            if (work == null) return;

            Files.createDirectory(journal);
            try {
                if (!exists(app)) Files.createFile(journal.resolve("new-app"));
                if (exists(desktop)) {
                    Files.copy(desktop, journal.resolve("desktop"), LinkOption.NOFOLLOW_LINKS, StandardCopyOption.COPY_ATTRIBUTES);
                } else {
                    Files.createFile(journal.resolve("new-desktop"));
                }
                Files.createFile(journal.resolve("ready"));
                if (exists(app)) move(app, journal.resolve("app"));
                move(work.resolve("loliland-launcher"), app);
                move(work.resolve("loliland.desktop"), desktop);
                move(journal, work.resolve("committed"));
            } catch (IOException failure) {
                try {
                    recover(journal, app, desktop);
                } catch (IOException rollbackFailure) {
                    failure.addSuppressed(rollbackFailure);
                }
                throw failure;
            }
        }
    }

    // Rollback is safe to repeat if the installer stops during recovery.
    private static void recover(Path journal, Path app, Path desktop) throws IOException {
        if (!exists(journal)) return;
        if (exists(journal.resolve("ready"))) {
            Path previousApp = journal.resolve("app");
            if (exists(previousApp)) {
                removeTree(app);
                move(previousApp, app);
            } else if (exists(journal.resolve("new-app"))) {
                removeTree(app);
            }
            Path previousDesktop = journal.resolve("desktop");
            if (exists(previousDesktop)) {
                move(previousDesktop, desktop);
            } else if (exists(journal.resolve("new-desktop"))) {
                Files.deleteIfExists(desktop);
            }
        }
        removeTree(journal);
    }

    private static boolean exists(Path path) {
        return Files.exists(path, LinkOption.NOFOLLOW_LINKS);
    }

    private static void move(Path source, Path destination) throws IOException {
        Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE);
    }

    private static void removeTree(Path root) throws IOException {
        if (!exists(root)) return;
        try (var paths = Files.walk(root)) {
            for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) Files.delete(path);
        }
    }
}
INSTALLER_JAVA
"$JAVA_HOME_LOCAL/bin/java" -m jdk.compiler/com.sun.tools.javac.Main -d "$WORK" "$WORK/Installer.java" \
  || die 'Не удалось собрать вспомогательную программу установки.'
install_helper() { "$JAVA_HOME_LOCAL/bin/java" -cp "$WORK" Installer "$@"; }
install_helper recover "$SHARE" || die 'Не удалось восстановить предыдущую установку.'
step 2 'Лаунчер LoliLand'
download "$SOURCE/api/updater/win64" "$WORK/manifest.json" \
  || die 'Не удалось получить манифест LoliLand. Проверьте сеть и доступность сервера.'
SIZE="$(install_helper manifest "$WORK/manifest.json")" \
  || die 'Сервер вернул некорректный манифест лаунчера.'
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

step 3 'Сборка LoliLand'
printf '%s\n' "$RUNTIME" > "$BUNDLE/runtime-name.txt"
cat > "$BUNDLE/loliland" <<'LAUNCH'
#!/bin/bash
set -euo pipefail
umask 077
APP="$(dirname -- "$(readlink -f -- "$0")")"
RUNTIME="$(< "$APP/runtime-name.txt")"
export JAVA_HOME="$APP/runtimes/$RUNTIME"
export PATH="$JAVA_HOME/bin:$PATH"
# The launcher itself keeps its data in ~/.local/share/LoliLand.
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/LoliLand"
LOG="$DATA/linux-app.log"
# The game JVM inherits this from the launcher; LWJGL then loads our arm64 natives.
if [[ -d "$APP/natives" ]]; then
  # HotSpot accepts either quote delimiter and preserves the other one.
  if [[ "$APP" != *'"'* ]]; then
    export JAVA_TOOL_OPTIONS="-Dorg.lwjgl.librarypath=\"$APP/natives\" ${JAVA_TOOL_OPTIONS:-}"
  elif [[ "$APP" != *"'"* ]]; then
    export JAVA_TOOL_OPTIONS="-Dorg.lwjgl.librarypath='$APP/natives' ${JAVA_TOOL_OPTIONS:-}"
  else
    printf 'Путь к библиотекам LWJGL содержит оба вида кавычек.\n' >&2
    exit 1
  fi
fi
mkdir -p "$DATA"
chmod go-rwx -- "$DATA"
cd -- "$DATA"
# Keep only the current and the previous launch.
[[ ! -f "$LOG" ]] || mv -f -- "$LOG" "$LOG.1"
exec "$JAVA_HOME/bin/java" --add-opens jcef/org.cef=ALL-UNNAMED \
  -cp "$APP/classes:$APP/launcher.jar" LoliLand "$@" > "$LOG" 2>&1
LAUNCH
chmod +x "$BUNDLE/loliland"
bash -n "$BUNDLE/loliland"

# Launcher fixes, compiled here from source with the JBR's own javac.
cat > "$WORK/LoliLand.java" <<'JAVA'
import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.WindowEvent;
import javax.swing.SwingUtilities;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
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
        migrateStorage();
        Thread fix = new Thread(LoliLand::focusBrowserWithWindow, "keyboard-focus-fix");
        fix.setDaemon(true);
        fix.start();
        loliland.launcher.app.Main.main(args);
    }

    private static void migrateStorage() throws java.io.IOException {
        Path storage = Path.of("Binaries", "launcher-data", "storage.txt");
        if (!Files.isRegularFile(storage)) return;
        Files.setPosixFilePermissions(storage, PosixFilePermissions.fromString("rw-------"));
        String contents = Files.readString(storage);
        String cleaned = contents.replaceAll("(?m)^auth\\.password:[^\\r\\n]*(?:\\r?\\n|$)", "");
        if (contents.equals(cleaned)) return;
        Path temp = Files.createTempFile(storage.getParent(), ".storage-", ".tmp");
        try {
            Files.writeString(temp, cleaned);
            Files.move(temp, storage, java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    public static List<String> normalizeGameArguments(List<String> arguments) {
        List<String> normalized = null;
        for (int i = 0; i < arguments.size(); i++) {
            String argument = arguments.get(i);
            String replacement = argument.replace("\"${auth_player_name}\"", "${auth_player_name}");
            if (!argument.equals(replacement)) {
                if (normalized == null) normalized = new ArrayList<>(arguments);
                normalized.set(i, replacement);
            }
        }
        return normalized == null ? arguments : normalized;
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
cat > "$WORK/PatchLauncher.java" <<'JAVA'
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.jar.JarFile;
import jdk.internal.org.objectweb.asm.ClassReader;
import jdk.internal.org.objectweb.asm.ClassVisitor;
import jdk.internal.org.objectweb.asm.ClassWriter;
import jdk.internal.org.objectweb.asm.Label;
import jdk.internal.org.objectweb.asm.MethodVisitor;
import jdk.internal.org.objectweb.asm.Opcodes;

public final class PatchLauncher {
    private static final String CONFIG_CLASS = "loliland/launcher/app/data/ClientLaunchConfig.class";

    public static void main(String[] args) throws Exception {
        Path classes = Path.of(args[1]);
        patchNickname(args[0], classes);
        patchPasswordStorage(args[0], classes);
    }

    private static void patchNickname(String jarPath, Path classes) throws Exception {
        // ProcessBuilder on Linux passes literal quotes from the launch template
        // to Minecraft. Normalize the nickname placeholder before substitution.
        ClassReader config;
        try (JarFile jar = new JarFile(jarPath)) {
            var entry = jar.getJarEntry(CONFIG_CLASS);
            if (entry == null) {
                System.err.println("Предупреждение: класс настроек игры изменился, исправление ника пропущено.");
                return;
            }
            try (var input = jar.getInputStream(entry)) {
                config = new ClassReader(input);
            }
        }
        ClassWriter patched = new ClassWriter(config, 0);
        boolean[] changed = { false };
        config.accept(new ClassVisitor(Opcodes.ASM8, patched) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                MethodVisitor method = super.visitMethod(access, name, descriptor, signature, exceptions);
                if (!name.equals("getGameArguments") || !descriptor.equals("()Ljava/util/List;")) return method;
                return new MethodVisitor(Opcodes.ASM8, method) {
                    @Override
                    public void visitInsn(int opcode) {
                        if (opcode == Opcodes.ARETURN) {
                            super.visitMethodInsn(Opcodes.INVOKESTATIC, "LoliLand", "normalizeGameArguments",
                                "(Ljava/util/List;)Ljava/util/List;", false);
                            changed[0] = true;
                        }
                        super.visitInsn(opcode);
                    }
                };
            }
        }, 0);
        if (!changed[0]) {
            System.err.println("Предупреждение: метод параметров игры изменился, исправление ника пропущено.");
            return;
        }
        writeClass(classes, CONFIG_CLASS, patched);
    }

    private static void patchPasswordStorage(String jarPath, Path classes) throws Exception {
        int[] writes = { 0 };
        try (JarFile jar = new JarFile(jarPath)) {
            for (var entries = jar.entries(); entries.hasMoreElements();) {
                var entry = entries.nextElement();
                String name = entry.getName();
                if (!name.startsWith("loliland/launcher/app/") || !name.endsWith(".class")) continue;
                byte[] bytes;
                try (var input = jar.getInputStream(entry)) {
                    bytes = input.readAllBytes();
                }
                if (!new String(bytes, StandardCharsets.ISO_8859_1).contains("storage.txt")) continue;
                ClassReader original = new ClassReader(bytes);
                ClassWriter patched = new ClassWriter(original, 0);
                int before = writes[0];
                original.accept(new ClassVisitor(Opcodes.ASM8, patched) {
                    @Override
                    public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                        MethodVisitor method = super.visitMethod(access, name, descriptor, signature, exceptions);
                        if ((access & Opcodes.ACC_STATIC) != 0 || !descriptor.equals("(Ljava/lang/String;Ljava/lang/Object;)V")) {
                            return method;
                        }
                        writes[0]++;
                        return new MethodVisitor(Opcodes.ASM8, method) {
                            @Override
                            public void visitCode() {
                                super.visitCode();
                                Label keep = new Label();
                                super.visitLdcInsn("auth.password");
                                super.visitVarInsn(Opcodes.ALOAD, 1);
                                super.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String", "equals",
                                    "(Ljava/lang/Object;)Z", false);
                                super.visitJumpInsn(Opcodes.IFEQ, keep);
                                super.visitInsn(Opcodes.RETURN);
                                super.visitLabel(keep);
                                super.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
                            }

                            @Override
                            public void visitMaxs(int stack, int locals) {
                                super.visitMaxs(Math.max(stack, 2), locals);
                            }
                        };
                    }
                }, 0);
                if (writes[0] != before) writeClass(classes, name, patched);
            }
        }
        if (writes[0] != 1) throw new IllegalStateException("Изменился код сохранения пароля: " + writes[0]);
    }

    private static void writeClass(Path classes, String name, ClassWriter patched) throws Exception {
        Path output = classes.resolve(name);
        Files.createDirectories(output.getParent());
        Files.write(output, patched.toByteArray());
    }
}
JAVA
"$JAVA_HOME_LOCAL/bin/java" -m jdk.compiler/com.sun.tools.javac.Main -nowarn \
  -cp "$BUNDLE/launcher.jar" -d "$BUNDLE/classes" "$WORK/LoliLand.java" \
  || die 'Не удалось собрать исправление клавиатуры.'
# Build the replacement class from the downloaded JAR without modifying the JAR itself.
ASM_EXPORT='java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED'
"$JAVA_HOME_LOCAL/bin/java" --add-exports "$ASM_EXPORT" \
  "$WORK/PatchLauncher.java" "$BUNDLE/launcher.jar" "$BUNDLE/classes" \
  || die 'Не удалось применить исправления ника и хранения пароля.'

# Prefer the embedded PNG and fall back to a desktop theme icon.
ICON=applications-games
if install_helper icon "$BUNDLE/launcher.jar" "$BUNDLE/loliland.png"; then
  ICON="$APP/loliland.png"
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
install_helper publish "$SHARE" "$WORK" || die 'Не удалось опубликовать лаунчер.'
[[ ! -e "$WORK/committed/app" ]] || ok 'Предыдущая версия LoliLand заменена'
! command -v update-desktop-database >/dev/null || update-desktop-database "$SHARE/applications" 2>/dev/null || true

printf '\n%s%s✓ Готово:%s %s\n\n' "$G" "$B" "$N" "$APP"
printf 'LoliLand появился в меню приложений (раздел «Игры»).\n'
printf 'Запуск из терминала: %s/loliland\n\n' "$APP"
