# OpenBSD

В проект добавлена отдельная конфигурируемая реализация для OpenBSD:

```sh
init.d/openbsd/zapret2.sh
```

Она поддерживает оба режима из мануала:

1. `PF_MODE=safe`
2. `PF_MODE=full`

## Файлы

Рабочие файлы:

```sh
init.d/openbsd/zapret2.sh
init.d/openbsd/zapret2.conf
init.d/openbsd/dvtws2.args
init.d/openbsd/apply_blockcheck.sh
```

После установки в `/usr/local/etc/zapret2`:

```sh
/usr/local/etc/zapret2/init.d/openbsd/zapret2.sh
/usr/local/etc/zapret2/init.d/openbsd/zapret2.conf
/usr/local/etc/zapret2/init.d/openbsd/dvtws2.args
/usr/local/etc/zapret2/init.d/openbsd/apply_blockcheck.sh
```

## Установка из git clone

```sh
git clone <repo-url> /root/zapret2
cd /root/zapret2
sh install_openbsd.sh
```

`install_openbsd.sh`:

1. Копирует проект в `/usr/local/etc/zapret2`.
2. Пытается использовать готовые бинарники.
3. Если их нет, ставит `gmake` и `luajit`, затем собирает бинарники из исходников.
4. Запускает `init.d/openbsd/zapret2.sh start`.

## Конфиг

Основной конфиг:

```sh
ZAPRET_DIR=/usr/local/etc/zapret2
PF_MAIN_CONF=/etc/pf.conf
PF_ANCHOR_NAME=zapret2
PF_ANCHOR_FILE=/etc/pf.zapret2.conf
PF_AUTOINSTALL_ANCHOR=1
PF_MODE=safe
IFACE_WAN=em0
PORTS_TCP=80,443
PORTS_UDP=443
PORT_DIVERT=989
DVTWS2_ARGS_FILE=/usr/local/etc/zapret2/init.d/openbsd/dvtws2.args
DVTWS2_ARGS="--lua-desync=multisplit"
```

## Режимы pf

`PF_MODE=safe` генерирует правила:

```pf
pass in quick on em0 proto tcp from port { 80,443 } flags SA/SA divert-packet port 989 no state
pass in quick on em0 proto tcp from port { 80,443 } flags R/R divert-packet port 989 no state
pass in quick on em0 proto tcp from port { 80,443 } flags F/F divert-packet port 989 no state
pass in quick on em0 proto tcp from port { 80,443 } no state
pass out quick on em0 proto tcp to port { 80,443 } divert-packet port 989 no state
pass out quick on em0 proto udp to port { 443 } divert-packet port 989 no state
```

`PF_MODE=full` генерирует правила:

```pf
pass out quick on em0 proto tcp to port { 80,443 } divert-packet port 989
pass out quick on em0 proto udp to port { 443 } divert-packet port 989
```

## Управление

```sh
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh start
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh stop
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh restart
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh status
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh show-pf
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh apply-pf
```

По умолчанию скрипт:

1. Добавляет в `/etc/pf.conf` anchor `zapret2`, если его еще нет.
2. Пишет правила в `/etc/pf.zapret2.conf`.
3. Перезагружает `pf`.
4. Запускает `dvtws2`.

## blockcheck2 -> runtime

Для переноса итоговой стратегии из `blockcheck2.sh`:

```sh
sh /usr/local/etc/zapret2/init.d/openbsd/apply_blockcheck.sh extract
sh /usr/local/etc/zapret2/init.d/openbsd/zapret2.sh restart
```

По умолчанию helper ищет первую строку `dvtws2 ...` в секции `* COMMON` из лога:

```sh
/tmp/blockcheck2.log
```

Можно сразу запустить тест, вытащить стратегию и применить ее:

```sh
BLOCKCHECK_MATCH="ipv4" sh /usr/local/etc/zapret2/init.d/openbsd/apply_blockcheck.sh auto
```

Если нужен не `COMMON`, а весь `SUMMARY`:

```sh
BLOCKCHECK_SCOPE=summary BLOCKCHECK_MATCH="https_tls12 ipv4" \
sh /usr/local/etc/zapret2/init.d/openbsd/apply_blockcheck.sh extract
```

Helper записывает результат в:

```sh
/usr/local/etc/zapret2/init.d/openbsd/dvtws2.args
```

в виде shell-assign:

```sh
DVTWS2_ARGS='--filter-tcp=443 ...'
```

После этого `zapret2.sh` автоматически берет эти параметры при старте.

## Практический workflow

1. Настроить `init.d/openbsd/zapret2.conf`.
2. Запустить `blockcheck2.sh` и сохранить лог.
3. Через `apply_blockcheck.sh` перенести подходящую стратегию в `dvtws2.args`.
4. Перезапустить `init.d/openbsd/zapret2.sh`.

## Ограничения

- В `full` режиме весь поток идет через `dvtws2`, что сильно нагружает CPU.
- Автоматический выбор стратегии из `blockcheck2` опирается на первую подходящую строку `dvtws2 ...`; это ускоряет внедрение, но не заменяет ручную верификацию.
- FreeBSD и pfSense сюда не относятся: для них в проекте остается ветка с `ipfw`, а не `pf`.
