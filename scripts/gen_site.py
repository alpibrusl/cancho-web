import re, pathlib
import os
SRC = pathlib.Path(os.environ.get('GATEWAY_INDEX', '/home/user/alpibrusl/cancho-gateway/docs/index.html')).read_text()
CSS = SRC[SRC.index('<style>'):SRC.index('</style>')] + 'table.fit.num thead th + th { text-align: right; }\n</style>'
OUT = pathlib.Path(__file__).resolve().parent.parent / 'docs'
REPO = 'https://github.com/alpibrusl/cancho-web'
SITE = 'https://alpibrusl.github.io/cancho-web/'

import json
def jsonld(title, desc, page):
    url = SITE + page
    if page == '':
        data = {"@context": "https://schema.org", "@graph": [
            {"@type": "WebSite", "@id": SITE + "#site", "url": SITE, "name": "cancho-web", "description": desc, "inLanguage": "en"},
            {"@type": "SoftwareSourceCode", "@id": SITE + "#code", "name": "cancho-web", "description": desc,
             "codeRepository": REPO, "programmingLanguage": "cancho", "license": "https://spdx.org/licenses/EUPL-1.2.html",
             "url": SITE, "image": SITE + "og.png", "isPartOf": {"@id": SITE + "#site"}}]}
    else:
        data = {"@context": "https://schema.org", "@type": "TechArticle", "headline": title, "description": desc, "url": url,
                "inLanguage": "en", "image": SITE + "og.png", "isPartOf": {"@type": "WebSite", "name": "cancho-web", "url": SITE},
                "about": {"@type": "SoftwareSourceCode", "name": "cancho-web", "codeRepository": REPO}}
    return json.dumps(data, separators=(",", ":")).replace("</", "<\\/")

def head(title, desc, ogtitle, ogdesc, ogalt, page):
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta property="og:title" content="{ogtitle}">
<meta property="og:description" content="{ogdesc}">
<meta name="color-scheme" content="light dark">
<meta property="og:type" content="website">
<meta property="og:image" content="{SITE}og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{ogalt}">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" type="image/svg+xml" href="favicon.svg">
<link rel="icon" type="image/png" sizes="64x64" href="favicon.png">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<meta property="og:url" content="{SITE}{page}">
<link rel="canonical" href="{SITE}{page}">
<meta property="og:site_name" content="cancho-web">
<meta property="og:locale" content="en">
<meta name="twitter:title" content="{ogtitle}">
<meta name="twitter:description" content="{ogdesc}">
<meta name="twitter:image" content="{SITE}og.png">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#265e8d">
<meta name="keywords" content="cancho, cancho-web, OpenAPI 3.1, typed web framework, request validation, problem+json, RFC 9457, JSON Schema, systems language, capability effects">
<meta name="author" content="alpibrusl">
<script type="application/ld+json">{jsonld(title, desc, page)}</script>
{CSS}
</head>
'''

def header(cur):
    def a(href, text, key, opt=False):
        cls = []
        if opt: cls.append('opt')
        attr = ' aria-current="page"' if cur == key else ''
        c = f' class="{" ".join(cls)}"' if cls else ''
        return f'<a href="{href}"{attr}{c}>{text}</a>'
    return f'''<body>
<a class="skip" href="#main">Skip to content</a>
<header class="top"><div class="wrap">
  <a class="brand" href="index.html"><img class="mark" src="mark.png" alt="" width="30" height="30">cancho-web</a>
  <nav aria-label="Sections">
    {a("index.html","Overview","index",True)}{a("examples.html","Examples","examples")}{a("evidence.html","Evidence","evidence",True)}{a("index.html#numbers","Numbers","n",True)}{a("examples.html#run","Run it","r")}
    <a href="{REPO}" class="opt">GitHub</a>
  </nav>
</div></header>

<main id="main" class="wrap">
'''

FOOT = f'''
</main>

<footer><div class="wrap">
  <a href="{REPO}">Repository</a><a href="evidence.html">Evidence</a><a href="examples.html">Examples</a>
  <a href="{REPO}/blob/main/docs/design.md">Design</a><a href="{REPO}/blob/main/docs/benchmarks.md">Benchmarks</a>
  <a href="https://github.com/alpibrusl/cancho-schema">cancho-schema</a><a href="https://github.com/alpibrusl/cancho">cancho</a>
  <span>A cancho is a boulder; this one sits at the edge of the network.</span><span>Alpha · EUPL-1.2</span>
</div></footer>
</body>
</html>
'''

# ------------------------------------------------------------------ index
index = head(
 'cancho-web: the API boundary as a checked artifact',
 'cancho-web makes the API boundary a checked artifact of the program: one declaration defines the route, checks its inputs, generates the OpenAPI document and is what CI tests. Built in cancho, whose compiler states what the service may touch. Alpha.',
 'cancho-web: the API boundary as a checked artifact',
 'One declaration defines the route, checks its inputs, generates the OpenAPI document and is what CI tests. The compiler states what the service may touch. Alpha.',
 'cancho-web: a web layer for cancho. A route and its contract are declared once. Bodies are checked by schema. No Ffi, no C.',
 '') + header('index') + f'''
<div class="hero" id="top">
  <div>
    <img class="logo" src="logo.png" alt="cancho web: a rock caught in a web, in front of a blue circle" width="176" height="176">
    <a class="badge" href="#status"><i></i>Alpha · declaration and parameter dispatch are built; middleware is not</a>
    <h1>Declare the API once.</h1>
    <p class="lead">cancho-web makes the API boundary a checked artifact of the program. One declaration defines the route, checks its inputs, generates the OpenAPI document, and is what CI tests. <strong>Write it once. Serve it. Document it. Test it.</strong></p>
    <div class="cta"><a class="btn primary" href="examples.html#run">Run it</a><a class="btn ghost" href="examples.html">Examples</a><a class="btn ghost" href="#proof">See the evidence</a></div>
  </div>
  <div class="term" role="img" aria-label="A body that breaks four rules is refused with all four errors; a missing user is a 404 problem; the OpenAPI document lists the three paths."><div class="bar"><i></i><i></i><i></i></div>
<pre><span class="c">$</span> curl -si -XPOST -H 'Content-Type: application/json' \\
    -d '{{"name":"","age":151,"role":"root","nope":1}}' \\
    localhost:8080/users
HTTP/1.1 <span class="r">422 Unprocessable Content</span>
Content-Type: <span class="y">application/problem+json</span>

{{"status":422,"count":<span class="y">4</span>,"errors":[
 {{"pointer":"<span class="y">/name</span>","code":"min_length",…}},
 {{"pointer":"<span class="y">/age</span>","code":"maximum",…}},
 {{"pointer":"<span class="y">/role</span>","code":"choice",…}},
 {{"pointer":"<span class="y">/nope</span>","code":"unknown",…}}]}}
<span class="c"># (type, title and each detail left out here)</span>

<span class="c">$</span> curl -s localhost:8080/openapi.json | …
<span class="g">3.1.0</span> ['/health', '/users', '/users/{{id}}']</pre>
  </div>
</div>

<div class="three">
  <div><h3>One declaration</h3><p>The route, its parameters, body and responses, written once as data. The router and the OpenAPI 3.1 document are both made from it, so a route cannot be served and undocumented.</p></div>
  <div><h3>One boundary</h3><p>A path, query or header parameter that breaks its schema never reaches the handler: it is a <code>422</code> that lists every error, each with where it is. A body is checked by the same schema nodes before anything is stored.</p></div>
  <div><h3>One contract</h3><p>The served OpenAPI document is a file in the repository, and a test compares the two byte for byte. Every response in the tests must be one the document declares, and a generator tries to break it.</p></div>
</div>

<section id="authority">
  <h2>The language writes down what the service may touch.</h2>
  <div class="two">
    <div>
      <p class="sub" style="max-width:none">cancho is a typed systems language whose compiler states what a program may do. <code>cancho authority</code> on the built service prints the list on the right: it listens, polls and answers on sockets, reads its arguments and a clock, allocates, and writes to its error stream. <strong>It touches no file and no foreign code, and C is not on the list.</strong></p>
      <p class="sub" style="max-width:none">That is a statement about the program, made by the compiler, not a property a framework can add with a library. For a service whose job is a boundary, it is the second half of the contract: what the API accepts, and what the program behind it can reach.</p>
      <p class="note">What it does not say: <code>net_in("")</code> is the network, not narrowed to a port, because the compiler has one bound for listening and connecting. With PostgreSQL the list gains the network and one random-file read for the login, and still nothing foreign. <a href="https://github.com/alpibrusl/cancho-gateway">cancho-gateway</a> and <a href="https://github.com/alpibrusl/cancho-hooks">cancho-hooks</a> commit their reports and CI fails when one changes; <strong>so does this repository</strong>: <code>docs/authority.json</code> is the report as last approved, and a new capability is a red diff that only committing the new file makes green. (Adding one write to standard output to the service shows up as a new <code>io_write</code>; that was tried.)</p>
    </div>
    <div class="term" role="img" aria-label="cancho authority on the users service: it performs args, clock, conn_accept, conn_read, conn_write, err_write, heap, net_in and poll, and never touches the filesystem, signals, other programs or foreign code."><div class="bar"><i></i><i></i><i></i></div>
