// The floor: the users API of examples/users as one hand-written epoll server in C.
//
//   cc -O2 -o floor floor.c && ./floor 8000
//
// Not a framework and not meant to be one. It is what the same API costs when
// nothing is general: one thread, one epoll loop, a request parser that knows
// four routes, and a JSON reader that validates *and* writes the stored answer in
// one pass because it knows this schema and no other. It exists to answer a
// question the other comparisons cannot: how much of a framework's per-request
// cost is the framework, and is the load generator the limit?
//
// Same work as examples/users/users.cho where the benchmark can tell: name 1..64
// code points, email 3..120, age 0..150, role in admin/user/guest, up to 8 tags of
// 1..16, no unknown fields, limit 1..100, the stored answer is the canonical
// compact JSON with `id` first. Left out: /openapi.json, chunked request bodies,
// anything under TLS. Known edges where it differs from the cancho service (none is
// in benches/equivalent.py's cases): `150.0` is not an integer here, a `null` field
// is a 422, invalid UTF-8 is not checked, and of two equal keys the last wins (the
// cancho service keeps the first).
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAXUSERS 100000
#define RBUF (1 << 16)
#define STR 2048 /* decoded bytes kept of one string; beyond it the value is invalid anyway */

// ---- the store ------------------------------------------------------------
static char *rows[MAXUSERS];
static int rowlen[MAXUSERS];
static int count, live;

// ---- one connection ----------------------------------------------------------
typedef struct {
  int fd;
  char in[RBUF];
  int inlen;
  char *out;
  size_t outlen, outpos, outcap;
  int close_after;
  int armed_out; // EPOLLOUT is on: only changed when it must be, not once per request
} Conn;

static void out_put(Conn *c, const char *p, size_t n) {
  if (c->outlen + n > c->outcap) {
    c->outcap = (c->outlen + n) * 2 + 1024;
    c->out = realloc(c->out, c->outcap);
  }
  memcpy(c->out + c->outlen, p, n);
  c->outlen += n;
}

static void respond(Conn *c, int status, const char *reason, const char *ctype, const char *extra, const char *body, size_t n, int keep) {
  char head[512];
  int h;
  if (status == 204)
    h = snprintf(head, sizeof head, "HTTP/1.1 204 %s\r\n%s%s\r\n", reason, extra, keep ? "" : "Connection: close\r\n");
  else
    h = snprintf(head, sizeof head, "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n%s%s\r\n", status, reason, ctype, n, extra, keep ? "" : "Connection: close\r\n");
  out_put(c, head, h);
  if (status != 204) out_put(c, body, n);
  if (!keep) c->close_after = 1;
}

static void problem(Conn *c, int status, const char *reason, const char *detail, int keep) {
  char b[256];
  int n = snprintf(b, sizeof b, "{\"title\":\"%s\",\"status\":%d,\"detail\":\"%s\"}", reason, status, detail);
  respond(c, status, reason, "application/problem+json", "", b, n, keep);
}

// ---- JSON: validate against the schema while writing the stored answer --------
typedef struct {
  const char *p, *end;
  int syntax; // set on malformed JSON: a 400
  int bad;    // set on a schema violation: a 422 (only if the JSON itself was fine)
} J;

static void ws(J *j) {
  while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++;
}

static int hex4(J *j) {
  if (j->end - j->p < 4) return -1;
  int v = 0;
  for (int i = 0; i < 4; i++) {
    char c = j->p[i];
    v <<= 4;
    if (c >= '0' && c <= '9') v |= c - '0';
    else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
    else return -1;
  }
  j->p += 4;
  return v;
}

static int utf8_put(char *d, int cap, int at, unsigned cp) {
  char t[4];
  int n = cp < 0x80 ? (t[0] = cp, 1)
        : cp < 0x800 ? (t[0] = 0xC0 | cp >> 6, t[1] = 0x80 | (cp & 63), 2)
        : cp < 0x10000 ? (t[0] = 0xE0 | cp >> 12, t[1] = 0x80 | (cp >> 6 & 63), t[2] = 0x80 | (cp & 63), 3)
        : (t[0] = 0xF0 | cp >> 18, t[1] = 0x80 | (cp >> 12 & 63), t[2] = 0x80 | (cp >> 6 & 63), t[3] = 0x80 | (cp & 63), 4);
  if (at + n <= cap) memcpy(d + at, t, n);
  return at + n;
}

