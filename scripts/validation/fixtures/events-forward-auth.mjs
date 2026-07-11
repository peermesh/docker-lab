import { createServer } from 'node:http';

const port = 9000;

createServer((request, response) => {
  const spoofedActor = request.headers['x-peermesh-actor-webid'];
  if (typeof spoofedActor === 'string' && spoofedActor.length > 0) {
    response.writeHead(400, { 'content-type': 'text/plain' });
    response.end('spoofed actor header reached forward auth');
    return;
  }

  const actor = request.headers['x-sandbox-actor'];
  if (typeof actor !== 'string' || !/^[a-z0-9-]{1,32}$/.test(actor)) {
    response.writeHead(401, { 'content-type': 'text/plain' });
    response.end('missing or invalid sandbox actor');
    return;
  }

  response.writeHead(200, {
    'X-Peermesh-Auth-Subject': `sandbox:${actor}`,
    'X-Peermesh-Actor-WebID': `https://actors.example.invalid/${actor}`,
    'X-Peermesh-Tenant-ID': 'tenant-sandbox',
    'X-Peermesh-Property-ID': 'events.localhost',
    'X-Peermesh-Roles': 'admin',
  });
  response.end();
}).listen(port, '0.0.0.0', () => {
  process.stdout.write(`Events sandbox forward-auth fixture listening on ${port}\n`);
});
