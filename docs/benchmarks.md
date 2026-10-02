# The users API against FastAPI

> **Status: measured, once, on one machine** (the numbers below are from a 4-vCPU
> Firecracker VM, Intel Xeon 2.1 GHz, Linux 6.18, Python 3.11, FastAPI 0.142,
> uvicorn 0.54). Treat the *ratios* as the finding and the absolute figures as this
> VM's. `benches/run.sh` reproduces them.

## What is compared

`examples/users` (this repository, over `http.server` and `lexsys-schema`) and the
same API written the ordinary way in FastAPI + pydantic (`benches/fastapi_users/app.py`):
the same routes, the same limits, the same validation rules. They are held to *do the
same work* before either is timed: `benches/equivalent.py` sends both the same sixteen
requests -- valid and invalid, reads, pages, a 404, a limit past its range -- and the
run refuses to start unless every status agrees and every successful body is equal.
(Error *documents* differ by design: FastAPI has its own 422 shape, this service answers
RFC 9457; only their status is compared.)

FastAPI is measured three ways, because "FastAPI" is not one number:

| | |
|---|---|
| **uvicorn (asyncio)** | `uvicorn app:app` -- what the tutorial runs |
| **uvloop + httptools** | `--loop uvloop --http httptools` -- the faster setup the documentation recommends |
| **lean** | the same, and handlers return the stored bytes instead of going through a `response_model`: the least work an honest FastAPI handler can do |

Each server runs **alone on core 0**; the load generator (`benches/kload.c`, two threads
of 16 keep-alive connections, closed loop, one request outstanding per connection) runs
on cores 2 and 3. A request is 5 seconds of load, three times, median; "create" is a fixed
30,000 requests from a fresh process (it adds state, so "as many as fit in 5 s" would fill
the store).

## Results

Requests a second, median of 3:

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **lex-sys users** | **120,342** | **39,350** | **93,414** | **73,976** |
| FastAPI, uvicorn (asyncio) | 4,921 | 4,300 | 3,481 | 4,182 |
| FastAPI, uvloop + httptools | 4,675 | 4,144 | 3,532 | 4,100 |
| FastAPI lean, uvloop + httptools | 5,232 | 4,556 | 3,401 | 4,495 |

About **23x** on a read, **9x** on a page, **26x** on a rejected body and **16x** on a
create, against the best FastAPI figure in each column.

Latency of `GET one user` under that load (32 requests in flight, so each figure is a
service time *plus the queue of the others*):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| lex-sys users | 159 µs | 211 µs | 362 µs | 944 µs | 17.1 ms |
| FastAPI, uvicorn | 5.0 ms | 8.6 ms | 14.0 ms | 24.3 ms | 42.9 ms |

## How to read it

* **It is one core against one core.** Neither server uses a second; FastAPI is normally
  run with several worker processes, and lex-sys with `reuseport` copies. Per-core is the
  fair comparison and not what a deployment does.
* **FastAPI is CPU-bound in Python, not in its server.** uvloop and httptools, which speed
  up the network layer, change almost nothing (they are within noise of plain asyncio, and
  slightly lower on two columns), and the lean variant -- no response validation -- gains
  about 10%. What is left is routing, dependency resolution and pydantic.
* **The page is the narrowest gap (9x), and the reason is in the service.** Listing 20
  users splices 20 stored JSON values through `json.put_fragment`, each checked by the
  strict parser. That check costs, and it is the price of a writer that cannot produce an
  invalid document. Rendering from structured data instead of re-validating stored text
  would be faster and is not done here.
* **Nothing here measures TLS, a database, or a real handler's work.** A service that
  spends 5 ms in a query is 5 ms slower in both. The comparison is of the *framework's
  own* cost per request, which is what a framework chooses.
* **A load generator is code too.** `kload` found a bug in itself on the first FastAPI
  run: it matched `Content-Length:` case-sensitively, and uvicorn sends it lowercase, so
  the body of every answer was left unread and counted as the next response. The
  figures looked plausible (about 5,000 a second) and were wrong in a way that happened
  to land near the right answer. It was caught only because the generator now checks every
  status against the one expected (`KLOAD_EXPECT`) and fails the run, and it now matches
  headers case-insensitively. A benchmark that cannot fail is not a measurement.

## Reproducing

```
pip install fastapi uvicorn uvloop httptools
LEX_SYS=/path/to/lex-sys benches/run.sh 3        # needs >= 4 cores for the pinning
```
