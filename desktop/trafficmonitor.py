#!/usr/bin/env python3
"""TrafficMonitor local USB collector, SQLite store and authenticated dashboard."""
import argparse
import base64
import collections
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import sqlite3
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent
DEFAULT_APP = 'com.korea.mrtgd2.ios'


class USB:
    def __init__(self, udid=None):
        import tidevice
        devices = tidevice.Usbmux().device_list()
        if not udid:
            if len(devices) != 1:
                raise RuntimeError('请只连接一台 iPhone，或用 --udid 指定设备')
            udid = devices[0].udid
        self.device = tidevice.Device(udid)
        self.lock = threading.Lock()

    def request(self, path, body=None):
        with self.lock:
            with self.device.create_inner_connection(8081) as tunnel:
                connection = http.client.HTTPConnection('mks-usb', timeout=12)
                connection.sock = tunnel.get_socket()
                connection.sock.settimeout(12)
                data = None if body is None else json.dumps(body).encode()
                connection.request('GET' if body is None else 'POST', path, body=data,
                                   headers={'Content-Type': 'application/json', 'Connection': 'close'})
                response = connection.getresponse()
                raw = response.read(4 * 1024 * 1024)
                if response.status != 200:
                    raise RuntimeError('设备管理通道返回 HTTP ' + str(response.status))
                result = json.loads(raw)
                if result.get('status') in ('error', 'fail'):
                    raise RuntimeError('设备拒绝操作')
                return result

    def shell(self, command):
        return self.request('/runShell', {'cmd': command}).get('data', '')

    def apps(self):
        result = []
        for app in self.request('/apps').get('applications', []):
            bundle = app.get('applicationIdentifier', '')
            container = app.get('dataContainerURL', '')
            if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
                continue
            if not re.fullmatch(r'/(?:private/)?var/mobile/Containers/Data/Application/[0-9A-Fa-f-]{36}/?', container):
                continue
            result.append({'id': bundle, 'name': app.get('localizedName') or bundle,
                           'container': container.rstrip('/')})
        return sorted(result, key=lambda value: value['name'].casefold())

    def configure(self, apps, selected, generation=0):
        commands = ['PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin; export PATH', 'set -e']
        for app in apps:
            directory = app['container'] + '/tmp/TrafficMonitor'
            config = plistlib.dumps({'bundle_id': app['id'], 'enabled': app['id'] in selected,
                                      'generation': generation})
            commands += ['mkdir -p ' + shlex.quote(directory),
                         'chmod 700 ' + shlex.quote(directory),
                         'printf %s ' + shlex.quote(base64.b64encode(config).decode()) + ' | base64 -d > ' + shlex.quote(directory + '/config.plist'),
                         'chmod 600 ' + shlex.quote(directory + '/config.plist'),
                         'chown mobile:mobile ' + shlex.quote(directory) + ' ' + shlex.quote(directory + '/config.plist')]
        # Only exact identifiers are accepted, including an inert sentinel for no selection.
        payload = plistlib.dumps({'Filter': {'Bundles': selected or ['com.example.trafficmonitor.disabled']}})
        destination = '/var/jb/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.plist'
        commands += ['if test ! -d /var/jb/Library/MobileSubstrate/DynamicLibraries; then TM_PREFIX=""; else TM_PREFIX=/var/jb; fi',
                     'printf %s ' + shlex.quote(base64.b64encode(payload).decode()) +
                     ' | base64 -d > "$TM_PREFIX/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.plist.tmp"',
                     'chmod 644 "$TM_PREFIX/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.plist.tmp"',
                     'mv "$TM_PREFIX/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.plist.tmp" "$TM_PREFIX/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.plist"',
                     'printf TM_CONFIG_OK']
        if not self.shell('\n'.join(commands)).rstrip().endswith('TM_CONFIG_OK'):
            raise RuntimeError('配置写入未确认；请检查手机插件和 roothelp')

    def read_files(self, apps, cursors):
        commands = ['PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin; export PATH']
        for app in apps:
            for name in ('http-events.jsonl.1', 'http-events.jsonl', 'socket-events.jsonl.1', 'socket-events.jsonl'):
                path = app['container'] + '/tmp/TrafficMonitor/' + name
                key = app['id'] + ':' + name
                inode, offset = cursors.get(key, ('', 0))
                commands.append('if test -f {p} && test ! -L {p}; then set -- $(stat -c "%i %s" {p}); '
                                'n=0; if test "$1" = {inode} && test "$2" -ge {offset}; then n={offset}; fi; '
                                'printf "TMFILE|{key}|%s|%s|%s|" "$1" "$2" "$n"; '
                                'tail -c +$((n+1)) {p} | head -c 65536 | base64 -w0; printf "\\n"; fi'.format(
                                    p=shlex.quote(path), inode=shlex.quote(str(inode)), offset=int(offset), key=key))
        records = []
        for line in self.shell('\n'.join(commands)).splitlines():
            if not line.startswith('TMFILE|'):
                continue
            _, key, inode, size, start, data = line.split('|', 5)
            raw = base64.b64decode(data)
            boundary = raw.rfind(b'\n') + 1
            if boundary:
                records.append((key, inode, int(start) + boundary, raw[:boundary]))
        return records

    def clear_files(self, apps):
        commands=['set -e']
        for app in apps:
            for name in ('http-events.jsonl','http-events.jsonl.1','socket-events.jsonl','socket-events.jsonl.1'):
                path=shlex.quote(app['container']+'/tmp/TrafficMonitor/'+name)
                commands.append(f'if test -f {path} && test ! -L {path}; then : > {path}; fi')
        commands.append('printf TM_CLEAR_OK')
        if not self.shell('\n'.join(commands)).rstrip().endswith('TM_CLEAR_OK'):
            raise RuntimeError('手机诊断文件清理未确认')