<pre><span class="c">$</span> cancho authority users.cho web.cho … --std
performs
    args
    clock
    conn_accept
    conn_read
    conn_write
    err_write
    heap
    <span class="y">net_in("")</span>
    poll
never touches
    <span class="g">the filesystem</span>
    <span class="g">signals</span>
    <span class="g">other programs</span>
    <span class="g">foreign code</span>
provably pure (235 of 404 functions)</pre>
    </div>
  </div>
</section>

<section id="why">
  <h2>What a request meets.</h2>
  <div class="fitwrap"><table class="fit">
    <thead><tr><th>When</th><th>What the service answers</th></tr></thead>
    <tbody>
      <tr><th>A body breaks the schema</th><td><code>422</code> with every error and its pointer. An unknown key is an error too.</td></tr>
      <tr><th>The body is not JSON, or the content type is not</th><td><code>400</code> with the byte it failed at; <code>415</code> for another content type.</td></tr>
      <tr><th>A path, query or header parameter breaks its schema, a query key is unknown or repeated</th><td><code>422</code> from <code>web.dispatch</code>, before the handler runs: every error, each at <code>/query/limit</code>, <code>/path/id</code> or <code>/header/…</code> with a code (<code>maximum</code>, <code>type</code>, <code>unknown</code>, <code>duplicate</code>). A client that misspells <code>limit</code> is told, not served the default.</td></tr>
      <tr><th>No such route, or the wrong method</th><td><code>404</code> as <code>problem+json</code>; <code>405</code> with <code>Allow</code>. Both written by <code>dispatch</code>.</td></tr>
      <tr><th>A user is deleted</th><td><code>204</code> with no body and neither <code>Content-Length</code> nor <code>Content-Type</code>, framed correctly even when pipelined.</td></tr>
      <tr><th>The store is full</th><td><code>503</code>, not a crash. The example holds up to 100,000 users or 64 MiB.</td></tr>
      <tr><th>A route is added to the declaration</th><td>It is in <code>/openapi.json</code>. A route that is served and deliberately not documented (the document itself) is declared <code>internal</code>.</td></tr>
    </tbody>
  </table></div>
</section>

<section id="how">
  <h2>How it works</h2>
  <p class="sub">The application keeps its loop. <code>web</code> declares, routes, documents and judges parameters: <code>web.dispatch</code> is called in the loop where <code>web.find</code> was.</p>
  <div class="two">
    <figure class="figure">
      <svg viewBox="0 0 440 260" role="img" aria-label="At start-up, one declaration of operations produces the router and the OpenAPI document. At run time the application's loop waits, takes a request, finds its route, runs the handler and responds.">
        <defs><marker id="h" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0 10 5 0 10z" fill="var(--muted)"/></marker></defs>
        <rect class="hot" x="6" y="8" width="160" height="96" rx="12"/><text class="t" x="86" y="30" text-anchor="middle">web.operation …</text>
        <text class="s" x="86" y="52" text-anchor="middle">route · parameters</text><text class="s" x="86" y="70" text-anchor="middle">body · responses</text><text class="s" x="86" y="88" text-anchor="middle">declared once, at start</text>
        <rect class="box" x="236" y="8" width="198" height="40" rx="8"/><text class="t" x="335" y="33" text-anchor="middle">router · web.find</text>
        <rect class="box" x="236" y="64" width="198" height="40" rx="8"/><text class="t" x="335" y="89" text-anchor="middle">openapi.json · checked in</text>
        <path class="ar" d="M166 40C200 40 200 28 234 28" marker-end="url(#h)"/><path class="ar" d="M166 74C200 74 200 84 234 84" marker-end="url(#h)"/>
        <rect class="box" x="6" y="140" width="428" height="112" rx="12"/><text class="t" x="20" y="162">your loop</text>
        <rect class="box" x="20" y="176" width="86" height="60" rx="8"/><text class="s" x="63" y="202" text-anchor="middle">server.wait</text><text class="s" x="63" y="220" text-anchor="middle">I/O, once</text>
        <rect class="box" x="124" y="176" width="86" height="60" rx="8"/><text class="s" x="167" y="202" text-anchor="middle">server.next</text><text class="s" x="167" y="220" text-anchor="middle">one request</text>
        <rect class="hot" x="228" y="176" width="92" height="60" rx="8"/><text class="s" x="274" y="202" text-anchor="middle">dispatch</text><text class="s" x="274" y="220" text-anchor="middle">then handle</text>
        <rect class="box" x="338" y="176" width="86" height="60" rx="8"/><text class="s" x="381" y="202" text-anchor="middle">respond</text><text class="s" x="381" y="220" text-anchor="middle">the answer</text>
        <path class="ar" d="M106 206H122" marker-end="url(#h)"/><path class="ar" d="M210 206H226" marker-end="url(#h)"/><path class="ar" d="M320 206H336" marker-end="url(#h)"/>
        <path class="ar dash" d="M335 104C335 130 300 150 280 174" marker-end="url(#h)"/>
      </svg>
    </figure>
    <figure class="figure">
      <h3>The declaration, in code</h3>
      <pre class="code" tabindex="0" style="margin:0"><code>let (api, op) = web.operation(heap, api,
    "GET", "/users/:id", "getUser");
api = web.path_param(heap, api, op, "id", path_id);
api = web.respond(heap, api, op, 200, "the user", user);
api = web.respond_problem(heap, api, op, 404);
api = web.respond_problem(heap, api, op, 422);

// in the loop: the route, with its parameters judged
let (routed, id) = web.dispatch(heap, api, sc, request,
    table, params, args, scratch, out, keep);
if id == web.answered() {{ return routed; }}   // 404, 405, 422
let id_value = web.int_arg(args, id_slot);   // valid, 1..99</code></pre>
      <figcaption><code>path_id</code> and <code>user</code> are <code>cancho-schema</code> nodes: the ones that validate are the ones that appear in the document. <code>dispatch</code> keeps nothing and allocates nothing for a request that is fine.</figcaption>
    </figure>
  </div>
  <p class="note">Why the loop is the application&rsquo;s: a framework that owned it would hand each handler a view of buffers the handler cannot name a region for, which does not type-check in cancho today (<a href="{REPO}/blob/main/docs/design.md">design §2</a>). So a handler is an ordinary function the application calls, and what it can touch is in its signature.</p>
</section>

<section id="proof">
  <h2>We hold it to its own contract.</h2>
  <p class="sub">The real binary on a real socket, a real HTTP client, and a generator that reads the served OpenAPI document and sends requests the document allows and ones it does not. A response the document does not declare fails the test.</p>
  <div class="stats">
    <div><b>27</b><span>end-to-end tests over real sockets, run against the built service</span></div>
    <div><b>8,447</b><span>requests generated by Schemathesis from the document in the last 500-example run; none failing</span></div>
    <div><b>byte for byte</b><span>the served document is the checked-in <code>openapi.json</code>, and validates as OpenAPI 3.1</span></div>
    <div><b>20</b><span>deliberate breakages of <code>dispatch</code> and the code under it, each caught by a test</span></div>
  </div>
  <p class="note"><a href="evidence.html">What the tests cover, what they found, and what is not claimed</a></p>
  <div class="cols">
    <div><h3>What building it found</h3><ul>
      <li><code>150.0</code> is an integer in JSON Schema and string length counts code points: both were wrong in <code>cancho-schema</code>, and the schema's own tests had been shaped to agree. Schemathesis disagreed on the first run.</li>
      <li>A float-spelled integer read as <code>0</code> and would have stored <code>"age": 0</code> silently.</li>
      <li>No <code>204</code> was possible: <code>http.respond_head</code> always wrote <code>Content-Length</code>. Fixed in cancho.</li>
      <li>The comparison with Go found the page endpoint at 0.62&times; of it, for two reasons, one in the example and one in cancho&rsquo;s <code>std.buffer</code>. Both fixed.</li>
    </ul></div>
    <div><h3>What it disproved</h3><ul>
      <li>That a framework can own the loop and call a handler: it does not type-check, and the reason was reproduced, not assumed.</li>
      <li>That a validated value should be validated again on the way out: re-checking the program&rsquo;s own output held the page endpoint to about 40,000 requests a second; splicing it as bytes made it 62,000.</li>
      <li>That a benchmark number is a measurement because it looks plausible: the load generator once mis-read every response and landed near the right answer.</li>
    </ul></div>
  </div>