// A string at j->p (which is on the opening quote): decoded into d, its length in
// *len (may exceed cap, then d is incomplete) and its length in code points in *cps.
static int string(J *j, char *d, int cap, int *len, int *cps) {
  if (j->p >= j->end || *j->p != '"') { j->syntax = 1; return 0; }
  j->p++;
  int at = 0, n = 0;
  for (;;) {
    if (j->p >= j->end) { j->syntax = 1; return 0; }
    unsigned char c = *j->p++;
    if (c == '"') break;
    if (c < 0x20) { j->syntax = 1; return 0; }
    if (c == '\\') {
      if (j->p >= j->end) { j->syntax = 1; return 0; }
      char e = *j->p++;
      unsigned cp;
      switch (e) {
        case '"': cp = '"'; break; case '\\': cp = '\\'; break; case '/': cp = '/'; break;
        case 'b': cp = 8; break; case 'f': cp = 12; break; case 'n': cp = 10; break;
        case 'r': cp = 13; break; case 't': cp = 9; break;
        case 'u': {
          int u = hex4(j);
          if (u < 0) { j->syntax = 1; return 0; }
          cp = u;
          if (u >= 0xD800 && u < 0xDC00) { // a high surrogate must be followed by a low one
            int lo = -1;
            if (j->end - j->p >= 6 && j->p[0] == '\\' && j->p[1] == 'u') { j->p += 2; lo = hex4(j); }
            if (lo < 0xDC00 || lo >= 0xE000) { j->syntax = 1; return 0; }
            cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
          } else if (u >= 0xDC00 && u < 0xE000) { j->syntax = 1; return 0; }
          break;
        }
        default: j->syntax = 1; return 0;
      }
      at = utf8_put(d, cap, at, cp);
      n++;
    } else {
      // a literal byte: copy it, and count a code point at each non-continuation byte
      if (at < cap) d[at] = c;
      at++;
      if ((c & 0xC0) != 0x80) n++;
    }
  }
  *len = at;
  *cps = n;
  return 1;
}

// A JSON number at j->p, per the grammar: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
// Leaves *integer set if it has no fraction or exponent, and *v its value (if it fits).
static int number(J *j, int *integer, long *v) {
  const char *q = j->p, *e = j->end;
  int neg = 0, nd = 0;
  long x = 0;
  *integer = 1;
  if (q < e && *q == '-') { neg = 1; q++; }
  if (q >= e || *q < '0' || *q > '9') { j->syntax = 1; return 0; }
  if (*q == '0') { q++; nd = 1; }
  else while (q < e && *q >= '0' && *q <= '9') { if (nd < 18) x = x * 10 + (*q - '0'); nd++; q++; }
  if (nd > 18) *integer = 0; // too large for a long: not a valid age either
  if (q < e && *q == '.') {
    *integer = 0;
    q++;
    if (q >= e || *q < '0' || *q > '9') { j->syntax = 1; return 0; }
    while (q < e && *q >= '0' && *q <= '9') q++;
  }
  if (q < e && (*q == 'e' || *q == 'E')) {
    *integer = 0;
    q++;
    if (q < e && (*q == '+' || *q == '-')) q++;
    if (q >= e || *q < '0' || *q > '9') { j->syntax = 1; return 0; }
    while (q < e && *q >= '0' && *q <= '9') q++;
  }
  j->p = q;
  *v = neg ? -x : x;
  return 1;
}

static int skip_value(J *j, int depth);

static int skip_string(J *j) {
  char d[1];
  int l, n;
  return string(j, d, 0, &l, &n);
}

