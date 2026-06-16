const http = require('http');
const PORT = 5000;
const data = {
  users:    [{ id:1, name:'Alice' }, { id:2, name:'Bob' }],
  products: [{ id:1, name:'Widget', price:9.99 }, { id:2, name:'Gadget', price:19.99 }],
  orders:   [{ id:1, userId:1, productId:2, status:'shipped' }]
};
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  const routes = { '/users': data.users, '/products': data.products, '/orders': data.orders };
  const body = routes[req.url];
  if (body) { res.writeHead(200); res.end(JSON.stringify(body)); }
  else if (req.url === '/') { res.writeHead(200); res.end(JSON.stringify({ service:'api-service', port:PORT })); }
  else { res.writeHead(404); res.end(JSON.stringify({ error:'not found' })); }
});
server.listen(PORT, '0.0.0.0', () => console.log('api-service listening on port ' + PORT));
    