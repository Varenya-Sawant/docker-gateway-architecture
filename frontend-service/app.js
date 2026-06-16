const http = require('http');
const PORT = 3000;
const server = http.createServer((req, res) => {
  if (req.url === '/') {

    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Frontend Dashboard</title>
    <style>body{font-family:Arial,Helvetica,sans-serif;padding:24px}</style>
  </head>
  <body>
    <h1>Frontend Dashboard</h1>
    <p>Service: frontend-service | Port: ${PORT}</p>
  </body>
</html>`);
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});
server.listen(PORT, '0.0.0.0', () => {
  console.log('frontend-service listening on port ' + PORT);
});
