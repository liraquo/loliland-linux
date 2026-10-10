# LoliLand для Linux

Неофициальный установщик лаунчера LoliLand для Linux.

Официально лаунчер выпускается только для Windows (`LoliLand.exe`), на Linux он сам по себе не запускается.
Этот скрипт ставит лаунчер, который работает на Linux напрямую, без Wine, Proton, виртуальных машин и других прослоек.

> Я не связан с администрацией LoliLand

Версия для macOS: [liraquo/loliland-mac](https://github.com/liraquo/loliland-mac).

## Быстрый старт

Откройте терминал и выполните:

```sh
curl -fLO https://raw.githubusercontent.com/liraquo/loliland-linux/main/install-loliland.sh
bash install-loliland.sh
```

Дождитесь сообщения «Готово». LoliLand должен появиться в меню приложений.
Скачанный `install-loliland.sh` после этого можно удалить.

- Приложение: `~/.local/share/loliland-launcher/`
- Данные лаунчера и логи: `~/.local/share/LoliLand/` (там же игры и лог `linux-app.log`)
- Ярлык: `~/.local/share/applications/loliland.desktop`

Я не разработчик проекта и не администратор, работа отдельных игровых сборок на Linux не гарантируется.