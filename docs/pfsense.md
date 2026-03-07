# pfSense

Для `pfSense` используется минимальный официальный вариант скрипта:

```sh
init.d/pfsense/zapret2.sh
```

Он рассчитан на ручное размещение в:

```sh
/usr/local/etc/rc.d/zapret2
```

и запуск:

```sh
sh /usr/local/etc/rc.d/zapret2
```

## Установка из git clone

На `pfSense`:

```sh
git clone <repo-url> /root/zapret2
cd /root/zapret2
sh install_pfsense.sh
```

`install_pfsense.sh`:

1. Копирует проект в `/usr/local/etc/zapret2`.
2. Пытается подключить готовые бинарники через `install_bin.sh`.
3. Если бинарников нет, пробует поставить build dependencies и собрать их из исходников.
4. Копирует `init.d/pfsense/zapret2.sh` в `/usr/local/etc/rc.d/zapret2`.
5. Запускает `zapret2`.

Что он делает:

1. Загружает `ipfw` и `ipdivert`.
2. Пытается выставить старые `pfil` sysctl для старых версий pfSense.
3. Выполняет `pfctl -d ; pfctl -e`.
4. Добавляет одно правило `ipfw divert`.
5. Запускает `dvtws2` с `zapret-lib.lua` и `zapret-antidpi.lua`.

Пути в самом скрипте жестко заданы под:

```sh
ZDIR=/usr/local/etc/zapret2
```

Если нужен другой путь, меняйте сам `init.d/pfsense/zapret2.sh`.

`install_pfsense.sh` рассчитан именно на сценарий `git clone -> install -> run`: он сначала пытается использовать готовые бинарники, а при их отсутствии собирает их из исходников.