static int skip_value(J *j, int depth) {
  ws(j);
  if (j->p >= j->end || depth > 64) { j->syntax = 1; return 0; }
  char c = *j->p;
  if (c == '"') return skip_string(j);
  if (c == '{' || c == '[') {
    char close = c == '{' ? '}' : ']';
    j->p++;
    ws(j);
    if (j->p < j->end && *j->p == close) { j->p++; return 1; }
    for (;;) {
      ws(j);
      if (c == '{') {
        if (!skip_string(j)) return 0;
        ws(j);
        if (j->p >= j->end || *j->p++ != ':') { j->syntax = 1; return 0; }
      }
      if (!skip_value(j, depth + 1)) return 0;
      ws(j);
      if (j->p >= j->end) { j->syntax = 1; return 0; }
      if (*j->p == ',') { j->p++; continue; }
      if (*j->p == close) { j->p++; return 1; }
      j->syntax = 1;
      return 0;
    }
  }
  if (!strncmp(j->p, "true", 4) && j->end - j->p >= 4) { j->p += 4; return 1; }
  if (!strncmp(j->p, "false", 5) && j->end - j->p >= 5) { j->p += 5; return 1; }
  if (!strncmp(j->p, "null", 4) && j->end - j->p >= 4) { j->p += 4; return 1; }
  if (c == '-' || (c >= '0' && c <= '9')) {
    int integer;
    long v;
    return number(j, &integer, &v);
  }
  j->syntax = 1;
  return 0;
}

typedef struct {
  char name[STR], email[STR], role[STR], tag[8][STR];
  int name_len, email_len, role_len, tag_len[8];
  int has_name, has_email, has_age, has_role, has_tags, ntags;
  long age;
} Fields;

static int key_is(const char *k, int kl, const char *s) { return kl == (int)strlen(s) && !memcmp(k, s, kl); }

// A string field: parsed, its length in code points checked against lo..hi.
static void str_field(J *j, char *d, int *dl, int lo, int hi) {
  ws(j);
  int cps;
  if (j->p < j->end && *j->p != '"') { j->bad = 1; skip_value(j, 1); return; }
  if (!string(j, d, STR, dl, &cps)) return;
  if (cps < lo || cps > hi || *dl > STR) j->bad = 1;
}

// The document: an object with the five fields and nothing else.
static int parse_user(J *j, Fields *f) {
  f->has_name = f->has_email = f->has_age = f->has_role = f->has_tags = f->ntags = 0;
  ws(j);
  if (j->p >= j->end) { j->syntax = 1; return 0; }
  if (*j->p != '{') {
    if (!skip_value(j, 0)) return 0;
    j->bad = 1;
    goto trailing;
  }
  j->p++;
  ws(j);
  if (j->p < j->end && *j->p == '}') { j->p++; goto trailing; }
  for (;;) {
    ws(j);
    char k[64];
    int kl, kc;
    if (!string(j, k, sizeof k, &kl, &kc)) return 0;
    ws(j);
    if (j->p >= j->end || *j->p++ != ':') { j->syntax = 1; return 0; }
    ws(j);
    if (key_is(k, kl, "name")) { str_field(j, f->name, &f->name_len, 1, 64); f->has_name = 1; }
    else if (key_is(k, kl, "email")) { str_field(j, f->email, &f->email_len, 3, 120); f->has_email = 1; }
    else if (key_is(k, kl, "role")) {
      str_field(j, f->role, &f->role_len, 1, 5);
      f->has_role = 1;
      if (!(key_is(f->role, f->role_len, "admin") || key_is(f->role, f->role_len, "user") || key_is(f->role, f->role_len, "guest"))) j->bad = 1;
    } else if (key_is(k, kl, "age")) {
      if (j->p < j->end && ((*j->p >= '0' && *j->p <= '9') || *j->p == '-')) {
        int integer;
        if (!number(j, &integer, &f->age)) return 0;
        if (!integer || f->age < 0 || f->age > 150) j->bad = 1;
        f->has_age = 1;
      } else { j->bad = 1; if (!skip_value(j, 1)) return 0; }
    } else if (key_is(k, kl, "tags")) {
      f->has_tags = 1;
      f->ntags = 0;
      if (j->p < j->end && *j->p == '[') {
        j->p++;
        ws(j);
        if (j->p < j->end && *j->p == ']') j->p++;
        else for (;;) {
          ws(j);
          if (f->ntags < 8) {
            str_field(j, f->tag[f->ntags], &f->tag_len[f->ntags], 1, 16);
            f->ntags++;
          } else { j->bad = 1; if (!skip_value(j, 1)) return 0; }
          if (j->syntax) return 0;
          ws(j);
          if (j->p >= j->end) { j->syntax = 1; return 0; }
          if (*j->p == ',') { j->p++; continue; }
          if (*j->p == ']') { j->p++; break; }
          j->syntax = 1;
          return 0;
        }
      } else { j->bad = 1; if (!skip_value(j, 1)) return 0; }
    } else { j->bad = 1; if (!skip_value(j, 1)) return 0; }
    if (j->syntax) return 0;
    ws(j);
    if (j->p >= j->end) { j->syntax = 1; return 0; }
    if (*j->p == ',') { j->p++; continue; }
    if (*j->p == '}') { j->p++; break; }
    j->syntax = 1;
    return 0;
  }
trailing:
  ws(j);
  if (j->p != j->end) { j->syntax = 1; return 0; }
  if (!f->has_name) j->bad = 1;
  return 1;
}

