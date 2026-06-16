const http = require('http');
const PORT = 6000;
const START = Date.now();
const server = http.createServer((req, res) => {
  if (req.url === '/' || req.url === '/admin') {
    res.writeHead(200, {'Content-Type':'text/html'});
    res.end(`<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Admin Panel</title></head>
  <body>
    <h1>Admin Panel</h1>
    <p>Service: admin-service | Port: 6000</p>
    <p><a href="/admin/health">/health</a></p>
  </body>
</html>`);
  } else if (req.url === '/health' || req.url === '/admin/health') {
    res.writeHead(200, {'Content-Type':'application/json'});
    res.end(JSON.stringify({ status:'ok', service:'admin-service', uptime: ((Date.now()-START)/1000).toFixed(1)+'s' }));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});
server.listen(PORT, '0.0.0.0', () => console.log('admin-service on port ' + PORT));