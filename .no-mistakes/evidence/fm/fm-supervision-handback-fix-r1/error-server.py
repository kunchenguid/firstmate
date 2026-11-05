from http.server import BaseHTTPRequestHandler, HTTPServer
import json, time
from pathlib import Path
root=Path(__file__).parent
class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        n=int(self.headers.get('Content-Length','0')); self.rfile.read(n)
        with (root/'requests.jsonl').open('a') as f: f.write(json.dumps({'time':time.time(),'path':self.path,'status':401})+'\n')
        self.send_response(401); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"Disposable local StopFailure validation endpoint"}}')
    def log_message(self,*args): pass
server=HTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port))
server.serve_forever()
