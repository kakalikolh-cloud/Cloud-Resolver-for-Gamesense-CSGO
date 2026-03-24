# Cloud Resolver v18 - Инструкция по установке и использованию

## Описание

Cloud Resolver позволяет синхронизировать данные резолвера между тиммейтами в реальном времени. Когда один игрок попадает по противнику, правильный угол автоматически передаётся всем тиммейтам.

## Архитектура

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Игрок A    │     │ Cloud Server │     │   Игрок B    │
│ (тиммейт 1)  │────▶│   (Node.js)  │◀────│ (тиммейт 2)  │
└──────────────┘     └──────────────┘     └──────────────┘
                            │
                     ┌──────┴──────┐
                     │   Данные:   │
                     │ Steam64:    │
                     │ Angle: 45°  │
                     │ Conf: 0.85  │
                     └─────────────┘
```

## Установка сервера

### Вариант 1: Локальный сервер (для игры с друзьями в одной сети)

1. Установите Node.js с https://nodejs.org/

2. Создайте папку и скопируйте файл `cloud_resolver_server.js`

3. Запустите сервер:
```bash
node cloud_resolver_server.js
```

4. Сервер будет доступен по адресу `http://localhost:3000`

5. В игре настройте URL: `http://localhost:3000/api`

### Вариант 2: VPS/VDS сервер (для игры через интернет)

1. Арендуйте VPS (можно дешёвый за $2-5/мес)
   - Рекомендую: DigitalOcean, Vultr, Hetzner

2. Подключитесь по SSH и установите Node.js:
```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs
```

3. Создайте папку и скопируйте сервер:
```bash
mkdir cloud-resolver
cd cloud-resolver
nano cloud_resolver_server.js
# Вставьте код сервера
```

4. Запустите сервер:
```bash
node cloud_resolver_server.js
```

5. Для постоянной работы используйте PM2:
```bash
sudo npm install -g pm2
pm2 start cloud_resolver_server.js --name cloud-resolver
pm2 save
pm2 startup
```

6. Откройте порт 3000 в фаерволе:
```bash
sudo ufw allow 3000
```

7. URL для игры: `http://YOUR_SERVER_IP:3000/api`

### Вариант 3: Бесплатный хостинг (Heroku, Render, Railway)

**Render.com (бесплатно):**

1. Создайте аккаунт на https://render.com
2. Создайте новый Web Service
3. Подключите GitHub репозиторий с сервером
4. Render автоматически запустит сервер

**Файл package.json для Render:**
```json
{
  "name": "cloud-resolver",
  "version": "1.0.0",
  "main": "cloud_resolver_server.js",
  "scripts": {
    "start": "node cloud_resolver_server.js"
  }
}
```

## Настройка в игре

1. Скопируйте файл `resolver_v18_cloud.lua` в папку Gamesense:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\gamesense\lua\
   ```

2. Загрузите скрипт в Gamesense

3. В настройках резолвера:
   - Включите "Enable Cloud Sync"
   - В поле "Server URL" введите адрес вашего сервера
   - Пример: `http://192.168.1.100:3000/api` (локальная сеть)
   - Пример: `http://123.45.67.89:3000/api` (интернет)

## API Endpoints

### POST /api/resolver/update
Отправка данных о попадании/проме

```json
{
  "reporter_steamid": "76561198XXXXXXXX",
  "enemy_steam64": "76561198YYYYYYYY",
  "angle": 45.5,
  "confidence": 0.85,
  "hit": true,
  "pattern": "jitter"
}
```

### GET /api/resolver/get
Получение всех данных

### GET /api/resolver/status
Статус сервера

### POST /api/resolver/clear
Очистка всех данных

## Как это работает

1. **Игрок A стреляет по противнику**
   - Резолвер вычисляет угол
   - Если попадание → отправляем данные на сервер

2. **Сервер сохраняет данные**
   - Steam64 противника → правильный угол
   - Добавляем confidence и timestamp

3. **Игрок B запрашивает данные**
   - Раз в 2 секунды
   - Получает углы для всех известных противников

4. **Игрок B использует данные**
   - Если confidence > 0.5 и данные свежие
   - Применяет угол от тиммейта

## Безопасность

⚠️ **Важно:** 
- Сервер не шифрует данные
- Не передавайте чувствительные данные
- Используйте только с доверенными тиммейтами
- IP сервера виден всем игрокам

## Troubleshooting

### Сервер не запускается
- Проверьте, установлен ли Node.js
- Проверьте, свободен ли порт 3000

### Данные не синхронизируются
- Проверьте URL в настройках
- Проверьте подключение к серверу (кнопка "Test Connection")
- Включите "Cloud Debug" для логов

### Низкий confidence
- Cloud данные используются только при confidence >= 0.5
- Hit'ы дают более высокий confidence
- Miss'ы снижают confidence

## Статистика

Выводится на экране:
- Cloud: CONNECTED/DISCONNECTED
- Syncs: количество синхронизаций
- Cloud resolves: количество использований cloud данных
- Cloud hits: попадания благодаря cloud данным

## Файлы

- `resolver_v18_cloud.lua` - Резолвер с cloud поддержкой
- `cloud_resolver_server.js` - Node.js сервер
- `README_CLOUD_RESOLVER.md` - Эта инструкция
