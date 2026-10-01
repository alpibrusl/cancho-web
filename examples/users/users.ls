edition 5;

// `users` -- a JSON API over `http.server` and `schema`: the example that makes
// the two packages carry a real service.
//
//     users <port>
//
//     GET    /health
//     GET    /users?limit=&offset=      a page of users          (limit 1..100, default 20)
//     POST   /users                     create one               201 + Location
//     GET    /users/:id
//     DELETE /users/:id                 the deleted user
//     GET    /openapi.json              the contract, generated from the same schemas
//
// What is real about it: the request body is checked by `schema.validate`
// against a `Schema` built once at start-up; a body that fails is answered with
// `schema.problem` (RFC 9457, every error, JSON pointers); and the OpenAPI
// document at `/openapi.json` embeds `schema.json_schema` of the *same* nodes the
// validator runs, so what the API accepts and what it documents are one object.
// `tests/e2e.py` holds the service to that document: every response must conform
// to it, and Schemathesis generates requests from it.
//
// Storage is in memory and bounded: 10,000 users in a 4 MiB arena, a full store
// is a 503 rather than growth. A delete leaves a hole (ids are not reused).
//
// Authority (`lex-sys authority`): `net_in`, `conn_*`, `poll`, `clock`, `heap`,
// `args`, the console -- and no `ffi`.

import std.buffer;
import std.bytes;
import std.http;
import std.io;
import std.json;
import std.route;
import http.server;
import schema;

fn max_users() -> [] int {
    return 10000;
}

fn arena_bytes() -> [] int {
    return 4194304;
}

fn default_limit() -> [] int {
    return 20;
}

fn max_limit() -> [] int {
    return 100;
}

// A decimal number, or -1 for empty text, a non-digit, or more than 17 digits.
fn number_of[&t](text: &t [byte]) -> [] int {
    if len(text) == 0 || len(text) > 17 {
        return 0 - 1;
    }
    var n = 0;
    var i = 0;
    while i < len(text) {
        let c = int_of(text[i]);
        if c < 48 || c > 57 {
            return 0 - 1;
        }
        n = n * 10 + (c - 48);
        i = i + 1;
    }
    return n;
}

// ---------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------

// Each user is kept as the JSON it is answered with, in one arena; `index[2k]`
// and `index[2k+1]` are where user `k + 1` starts and how long it is (-1: deleted).
res struct Store {
    rows: Box[[byte]],
    index: Box[[int]],
    used: int,
    count: int,
    live: int,
}

fn store_new[&h](heap: &!h Heap) -> [heap] Store {
    return Store { rows: box_slice(heap, arena_bytes(), byte_of(0)), index: box_slice(heap, 2 * max_users(), 0), used: 0, count: 0, live: 0 };
}

fn store_drop[&h](heap: &!h Heap, s: Store) -> [heap] int {
    let Store { rows, index, used, count, live } = s;
    unbox_slice(heap, rows);
    unbox_slice(heap, index);
    return live;
}

// Add `json`, answering the new id, or -1 if the store is full.
fn store_add[&s, &b](st: &!s Store, json: &b [byte]) -> [] int {
    if st.count >= max_users() || st.used + len(json) > arena_bytes() {
        return 0 - 1;
    }
    let rows = contents(st.rows);
    let index = contents(st.index);
    var i = 0;
    while i < len(json) {
        rows[st.used + i] = json[i];
        i = i + 1;
    }
    index[2 * st.count] = st.used;
    index[2 * st.count + 1] = len(json);
    st.used = st.used + len(json);
    st.count = st.count + 1;
    st.live = st.live + 1;
    return st.count;
}

fn store_has[&s](st: &s Store, id: int) -> [] bool {
    if id < 1 || id > st.count {
        return false;
    }
    return contents(st.index)[2 * (id - 1) + 1] >= 0;
}