static char *put_str(char *o, const char *s, int n) {
  *o++ = '"';
  for (int i = 0; i < n; i++) {
    unsigned char c = s[i];
    if (c == '"' || c == '\\') { *o++ = '\\'; *o++ = c; }
    else if (c < 0x20) o += sprintf(o, "\\u%04x", c);
    else *o++ = c;
  }
  *o++ = '"';
  return o;
}

// ---- the routes ----------------------------------------------------------------------------
static long digits(const char *s, int n) {
  if (n <= 0 || n > 17) return -1;
  long v = 0;
  for (int i = 0; i < n; i++) {
    if (s[i] < '0' || s[i] > '9') return -1;
    v = v * 10 + (s[i] - '0');
  }
  return v;
}

static void do_create(Conn *c, const char *ctype, const char *body, int n, int keep) {
  if (strncasecmp(ctype, "application/json", 16)) { problem(c, 415, "Unsupported Media Type", "send Content-Type: application/json", keep); return; }
  J j = {body, body + n, 0, 0};
  static Fields f;
  parse_user(&j, &f);
  if (j.syntax) { problem(c, 400, "Bad Request", "malformed JSON", keep); return; }
  if (j.bad) { problem(c, 422, "Unprocessable Content", "the body does not satisfy the schema", keep); return; }
  if (count >= MAXUSERS) { problem(c, 503, "Service Unavailable", "the store is full", keep); return; }
  int room = 128 + 6 * (f.name_len + f.email_len + f.role_len);
  for (int i = 0; i < f.ntags; i++) room += 8 + 6 * f.tag_len[i];
  char *o = malloc(room), *s = o;
  s += sprintf(s, "{\"id\":%d,\"name\":", count + 1);
  s = put_str(s, f.name, f.name_len);
  if (f.has_email) { s += sprintf(s, ",\"email\":"); s = put_str(s, f.email, f.email_len); }
  if (f.has_age) s += sprintf(s, ",\"age\":%ld", f.age);
  if (f.has_role) { s += sprintf(s, ",\"role\":"); s = put_str(s, f.role, f.role_len); }
  if (f.has_tags) {
    s += sprintf(s, ",\"tags\":[");
    for (int i = 0; i < f.ntags; i++) { if (i) *s++ = ','; s = put_str(s, f.tag[i], f.tag_len[i]); }
    *s++ = ']';
  }
  *s++ = '}';
  rows[count] = o;
  rowlen[count] = s - o;
  count++;
  live++;
  char loc[64];
  snprintf(loc, sizeof loc, "Location: /users/%d\r\n", count);
  respond(c, 201, "Created", "application/json", loc, o, s - o, keep);
}

