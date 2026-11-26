# LoliLand для Linux

Неофициальный установщик лаунчера LoliLand для Linux.

Официально лаунчер выпускается только для Windows в формате `.exe`, на Linux он, соответственно, не запускается.
Этот скрипт ставит лаунчер, который работает на Linux напрямую, без Wine, Proton, виртуальных машин и других прослоек.

Версия для macOS: [liraquo/loliland-mac](https://github.com/liraquo/loliland-mac).

## Быстрый старт

Запустите установщик от своего пользователя.

```sh
curl -fLO https://raw.githubusercontent.com/liraquo/loliland-linux/main/install-loliland.sh
bash install-loliland.sh
```

Дождитесь сообщения «Готово». LoliLand должен появиться в меню приложений.
Скачанный `install-loliland.sh` после этого можно удалить.

- Приложение: `~/.local/share/loliland-launcher/`
- Данные лаунчера и логи: `~/.local/share/LoliLand/` (там же игры и лог `linux-app.log`)
- Ярлык: `~/.local/share/applications/loliland.desktop`

Если задан `XDG_DATA_HOME`, установщик использует его вместо `~/.local/share`.

Я не разработчик проекта и не администратор, работа отдельных игровых сборок на Linux не гарантируется.