// The JSON of user `id`; empty if there is none.
fn store_get[&s](st: &s Store, id: int) -> [] &s [byte] {
    let rows = contents(st.rows);
    if !store_has(st, id) {
        return rows[0..0];
    }
    let at = contents(st.index)[2 * (id - 1)];
    return rows[at..at + contents(st.index)[2 * (id - 1) + 1]];
}

fn store_delete[&s](st: &!s Store, id: int) -> [] bool {
    if !store_has(st, id) {
        return false;
    }
    contents(st.index)[2 * (id - 1) + 1] = 0 - 1;
    st.live = st.live - 1;
    return true;
}

// ---------------------------------------------------------------------
// The schemas, built once
// ---------------------------------------------------------------------

// `NewUser`'s fields, in the order `setup` adds them: `schema.validate` fills one
// slot per field in that order.
fn slot_name() -> [] int {
    return 0;
}

fn slot_email() -> [] int {
    return 1;
}

fn slot_age() -> [] int {
    return 2;
}

fn slot_role() -> [] int {
    return 3;
}

fn slot_tags() -> [] int {
    return 4;
}

// Add the five user fields to `obj`; `id` too if it is not -1.
fn user_fields[&h](heap: &!h Heap, s: schema.Schema, obj: int, id: int, name: int, email: int, age: int, role: int, tags: int) -> [heap] schema.Schema {
    var t = s;
    if id >= 0 {
        t = schema.add_field(heap, t, obj, "id", id, true);
    }
    t = schema.add_field(heap, t, obj, "name", name, true);
    t = schema.add_field(heap, t, obj, "email", email, false);
    t = schema.add_field(heap, t, obj, "age", age, false);
    t = schema.add_field(heap, t, obj, "role", role, false);
    t = schema.add_field(heap, t, obj, "tags", tags, false);
    return t;
}

// The OpenAPI document: the paths written out, the schemas generated.
fn openapi[&h, &s](heap: &!h Heap, sc: &s schema.Schema, new_user: int, user: int, page: int, problem: int) -> [heap] buffer.Buffer {
    var d = buffer.empty(heap, 8192);
    d = buffer.append(heap, d, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"Users API\",\"version\":\"1.0.0\"},\"paths\":{");
    d = buffer.append(heap, d, "\"/health\":{\"get\":{\"operationId\":\"health\",\"responses\":{\"200\":{\"description\":\"alive\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"],\"additionalProperties\":false}}}}}}},");
    d = buffer.append(heap, d, "\"/users\":{\"get\":{\"operationId\":\"listUsers\",\"parameters\":[{\"name\":\"limit\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100}},{\"name\":\"offset\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":99999999999999999}}],\"responses\":{\"200\":{\"description\":\"a page\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Page\"}}}},\"422\":{\"$ref\":\"#/components/responses/Problem\"}}},");
    d = buffer.append(heap, d, "\"post\":{\"operationId\":\"createUser\",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/NewUser\"}}}},\"responses\":{\"201\":{\"description\":\"created\",\"headers\":{\"Location\":{\"schema\":{\"type\":\"string\"}}},\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/User\"}}}},\"400\":{\"$ref\":\"#/components/responses/Problem\"},\"415\":{\"$ref\":\"#/components/responses/Problem\"},\"422\":{\"$ref\":\"#/components/responses/Problem\"},\"503\":{\"$ref\":\"#/components/responses/Problem\"}}}},");
    d = buffer.append(heap, d, "\"/users/{id}\":{\"parameters\":[{\"name\":\"id\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":99999999999999999}}],\"get\":{\"operationId\":\"getUser\",\"responses\":{\"200\":{\"description\":\"the user\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/User\"}}}},\"404\":{\"$ref\":\"#/components/responses/Problem\"},\"422\":{\"$ref\":\"#/components/responses/Problem\"}}},");
    d = buffer.append(heap, d, "\"delete\":{\"operationId\":\"deleteUser\",\"responses\":{\"200\":{\"description\":\"the deleted user\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/User\"}}}},\"404\":{\"$ref\":\"#/components/responses/Problem\"},\"422\":{\"$ref\":\"#/components/responses/Problem\"}}}}},");
    d = buffer.append(heap, d, "\"components\":{\"responses\":{\"Problem\":{\"description\":\"a problem\",\"content\":{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/Problem\"}}}}},\"schemas\":{");
    let a = schema.json_schema(heap, sc, new_user);
    borrow a as &ab in {
        d = buffer.append(heap, d, "\"NewUser\":");
        d = buffer.append(heap, d, buffer.bytes(ab));
    }
    buffer.drop(heap, a);
    let b = schema.json_schema(heap, sc, user);
    borrow b as &bb in {
        d = buffer.append(heap, d, ",\"User\":");
        d = buffer.append(heap, d, buffer.bytes(bb));
    }
    buffer.drop(heap, b);
    let c = schema.json_schema(heap, sc, page);
    borrow c as &cb in {
        d = buffer.append(heap, d, ",\"Page\":");
        d = buffer.append(heap, d, buffer.bytes(cb));
    }
    buffer.drop(heap, c);
    let e = schema.json_schema(heap, sc, problem);
    borrow e as &eb in {
        d = buffer.append(heap, d, ",\"Problem\":");
        d = buffer.append(heap, d, buffer.bytes(eb));
    }
    buffer.drop(heap, e);
    return buffer.append(heap, d, "}}}");
}