</section>

<section id="fit">
  <h2>Where it fits</h2>
  <p class="sub">For a JSON API whose contract you want to be a file that CI checks, on a service that has to be small and auditable. Not yet for the public edge, and not where you need what FastAPI&rsquo;s ecosystem gives. <strong>Speed is the supporting evidence below, not the argument.</strong></p>
  <div class="fitwrap"><table class="fit wide">
    <thead><tr><th></th><th>FastAPI</th><th>Go <code>net/http</code></th><th>cancho-web</th></tr></thead>
    <tbody>
      <tr><th>API declaration</th><td>Decorated functions and pydantic models</td><td>Handlers; the contract is written separately, or by a library</td><td>Operation declarations, as data</td></tr>
      <tr><th>OpenAPI</th><td>Generated from those declarations</td><td>A separate tool or library</td><td>Generated from the same declaration, and a file that a test compares byte for byte</td></tr>
      <tr><th>Input validation</th><td>A model layer, before the handler</td><td>By hand, or a library</td><td>The schema nodes that document the input: parameters before the handler, bodies in its first lines</td></tr>
      <tr><th>What the service may touch</th><td>Not stated</td><td>Not stated</td><td>The compiler&rsquo;s report: no foreign code, no files</td></tr>
      <tr><th>Runtime model</th><td><code>async</code> on an event loop</td><td>Goroutines</td><td>One explicit loop and one thread; more cores are more processes or threads</td></tr>
      <tr><th>Ecosystem</th><td>Huge</td><td>Huge</td><td>Tiny: one example service, and the API of cancho-hooks</td></tr>
      <tr><th>A read on one core, this VM</th><td>4,921 a second</td><td>65,216</td><td>83,289</td></tr>
    </tbody>
  </table></div>
  <p class="note">FastAPI also generates its document from its declarations, so the difference is not that the others drift. It is that here the declaration is data and not reflection, the document is a file CI compares, and the compiler says what the program behind it can reach. What you give up: dependency injection, middleware, <code>async</code>, authentication, a docs UI, defaults declared once, and an ecosystem. One thread, a <code>Poller</code>: more cores are more processes (<code>reuseport</code>) or, in <code>examples/users_threads</code>, the same loop in two threads (cancho has threads; that example shares no state, so it is not a deployable service).</p>
  <div class="cols">
    <div><h3>Built for</h3><ul><li>JSON APIs behind a TLS-terminating front</li><li>A contract you want diffed in review</li><li>Services where &ldquo;what can it touch?&rdquo; has to have an answer</li></ul></div>
    <div class="no"><h3>Not for</h3><ul><li>The public edge, until a service is put behind cancho&rsquo;s TLS server (it exists; this layer has not been tried with it)</li><li>Anything that needs authentication, middleware or dependency injection today</li><li>Streaming bodies, or a store shared between threads</li></ul></div>
  </div>
</section>

<section id="numbers">
  <h2>And it is fast, honestly.</h2>
  <p class="sub">One core each, loopback, one 4-vCPU VM, one run (the second; <a href="evidence.html#bench">the first is in the evidence</a>), repeats within about 5% (a create up to 10%). Every implementation is first held to do the same work: the same requests, the same statuses and bodies. <strong>It is behind a hand-written C server</strong> on a rejected body and a create (by 6% and 11%) and ahead of it on a read and a page, and <strong>behind Go&rsquo;s <code>fasthttp</code></strong> on a read and a create (by 11% and 7%, in a later run on another VM).</p>
  <div class="two" style="grid-template-columns:1fr">
    <figure class="figure"><img src="figures/bench.svg" width="700" height="{22 + (34 + 4*19 + 14) * 4}" alt="Requests per second on one core in four cells. cancho-web is 14 to 18 times FastAPI, ahead of Go net/http in all four, ahead of hand-written C on a read and a page and behind it on the other two."><figcaption>Median of 3, requests a second, the figures of <a href="evidence.html#bench">the table</a>. FastAPI is its best of three set-ups in each column. Against FastAPI a gap of 14&ndash;18&times; says mostly that Python&rsquo;s cost per request is high; the Go and C servers are there so that a number is a position, not only a ratio.</figcaption></figure>
  </div>
  <div class="stats">
    <div><b>14&ndash;18&times;</b><span>FastAPI, one core each (19&ndash;25&times; its two workers, on two cores each)</span></div>
    <div><b>0.55 ms</b><span>p99 on a read (FastAPI: 10.8 ms)</span></div>
    <div><b>1.3&ndash;1.4&times;</b><span>Go <code>net/http</code>, with two thirds of its p99</span></div>
    <div><b>92%</b><span>of what one core can do over loopback TCP (a server that answers one canned reply)</span></div>
  </div>
  <div class="stats">
    <div><b>1.8 MiB</b><span>resident at rest, 2.0 MiB with 100 idle connections (FastAPI: 47 MiB; Go: 7&ndash;12 MiB)</span></div>
    <div><b>4 ms</b><span>to the first answer (FastAPI: about half a second)</span></div>
  </div>
  <p class="note"><strong>Stronger yardsticks than FastAPI.</strong> A later run, on a slower VM, added Go&rsquo;s <code>fasthttp</code> and Rust&rsquo;s axum (one thread, serde), each held to the same work first. <code>fasthttp</code> served 80,150 reads a second against cancho&rsquo;s 72,153, and 45,428 creates against 42,562; cancho was ahead on a page of 20 (62,320 against 54,236) and level on a rejected body; axum served 39,747 reads. cancho is in the same league as the Go server written for speed, not above it. <a href="evidence.html#yardsticks">The evidence has the table.</a></p>
  <p class="note">None of this measures TLS or a real handler&rsquo;s work. Two cores each are in <a href="evidence.html#cores">the evidence</a>: the gap with FastAPI narrows to 19&ndash;25&times; and does not close. A first run, on a faster VM, had 15&ndash;26&times;: against a Python program the ratio depends on the machine. A service that spends 5 ms in a query is 5 ms slower in all of them.</p>
</section>

<section id="features">
  <h2>What you get</h2>
  <div class="grid">
    <div><h3>Operations</h3><p>Method, path pattern, an operation id; the route id is what the handler tests.</p></div>
    <div><h3>Typed parameters</h3><p>Path, query and header parameters with a schema node each, written to the document <em>and</em> checked by <code>dispatch</code> before the handler runs. Values arrive in a slot table, already valid.</p></div>
    <div><h3>Validated bodies</h3><p><code>cancho-schema</code>: every error, a JSON Pointer each, strict objects, string length in code points.</p></div>
    <div><h3>problem+json</h3><p>RFC 9457, with <code>errors</code> and <code>count</code> for a body, and a named <code>Problem</code> component in the document.</p></div>
    <div><h3>OpenAPI 3.1</h3><p>Generated at start-up, checked against a stock validator, diffed in CI. Components, shared path parameters, response headers, plain-text answers.</p></div>
    <div><h3>Who may call</h3><p>Bearer schemes and <code>require</code> / <code>no_auth</code> are declared and readable back. Nothing here checks a token.</p></div>
    <div><h3>A package</h3><p><code>web</code> is published as a store, so a project names it in <code>cancho.toml</code> instead of copying a file.</p></div>
    <div><h3>PostgreSQL</h3><p><code>examples/users_pg</code> is the same API on a table, same document, same tests; optionally a pool so a slow query does not stop the loop.</p></div>
  </div>
</section>

<section id="start">
  <h2>Try it</h2>
  <p class="sub">Build the pinned compiler and the two packages, then the example:</p>
  <pre class="code" tabindex="0"><code>git clone https://github.com/alpibrusl/cancho
git clone https://github.com/alpibrusl/cancho-schema
git clone https://github.com/alpibrusl/cancho-web &amp;&amp; cd cancho-web
pin() {{ sed -n "s/^ *$1: *//p" .github/workflows/ci.yml; }}
(cd ../cancho &amp;&amp; git checkout "$(pin CANCHO_REV)" &amp;&amp; cargo build --release -p cancho)
(cd ../cancho-schema &amp;&amp; git checkout "$(pin SCHEMA_REV)")
export CANCHO=$PWD/../cancho/target/release/cancho

