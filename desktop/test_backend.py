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

    def test_domains_aggregate_all_saved_requests_and_unknowns(self):
        self.seed()
        self.collector.selected=['com.example.test']
        with self.store.lock:
            for i in range(205):
                self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,?,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                      ('known-'+str(i),'https://example.com/known',10,25,'request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,url,?,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('larger','larger.test',10000,20000,'request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,app,at,method,url,?,status,duration,up,down,source,detail FROM http WHERE id=?',
                                  ('unknown','unknown.test','request-1'))
            self.store.db.execute('INSERT INTO http SELECT ?,?,at,method,url,domain,status,duration,?,?,source,detail FROM http WHERE id=?',
                                  ('other','com.example.other',100000,200000,'request-1'))
            self.store.db.commit()
        status,body,_=self.call('/api/requests?view=domains')
        data=json.loads(body)
        self.assertEqual(status,200)
        self.assertEqual(data['requests'],[])
        self.assertEqual(data['domains'],[
            {'domain':'larger.test','size':30000,'requests':1,'unknown':0},
            {'domain':'example.com','size':7175,'requests':206,'unknown':1},
            {'domain':'unknown.test','size':None,'requests':1,'unknown':1}])
        self.assertEqual(self.call('/api/requests?view=invalid')[0],400)

    def test_delete_one_app_preserves_others_and_skips_old_reimport(self):
        self.seed()
        app,other='com.example.test','com.example.other'
        self.collector.selected=[app]
        stale=json.loads(self.store.db.execute('SELECT detail FROM http').fetchone()[0])
        other_event=dict(stale,bundle_id=other,request_id='other-request')
        sample={'kind':'socket_sample','event_id':'other-sample','connection_id':'other-connection',
                'bundle_id':other,'time':time.time(),'fd':8,'protocol':'TCP','ip':'127.0.0.1','port':80,
                'upload_bytes':10,'download_bytes':20,'state':'open'}
        records=[(other+':http-events.jsonl','other-inode',100,
                  ('\n'.join(map(json.dumps,[other_event,sample]))+'\n').encode())]
        self.store.ingest(records)
        generation=self.collector.generation
        self.assertEqual(self.call('/api/clear-app',{'app':app,'confirm':'wrong'})[0],400)
        self.assertEqual(self.call('/api/clear-app',{'app':'not-an-app','confirm':'CLEAR'})[0],400)
        self.assertEqual(self.call('/api/clear-app',{'confirm':'CLEAR'})[0],400)
        self.assertEqual(self.call('/api/clear-app',{'app':app,'confirm':'CLEAR'})[0],200)
        self.assertEqual(self.store.state(app)['totals']['requests'],0)
        self.assertEqual(self.store.state(other)['totals']['requests'],1)
        self.assertEqual(self.store.state(app)['totals']['up'],0)
        self.assertEqual(self.store.state(other)['totals']['up'],10)
        self.assertIn(other+':http-events.jsonl',self.store.cursors())
        self.assertNotIn(app+':http-events.jsonl',self.store.cursors())
        self.assertEqual(self.collector.generation,generation)
        self.assertIn(('clear_app',app),self.collector.commands)
        self.store.ingest([(app+':http-events.jsonl','old-inode',100,(json.dumps(stale)+'\n').encode())])
        self.assertEqual(self.store.state(app)['totals']['requests'],0)
        fresh=dict(stale,request_id='after-delete',completed_at_unix=time.time()+1)
        self.store.ingest([(app+':http-events.jsonl','new-inode',200,(json.dumps(fresh)+'\n').encode())])
        self.assertEqual(self.store.state(app)['totals']['requests'],1)

    def test_phone_cleanup_is_scoped_without_reconfiguring_other_apps(self):
        collector=self.collector
        calls=[]
        class Bridge:
            def apps(self):
                return [{'id':'com.example.test'},{'id':'com.example.other'}]
            def shell(self,command):
                return str(time.time())
            def configure(self,*args):
                calls.append(('configure',args))
            def clear_files(self,apps):
                calls.append(('clear',[a['id'] for a in apps]))
                collector.stop.set()
            def read_files(self,*args):
                return []
        collector.bridge=Bridge()
        collector.selected=['com.example.test']
        collector.queue(('clear_app','com.example.test'))
        collector.run()
        self.assertEqual(calls,[('clear',['com.example.test'])])

    def test_history_and_parameter_binding(self):
        self.seed()
        self.assertEqual(self.call('/api/state?app=%27%20OR%201%3D1--')[0],200)
        status,body,_=self.call('/api/state?app=com.example.test&range=604800')
        state=json.loads(body)
        self.assertEqual(state['totals']['requests'],1)
        self.assertLessEqual(len(state['graph']),121)
        self.assertIn('com.example.test',state['historical_apps'])


if __name__=='__main__':unittest.main()