// Build every schema, answering the `Schema`, the node a POST body is checked
// against, and the OpenAPI document.
fn setup[&h](heap: &!h Heap) -> [heap] (schema.Schema, int, buffer.Buffer) {
    var s = schema.empty(heap);
    let (s1, name) = schema.new_string(heap, s, 1, 64);
    let (s2, email) = schema.new_string(heap, s1, 3, 120);
    let (s3, age) = schema.new_int(heap, s2, 0, 150);
    let (s4, role) = schema.new_string(heap, s3, 0, schema.int_max());
    s = schema.add_choice(heap, s4, role, "admin");
    s = schema.add_choice(heap, s, role, "user");
    s = schema.add_choice(heap, s, role, "guest");
    let (s5, tag) = schema.new_string(heap, s, 1, 16);
    let (s6, tags) = schema.new_array(heap, s5, tag, 0, 8);
    let (s7, new_user) = schema.new_object(heap, s6, true);
    s = user_fields(heap, s7, new_user, 0 - 1, name, email, age, role, tags);

    let (s8, id) = schema.new_int(heap, s, 1, schema.int_max());
    let (s9, user) = schema.new_object(heap, s8, true);
    s = user_fields(heap, s9, user, id, name, email, age, role, tags);

    let (s10, total) = schema.new_int(heap, s, 0, schema.int_max());
    let (s11, items) = schema.new_array(heap, s10, user, 0, schema.int_max());
    let (s12, page) = schema.new_object(heap, s11, true);
    s = schema.add_field(heap, s12, page, "total", total, true);
    s = schema.add_field(heap, s, page, "items", items, true);

    let (s13, text) = schema.new_string(heap, s, 0, schema.int_max());
    let (s14, status) = schema.new_int(heap, s13, 100, 599);
    let (s15, count) = schema.new_int(heap, s14, 0, schema.int_max());
    let (s16, one) = schema.new_object(heap, s15, true);
    s = schema.add_field(heap, s16, one, "pointer", text, true);
    s = schema.add_field(heap, s, one, "code", text, true);
    s = schema.add_field(heap, s, one, "detail", text, true);
    let (s17, errors) = schema.new_array(heap, s, one, 0, schema.int_max());
    let (s18, problem) = schema.new_object(heap, s17, true);
    s = schema.add_field(heap, s18, problem, "type", text, true);
    s = schema.add_field(heap, s, problem, "title", text, true);
    s = schema.add_field(heap, s, problem, "status", status, true);
    s = schema.add_field(heap, s, problem, "detail", text, false);
    s = schema.add_field(heap, s, problem, "count", count, false);
    s = schema.add_field(heap, s, problem, "errors", errors, false);

    var doc = buffer.empty(heap, 16);
    borrow s as &sr in {
        buffer.drop(heap, doc);
        doc = openapi(heap, sr, new_user, user, page, problem);
    }
    return (s, new_user, doc);
}

