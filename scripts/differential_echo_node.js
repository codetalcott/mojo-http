// A reference for the differential corpus: Node's http server, whose parser
// is llhttp (strict by default), answering each request with what it
// parsed, as apps/request_echo answers with what this server parsed (SPEC
// B25). A request llhttp refuses is answered 400 and closed (417 for an
// Expect it does not know, which Node answers itself). Never run by CI:
// `poe freeze-differential` starts it, when `node` is on PATH, to record
// the table's `llhttp` column, which is for reading a row.
//
//     node scripts/differential_echo_node.js PORT
const http = require('http');

const hex = (s) => Buffer.from(s, 'latin1').toString('hex');

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const headers = [];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      headers.push([hex(req.rawHeaders[i]), hex(req.rawHeaders[i + 1])]);
    }
    const out = JSON.stringify({
      method: hex(req.method),
      target: hex(req.url),
      request_uri: hex(req.url),
      protocol: hex('HTTP/' + req.httpVersion),
      headers,
      body_len: body.length,
      body: body.subarray(0, 512).toString('hex'),
    });
    res.writeHead(200, {
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(out),
    });
    res.end(out);
  });
});

server.on('clientError', (err, socket) => {
  const why = err.code || 'x';
  if (socket.writable) {
    socket.end('HTTP/1.1 400 Bad Request\r\ncontent-length: ' + Buffer.byteLength(why)
      + '\r\nconnection: close\r\n\r\n' + why);
  } else {
    socket.destroy();
  }
});

server.listen(parseInt(process.argv[2], 10), '127.0.0.1', () => {
  console.log('node echo ready, node ' + process.version);
});
