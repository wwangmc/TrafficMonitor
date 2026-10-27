import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from trafficmonitor import Store, Collector, Handler
from http.server import ThreadingHTTPServer


class BackendTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.store=Store(Path(self.temp.name)/'test.sqlite3')
        self.collector=Collector(self.store)
        self.collector.apps=[{'id':'com.example.test','name':'Test','container':'/not-used'}]
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.collector=self.collector
        threading.Thread(target=self.server.serve_forever,daemon=True).start()

    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.store.db.close();self.temp.cleanup()

    def call(self,path,body=None,headers=None):
        connection=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        request_headers={}
        request_headers.update(headers or {})
        if body is not None:request_headers['Content-Type']='application/json'
        connection.request('POST' if body is not None else 'GET',path,json.dumps(body) if body is not None else None,request_headers)
        response=connection.getresponse();raw=response.read();connection.close()
        return response.status,raw,response.headers

    def seed(self):
        now=time.time()
        events=[{'kind':'http_request','request_id':'request-1','bundle_id':'com.example.test','completed_at_unix':now,
                 'method':'POST','url':'https://example.com/path?token=%3Credacted%3E','status_code':None,'duration_ms':30,
                 'request_body_bytes':None,'response_body_bytes':None,'source':'nsurlsession_delegate'},
                {'kind':'socket_sample','event_id':'sample-1','connection_id':'connection-1','bundle_id':'com.example.test',
                 'time':now,'fd':7,'protocol':'TCP','ip':'127.0.0.1','port':80,'upload_bytes':128,'download_bytes':512,'state':'open'}]
        records=[('com.example.test:http-events.jsonl','inode',100,('\n'.join(map(json.dumps,events))+'\n').encode())]
        self.store.ingest(records);self.store.ingest(records)

    def test_store_dedup_separate_bytes_and_null(self):
        self.seed();state=self.store.state('com.example.test',300)
        self.assertEqual(state['totals']['requests'],1)
        self.assertEqual(state['totals']['up'],128)
        self.assertEqual(state['totals']['down'],512)
        self.assertIsNone(state['requests'][0]['up'])
        self.assertIsNone(state['requests'][0]['status'])
        self.assertEqual(state['ips'][0]['down'],512)
        self.assertEqual(len(state['graph']),1)

    def test_local_access_host_origin_and_static_policy(self):
        self.assertEqual(self.call('/api/state')[0],200)
        self.assertEqual(self.call('/api/export')[0],200)
        self.assertEqual(self.call('/api/state',headers={'Host':'evil.example'})[0],403)
        self.assertEqual(self.call('/api/config',{'selected':[]},headers={'Origin':'https://evil.example'})[0],403)
        status,raw,headers=self.call('/')
        self.assertEqual(status,200)
        self.assertIn('frame-ancestors',headers['Content-Security-Policy'])

    def test_config_validation_and_clear(self):
        before=self.collector.selected[:]
        self.assertEqual(self.call('/api/config',{'selected':['not-installed']})[0],400)
        self.assertEqual(self.call('/api/config',{'selected':[],'retention_days':-1})[0],400)
        self.assertEqual(self.collector.selected,before)
        self.assertEqual(self.call('/api/config',{'selected':['com.example.test'],'paused':True})[0],200)
        self.assertTrue(self.collector.paused)
        self.seed()
        self.assertEqual(self.call('/api/clear',{'confirm':'wrong'})[0],400)
        self.assertEqual(self.call('/api/clear',{'confirm':'CLEAR'})[0],200)
        self.assertEqual(self.store.state()['totals']['requests'],0)
        self.assertEqual(self.store.cursors(),{})

    def test_simple_request_list_scopes_app_and_preserves_unknown_size(self):
        self.seed()
        self.collector.selected=['com.example.test']
        with self.store.lock:
            self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,?,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('known','https://example.com/known',10,25,'request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,?,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('large','https://example.com/large',10000,20000,'request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,?,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('zero','https://example.com/zero',0,0,'request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,?,at,method,?,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('other','com.example.other','https://example.com/other',100,200,'request-1'))
            self.store.db.commit()
        status,body,_=self.call('/api/requests')
        data=json.loads(body)
        self.assertEqual(status,200)
        self.assertEqual(data['app'],'com.example.test')
        sizes={r['url']:r['size'] for r in data['requests']}
        self.assertEqual(sizes['https://example.com/known'],35)
        self.assertIsNone(sizes['https://example.com/path?token=%3Credacted%3E'])
        self.assertNotIn('https://example.com/other',sizes)
        self.assertEqual([r['size'] for r in data['requests']],[30000,35,0,None])
        self.assertNotIn('rate',data)
        status,body,_=self.call('/api/requests?app=com.example.other')
        self.assertEqual(json.loads(body)['requests'],[{'url':'https://example.com/other','size':300}])

    def test_history_and_parameter_binding(self):
        self.seed()
        self.assertEqual(self.call('/api/state?app=%27%20OR%201%3D1--')[0],200)
        status,body,_=self.call('/api/state?app=com.example.test&range=604800')
        state=json.loads(body)
        self.assertEqual(state['totals']['requests'],1)
        self.assertLessEqual(len(state['graph']),121)
        self.assertIn('com.example.test',state['historical_apps'])


if __name__=='__main__':unittest.main()