// ---------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------

// A whole response of any content type.
fn reply_as[&h, &c, &b, &x](heap: &!h Heap, out: buffer.Buffer, status: int, content_type: &c [byte], body: &b [byte], keep: bool, extra: &x [byte]) -> [heap] buffer.Buffer {
    let head = http.respond_head_with(heap, out, status, content_type, len(body), keep, extra);
    return buffer.append(heap, head, body);
}

// `application/problem+json` (RFC 9457) with a `detail` and no error list.
fn problem[&h, &t, &d](heap: &!h Heap, out: buffer.Buffer, status: int, title: &t [byte], detail: &d [byte], keep: bool) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 128);
    w = json.begin_object(heap, w);
    w = json.put_key(heap, w, "type");
    w = json.put_string(heap, w, "about:blank");
    w = json.put_key(heap, w, "title");
    w = json.put_string(heap, w, title);
    w = json.put_key(heap, w, "status");
    w = json.put_int(heap, w, status);
    w = json.put_key(heap, w, "detail");
    w = json.put_string(heap, w, detail);
    w = json.end_object(heap, w);
    let body = json.finish(w);
    var answer = out;
    borrow body as &bb in {
        answer = reply_as(heap, answer, status, "application/problem+json", buffer.bytes(bb), keep, "");
    }
    buffer.drop(heap, body);
    return answer;
}

// A string value of the request, decoded, into the writer.
fn put_text[&h, &b, &t](heap: &!h Heap, w: json.Writer, body: &b [byte], tape: &t [int], node: int) -> [heap] json.Writer {
    let n = json.string_length(body, tape, node);
    if n <= 0 {
        return json.put_string(heap, w, "");
    }
    var o = w;
    let raw = box_slice(heap, n, byte_of(0));
    borrow mut raw as &!rw in {
        let d = contents(rw);
        json.string_into(body, tape, node, d);
        o = json.put_string(heap, o, d);
    }
    unbox_slice(heap, raw);
    return o;
}

// The user as it is stored and answered: `id` first, then whichever of the
// fields the (validated) request had, as the canonical compact JSON -- not the
// request's own text, so duplicate keys and odd spacing do not survive into
// what is stored.
fn render_user[&h, &b, &t, &u](heap: &!h Heap, id: int, body: &b [byte], tape: &t [int], slots: &u [int]) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 128);
    w = json.begin_object(heap, w);
    w = json.put_key(heap, w, "id");
    w = json.put_int(heap, w, id);
    w = json.put_key(heap, w, "name");
    w = put_text(heap, w, body, tape, slots[slot_name()]);
    if slots[slot_email()] >= 0 {
        w = json.put_key(heap, w, "email");
        w = put_text(heap, w, body, tape, slots[slot_email()]);
    }
    if slots[slot_age()] >= 0 {
        w = json.put_key(heap, w, "age");
        w = json.put_int(heap, w, schema.to_int(body, tape, slots[slot_age()]));
    }
    if slots[slot_role()] >= 0 {
        w = json.put_key(heap, w, "role");
        w = put_text(heap, w, body, tape, slots[slot_role()]);
    }
    if slots[slot_tags()] >= 0 {
        w = json.put_key(heap, w, "tags");
        w = json.begin_array(heap, w);
        var j = 0;
        while j < json.count(tape, slots[slot_tags()]) {
            w = put_text(heap, w, body, tape, json.at(tape, slots[slot_tags()], j));
            j = j + 1;
        }
        w = json.end_array(heap, w);
    }
    w = json.end_object(heap, w);
    return json.finish(w);
}