class Store:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
        PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA auto_vacuum=INCREMENTAL;
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE IF NOT EXISTS cursors(path TEXT PRIMARY KEY,inode TEXT,offset INTEGER);
        CREATE TABLE IF NOT EXISTS http(id TEXT PRIMARY KEY,app TEXT,at REAL,method TEXT,url TEXT,domain TEXT,
          status INTEGER,duration REAL,up INTEGER,down INTEGER,source TEXT,detail TEXT);
        CREATE INDEX IF NOT EXISTS http_app_time ON http(app,at);
        CREATE TABLE IF NOT EXISTS samples(id TEXT PRIMARY KEY,connection TEXT,app TEXT,at REAL,up INTEGER,down INTEGER);
        CREATE INDEX IF NOT EXISTS samples_app_time ON samples(app,at);
        CREATE TABLE IF NOT EXISTS connections(id TEXT PRIMARY KEY,app TEXT,fd INTEGER,protocol TEXT,ip TEXT,port INTEGER,
          first REAL,last REAL,up INTEGER,down INTEGER,state TEXT);
        CREATE INDEX IF NOT EXISTS connections_app_time ON connections(app,last);
        CREATE TABLE IF NOT EXISTS health(app TEXT PRIMARY KEY,at REAL,detail TEXT);
        ''')
        self.db.commit()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def setting(self, key, default=None):
        with self.lock:
            row = self.db.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
            return json.loads(row[0]) if row else default

    def set(self, key, value):
        with self.lock, self.db:
            self.db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)', (key, json.dumps(value)))

    def cursors(self):
        with self.lock:
            return {r['path']: (r['inode'], r['offset']) for r in self.db.execute('SELECT * FROM cursors')}

    def ingest(self, records, offset=0):
        cutoff = self.setting('cleared_at', 0)
        with self.lock, self.db:
            for key, inode, position, raw in records:
                for line in raw.splitlines():
                    try:
                        e = json.loads(line)
                        app = key.split(':', 1)[0]
                        if e.get('bundle_id') != app:
                            continue
                        kind = e.get('kind')
                        at = float(e.get('completed_at_unix', e.get('time', 0))) + offset
                        if at <= cutoff or at > time.time() + 60:
                            continue
                        if kind == 'http_request':
                            url = str(e.get('url', ''))[:4096]
                            domain = urllib.parse.urlsplit(url).hostname or '<unknown>'
                            self.db.execute('INSERT OR IGNORE INTO http VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                                (e['request_id'], app, at, e.get('method'), url, domain, e.get('status_code'),
                                 e.get('duration_ms'), e.get('request_body_bytes'), e.get('response_body_bytes'),
                                 e.get('source'), json.dumps(e, ensure_ascii=False)))
                        elif kind == 'socket_sample':
                            up, down = max(0, int(e['upload_bytes'])), max(0, int(e['download_bytes']))
                            inserted = self.db.execute('INSERT OR IGNORE INTO samples VALUES(?,?,?,?,?,?)',
                                (e['event_id'], e['connection_id'], app, at, up, down)).rowcount
                            if inserted:
                                self.db.execute('''INSERT INTO connections VALUES(?,?,?,?,?,?,?,?,?,?,?)
                                  ON CONFLICT(id) DO UPDATE SET last=excluded.last,up=up+excluded.up,
                                  down=down+excluded.down,state=excluded.state''',
                                  (e['connection_id'], app, e['fd'], e['protocol'], e['ip'], e['port'], at, at, up, down, e['state']))
                        elif kind == 'collector_health':
                            self.db.execute('INSERT OR REPLACE INTO health VALUES(?,?,?)', (app, at, json.dumps(e)))
                    except (ValueError, KeyError, TypeError):
                        continue
                self.db.execute('INSERT OR REPLACE INTO cursors VALUES(?,?,?)', (key, inode, position))

    def prune(self):
        with self.lock, self.db:
            before = time.time() - self.setting('retention_days', 7) * 86400
            self.db.execute('DELETE FROM http WHERE at<?', (before,))
            self.db.execute('DELETE FROM samples WHERE at<?', (before,))
            self.db.execute('DELETE FROM connections WHERE last<?', (before,))
            for table in ('http', 'samples'):
                self.db.execute(f'DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} ORDER BY rowid DESC LIMIT -1 OFFSET 100000)')
            self.db.execute('DELETE FROM connections WHERE id NOT IN (SELECT DISTINCT connection FROM samples)')
        with self.lock:
            self.db.execute('PRAGMA wal_checkpoint(PASSIVE)')
            self.db.execute('PRAGMA incremental_vacuum(256)')

    def clear(self):
        self.set('cleared_at', time.time())
        with self.lock, self.db:
            for table in ('http', 'samples', 'connections', 'health', 'cursors'):
                self.db.execute('DELETE FROM ' + table)
        with self.lock:
            self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
            self.db.execute('VACUUM')

    def state(self, app='', seconds=300, search=''):
        since = time.time() - seconds
        condition = 'at>=?' + (' AND app=?' if app else '')
        args = [since] + ([app] if app else [])
        with self.lock:
            rows = lambda query, values=args: [dict(row) for row in self.db.execute(query, values)]
            http = rows('SELECT id,app,at,method,url,status,duration,up,down,source FROM http WHERE ' + condition +
                        ' AND (url LIKE ? OR method LIKE ?) ORDER BY at DESC LIMIT 200', args + ['%' + search[:120] + '%'] * 2)
            domains = rows('SELECT domain,count(*) requests,sum(up) up,sum(down) down FROM http WHERE ' + condition + ' GROUP BY domain ORDER BY requests DESC LIMIT 40')
            bucket=max(1,int(seconds/120))
            graph = rows('SELECT cast(at/? as integer)*? t,sum(up) up,sum(down) down FROM samples WHERE ' + condition + ' GROUP BY t ORDER BY t',[bucket,bucket]+args)
            totals = rows('SELECT count(*) requests,sum(status>=400 OR status IS NULL) errors,avg(duration) latency,sum(up) body_up,sum(down) body_down FROM http WHERE ' + condition)[0]
            socket_totals = rows('SELECT coalesce(sum(up),0) up,coalesce(sum(down),0) down FROM samples WHERE ' + condition)[0]
            live_args = [time.time() - 2] + ([app] if app else [])
            rate = rows('SELECT coalesce(sum(up),0)/2.0 up,coalesce(sum(down),0)/2.0 down FROM samples WHERE ' + condition, live_args)[0]
            conn_args = [since] + ([app] if app else [])
            connections = rows('SELECT * FROM connections WHERE last>=?' + (' AND app=?' if app else '') + ' ORDER BY last DESC LIMIT 200', conn_args)
            ips = rows('SELECT c.ip,c.protocol,sum(s.up) up,sum(s.down) down,count(DISTINCT c.id) sessions FROM samples s JOIN connections c ON s.connection=c.id WHERE s.at>=?' +
                       (' AND s.app=?' if app else '') + ' GROUP BY c.ip,c.protocol ORDER BY sum(s.up)+sum(s.down) DESC LIMIT 40', conn_args)
            health = rows('SELECT app,at,detail FROM health', [])
            for item in health:
                item['detail'] = json.loads(item['detail'])
            return {'requests': http, 'domains': domains, 'connections': connections, 'ips': ips, 'graph': graph,
                    'totals': dict(totals, **socket_totals), 'rate': rate, 'health': health,
                    'now': time.time(), 'window': seconds,'bucket':bucket, 'active': sum(c['state'] not in ('closed','failed') and c['last']>time.time()-60 for c in connections)}


class Collector:
    def __init__(self, store, bridge=None):
        self.store, self.bridge = store, bridge
        self.apps, self.error, self.updated, self.offset = [], '正在连接设备', 0, 0
        self.commands = []
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.udid=None
        self.selected = store.setting('selected', [DEFAULT_APP])
        self.paused = store.setting('paused', False)
        self.generation = store.setting('generation', 0)

    def queue(self, command):
        with self.lock:
            self.commands.append(command)

    def run(self):
        last_apps = last_prune = 0
        while not self.stop.is_set():
            try:
                if not self.bridge:
                    self.bridge = USB(self.udid)
                if time.time() - last_apps > 60:
                    self.apps = self.bridge.apps()
                    clock = self.bridge.shell('date +%s').strip().splitlines()[-1]
                    self.offset = time.time() - float(clock)
                    last_apps = time.time()
                with self.lock:
                    commands, self.commands = self.commands, []
                if commands:
                    affected = [a for a in self.apps if a['id'] in self.selected or a['id'] in self.store.setting('previous_selected', [])]
                    try:
                        self.bridge.configure(affected, [] if self.paused else self.selected, self.generation)
                        if 'clear' in commands:self.bridge.clear_files(self.apps)
                    except Exception:
                        with self.lock:self.commands=commands+self.commands
                        raise
                    self.store.set('previous_selected', self.selected)
                if not self.paused:
                    active = [a for a in self.apps if a['id'] in self.selected]
                    self.store.ingest(self.bridge.read_files(active, self.store.cursors()), self.offset)
                if time.time() - last_prune > 60:
                    self.store.prune()
                    last_prune = time.time()
                self.error, self.updated = '', time.time()
            except Exception as error:
                self.error = str(error)[:160]
                self.bridge=None
                last_apps=0
            self.stop.wait(1)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'TrafficMonitor/0.3'
    def log_message(self, *args):
        pass

    def reply(self, status, data, content='application/json; charset=utf-8'):
        raw = json.dumps(data, ensure_ascii=False).encode() if isinstance(data, (dict,list)) else data
        self.send_response(status)
        self.send_header('Content-Type', content)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(raw)

    def allowed(self):
        host = self.headers.get('Host','')
        if host not in (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'):
            self.reply(403, {'error':'Host 不受信任'}); return False
        origin = self.headers.get('Origin')
        if origin and origin not in ('http://' + host,):
            self.reply(403, {'error':'Origin 不受信任'}); return False
        return True

    def authorized(self):
        return secrets.compare_digest(self.headers.get('Authorization','').encode('utf-8'), ('Bearer ' + self.server.token).encode())

    def do_GET(self):
        if not self.allowed(): return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path in ('/', '/app.js', '/style.css'):
            name = {'/':'index.html','/app.js':'app.js','/style.css':'style.css'}[parsed.path]
            content = {'index.html':'text/html; charset=utf-8','app.js':'text/javascript; charset=utf-8','style.css':'text/css; charset=utf-8'}[name]
            self.reply(200, (ROOT / 'web' / name).read_bytes(), content); return
        if not self.authorized(): self.reply(401, {'error':'请输入本次启动的访问令牌'}); return
        collector, store = self.server.collector, self.server.collector.store
        query = urllib.parse.parse_qs(parsed.query)
        if parsed.path == '/api/state':
            try:
                seconds = max(60, min(604800, int(query.get('range',['300'])[0])))
                state = store.state(query.get('app',[''])[0], seconds, query.get('search',[''])[0])
            except ValueError:
                self.reply(400, {'error':'时间范围无效'}); return
            state.update(connected=bool(collector.updated) and not bool(collector.error), error=collector.error, updated=collector.updated,
                         selected=collector.selected, paused=collector.paused, retention_days=store.setting('retention_days',7),
                         apps=[{'id':a['id'],'name':a['name']} for a in collector.apps])
            with store.lock:
                state['historical_apps']=[r[0] for r in store.db.execute('SELECT DISTINCT app FROM http UNION SELECT DISTINCT app FROM samples')]
            self.reply(200,state)
        elif parsed.path == '/api/request':
            with store.lock:
                row = store.db.execute('SELECT detail FROM http WHERE id=?', (query.get('id',[''])[0],)).fetchone()
            self.reply(200,json.loads(row[0]) if row else {})
        elif parsed.path == '/api/export':
            data=store.state(query.get('app',[''])[0],604800)
            self.reply(200,data)
        else: self.reply(404,{'error':'接口不存在'})

    def do_POST(self):
        if not self.allowed(): return
        if not self.authorized(): self.reply(401,{'error':'未认证'});return
        try:
            length=int(self.headers.get('Content-Length','0'))
            if not 0<length<=8192: raise ValueError()
            body=json.loads(self.rfile.read(length))
            if not isinstance(body,dict):raise ValueError()
            collector, store = self.server.collector, self.server.collector.store
            if self.path == '/api/config':
                selected=body.get('selected',collector.selected)
                if not isinstance(selected,list) or len(selected)>8 or any(x not in {a['id'] for a in collector.apps} for x in selected):
                    raise ValueError('请选择最多 8 个已连接设备上的应用')
                retention=int(body.get('retention_days',store.setting('retention_days',7)))
                if retention not in (1,3,7):raise ValueError('保留期仅支持 1、3、7 天')
                if not isinstance(body.get('paused',collector.paused),bool):raise ValueError('暂停参数无效')
                old=collector.selected
                collector.selected=list(dict.fromkeys(selected))
                collector.paused=body.get('paused',collector.paused)
                store.set('previous_selected', list(set(old+store.setting('previous_selected',[]))))
                store.set('selected',collector.selected);store.set('paused',collector.paused);store.set('retention_days',retention)
                collector.queue('config')
                self.reply(200,{'ok':True,'message':'配置已保存，USB 同步后新选应用需完全退出再打开'})
            elif self.path == '/api/clear':
                if body.get('confirm')!='CLEAR':raise ValueError('需要确认清理')
                collector.generation+=1;store.set('generation',collector.generation)
                store.clear();collector.queue('clear')
                self.reply(200,{'ok':True,'message':'数据库已清理，运行中的采集器将在同步后轮换本地文件'})
            else:self.reply(404,{'error':'接口不存在'})
        except (ValueError,TypeError,json.JSONDecodeError) as error:
            self.reply(400,{'error':str(error) or '请求无效'})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',type=int,default=27681)
    parser.add_argument('--udid')
    parser.add_argument('--data',default=str(ROOT/'data'/'trafficmonitor.sqlite3'))
    parser.add_argument('--offline',action='store_true',help='只查看本地历史，不连接手机')
    args=parser.parse_args()
    store=Store(args.data)
    collector=Collector(store)
    collector.udid=args.udid
    if args.udid:collector.bridge=USB(args.udid)
    if args.offline:collector.error='离线历史模式'
    else:threading.Thread(target=collector.run,daemon=True).start()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    server.daemon_threads=True;server.collector=collector;server.token=secrets.token_urlsafe(32)
    print(json.dumps({'url':f'http://127.0.0.1:{server.server_port}/#token={server.token}', 'port':server.server_port}),flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:collector.stop.set();server.server_close()


if __name__=='__main__':main()