scripts/build.sh examples/users/users.cho build/users
build/users 8080 &amp;
curl -s -XPOST -H 'Content-Type: application/json' -d '{{"name":"Ada","age":36}}' localhost:8080/users</code></pre>
  <p class="note">Building needs Rust (the compiler pins its own toolchain). The packages are fetched and checked against <code>deps/*.lock</code> by hash every time. <a href="examples.html#run">The examples page</a> goes further; the <a href="{REPO}#readme">README</a> has the rest.</p>
</section>

<aside class="status" id="status">
  <h2>Alpha: the declaration half is built</h2>
  <p class="note" style="margin:.2rem 0 .6rem">Alpha means the interfaces may change and nothing here is certified for production.</p>
  <ul>
    <li><strong>Not built yet:</strong> defaults declared once (a handler still says what <code>limit</code> is when it is absent), and <code>dispatch</code> in the PostgreSQL and threads examples, which keep <code>web.find</code> and their own checks. <a href="{REPO}/blob/main/docs/design.md">§9</a> says what <code>dispatch</code> does, what building it found, and what it cost: a read 1.5% slower, a refused parameter 10%.</li>
    <li><strong>No middleware, authentication or dependency injection</strong>; nothing checks a token.</li>
    <li><strong>TLS, threads and streaming exist in cancho and are not used here.</strong> cancho has a TLS 1.3 server (not independently reviewed) and an <code>http.server</code> that a terminator can drive (<code>examples/https_hello</code>); no service in this repository has been put behind it, so terminate TLS in front. Threads run the loop twice in <code>examples/users_threads</code>, with a store each; a store they share is not built. <code>http.server</code> can stream a response; <code>web</code> cannot declare one yet.</li>
    <li>Responses are documented, not enforced: nothing checks that a handler answered what it declared. The contract tests do, from outside, for every request. A request <em>body</em> is still read by the handler (validated, but not by <code>dispatch</code>).</li>
    <li>The generated JSON Schema has no <code>$ref</code>/<code>$defs</code> of its own.</li>
    <li>The benchmark is one VM, one run. The ratios are the finding; the absolute figures are that VM&rsquo;s.</li>
  </ul>
  <p style="margin:.8rem 0 0"><a href="evidence.html">The evidence</a> · <a href="{REPO}/blob/main/docs/design.md">The design</a> · <a href="{REPO}/blob/main/docs/benchmarks.md">The benchmarks</a></p>
</aside>
''' + FOOT
(OUT/'index.html').write_text(index)
print('index', len(index))

# ------------------------------------------------------------------ examples
def plain(s):
    return s.replace('@@REPO@@', REPO)

examples = head(
 'cancho-web examples: the users API, run',
 'Runnable sessions with cancho-web: create, read and page users, every error at once, the generated OpenAPI document, the same API on PostgreSQL. Every response shown is real output.',
 'cancho-web: examples',
 'The users API, run: what it answers, what it refuses, and the document it serves.',
 'cancho-web examples: the users API, with the answers it gives and the document it serves.',
 'examples.html') + header('examples') + plain('''
<section id="top" style="padding-top:3rem">
  <h1 style="font-size:clamp(2rem,5vw,3rem)">Examples</h1>
  <p class="lead">Three runnable services, all held to their own OpenAPI document by the end-to-end tests: <code>examples/users</code> (a CRUD JSON API in memory), <code>examples/users_pg</code> (the same API on PostgreSQL) and <code>examples/users_threads</code> (the same loop in two threads of one process). Every response below is real output of the built service.</p>
  <p class="note">There is no prebuilt binary yet: the service is built from source against a pinned compiler.</p>
</section>

<section id="run">
  <h2>Run it, once</h2>
  <p class="sub">The compiler and the two packages are checked out at the revisions CI builds and tests with, read from <code>ci.yml</code> so this text cannot drift from it. The packages are fetched and verified against <code>deps/*.lock</code> by hash every time, never taken from a copy checked in here.</p>
  <pre class="code" tabindex="0"><code>git clone https://github.com/alpibrusl/cancho
git clone https://github.com/alpibrusl/cancho-schema
git clone https://github.com/alpibrusl/cancho-web &amp;&amp; cd cancho-web
pin() { sed -n "s/^ *$1: *//p" .github/workflows/ci.yml; }
(cd ../cancho &amp;&amp; git checkout "$(pin CANCHO_REV)" &amp;&amp; cargo build --release -p cancho)
(cd ../cancho-schema &amp;&amp; git checkout "$(pin SCHEMA_REV)")
export CANCHO=$PWD/../cancho/target/release/cancho

scripts/build.sh examples/users/users.cho build/users
build/users 8080 &amp;</code></pre>
  <p class="note">To run the tests too: <code>pip install jsonschema openapi-spec-validator schemathesis</code>, then <code>python3 tests/e2e.py</code> (27 tests, Schemathesis included, about 25 s) and <code>benches/check.sh</code>.</p>
</section>

<section id="create">
  <h2>1. Create, and what comes back</h2>
  <p class="sub">A valid body: <code>201</code>, a <code>Location</code>, the stored user.</p>
  <pre class="code" tabindex="0"><code>$ curl -i -XPOST -H 'Content-Type: application/json' \\
       -d '{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}' \\
       localhost:8080/users
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 103
Connection: keep-alive
Location: /users/1