// `application/json` at the front of a `Content-Type`, parameters allowed.
fn is_json_type[&c](value: &c [byte]) -> [] bool {
    let want = "application/json";
    if len(value) < len(want) {
        return false;
    }
    var i = 0;
    while i < len(want) {
        var c = int_of(value[i]);
        if c >= 65 && c <= 90 {
            c = c + 32;
        }
        if c != int_of(want[i]) {
            return false;
        }
        i = i + 1;
    }
    return len(value) == len(want) || int_of(value[len(want)]) == 59 || int_of(value[len(want)]) == 32;
}

fn create[&h, &sc, &st, &q, &t, &b](heap: &!h Heap, sc: &sc schema.Schema, new_user: int, store: &!st Store, request: &q [byte], table: &t [int], body: &b [byte], out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    if !is_json_type(http.header(request, table, "content-type")) {
        return problem(heap, out, 415, "Unsupported Media Type", "send Content-Type: application/json", keep);
    }
    let tape = box_slice(heap, json.tape_len(body), 0);
    var answer = out;
    borrow mut tape as &!tw in {
        let tp = contents(tw);
        let nodes = json.parse(body, tp);
        if nodes < 0 {
            var detail = buffer.append(heap, buffer.empty(heap, 64), json.error_message(json.error_code(nodes)));
            detail = buffer.append(heap, detail, " at byte ");
            detail = buffer.push_nat(heap, detail, json.error_position(nodes));
            borrow detail as &db in {
                answer = problem(heap, answer, 400, "Bad Request", buffer.bytes(db), keep);
            }
            buffer.drop(heap, detail);
        } else {
            let slots = box_slice(heap, schema.slot_count(sc), 0);
            let errs = box_slice(heap, schema.errors_len(16), 0);
            borrow mut slots as &!sw in {
                borrow mut errs as &!ew in {
                    let sl = contents(sw);
                    let es = contents(ew);
                    if schema.validate(sc, new_user, body, tp, sl, es) > 0 {
                        let p = schema.problem(heap, sc, body, tp, es, 422, "Unprocessable Content");
                        borrow p as &pb in {
                            answer = reply_as(heap, answer, 422, "application/problem+json", buffer.bytes(pb), keep, "");
                        }
                        buffer.drop(heap, p);
                    } else {
                        let user = render_user(heap, store.count + 1, body, tp, sl);
                        borrow user as &ub in {
                            let id = store_add(store, buffer.bytes(ub));
                            if id < 0 {
                                answer = problem(heap, answer, 503, "Service Unavailable", "the store is full", keep);
                            } else {
                                var location = buffer.append(heap, buffer.empty(heap, 32), "Location: /users/");
                                location = buffer.push_nat(heap, location, id);
                                location = buffer.append(heap, location, "\r\n");
                                borrow location as &lb in {
                                    answer = reply_as(heap, answer, 201, "application/json", buffer.bytes(ub), keep, buffer.bytes(lb));
                                }
                                buffer.drop(heap, location);
                            }
                        }
                        buffer.drop(heap, user);
                    }
                }
            }
            unbox_slice(heap, errs);
            unbox_slice(heap, slots);
        }
    }
    unbox_slice(heap, tape);
    return answer;
}

// `?limit=&offset=`: the value of `key`, or `fallback` if absent, or -1 if it is
// not a number.
fn query_number[&q](query: &q [byte], key: &static [byte], fallback: int) -> [] int {
    let (from, to) = http.query_value(query, key);
    if from < 0 {
        return fallback;
    }
    return number_of(query[from..to]);
}

// Whether every key in the query string is one `GET /users` takes. A key it does
// not know is refused rather than ignored, for the reason an unknown field in a
// body is: a client that misspells `limit` should be told, not served the default.
fn query_keys_known[&q](query: &q [byte]) -> [] bool {
    var at = 0;
    while at < len(query) {
        var end = at;
        while end < len(query) && int_of(query[end]) != 38 {
            end = end + 1;
        }
        var eq = at;
        while eq < end && int_of(query[eq]) != 61 {
            eq = eq + 1;
        }
        if !bytes.equal(query[at..eq], "limit") && !bytes.equal(query[at..eq], "offset") {
            return false;
        }
        at = end + 1;
    }
    return true;
}

