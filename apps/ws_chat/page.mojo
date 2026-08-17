"""The single HTML page served by the chat demo.

Built as a Mojo string, like the counter's page: one binary, no
static-file dependency, no `open()` in the request path. The client is
deliberately plain-browser WebSocket — no library — because the point of
the demo is the server side.
"""


def render_page(worker_pid: Int) -> String:
    """Full HTML document. The footer shows which worker served the page;
    under M0_WORKERS>1 a reload can land anywhere, and messages still reach
    every tab — that is the demo."""
    return String(
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<title>mojo-http chat</title><style>"
        "body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}"
        "#log{border:1px solid #ccc;border-radius:6px;height:20rem;overflow-y:auto;"
        "padding:.5rem;margin-bottom:.5rem;white-space:pre-wrap}"
        "#log div{padding:.15rem 0}"
        "form{display:flex;gap:.5rem}"
        "input{flex:1;padding:.4rem;border:1px solid #ccc;border-radius:6px}"
        "button{padding:.4rem 1rem}"
        "footer{color:#888;font-size:.8rem;margin-top:.75rem}"
        "</style></head><body>"
        "<h1>mojo-http chat</h1>"
        "<p>Open this page in several tabs — every message reaches all of"
        " them, across workers.</p>"
        "<div id='log'></div>"
        "<form id='f'><input id='msg' autocomplete='off'"
        " placeholder='Say something'><button>Send</button></form>"
        "<footer>served by worker pid " + String(worker_pid) + "</footer>"
        "<script>"
        "const log=document.getElementById('log');"
        "const ws=new WebSocket('ws://'+location.host+'/ws');"
        "ws.onmessage=(e)=>{const d=document.createElement('div');"
        "d.textContent=e.data;log.appendChild(d);log.scrollTop=log.scrollHeight;};"
        "ws.onclose=()=>{const d=document.createElement('div');"
        "d.textContent='[disconnected]';log.appendChild(d);};"
        "document.getElementById('f').addEventListener('submit',(e)=>{"
        "e.preventDefault();const i=document.getElementById('msg');"
        "if(i.value&&ws.readyState===1){ws.send(i.value);i.value='';}});"
        "</script></body></html>"
    )