static void do_list(Conn *c, const char *q, int ql, int keep) {
  long limit = 20, offset = 0;
  int at = 0;
  while (at < ql) {
    int end = at;
    while (end < ql && q[end] != '&') end++;
    int eq = at;
    while (eq < end && q[eq] != '=') eq++;
    int kl = eq - at, vl = end > eq ? end - eq - 1 : 0;
    if (kl == 5 && !memcmp(q + at, "limit", 5)) limit = digits(q + eq + 1, vl);
    else if (kl == 6 && !memcmp(q + at, "offset", 6)) offset = digits(q + eq + 1, vl);
    else { problem(c, 422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken", keep); return; }
    at = end + 1;
  }
  if (limit < 1 || limit > 100) { problem(c, 422, "Unprocessable Content", "limit must be an integer from 1 to 100", keep); return; }
  if (offset < 0) { problem(c, 422, "Unprocessable Content", "offset must be a non-negative integer", keep); return; }
  static char page[1 << 20]; // 100 users of at most ~2.5 KB each
  char *o = page;
  o += sprintf(o, "{\"total\":%d,\"items\":[", live);
  long taken = 0, skipped = 0;
  for (int i = 0; i < count && taken < limit; i++) {
    if (!rows[i]) continue;
    if (skipped < offset) { skipped++; continue; }
    if (taken) *o++ = ',';
    memcpy(o, rows[i], rowlen[i]);
    o += rowlen[i];
    taken++;
  }
  *o++ = ']';
  *o++ = '}';
  respond(c, 200, "OK", "application/json", "", page, o - page, keep);
}

static void do_one(Conn *c, const char *p, int n, int remove, int keep) {
  long id = digits(p, n);
  if (id < 1) { problem(c, 422, "Unprocessable Content", "id must be a positive integer", keep); return; }
  if (id > count || !rows[id - 1]) { problem(c, 404, "Not Found", "no such user", keep); return; }
  if (remove) {
    free(rows[id - 1]);
    rows[id - 1] = NULL;
    live--;
    respond(c, 204, "No Content", "", "", "", 0, keep);
    return;
  }
  respond(c, 200, "OK", "application/json", "", rows[id - 1], rowlen[id - 1], keep);
}

// One request at c->in[0..head+body]; the head ends at `head`.
static void route(Conn *c, char *m, int ml, char *t, int tl, const char *ctype, const char *body, int bl, int keep) {
  int ql = 0;
  char *qm = memchr(t, '?', tl);
  const char *q = "";
  if (qm) { q = qm + 1; ql = t + tl - q; tl = qm - t; }
  int get = ml == 3 && !memcmp(m, "GET", 3), post = ml == 4 && !memcmp(m, "POST", 4), del = ml == 6 && !memcmp(m, "DELETE", 6);
  if (tl == 7 && !memcmp(t, "/health", 7) && get) { respond(c, 200, "OK", "application/json", "", "{\"ok\":true}", 11, keep); return; }
  if (tl == 6 && !memcmp(t, "/users", 6)) {
    if (get) do_list(c, q, ql, keep);
    else if (post) do_create(c, ctype, body, bl, keep);
    else respond(c, 405, "Method Not Allowed", "application/json", "Allow: GET, POST\r\n", "{}", 2, keep);
    return;
  }
  if (tl > 7 && !memcmp(t, "/users/", 7)) {
    if (get || del) do_one(c, t + 7, tl - 7, del, keep);
    else respond(c, 405, "Method Not Allowed", "application/json", "Allow: GET, DELETE\r\n", "{}", 2, keep);
    return;
  }
  problem(c, 404, "Not Found", "no such route", keep);
}

// Handle every complete request in c->in; returns 0 to close the connection.
static int serve(Conn *c) {
  int used = 0;
  while (!c->close_after) {
    char *s = c->in + used;
    int avail = c->inlen - used;
    char *e = memmem(s, avail, "\r\n\r\n", 4);
    if (!e) break;
    int head = e - s + 4;
    char *m = s, *sp = memchr(s, ' ', head);
    if (!sp) return 0;
    char *t = sp + 1, *sp2 = memchr(t, ' ', head - (t - s));
    if (!sp2) return 0;
    int ml = sp - m, tl = sp2 - t, keep = 1, clen = 0;
    const char *ctype = "";
    char *h = memchr(sp2, '\n', head) + 1; // the first header line; `e` is the last line's end
    while (h <= e) {
      char *eol = memchr(h, '\r', e + 1 - h);
      if (!strncasecmp(h, "content-length:", 15)) clen = atoi(h + 15);
      else if (!strncasecmp(h, "content-type:", 13)) { ctype = h + 13; while (*ctype == ' ') ctype++; }
      else if (!strncasecmp(h, "connection:", 11)) { for (char *q = h + 11; q + 5 <= eol; q++) if (!strncasecmp(q, "close", 5)) keep = 0; }
      else if (!strncasecmp(h, "transfer-encoding:", 18)) { respond(c, 501, "Not Implemented", "application/json", "", "{}", 2, 0); return 1; }
      h = eol + 2;
    }
    if (clen > RBUF - 8192) { respond(c, 413, "Content Too Large", "application/json", "", "{}", 2, 0); return 1; }
    if (avail < head + clen) break;
    // ctype points into the head, which is not NUL-terminated: copy the value
    char ct[64];
    int cl = 0;
    while (ctype[cl] && ctype[cl] != '\r' && cl < 63) { ct[cl] = ctype[cl]; cl++; }
    ct[cl] = 0;
    route(c, m, ml, t, tl, ct, s + head, clen, keep);
    used += head + clen;
  }
  memmove(c->in, c->in + used, c->inlen - used);
  c->inlen -= used;
  return 1;
}

static int flush(Conn *c) { // 1 = all sent, 0 = would block, -1 = error
  while (c->outpos < c->outlen) {
    ssize_t n = send(c->fd, c->out + c->outpos, c->outlen - c->outpos, MSG_NOSIGNAL);
    if (n < 0) return errno == EAGAIN ? 0 : -1;
    c->outpos += n;
  }
  c->outpos = c->outlen = 0;
  return 1;
}

int main(int argc, char **argv) {
  int port = argc > 1 ? atoi(argv[1]) : 8000;
  int ls = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0), one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in sa = {0};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
  if (bind(ls, (struct sockaddr *)&sa, sizeof sa) || listen(ls, 1024)) { perror("listen"); return 1; }
  int ep = epoll_create1(0);
  struct epoll_event ev = {.events = EPOLLIN, .data.ptr = NULL};
  epoll_ctl(ep, EPOLL_CTL_ADD, ls, &ev);
  printf("listening on %d\n", port);
  fflush(stdout);
  struct epoll_event evs[256];
  for (;;) {
    int n = epoll_wait(ep, evs, 256, -1);
    for (int i = 0; i < n; i++) {
      Conn *c = evs[i].data.ptr;
      if (!c) {
        for (;;) {
          int fd = accept4(ls, NULL, NULL, SOCK_NONBLOCK);
          if (fd < 0) break;
          setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
          c = calloc(1, sizeof *c);
          c->fd = fd;
          struct epoll_event ce = {.events = EPOLLIN | EPOLLRDHUP, .data.ptr = c};
          epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ce);
        }
        continue;
      }
      int alive = !(evs[i].events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP));
      if (alive && (evs[i].events & EPOLLIN)) {
        for (;;) {
          int room = RBUF - c->inlen;
          ssize_t r = room > 0 ? read(c->fd, c->in + c->inlen, room) : 0;
          if (r > 0) {
            c->inlen += r;
            if (!serve(c)) { alive = 0; break; }
            if (r < room) break;
          } else {
            if (r == 0 || errno != EAGAIN) alive = 0;
            break;
          }
        }
      }
      if (alive) {
        int f = flush(c);
        if (f < 0) alive = 0;
        else if (f == 1 && c->close_after) alive = 0;
        else if ((f == 0) != c->armed_out) {
          c->armed_out = f == 0;
          struct epoll_event ce = {.events = EPOLLIN | EPOLLRDHUP | (f == 0 ? EPOLLOUT : 0), .data.ptr = c};
          epoll_ctl(ep, EPOLL_CTL_MOD, c->fd, &ce);
        }
      }
      if (!alive) {
        epoll_ctl(ep, EPOLL_CTL_DEL, c->fd, NULL);
        close(c->fd);
        free(c->out);
        free(c);
      }
    }
  }
}