fn list[&h, &st, &q](heap: &!h Heap, store: &st Store, query: &q [byte], out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    if !query_keys_known(query) {
        return problem(heap, out, 422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken", keep);
    }
    let limit = query_number(query, "limit", default_limit());
    let offset = query_number(query, "offset", 0);
    if limit < 1 || limit > max_limit() {
        return problem(heap, out, 422, "Unprocessable Content", "limit must be an integer from 1 to 100", keep);
    }
    if offset < 0 {
        return problem(heap, out, 422, "Unprocessable Content", "offset must be a non-negative integer", keep);
    }
    var body = buffer.append(heap, buffer.empty(heap, 256), "{\"total\":");
    body = buffer.push_nat(heap, body, store.live);
    body = buffer.append(heap, body, ",\"items\":[");
    var skipped = 0;
    var taken = 0;
    var id = 1;
    while id <= store.count && taken < limit {
        if store_has(store, id) {
            if skipped < offset {
                skipped = skipped + 1;
            } else {
                if taken > 0 {
                    body = buffer.push(heap, body, byte_of(44));
                }
                body = buffer.append(heap, body, store_get(store, id));
                taken = taken + 1;
            }
        }
        id = id + 1;
    }
    body = buffer.append(heap, body, "]}");
    var answer = out;
    borrow body as &bb in {
        answer = server.reply(heap, answer, 200, buffer.bytes(bb), keep);
    }
    buffer.drop(heap, body);
    return answer;
}

fn one[&h, &st, &p, &s](heap: &!h Heap, store: &!st Store, path: &s [byte], params: &p [int], remove: bool, out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    let id = route.param_nat(path, params, 0);
    if id < 1 {
        return problem(heap, out, 422, "Unprocessable Content", "id must be a positive integer", keep);
    }
    if !store_has(store, id) {
        return problem(heap, out, 404, "Not Found", "no such user", keep);
    }
    var answer = out;
    var user = buffer.append(heap, buffer.empty(heap, 128), store_get(store, id));
    if remove {
        store_delete(store, id);
    }
    borrow user as &ub in {
        answer = server.reply(heap, answer, 200, buffer.bytes(ub), keep);
    }
    buffer.drop(heap, user);
    return answer;
}

fn routes[&h](heap: &!h Heap) -> [heap] route.Router {
    var r = route.empty(heap);
    r = route.add(heap, r, "GET", "/health", 1);
    r = route.add(heap, r, "GET", "/users", 2);
    r = route.add(heap, r, "POST", "/users", 3);
    r = route.add(heap, r, "GET", "/users/:id", 4);
    r = route.add(heap, r, "DELETE", "/users/:id", 5);
    r = route.add(heap, r, "GET", "/openapi.json", 6);
    return r;
}

// One parsed request in, one response appended to `out`.
fn handle[&h, &r, &sc, &st, &d, &q, &t, &p, &b](heap: &!h Heap, router: &r route.Router, sc: &sc schema.Schema, new_user: int, store: &!st Store, doc: &d [byte], request: &q [byte], table: &t [int], params: &!p [int], body: &b [byte], out: buffer.Buffer) -> [heap] buffer.Buffer {
    let keep = http.keeps_alive(table);
    let path = http.path(request, table);
    let id = route.find(router, http.method(request, table), path, params);
    if id == 1 {
        return server.reply(heap, out, 200, "{\"ok\":true}", keep);
    }
    if id == 2 {
        return list(heap, store, http.query(request, table), out, keep);
    }
    if id == 3 {
        return create(heap, sc, new_user, store, request, table, body, out, keep);
    }
    if id == 4 {
        return one(heap, store, path, params, false, out, keep);
    }
    if id == 5 {
        return one(heap, store, path, params, true, out, keep);
    }
    if id == 6 {
        return server.reply(heap, out, 200, doc, keep);
    }
    if id == 0 - 2 {
        var extra = buffer.append(heap, buffer.empty(heap, 48), "Allow: ");
        extra = route.allowed(heap, router, path, params, extra);
        extra = buffer.append(heap, extra, "\r\n");
        var answer = out;
        borrow extra as &eb in {
            answer = server.failure_with(heap, answer, 405, "method not allowed", keep, buffer.bytes(eb));
        }
        buffer.drop(heap, extra);
        return answer;
    }
    return problem(heap, out, 404, "Not Found", "no such route", keep);
}

// ---------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------

fn run[&h, &r, &k, &l](heap: &!h Heap, router: &r route.Router, clock: &k Clock, listener: &!l Listener) -> [heap, conn_accept, conn_read, conn_write, poll, clock] int {
    match poller_new() {
        Polling::Ok(p) => {
            var srv = server.open(heap, p, listener, 16384, 0, 9);
            var widest = 1;
            if route.most_params(router) > 1 {
                widest = route.most_params(router);
            }
            let params = box_slice(heap, 2 * widest, 0);
            var store = store_new(heap);
            let (sc, new_user, doc) = setup(heap);
            var out = buffer.empty(heap, 4096);
            while true {
                srv = server.wait(heap, srv, clock, listener, 1000);
                var more = true;
                while more {
                    var slot = 0 - 1;
                    borrow mut srv as &!sw in {
                        slot = server.next(heap, sw);
                    }
                    if slot < 0 {
                        more = false;
                    } else {
                        borrow mut out as &!ob in {
                            buffer.clear(ob);
                        }
                        borrow srv as &sr in {
                            borrow mut params as &!pw in {
                                borrow mut store as &!stw in {
                                    borrow sc as &scr in {
                                        borrow doc as &dr in {
                                            out = handle(heap, router, scr, new_user, stw, buffer.bytes(dr), server.head(sr), server.parsed(sr), contents(pw), server.body(sr), out);
                                        }
                                    }
                                }
                            }
                        }
                        borrow mut srv as &!sw in {
                            borrow out as &ob in {
                                server.respond(sw, buffer.bytes(ob));
                            }
                        }
                    }
                }
            }
            server.close(heap, srv);
            buffer.drop(heap, out);
            buffer.drop(heap, doc);
            schema.drop(heap, sc);
            store_drop(heap, store);
            unbox_slice(heap, params);
            return 0;
        }
        Polling::Failed(e) => {
            return 4;
        }
    }
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(fs);
    release(ffi);
    var port = 0 - 1;
    borrow args as &g in {
        if arg_count(g) > 1 {
            port = number_of(arg(g, 1));
        }
    }
    var status = 2;
    if port > 0 && port < 65536 {
        status = 3;
        borrow net as &nn in {
            match tcp_listen(nn, port, 1024, 0) {
                Listening::Ok(l) => {
                    var listener = l;
                    borrow mut listener as &!lh in {
                        listener_nonblocking(lh);
                        borrow mut heap as &!h in {
                            let router = routes(h);
                            borrow mut io as &!i in {
                                var line = buffer.append(h, buffer.empty(h, 64), "listening on ");
                                line = buffer.push_nat(h, line, port);
                                line = buffer.push(h, line, byte_of(10));
                                borrow line as &lb in {
                                    io.error_all(i, buffer.bytes(lb));
                                }
                                buffer.drop(h, line);
                            }
                            borrow router as &r in {
                                borrow clock as &c in {
                                    status = run(h, r, c, lh);
                                }
                            }
                            route.drop(h, router);
                        }
                    }
                    listener_close(listener);
                }
                Listening::Failed(e) => {
                }
            }
        }
    }
    release(net);
    release(clock);
    release(args);
    release(io);
    release(heap);
    return status;
}
