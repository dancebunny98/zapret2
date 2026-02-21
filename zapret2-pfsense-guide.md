# Полный гайд: zapret2 на pfSense 2.8.1

> **Версии:** `zapret2-v0.9.4.2` (стабильная) / `zapret2-master` (актуальная, v0.9.5+)  
> **Платформа:** pfSense 2.8.1 (FreeBSD 14.x, x86_64)  
> **Бинарник:** `dvtws2` (FreeBSD-версия nfqws2)  
> **Метод перехвата:** IPFW + ipdivert + Lua-скрипты

---

## Содержание

1. [Как это работает](#1-как-это-работает)
2. [Что нужно перед установкой](#2-что-нужно-перед-установкой)
3. [Шаг 1 — Подключение по SSH к pfSense](#3-шаг-1--подключение-по-ssh-к-pfsense)
4. [Шаг 2 — Загрузка и распаковка zapret2](#4-шаг-2--загрузка-и-распаковка-zapret2)
5. [Шаг 3 — Установка бинарников](#5-шаг-3--установка-бинарников)
6. [Шаг 4 — Настройка rc-скрипта автозапуска](#6-шаг-4--настройка-rc-скрипта-автозапуска)
7. [Шаг 5 — Настройка стратегии обхода DPI](#7-шаг-5--настройка-стратегии-обхода-dpi)
8. [Шаг 6 — Первый запуск и проверка](#8-шаг-6--первый-запуск-и-проверка)
9. [Шаг 7 — Автозапуск при перезагрузке](#9-шаг-7--автозапуск-при-перезагрузке)
10. [Продвинутые стратегии обхода](#10-продвинутые-стратегии-обхода)
11. [Подбор стратегии (blockcheck2)](#11-подбор-стратегии-blockcheck2)
12. [Работа с хостлистами и ipset](#12-работа-с-хостлистами-и-ipset)
13. [Отладка и диагностика](#13-отладка-и-диагностика)
14. [Обновление](#14-обновление)
15. [Удаление](#15-удаление)
16. [Структура файлов проекта](#16-структура-файлов-проекта)
17. [Частые ошибки и решения](#17-частые-ошибки-и-решения)

---

## 1. Как это работает

### Схема обработки трафика

```
Клиент LAN ──► pfSense ──► IPFW правило #100
                                   │
                     divert → порт 990 (ipdivert)
                                   │
                              dvtws2 daemon
                                   │
                    Lua: zapret-lib.lua + zapret-antidpi.lua
                                   │
                    Модификация TCP пакетов:
                    multisplit / fake / multidisorder
                                   │
                    Пакет уходит провайдеру
                    DPI не может собрать TLS ClientHello
```

### Почему IPFW, а не PF?

pfSense использует PF как основной фаервол, но PF не поддерживает `divert` — механизм перенаправления пакетов в userspace. IPFW в FreeBSD поддерживает `divert`. Оба фаервола запускаются одновременно, IPFW работает рядом с PF через `net.inet.ip.pfil`.

### Компоненты

| Компонент | Назначение |
|-----------|-----------|
| `dvtws2` | Демон для FreeBSD. Принимает пакеты через divert-сокет, применяет Lua-стратегии, возвращает обратно |
| `zapret-lib.lua` | Базовые функции: диссекция пакетов, работа с TCP/TLS, утилиты |
| `zapret-antidpi.lua` | Готовые стратегии: `multisplit`, `fake`, `multidisorder`, `fakeddisorder` и др. |
| IPFW правило | Перехватывает TCP трафик на 80/443 out и направляет в dvtws2 |
| ipfw + ipdivert | Модули ядра FreeBSD для divert |

---

## 2. Что нужно перед установкой

- pfSense 2.8.1 установлен и работает
- Доступ по SSH (включить: **System → Advanced → Admin Access → Enable SSH**)
- Архив `zapret2-v0.9.4.2.zip` (или `zapret2-master.zip` для новейших фич)
- Базовые знания командной строки FreeBSD/sh

> **Важно:** zapret2-master содержит код v0.9.5+, но **бинарники в архиве только до v0.9.4.2**. Для master нужно либо использовать бинарники из v0.9.4.2, либо собирать из исходников. Рекомендуется использовать **v0.9.4.2** — всё включено.

---

## 3. Шаг 1 — Подключение по SSH к pfSense

```sh
ssh admin@192.168.1.1
```

После входа вы окажетесь в меню pfSense. Выберите **8) Shell** для перехода в командную строку.

---

## 4. Шаг 2 — Загрузка и распаковка zapret2

### Вариант A: загрузка прямо с pfSense (если есть интернет)

```sh
# Скачать стабильный релиз
fetch -o /tmp/zapret2.zip \
  https://github.com/bol-van/zapret2/releases/download/v0.9.4.2/zapret2-v0.9.4.2.zip

# Распаковать
cd /usr/local/etc
unzip /tmp/zapret2.zip
mv zapret2-v0.9.4.2 zapret2
```

### Вариант B: загрузка через SCP с вашего компьютера

```sh
# На вашем ПК (не на pfSense):
scp zapret2-v0.9.4.2.zip admin@192.168.1.1:/tmp/

# На pfSense:
cd /usr/local/etc
unzip /tmp/zapret2-v0.9.4.2.zip
mv zapret2-v0.9.4.2 zapret2
```

### Вариант C: если уже загрузили оба архива (из вашего вопроса)

Загрузите нужный архив на pfSense через SCP и распакуйте по пути выше.

---

### Рекомендуемый способ установки (install_pfsense.sh)

Если архив распакован в `/usr/local/etc/zapret2`, выполните:

```sh
# войти в root shell
sudo su -

cd /usr/local/etc/zapret2
sh install_pfsense.sh --start
```

Этот скрипт:
- запускается только от `root` на FreeBSD/pfSense
- удаляет старые файлы установки и ставит заново (по умолчанию)
- копирует Lua/hostlist/файлы fake в `/usr/local/etc/zapret2`
- ставит бинарники в `/usr/local/sbin`
- устанавливает rc-скрипт в `/usr/local/etc/rc.d/zapret2.sh`
- выставляет владельца `root:wheel` и права (`755` для исполняемых, `644` для остальных файлов)
- сразу запускает сервис (если задан `--start`)

Если нужно без очистки старых файлов:

```sh
sh install_pfsense.sh --no-clean --start
```

После этого переходите сразу к [Шагу 6](#8-шаг-6--первый-запуск-и-проверка).

---

## 5. Шаг 3 — Установка бинарников

```sh
cd /usr/local/etc/zapret2

# Создать директорию для бинарников
mkdir -p /usr/local/sbin

# Скопировать бинарники FreeBSD x86_64
cp binaries/freebsd-x86_64/dvtws2  /usr/local/sbin/dvtws2
cp binaries/freebsd-x86_64/ip2net  /usr/local/sbin/ip2net
cp binaries/freebsd-x86_64/mdig    /usr/local/sbin/mdig

# Выдать права на исполнение
chmod 755 /usr/local/sbin/dvtws2
chmod 755 /usr/local/sbin/ip2net
chmod 755 /usr/local/sbin/mdig

# Проверить, что бинарник работает
/usr/local/sbin/dvtws2 --help 2>&1 | head -5
```

Ожидаемый вывод — строки с параметрами dvtws2. Если ошибка "not found" или "not executable" — проверьте chmod.

---

## 6. Шаг 4 — Настройка rc-скрипта автозапуска

Скрипт `init.d/pfsense/zapret2.sh` — основной файл запуска для pfSense. Он уже адаптирован для вашей версии.

### Просмотр оригинала

```sh
cat /usr/local/etc/zapret2/init.d/pfsense/zapret2.sh
```

Оригинальный скрипт уже содержит актуальную конфигурацию. Достаточно скопировать его в rc.d:

```sh
cp /usr/local/etc/zapret2/init.d/pfsense/zapret2.sh /usr/local/etc/rc.d/zapret2.sh
chmod 755 /usr/local/etc/rc.d/zapret2.sh
```

---

## 7. Шаг 5 — Настройка стратегии обхода DPI

Стратегия задаётся через параметры `--lua-desync` при запуске dvtws2. Можно задать несколько стратегий подряд — dvtws2 применяет их по цепочке.

### Встроенные блобы (fake-пакеты)

zapret2 включает готовые бинарные «фейки» в директории `files/fake/`. Они доступны по имени:

| Имя блоба | Описание |
|-----------|---------|
| `fake_default_tls` | Стандартный TLS ClientHello (автогенерация) |
| `fake_default_http` | Стандартный HTTP запрос |
| `fake_default_quic` | QUIC Initial пакет |
| `tls_clienthello_www_google_com` | TLS ClientHello для google.com |
| `tls_clienthello_vk_com` | TLS ClientHello для vk.com |
| `quic_initial_vk_com` | QUIC Initial для vk.com |

### Базовые стратегии

#### 1. multisplit — разбивка пакета на части

Разбивает первый TCP-сегмент с данными на несколько частей в разных позициях. DPI не успевает собрать TLS ClientHello.

```sh
--lua-desync=multisplit
# Разбивка по умолчанию в позиции 2

--lua-desync=multisplit:pos=1,midsld
# Разбивка в начале и в середине второго уровня домена
```

#### 2. fake — отправка фейкового пакета перед реальным

```sh
--lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000
# Отправка фейк TLS ClientHello с неверным MD5 и смещённым seq
```

#### 3. multidisorder — разбивка в обратном порядке

Отправляет части пакета от последнего к первому. Эффективно против DPI, собирающих stream последовательно.

```sh
--lua-desync=multidisorder:pos=1,midsld
```

#### 4. fakeddisorder — фейк + disorder комбо

```sh
--lua-desync=fakeddisorder:blob=fake_default_tls:tcp_md5
```

### Рекомендуемая конфигурация (универсальная)

Отредактируйте секцию запуска dvtws2 в `/usr/local/etc/rc.d/zapret2.sh`:

```sh
$DVTWS \
  --daemon \
  --port $DIVERT_PORT \
  --lua-init=@$ZDIR/zapret-lib.lua \
  --lua-init=@$ZDIR/zapret-antidpi.lua \
  \
  --filter-tcp=80 \
  --lua-desync=fake:blob=fake_default_http:tcp_md5 \
  --lua-desync=multisplit:pos=method+2 \
  --new \
  \
  --filter-tcp=443 \
  --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
  --lua-desync=multidisorder:pos=1,midsld \
  --new \
  \
  --filter-udp=443 \
  --lua-desync=fake:blob=fake_default_quic:repeats=6 \
  >> "$LOGFILE" 2>&1
```

> **`--new`** отделяет профили: каждая группа фильтр+стратегии применяется независимо.

---

## 8. Шаг 6 — Первый запуск и проверка

```sh
# Запустить скрипт вручную
/usr/local/etc/rc.d/zapret2.sh start

# Проверить, что dvtws2 запущен
pgrep -a dvtws2

# Проверить статус сервиса
/usr/local/etc/rc.d/zapret2.sh status

# Проверить IPFW правила
ipfw list

# Посмотреть лог
cat /var/log/zapret2.log
```

### Ожидаемый вывод `ipfw list`:

```
00100 divert 990 tcp from any to any 80,443 out not diverted not sockarg
65535 allow ip from any to any
```

### Проверка работы

```sh
# Попробовать открыть заблокированный ресурс через curl
curl -v --connect-timeout 10 https://blocked-site.example/

# Проверить модули ядра
kldstat | grep -E "ipfw|ipdivert"
```

---

## 9. Шаг 7 — Автозапуск при перезагрузке

pfSense запускает скрипты из `/usr/local/etc/rc.d/` автоматически при загрузке, если скрипт имеет права на исполнение. Наш скрипт уже там.

```sh
# Проверить расположение
ls -la /usr/local/etc/rc.d/zapret2.sh

# Перезагрузить pfSense и убедиться что dvtws2 поднялся
reboot

# После перезагрузки проверить
pgrep -a dvtws2
ipfw list | grep 100
```

> **Важно:** pfSense иногда сбрасывает IPFW при перезагрузке через веб-интерфейс (например, при сохранении настроек фаервола). Это нормально — скрипт восстанавливает правила при следующей загрузке. Для немедленного восстановления запустите скрипт вручную.

---

## 10. Продвинутые стратегии обхода

### Цепочка стратегий с разными TTL (fool)

```sh
$DVTWS \
  --daemon \
  --port 990 \
  --lua-init=@$ZDIR/zapret-lib.lua \
  --lua-init=@$ZDIR/zapret-antidpi.lua \
  --filter-tcp=443 \
  --lua-desync=fake:blob=fake_default_tls:tcp_md5:ip_ttl=5 \
  --lua-desync=multidisorder:pos=1,midsld \
  --new \
  --filter-tcp=80 \
  --lua-desync=fake:blob=fake_default_http:tcp_md5 \
  --lua-desync=multisplit:pos=method+2 \
  >> "$LOGFILE" 2>&1
```

Параметр `ip_ttl=5` — фейк-пакет отправляется с TTL=5, не доходит до сервера, но вводит DPI в заблуждение.

### Стратегия с seqovl (перекрытие seq)

```sh
--lua-desync=multidisorder:pos=1,midsld:seqovl=1
```

### Стратегия с oob (out-of-band данные)

```sh
--lua-desync=oob
```

### Использование автохостлистов

Позволяет применять обход только к нужным доменам (ускоряет работу, уменьшает нагрузку):

```sh
# В файле /usr/local/etc/zapret2/ipset/zapret-hosts-user.txt
echo "blocked-site.ru" >> /usr/local/etc/zapret2/ipset/zapret-hosts-user.txt

# В параметрах dvtws2:
--filter-tcp=443 \
--hostlist=/usr/local/etc/zapret2/ipset/zapret-hosts-user.txt \
--lua-desync=fake:blob=fake_default_tls:tcp_md5 \
--lua-desync=multidisorder:pos=1,midsld \
```

### Перехват только конкретных портов и протоколов

Добавьте несколько IPFW правил в скрипт:

```sh
# Только HTTPS (443)
ipfw add 100 divert 990 tcp from any to any 443 out not diverted not sockarg

# HTTP + HTTPS
ipfw add 100 divert 990 tcp from any to any 80,443 out not diverted not sockarg

# HTTP + HTTPS + QUIC
ipfw add 100 divert 990 tcp from any to any 80,443 out not diverted not sockarg
ipfw add 101 divert 990 udp from any to any 443 out not diverted not sockarg
```

---

## 11. Подбор стратегии (blockcheck2)

`blockcheck2.sh` — скрипт автоматического тестирования стратегий. На pfSense его запуск ограничен из-за отсутствия iptables, но тест можно провести вручную.

### Ручное тестирование стратегий

```sh
# Остановить текущий dvtws2
pkill dvtws2

# Удалить IPFW правило
ipfw delete 100 2>/dev/null

# Добавить правило
ipfw add 100 divert 990 tcp from any to any 80,443 out not diverted not sockarg

# Тест стратегии 1: multisplit
/usr/local/sbin/dvtws2 \
  --port 990 \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-lib.lua \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-antidpi.lua \
  --lua-desync=multisplit &

# Проверить доступность сайта
curl -v --connect-timeout 5 https://blocked-site.example/ 2>&1 | tail -5

# Убить и попробовать другую
pkill dvtws2
/usr/local/sbin/dvtws2 \
  --port 990 \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-lib.lua \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-antidpi.lua \
  --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
  --lua-desync=multidisorder:pos=1,midsld &

curl -v --connect-timeout 5 https://blocked-site.example/ 2>&1 | tail -5
```

---

## 12. Работа с хостлистами и ipset

### Структура списков

```
/usr/local/etc/zapret2/ipset/
├── zapret-hosts-user.txt         # Ваши домены (один на строку)
├── zapret-hosts-user-exclude.txt # Исключения (не трогать эти домены)
└── zapret-hosts-auto.txt         # Автоматически собранный лист (если autohostlist)
```

### Добавить домены вручную

```sh
# Добавить домен
echo "youtube.com" >> /usr/local/etc/zapret2/ipset/zapret-hosts-user.txt
echo "*.youtube.com" >> /usr/local/etc/zapret2/ipset/zapret-hosts-user.txt

# Посмотреть список
cat /usr/local/etc/zapret2/ipset/zapret-hosts-user.txt
```

### Использование hostlist в запуске dvtws2

```sh
$DVTWS \
  --daemon \
  --port 990 \
  --lua-init=@$ZDIR/zapret-lib.lua \
  --lua-init=@$ZDIR/zapret-antidpi.lua \
  --filter-tcp=443 \
  --hostlist=/usr/local/etc/zapret2/ipset/zapret-hosts-user.txt \
  --lua-desync=fake:blob=fake_default_tls:tcp_md5 \
  --lua-desync=multidisorder:pos=1,midsld \
  >> "$LOGFILE" 2>&1
```

### Скачать готовые листы блокировок

```sh
# Обновить список через встроенный скрипт (если есть curl/fetch и DNS)
cd /usr/local/etc/zapret2
sh ipset/get_antifilter_ipresolve.sh
```

---

## 13. Отладка и диагностика

### Запуск в режиме отладки (foreground)

```sh
# Остановить демон
pkill dvtws2

# Запустить в терминале с подробным выводом
/usr/local/sbin/dvtws2 \
  --port 990 \
  --debug \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-lib.lua \
  --lua-init=@/usr/local/etc/zapret2/lua/zapret-antidpi.lua \
  --lua-desync=multisplit
# Ctrl+C для остановки
```

Флаг `--debug` выводит каждый обработанный пакет, применённые функции и их результаты.

### Проверка состояния

```sh
# Процессы
pgrep -a dvtws2

# IPFW правила
ipfw list

# Загруженные модули ядра
kldstat | grep -E "ipfw|ipdivert"

# Сетевые соединения (видим divert-сокет)
sockstat | grep dvtws2

# Логи
tail -f /var/log/zapret2.log
```

### Проверка sysctls

```sh
sysctl net.inet.ip.pfil.outbound
sysctl net.inet.ip.pfil.inbound
# Ожидаемый вывод: ipfw,pf или pf,ipfw
```

### Тест перехвата пакетов

```sh
# Открыть соединение и посмотреть счётчики IPFW
ipfw show

# Счётчик пакетов для правила 100 должен расти при HTTP/HTTPS трафике
```

---

## 14. Обновление

### Обновление до zapret2-master (v0.9.5+)

```sh
# Остановить демон
pkill dvtws2

# Бекап текущей конфигурации
cp /usr/local/etc/rc.d/zapret2.sh /tmp/zapret2.sh.bak

# Скачать master
fetch -o /tmp/zapret2-master.zip \
  https://github.com/bol-van/zapret/archive/refs/heads/master.zip

# Распаковать в temp
cd /tmp
unzip zapret2-master.zip

# Обновить только lua-файлы (бинарники FreeBSD в master отсутствуют!)
cp -r /tmp/zapret-master/lua/* /usr/local/etc/zapret2/lua/

# Восстановить скрипт запуска
cp /tmp/zapret2.sh.bak /usr/local/etc/rc.d/zapret2.sh

# Перезапустить
/usr/local/etc/rc.d/zapret2.sh
```

> **Важно:** в `zapret2-master.zip` нет папки `binaries/`. Бинарники (`dvtws2`) берите только из стабильного релиза `v0.9.4.2`.

---

## 15. Удаление

```sh
# Остановить демон
pkill dvtws2

# Удалить IPFW правило
ipfw delete 100 2>/dev/null

# Удалить файлы
rm /usr/local/etc/rc.d/zapret2.sh
rm -rf /usr/local/etc/zapret2
rm /usr/local/sbin/dvtws2
rm /usr/local/sbin/ip2net
rm /usr/local/sbin/mdig

# Выгрузить модули (необязательно, загрузятся снова после ребута)
kldunload ipdivert 2>/dev/null
kldunload ipfw 2>/dev/null

# Убедиться что PF работает нормально
pfctl -s all | head -20
```

---

## 16. Структура файлов проекта

```
zapret2-v0.9.4.2/
│
├── binaries/
│   ├── freebsd-x86_64/        ← Для pfSense (FreeBSD)
│   │   ├── dvtws2             ← Основной демон
│   │   ├── ip2net             ← Утилита IP → подсеть
│   │   └── mdig               ← DNS-резолвер для списков
│   ├── linux-x86_64/
│   │   └── nfqws2             ← Linux-версия (не нужна для pfSense)
│   └── ...
│
├── lua/
│   ├── zapret-lib.lua         ← Базовая библиотека
│   ├── zapret-antidpi.lua     ← Стратегии обхода DPI
│   ├── zapret-auto.lua        ← Автовыбор стратегий
│   ├── zapret-obfs.lua        ← Дополнительные обфускации
│   └── zapret-pcap.lua        ← Захват пакетов (отладка)
│
├── files/fake/                ← Бинарные фейк-пакеты
│   ├── tls_clienthello_www_google_com.bin
│   ├── tls_clienthello_vk_com.bin
│   ├── quic_initial_vk_com.bin
│   └── ...
│
├── init.d/
│   └── pfsense/
│       └── zapret2.sh         ← Шаблон скрипта для pfSense
│
├── ipset/                     ← Скрипты для работы со списками
│   ├── get_antifilter_*.sh
│   └── get_user.sh
│
├── install_pfsense.sh         ← Установщик для pfSense
│
├── config.default             ← Дефолтная конфигурация (для Linux/OpenWRT)
└── blockcheck2.sh             ← Скрипт подбора стратегий
```

---

## 17. Частые ошибки и решения

### `kldload: can't load ipfw: File exists`
Нормально. Модуль уже загружен. Скрипт использует `2>/dev/null` чтобы скрыть это сообщение.

---

### `pfctl -d` завис или вернул ошибку
```sh
# Принудительно перезапустить PF
pfctl -d
pfctl -e -f /etc/pf.conf
```

---

### IPFW правило добавилось, но dvtws2 не принимает пакеты
```sh
# Проверить sysctl — IPFW должен быть в цепочке pfil
sysctl net.inet.ip.pfil.outbound
# Если нет ipfw в выводе:
sysctl net.inet.ip.pfil.outbound=ipfw,pf
```

---

### `Error: Incompatible NFQWS2_COMPAT_VER`
Версии бинарника и Lua-скриптов не совпадают. Используйте бинарники и скрипты из одного релиза.

```sh
# Убедиться что lua из того же архива, что dvtws2
ls -la /usr/local/etc/zapret2/lua/
```

---

### dvtws2 запустился, но заблокированные сайты не открываются
1. Убедитесь что IPFW правило активно: `ipfw list | grep 100`
2. Проверьте счётчики: `ipfw show` — число пакетов должно расти при трафике
3. Попробуйте другую стратегию (разные DPI по-разному работают)
4. Запустите с `--debug` и смотрите что происходит с пакетами
5. Проверьте, что трафик идёт через pfSense, а не напрямую

---

### Потеря интернета после запуска

```sh
# Остановить dvtws2
pkill dvtws2

# Убрать IPFW правило
ipfw delete 100

# Перезапустить PF
pfctl -d && pfctl -e

# Убедиться что интернет восстановился
ping -c 3 8.8.8.8
```

Скорее всего проблема в `pfctl -d && pfctl -e` — PF временно отключился и не поднялся. Добавьте задержку:

```sh
pfctl -d
sleep 0.5
pfctl -e
```

---

### pfSense перезаписывает IPFW правила через веб-интерфейс

При сохранении настроек фаервола в GUI pfSense перегружает свои правила PF, но IPFW при этом не трогает. Если вы используете `pfctl -d && pfctl -e` — PF сбрасывается. Можно убрать эту строку из скрипта если pfSense 2.8.1 и без неё корректно пропускает трафик через IPFW+PF одновременно.

---

## Итоговый скрипт `/usr/local/etc/rc.d/zapret2.sh`

Актуальная версия уже лежит в проекте:

```sh
cat /usr/local/etc/zapret2/init.d/pfsense/zapret2.sh
```

Поддерживаемые действия:

```sh
/usr/local/etc/rc.d/zapret2.sh start
/usr/local/etc/rc.d/zapret2.sh stop
/usr/local/etc/rc.d/zapret2.sh restart
/usr/local/etc/rc.d/zapret2.sh status
```

---

*Гайд составлен на основе анализа архивов `zapret2-v0.9.4.2.zip` и `zapret2-master.zip`.*  
*Актуальные обновления проекта: https://github.com/bol-van/zapret*