{"id":1,"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}</code></pre>
</section>

<section id="refuse">
  <h2>2. A body that breaks the rules gets every error</h2>
  <p class="sub">Not the first: all of them, each with where it is, as RFC 9457 <code>application/problem+json</code>. An unknown key is refused too, at its own pointer.</p>
  <pre class="code" tabindex="0"><code>$ curl -i -XPOST -H 'Content-Type: application/json' -d '{"name":"","age":151,"role":"root","nope":1}' localhost:8080/users
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json
Content-Length: 369

{"type":"about:blank","title":"Unprocessable Content","status":422,"count":4,"errors":[{"pointer":"/name","code":"min_length","detail":"is too short"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"},{"pointer":"/role","code":"choice","detail":"is not one of the allowed values"},{"pointer":"/nope","code":"unknown","detail":"is not a known field"}]}</code></pre>
  <div class="fitwrap"><table class="fit">
    <thead><tr><th>Request</th><th>Answer</th></tr></thead>
    <tbody>
      <tr><th>Malformed JSON</th><td><code>400</code>, saying what failed and at which byte</td></tr>
      <tr><th>Another content type</th><td><code>415</code></td></tr>
      <tr><th>A body that breaks the schema</th><td><code>422</code>, every error, as above</td></tr>
      <tr><th>An id that is not a positive integer</th><td><code>422</code>, at <code>/path/id</code></td></tr>
      <tr><th>No such user</th><td><code>404</code> as <code>problem+json</code></td></tr>
    </tbody>
  </table></div>
</section>

<section id="read">
  <h2>3. Read, page, delete</h2>
  <pre class="code" tabindex="0"><code>$ curl 'localhost:8080/users?limit=1&amp;offset=1'
{"total":2,"items":[{"id":2,"name":"Grace"}]}

$ curl -i -XDELETE localhost:8080/users/2
HTTP/1.1 204 No Content
Connection: keep-alive

$ curl -i localhost:8080/users/2
HTTP/1.1 404 Not Found
Content-Type: application/problem+json

{"type":"about:blank","title":"Not Found","status":404,"detail":"no such user"}

$ curl -i 'localhost:8080/users?limit=0'
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json

{"type":"about:blank","title":"Unprocessable Content","status":422,"count":1,"errors":[{"pointer":"/query/limit","code":"minimum","detail":"is below the minimum"}]}</code></pre>
  <p class="note">The <code>204</code> has no body and neither <code>Content-Length</code> nor <code>Content-Type</code>. An unknown query key is a <code>422</code> as well: a client that misspells <code>limit</code> should be told.</p>
  <p class="sub" style="margin-top:1.2rem">A parameter is judged like a body: every error, with where it is. Here three at once, from <code>web.dispatch</code>, before the handler runs:</p>
  <pre class="code" tabindex="0"><code>$ curl -s 'localhost:8080/users?limit=101&amp;offset=-1&amp;nope=1'
{"type":"about:blank","title":"Unprocessable Content","status":422,"count":3,"errors":[{"pointer":"/query/limit","code":"maximum","detail":"is above the maximum"},{"pointer":"/query/offset","code":"minimum","detail":"is below the minimum"},{"pointer":"/query/nope","code":"unknown","detail":"is not a known field"}]}</code></pre>
  <div class="fitwrap"><table class="fit">
    <thead><tr><th>Route</th><th>What it does</th></tr></thead>
    <tbody>
      <tr><th><code>GET /health</code></th><td><code>{"ok":true}</code></td></tr>
      <tr><th><code>GET /users?limit=&amp;offset=</code></th><td>a page (<code>limit</code> 1..100, default 20)</td></tr>
      <tr><th><code>POST /users</code></th><td>create</td></tr>
      <tr><th><code>GET /users/:id</code>, <code>DELETE /users/:id</code></th><td>the user / <code>204</code></td></tr>
      <tr><th><code>GET /openapi.json</code></th><td>the contract (OpenAPI 3.1: <code>NewUser</code>, <code>User</code>, <code>Page</code>, <code>Problem</code>)</td></tr>
    </tbody>
  </table></div>
  <p class="note">Storage is in memory, up to 100,000 users or 64 MiB (past that a <code>POST</code> is a 503); a delete leaves a hole, ids are not reused.</p>
</section>

<section id="contract">
  <h2>4. The contract is a file</h2>
  <p class="sub">The document is generated from the same declaration that makes the router and the same schema nodes the validator runs, and it is checked in as <a href="@@REPO@@/blob/main/examples/users/openapi.json"><code>examples/users/openapi.json</code></a>. An end-to-end test compares what the service serves with that file byte for byte, so a change to the API is a change to a file in review.</p>
  <pre class="code" tabindex="0"><code>$ curl -s localhost:8080/openapi.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["openapi"], sorted(d["paths"]))'
3.1.0 ['/health', '/users', '/users/{id}']</code></pre>
  <p class="sub" style="margin-top:1.2rem">Who may call an operation is declared the same way, and only the document is affected (the application&rsquo;s own gate still decides): <code>web.bearer_scheme</code>, then <code>web.require</code> once for each token that will do, <code>web.no_auth</code> for an open route. <code>web.requirements</code>, <code>web.requirement</code> and <code>web.is_open</code> read it back, so a gate need not keep a second table.</p>
</section>

<section id="postgres">
  <h2>5. The same API on PostgreSQL</h2>
  <p class="sub"><code>examples/users_pg</code> is this service with a table behind it: the same routes, the same schema nodes, the same OpenAPI document (plus a <code>pattern</code> on <code>name</code> and <code>email</code>, which refuse U+0000 because PostgreSQL text cannot hold it) and the same end-to-end suite, Schemathesis included. It reaches the database through functions that <code>pgen</code> (in <a href="https://github.com/alpibrusl/cancho-pg">cancho-pg</a>) wrote from <code>queries.sql</code> by asking the server what each statement&rsquo;s parameters and columns are.</p>
  <pre class="code" tabindex="0"><code>createdb users_pg &amp;&amp; psql users_pg -f examples/users_pg/schema.sql
scripts/build.sh examples/users_pg/users_pg.cho build/users_pg
build/users_pg 8080 127.0.0.1 5432 postgres users_pg -         # &lt;port&gt; &lt;db host&gt; &lt;db port&gt; &lt;db user&gt; &lt;db&gt; &lt;password|-&gt;

# a pool of connections: a request that needs the database is held, its query is queued, the loop goes on
build/users_pg 8080 127.0.0.1 5432 postgres users_pg - - 4     # ... &lt;password|-&gt; &lt;reuseport|-&gt; &lt;connections&gt;</code></pre>
  <p class="note">By default it holds one connection and each request that needs the database blocks the loop for a round trip. Measured (<a href="evidence.html#postgres">evidence</a>): a read is 14,976 requests a second, 5.1&times; lean FastAPI with asyncpg and 13.9&times; FastAPI with SQLAlchemy. With a pool, <code>GET /health</code> stays under a millisecond while a query waits a second on a lock (the blocking service: 645 ms).</p>
</section>

<section id="not">
  <h2>What these cases do not cover yet</h2>
  <div class="cols">
    <div class="no"><h3>Not built</h3><ul><li>Defaults declared once (the handler still says what <code>limit</code> is when it is absent), and <code>dispatch</code> in the PostgreSQL and threads examples</li><li>Middleware, authentication, dependency injection</li><li>TLS (cancho has a server and an <code>https_hello</code> example; none of these services has been put behind it), streaming a response</li></ul></div>
    <div class="no"><h3>Not shown here</h3><ul><li>More than one core in one process beyond the two-thread example, which keeps a store per thread</li><li>A service that is not the users API: <a href="https://github.com/alpibrusl/cancho-hooks">cancho-hooks</a> declares its API with <code>web</code> (<code>src/api.cho</code>), and its router and document are made from that declaration</li></ul></div>
  </div>
</section>
''') + FOOT
(OUT/'examples.html').write_text(examples)
print('examples', len(examples))

# ------------------------------------------------------------------ evidence
def table(head_cells, rows, cls='fit num', first_us=None, nums_from=1):
    out = ['<div class="fitwrap"><table class="%s">' % cls, '<thead><tr>' + ''.join('<th>%s</th>' % h for h in head_cells) + '</tr></thead>', '<tbody>']
    for i, r in enumerate(rows):
        tr = ' class="us"' if first_us is not None and i == first_us else ''
        cells = ['<th>%s</th>' % r[0]] + ['<td class="n">%s</td>' % c if j + 1 >= nums_from else '<td>%s</td>' % c for j, c in enumerate(r[1:])]
        out.append('<tr%s>%s</tr>' % (tr, ''.join(cells)))
    out.append('</tbody></table></div>')
    return '\n'.join(out)

T_FASTAPI = table(['', 'GET one user', 'GET a page of 20', 'POST, invalid (422)', 'POST, create'], [
 ['cancho-web (users)', '83,289', '75,286', '63,241', '53,755'],
 ['FastAPI, uvicorn (asyncio)', '4,374', '3,852', '3,456', '3,751'],
 ['FastAPI, uvloop + httptools', '4,528', '4,009', '3,385', '3,801'],
 ['FastAPI lean, uvloop + httptools', '4,921', '4,307', '3,536', '3,948'],
], first_us=0)
T_GOC = table(['', 'GET one user', 'GET a page of 20', 'POST, invalid (422)', 'POST, create'], [
 ['C ceiling (a canned reply)', '90,700', '&ndash;', '&ndash;', '&ndash;'],
 ['hand-written C (epoll)', '75,734', '68,144', '67,376', '60,719'],
 ['cancho-web (users)', '83,289', '75,286', '63,241', '53,755'],
 ['Go <code>net/http</code>', '65,216', '53,792', '47,011', '41,051'],
 ['FastAPI, best of three', '4,921', '4,307', '3,536', '3,948'],
], first_us=2)
T_RATIO = table(['cancho-web against', 'GET one', 'page', 'invalid', 'create'], [
 ['FastAPI, best of three', '16.9&times;', '17.5&times;', '17.9&times;', '13.6&times;'],
 ['Go', '1.28&times;', '1.40&times;', '1.35&times;', '1.31&times;'],
 ['hand-written C', '1.10&times;', '1.10&times;', '0.94&times;', '0.89&times;'],
 ['C ceiling', '0.92&times;', '', '', ''],
])
T_LAT = table(['GET one user, 32 in flight (µs)', 'p50', 'p90', 'p99', 'p99.9', 'max'], [
 ['C ceiling', '224', '298', '478', '1,217', '2,729'],
 ['hand-written C', '278', '369', '518', '953', '3,435'],
 ['cancho-web (users)', '249', '322', '547', '1,815', '6,038'],
 ['Go <code>net/http</code>', '393', '460', '841', '1,303', '4,087'],
 ['FastAPI, uvicorn', '5,406', '8,391', '10,763', '17,877', '42,171'],
], first_us=2)
T_FIRST = table(['the first run, a faster VM, before dispatch', 'GET one user', 'GET a page of 20', 'POST, invalid (422)', 'POST, create'], [
 ['cancho-web (users)', '128,972', '70,768', '94,659', '64,327'],
 ['hand-written C (epoll)', '117,958', '105,523', '107,680', '91,783'],
 ['Go <code>net/http</code>', '79,772', '65,654', '60,278', '53,580'],
 ['FastAPI, best of three', '5,216', '4,604', '3,606', '4,163'],
 ['cancho-web against FastAPI', '25&times;', '15&times;', '26&times;', '15&times;'],
], first_us=0)
T_CORES = table(['requests a second, median of 3', 'GET /health', 'POST, invalid', 'GET ?limit=0'], [
 ['cancho, 1 process', '77,478', '55,888', '63,260'],
 ['cancho, 2 processes (reuseport)', '115,443', '90,064', '105,987'],
 ['cancho, 2 threads of 1 process', '126,256', '89,753', '111,814'],
 ['Go <code>net/http</code>, 1 core', '44,886', '35,088', '39,676'],
 ['Go <code>net/http</code>, 2 cores', '58,956', '45,593', '50,540'],
 ['FastAPI lean, 1 worker', '3,414', '2,262', '2,332'],
 ['FastAPI lean, 2 workers', '6,169', '4,307', '4,217'],
], first_us=1)
T_PG = table(['requests a second, median of 3', 'GET one user', 'GET a page of 20', 'POST, invalid (422)', 'POST, create'], [
 ['cancho users_pg, prepared', '14,976', '4,496', '95,328', '4,404 (noisy)'],
 ['cancho users_pg, parsing every call', '9,788', '3,865', '90,902', '2,748 (noisy)'],
 ['FastAPI + asyncpg, lean', '2,918', '1,961', '3,337', '2,657'],
 ['FastAPI + SQLAlchemy + asyncpg', '1,078', '582', '3,238', '846'],
], first_us=0)
T_POOL = table(['users_pg, requests a second', 'GET one user', 'GET a page of 20', 'POST, create (median of 10; range)'], [
 ['blocking, 1 copy', '15,638', '4,524', '2,317 (3 runs)'],
 ['blocking, 4 copies on core 0', '', '', '5,818 (4,528&ndash;8,329)'],
 ['pool, 1 connection', '63,980 / 65,894 / 64,262', '7,894&ndash;8,409', '3,818 (3,190&ndash;5,306)'],
 ['pool, 4 connections', '45,056', '7,420', '8,091 (6,836&ndash;10,776)'],
], first_us=2)

T_YARD = table(['requests a second', 'GET one user', 'GET a page of 20', 'POST, invalid (422)', 'POST, create'], [
 ['cancho-web (users)', '72,153', '62,320', '55,136', '42,562'],
 ['Go <code>fasthttp</code>', '80,150', '54,236', '53,872', '45,428'],
 ['hand-written C (epoll)', '61,126', '54,812', '55,804', '51,543'],
 ['Rust axum (one thread)', '39,747', '38,803', '33,196', '32,241'],
 ['Go <code>net/http</code>', '43,616', '36,259', '32,841', '27,991'],
 ['FastAPI lean, uvloop + httptools', '3,184', '2,832', '2,198', '2,606'],
], first_us=0)
T_DISPATCH = table(['requests a second, median of 6', 'before', 'after', 'after / before'], [
 ['GET one user', '86,140', '84,816', '0.985'],
 ['GET a page of 20', '76,294', '74,451', '0.976'],
 ['POST, invalid body (422)', '63,011', '62,739', '0.996'],
 ['POST, create', '55,507', '54,559', '0.983'],
 ['GET /users?limit=0 (a parameter refused)', '81,516', '73,011', '0.896'],
])

T_RES = table(['median of 5', 'start-up (ms)', 'idle (MiB)', '1,000 users', '100 idle connections', 'peak after 20,000 requests'], [
 ['cancho users', '4', '1.8', '2.0', '2.0', '2.1'],
 ['Go <code>net/http</code>', '6', '7.4', '11.8', '12.1', '14.1'],
 ['hand-written C (epoll)', '4', '1.8', '2.2', '6.7', '6.5'],
 ['FastAPI lean, uvloop + httptools', '486', '47.2', '47.4', '47.7', '47.8'],
 ['FastAPI lean, 2 workers', '586', '131.4', '131.6', '132.1', '132.2'],
], first_us=0)

T_SCALE = table(['requests a second, median of 5', 'GET one user', 'GET a page of 20', 'GET ?limit=0 (refused)'], [
 ['6 operations', '71,219', '62,681', '61,446'],
 ['206 operations', '72,588', '63,027', '62,643'],
 ['2,006 operations', '73,532', '61,968', '63,555'],
])
T_START = table(['operations declared', 'start-up before', 'start-up after'], [
 ['200', '0.04 s', '0.01 s'],
 ['1,000', '1.76 s', '0.13 s'],
 ['2,000', '12.77 s', '0.29 s'],
 ['4,000', '102.58 s', '1.11 s'],
 ['10,000', '(not run)', '8.05 s'],
])

evidence = head(
 'cancho-web evidence: tests, benchmarks, limits',
 'What the cancho-web tests cover, what building it found, how each benchmark number was measured against FastAPI, Go and C, and what is not claimed.',
 'cancho-web: evidence',
 'The tests, the contract check, the benchmarks and what they found. What is claimed, and what is not.',
 'cancho-web evidence: tests held to the served OpenAPI document, and benchmarks against FastAPI, Go and C.',
 'evidence.html') + header('evidence') + plain('''
<section id="top" style="padding-top:3rem">
  <h1 style="font-size:clamp(2rem,5vw,3rem)">Evidence</h1>
  <p class="lead">What the tests cover, what building it found, how each number was measured, and what is not claimed. The long forms are <a href="@@REPO@@/blob/main/docs/design.md">docs/design.md</a> and <a href="@@REPO@@/blob/main/docs/benchmarks.md">docs/benchmarks.md</a>; this page repeats their numbers and nothing else.</p>
</section>

<section id="claims">
  <h2>What is claimed, and what is not</h2>
  <div class="cols">
    <div><h3>Claimed, and measured</h3><ul>
      <li>Every response any end-to-end test sees is one the served OpenAPI document declares, with a body that validates against the schema it declares.</li>
      <li>The served document validates as OpenAPI 3.1 and is byte for byte the checked-in <code>openapi.json</code>.</li>
      <li>Schemathesis, generating positive and negative requests and stateful scenarios from that document, found no failure in 8,447 cases (the last 500-example run).</li>
      <li>On one core, 14&ndash;18&times; FastAPI and 1.3&ndash;1.4&times; Go <code>net/http</code>, with the same work checked first. On two cores each, 19&ndash;25&times; FastAPI&rsquo;s two workers.</li>
    </ul></div>
    <div class="no"><h3>Not claimed</h3><ul>
      <li>That it beats C: it is 10% ahead of a hand-written server on a read and a page, and 6% and 11% behind it on a rejected body and a create. The first run had it behind on the page too, and the page ratio is the least settled.</li>
      <li>Anything about TLS or a real handler&rsquo;s work: none was measured. About cores, only two (below); about memory, only the size at rest and under 100 idle connections.</li>
      <li>That the absolute figures, or the ratios, hold on another machine. One 4-vCPU VM, one run; repeats differ by about 5%, and a create by up to 10%. The first run, on a faster VM, had cancho at 128,972 on a read and 15&ndash;26&times; FastAPI.</li>
      <li>That responses are enforced: they are documented, and checked from outside.</li>
    </ul></div>
  </div>
</section>

<section id="tests">
  <h2>The tests</h2>
  <p class="sub"><code>python3 tests/e2e.py</code> builds the service, starts it, and talks to it over real sockets with a real HTTP client. CI runs it for each of the three services (in memory, PostgreSQL, PostgreSQL with a pool), with the same suite.</p>
  <div class="fitwrap"><table class="fit">
    <thead><tr><th>What</th><th>How</th></tr></thead>
    <tbody>
      <tr><th>The contract</th><td>Every response any test sees must be one the document declares, with a body that validates against its schema.</td></tr>
      <tr><th>The document</th><td>It validates as OpenAPI 3.1 (<code>openapi-spec-validator</code>) and equals <code>examples/users/openapi.json</code> byte for byte. The test fails when a declaration changes; that was checked by changing one description.</td></tr>
      <tr><th>Schemathesis</th><td>Generates requests from the document, positive and negative cases and stateful scenarios, and checks what comes back. 8,447 cases in the last 500-example run (<code>EXAMPLES=500</code>), none failing.</td></tr>
      <tr><th>The wire</th><td>Pipelining, keep-alive, 8 concurrent clients, an oversized body, and two pipelined <code>204</code>s and a <code>200</code> staying framed.</td></tr>
      <tr><th>Validation edges</th><td>Every error at once with its pointer, no coercion, <code>150.0</code> as an integer, string length in code points.</td></tr>
      <tr><th>Unit tests of <code>web</code></th><td>Documents derived by hand, compared byte for byte, for a minimal API, shared path parameters with <code>$ref</code>s and the problem response, query/body/header/hidden routes with the routing the declaration also made, security alternatives, header parameters and words.</td></tr>
      <tr><th>Unit tests of <code>dispatch</code></th><td>Seven tests with a case for every refusal code, in each place a parameter can be (path, query, header), for several errors at once, for two path parameters, for what must <em>not</em> be refused, for 2,000 unknown keys, 2,000 copies of a known one, a 20,000-byte key, <code>%zz</code>, <code>%ff</code>, <code>%00</code> and a scratch buffer too small. Twenty deliberate breakages of the code each fail one of them.</td></tr>
      <tr><th>The authority report</th><td><code>scripts/check-authority.sh</code> regenerates <code>cancho authority</code> for the users service and fails on any difference from the committed <code>docs/authority.json</code> (the list of pure functions and the counts are left out: they change with every function). Checked by changing the program: one added write to standard output is a new <code>io_write</code> and a red diff.</td></tr>
      <tr><th>The comparison servers</th><td><code>benches/check.sh</code>: the Go and C implementations still do the same work as the service. <code>benches/equivalent.py</code> sends the same 16 requests to every implementation and refuses to time anything unless every status and every successful body agrees; <code>benches/edges.py</code> adds 84 more.</td></tr>
    </tbody>
  </table></div>
</section>

<section id="bench">
  <h2>The benchmark</h2>
  <p class="sub">Each server runs alone on core 0; the load generator (<code>benches/kload.c</code>, two threads of 16 keep-alive connections, closed loop) runs on cores 2 and 3. Five seconds of load, three times, median; &ldquo;create&rdquo; is a fixed 30,000 requests from a fresh process, because it adds state. One 4-vCPU VM, one run (2026-10-08, on the current code; FastAPI 0.142.4, uvicorn 0.53.0, uvloop 0.23.0, Go 1.24.7). <code>benches/run.sh</code> reproduces it. <strong>An earlier run, on a faster VM, is at the end of this section.</strong></p>
  <h3 id="fastapi" style="margin-top:2rem">Against FastAPI, three ways</h3>
''' ) + T_FASTAPI + plain('''
  <p class="note">About 17&times; on a read, 17&times; on a page, 18&times; on a rejected body and 14&times; on a create, against the best FastAPI figure in each column. uvloop and httptools change almost nothing: FastAPI is CPU-bound in Python, in routing, dependency resolution and pydantic, not in its server. The lean variant, whose handlers return stored bytes instead of going through a <code>response_model</code>, gains about 10%. Create is the noisiest column.</p>
  <h3 style="margin-top:2rem">Against Go and a hand-written C server</h3>
  <p class="sub">FastAPI is a weak yardstick for speed. Go uses the standard library only (<code>net/http</code>, <code>encoding/json</code> into a struct, hand-written range checks, a mutex around the store, one core visible). The C floor is one thread, one epoll loop and a parser that knows four routes, validating and writing the stored answer in one pass: a hand-written baseline, not a proven minimum. The C ceiling answers every read with the same canned reply, and is the most one core can do over loopback TCP.</p>
''') + T_GOC + T_RATIO + T_LAT + plain('''
  <figure class="figure wide"><img src="figures/bench.svg" width="700" height="518" alt="Requests per second on one core in four cells, fastest first." ><figcaption>The second table above as a picture, drawn by <code>scripts/figures.py</code> from the table in the README.</figcaption></figure>
  <div class="cols">
    <div><h3>What it says</h3><ul>
      <li>On a read and a page it is 10% ahead of a hand-written C server, and at 92% of the kernel&rsquo;s limit: one core spends several microseconds a request in the socket path before any server code runs. The C server is a baseline that was not tuned further, so this is not a claim that cancho beats C.</li>
      <li>It is ahead of Go on every workload, with two thirds of its p99. That is Go&rsquo;s goroutine-per-connection runtime and GC on one core against a loop with neither. Go on two cores is below, untuned.</li>
      <li>On a create or a rejected body it serves 11% and 6% fewer requests than the C floor, probably because it parses, validates and writes the answer in separate passes. That was not profiled.</li>
    </ul></div>
    <div class="no"><h3>Not measured</h3><ul>
      <li>Go with Gin; Node; Rust other than axum on one thread. (<code>fasthttp</code> and axum are <a href="#yardsticks">below</a>, on one core.)</li>
      <li>More than two cores for the server; TLS; a real handler&rsquo;s work.</li>
      <li>FastAPI&rsquo;s usual deployment in the one-core tables: several worker processes. Two cores each are <a href="#cores">below</a>.</li>
    </ul></div>
  </div>
  <h3 style="margin-top:2rem">The first run</h3>
  <p class="sub">The same benchmark, on a faster VM and before <code>web.dispatch</code>. <strong>FastAPI barely moved between the two VMs (5,216 and 4,921) and cancho did (0.65&times;)</strong>, so the ratio against a Python program fell from 15&ndash;26&times; to 14&ndash;18&times; with no change to either program that explains it. A ratio like this depends on the machine; neither run is the true one, and this page quotes the later, on the current code. Against Go the first run had 1.08&ndash;1.6&times;, and against the C floor 1.09&times; on a read and 0.67&ndash;0.88&times; on the rest.</p>
''') + T_FIRST + plain('''
</section>

<section id="scale">
  <h2>Does the size of the API matter?</h2>
  <p class="sub">A request should cost the parameters of its operation, not the size of the API. That was argued; the first implementation scanned every declaration record per request and was 6.5% slower on a read, so <code>benches/scale.sh</code> asks it directly. <code>users &lt;port&gt; - &lt;n&gt;</code> declares <code>n</code> more operations after the six real ones, and the same requests go to the same routes in an API of 6, 206 and 2,006 operations. Five rounds, alternating the sizes.</p>
''') + T_SCALE + plain('''
  <p class="note"><strong>No dependence on the size of the API</strong>: every cell is within 3.5% of the six-operation figure, in both directions, inside what this VM moves by (about 5%). That includes the router, which holds all 2,006 routes.</p>
  <h3 style="margin-top:2rem">What does grow: start-up</h3>
  <p class="sub">Declaring operations was never the cost. Generating the OpenAPI document was: it rescanned every record inside loops that already did, and called a helper that was itself a scan. The helper is now a lookup in the index <code>operation</code> keeps, a one-line change that leaves the document byte-identical.</p>
''') + T_START + plain('''
  <p class="note">It is <strong>still quadratic</strong> (10,000 operations take 8 s). Nothing here is that large (<code>cancho-hooks</code> has 28 operations, the users API 6), and the cost is paid once, before the first request is accepted. It was found only because this benchmark declared a large API; the design had said declaring and generating were linear, and it is corrected there.</p>
</section>

<section id="memory">
  <h2>Start-up and memory</h2>
  <p class="sub"><code>benches/resources.py</code>: the time from <code>exec</code> to the first answered <code>GET /health</code>, and the resident memory (the process and everything it started, so a uvicorn master and its workers count) idle, after 1,000 users, with 100 more connections held open and silent, and its high-water mark after 20,000 requests. Medians of 5, not pinned: this is about size, not speed.</p>
''') + T_RES + plain('''
  <div class="cols">
    <div><h3>What it says</h3><ul>
      <li>At rest it is as small as the hand-written C server, and smaller with connections open: 2.0 MiB with 100 idle connections, where the C server&rsquo;s per-connection buffers take it to 6.7 MiB.</li>
      <li>Go is 4 times larger idle and 6&ndash;7 times with connections open or after a run; FastAPI 24&ndash;26 times (one worker) and 66&ndash;73 times (two). FastAPI&rsquo;s half-second start is Python importing.</li>
    </ul></div>
    <div class="no"><h3>Not claimed</h3><ul>
      <li>That 100 idle connections is the cost of a busy server. A resident figure counts the pages that were touched, <code>http.server</code> is sized from limits (up to 1,024 connections and 256 MiB of input), and a store near its 64 MiB is larger. The store here held 1,000 small users.</li>
      <li>Start-up from a cold disk: the files were in the page cache. One VM, not repeated elsewhere.</li>
    </ul></div>
  </div>
</section>

<section id="cores">
  <h2>Two cores each</h2>
  <p class="sub">The one-core tables are not how FastAPI is deployed. <code>benches/run_cores.sh</code> gives every server cores 0 and 1 and the load generator cores 2 and 3 of the same VM, with each one-core figure beside it. The workloads share no state, because every process keeps its own store: a health check, a refused body, a refused parameter. Median of 3, five seconds.</p>
''') + T_CORES + plain('''
  <div class="cols">
    <div><h3>What it says</h3><ul>
      <li>The second core narrows the gap with FastAPI and does not close it: cancho&rsquo;s two processes are 19&ndash;25&times; FastAPI&rsquo;s two workers, against 23&ndash;27&times; on one core. FastAPI scales best (1.8&ndash;1.9&times;), cancho 1.5&ndash;1.8&times;, Go 1.3&times;.</li>
      <li><strong>One cancho process is 13&ndash;15&times; ahead of two FastAPI workers.</strong></li>
      <li>Threads and processes are the same within the noise. The threads example keeps a store each, so it is not a deployable service.</li>
    </ul></div>
    <div class="no"><h3>Not claimed</h3><ul>
      <li>cancho&rsquo;s two-core figures may be understated: at 115,000 a second the load generator is near the most it was shown to drive on the first VM, and that check was <strong>not repeated on this VM</strong>.</li>
      <li>Go on two cores was not tuned, and a Go with <code>fasthttp</code> or a Rust <code>axum</code> would be a stronger yardstick. Neither was measured.</li>
      <li>Four cores for the server, a workload with state.</li>
    </ul></div>
  </div>
  <p class="note">An earlier version of this table was wrong and was discarded: the script started one process for the &ldquo;2 processes&rdquo; row, so it showed no scaling at all (77,622 against 77,251). It started two once the table was seen to say something the code could not do.</p>
</section>

<section id="yardsticks">
  <h2>Go fasthttp and Rust axum</h2>
  <p class="sub">The same workload and the same equivalence gates (16 requests, 84 edge cases) as the servers above. <code>fasthttp</code> v1.75.0 was built with Go 1.26.0, <code>go_users</code> with 1.24.7. axum 0.8 runs on tokio&rsquo;s <code>current_thread</code> runtime with <code>TCP_NODELAY</code> on. One core each, median of 3, <strong>one run on a VM slower than the one above</strong> (cancho&rsquo;s read is 72,153 here, 83,289 there): compare the rows with each other, not with the tables above.</p>
''') + T_YARD + plain('''
  <p class="note"><strong>fasthttp is faster than cancho</strong> on a read (11%) and a create (7%); cancho is ahead on a page of 20 (15%) and level on a rejected body (2%). The earlier claim of being ahead of Go holds against <code>net/http</code>, not against the Go server written for speed. cancho is 1.3&ndash;1.8&times; ahead of axum on one thread, written the idiomatic way (tower layers, extractors, serde); a hand-tuned <code>hyper</code> service would be nearer. Orderings within 10% of each other (cancho, fasthttp, C) are not established by one run on a shared VM.</p>
</section>

<section id="dispatch">
  <h2>What dispatch cost</h2>
  <p class="sub"><code>benches/ab.sh</code> alternates two builds of <code>examples/users</code> round by round, so a drift of the machine lands on both: <code>main</code> (the handler checks its parameters) against <code>web.dispatch</code>. The workloads of the benchmark above plus <code>GET /users?limit=0</code>, six rounds. <strong>This VM is slower than the one above</strong> (a read here is about 86,000 a second), so only the ratios mean anything.</p>
''') + T_DISPATCH + plain('''
  <p class="note">Within the 5% this VM moves by, except the refusal of a parameter, which is 10% slower: it judges the request twice and builds a JSON document per error where the hand-written code wrote one sentence. <strong>The first implementation was slower on a read (0.93&ndash;0.94, in two runs)</strong>: it scanned every record of the declaration for each request. An index and a chain of each operation&rsquo;s own parameters removed that, and a pass that allocates nothing for a request that is fine removed the rest.</p>
</section>

<section id="postgres">
  <h2>On PostgreSQL</h2>
  <p class="sub"><code>examples/users_pg</code> against the same API in FastAPI twice, because &ldquo;FastAPI with a database&rdquo; is not one number. Server on core 0, <strong>PostgreSQL 16 on core 1</strong> (default settings, <code>fsync</code> on), load generator on cores 2 and 3. A create is a fixed 20,000 requests against a fresh table.</p>
''') + T_PG + plain('''
  <p class="note">A read is 53% faster than the build that parses every call (14,976 against 9,788), 5.1&times; lean FastAPI and 13.9&times; the SQLAlchemy one. <strong>A create: no conclusion.</strong> 4,404 against 2,748 looked like a 60% gain and was written up as one; ten runs of the same build span 2,155 to 4,245 a second, so 4,404 was the top of the noise. The write-up says so, and only the reads and pages are measured well enough to compare.</p>
  <h3 id="pool" style="margin-top:2rem">A pool in one process</h3>
  <p class="sub">With a pool of connections a request that needs the database is held, its query is queued, and the loop goes on. A query held behind a table lock for a second, with 100 <code>GET /health</code> meanwhile: the pool&rsquo;s median 0.14 ms and <strong>maximum 0.76 ms</strong>; the blocking service <strong>645 ms</strong>.</p>
''') + T_POOL + plain('''
  <p class="note">More connections make reads slower (PostgreSQL&rsquo;s backends share its one core) and a write wants several. The pool&rsquo;s write median beats four copies&rsquo;, but the ranges overlap. It does not reconnect after a database restart (database routes answer 503 until the service is restarted) and has no per-request deadline.</p>
</section>

<section id="threads">
  <h2>Two threads in one process</h2>
  <p class="sub"><code>examples/users_threads</code> runs the unchanged <code>users</code> loop in two threads of one process: one <code>SO_REUSEPORT</code> listener, a forked heap and a forked clock each (cancho&rsquo;s <code>docs/parallelism.md</code> section 9). The workload is the invalid <code>POST /users</code>, server on cores 0&ndash;1, load generator on 2&ndash;3, interleaved with two processes in three rounds of five runs.</p>
  <div class="stats">
    <div><b>149,380</b><span>requests a second, two threads (median of 15)</span></div>
    <div><b>141,208</b><span>two processes</span></div>
  </div>
  <p class="note">The ranges overlap almost completely, so the finding is that threads are <em>not worse</em>, not that they are faster. A stateless service shares nothing either way. What threads add is the possibility of sharing a store, which is not built: each thread keeps its own, so this example is not a deployable service.</p>
</section>

<section id="found">
  <h2>What the tests found</h2>
  <div class="cols">
    <div><h3>In <code>cancho-schema</code></h3><ul>
      <li><code>150.0</code> is an integer in JSON Schema, and string length counts code points. Both were decisions the schema&rsquo;s own tests agreed with, because the tests had been shaped to the decisions. Schemathesis disagreed on the first run.</li>
    </ul></div>
    <div><h3>In the example</h3><ul>
      <li>An unknown query parameter has to be refused for the reason an unknown body field is.</li>
      <li>The document must state the integer maximum the server enforces: a 17-digit limit that is true of the server and false of the contract is a defect in the contract.</li>
      <li><code>json.to_int</code> on a float-spelled integer answered 0, which would have stored <code>"age": 0</code> silently.</li>
    </ul></div>
    <div><h3>In cancho</h3><ul>
      <li><code>server.reply</code> hard-coded <code>Content-Type: application/json</code>; <code>problem+json</code> needed <code>reply_as</code>.</li>
      <li><code>http.respond_head</code> always wrote <code>Content-Length</code>, so a correct <code>204</code> was impossible.</li>
      <li><code>std.buffer.append</code> copied a byte at a time: 62,000 to 71,000 requests a second on the page endpoint.</li>
    </ul></div>
    <div><h3>In the benchmark</h3><ul>
      <li>The load generator matched <code>Content-Length:</code> case-sensitively, and uvicorn sends it lowercase, so every answer&rsquo;s body was counted as the next response. The figures were plausible (about 5,000 a second) and wrong. It is caught now because the generator checks every status against the one expected. A benchmark that cannot fail is not a measurement.</li>
      <li>The page endpoint was 0.62&times; of Go, for two reasons, both fixed: re-validating the program&rsquo;s own output, and the copy above.</li>
      <li>The first <code>dispatch</code> cost a read 6.5%, and the cost grew with the size of the API, not the operation: a declaration with 200 routes would have paid for all of them on every request. Measured twice, then fixed with an index.</li>
      <li>The cross-checks disagreed with the references too: on a repeated key the service keeps the first, Go and pydantic the last; on a lone surrogate Go stores U+FFFD. Shown, not counted.</li>
    </ul></div>
  </div>
</section>

<section id="limits">
  <h2>Not tested, not built</h2>
  <div class="cols">
    <div class="no"><h3>Not built</h3><ul>
      <li>Defaults declared once; <code>dispatch</code> in the PostgreSQL and threads examples.</li>
      <li>Middleware, authentication, dependency injection.</li>
      <li>TLS (cancho has a server, <code>examples/https_hello</code>, not independently reviewed; no service here has been put behind it), streaming a response, a store shared between threads (the two threads of <code>users_threads</code> share nothing).</li>
      <li><code>$ref</code>/<code>$defs</code> in the generated JSON Schema.</li>
    </ul></div>
    <div class="no"><h3>Not tested</h3><ul>
      <li>A service with a real workload behind it. <code>cancho-hooks</code> uses <code>web</code> for its router and document; its behaviour is its own repository&rsquo;s evidence.</li>
      <li>The Go and C servers leave out <code>/openapi.json</code>, and the C server chunked request bodies; none of it is on a benchmarked path.</li>
    </ul></div>
  </div>
</section>
''') + FOOT
(OUT/'evidence.html').write_text(evidence)
print('evidence', len(evidence))

(OUT/'robots.txt').write_text("User-agent: *\nAllow: /\n\nSitemap: " + SITE + "sitemap.xml\n")
import datetime
_today = datetime.date.today().isoformat()
(OUT/'sitemap.xml').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + ''.join(
    '  <url><loc>%s%s</loc><lastmod>%s</lastmod></url>\n' % (SITE, pg, _today) for pg in ('', 'examples.html', 'evidence.html')) + '</urlset>\n')
