edition 5;

// `users_pg` -- the `users` API with PostgreSQL as its store: the same routes, the same
// `schema`, the same OpenAPI document, the same answers, byte for byte -- what changes is
// that a user lives in a table and the service reaches it through the functions `pgen`
// wrote from `queries.sql`.
//
//     users_pg <port> <db host> <db port> <db user> <db name> <db password|-> [reuseport]
//
// The eighth argument, whatever it is, lets copies share the port (`reuseport`): see docs/benchmarks.md,
// "Copies of the blocking service".
//
// The table is `schema.sql`; the service does not create it. It holds one connection,
// opened, logged in and given its prepared statements before it listens, and every request
// that needs the database makes a blocking round trip on it: `http.server` is one loop serving every client, so the
// loop waits for PostgreSQL and no other request is served in the meantime (design.md of
// lexsys-pg, sections 4-5, and docs/benchmarks.md say what that costs, measured). If the
// database does not answer, the request is a 503; the connection is not reopened.
//
// Authority (`lex-sys authority`): `net_in`, `net_out`, `conn_*`, `poll`, `clock`, `heap`,
// `args`, `fs_read("/dev/urandom")` (the login's nonce), the console -- and no `ffi`.

import std.buffer;
import std.bytes;
import std.http;
import std.io;
import std.json;
import std.route;
import http.server;
import schema;
import web;
import pg;
import pg.pool;
import queries;

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

// Build every schema, then declare the API over them (`web`): the `Schema`, the node a
// POST body is checked against, the declared API (its router and what it documents), and
// the OpenAPI document generated from it.
//
// A route's id is the order it is declared in, which is what `handle` tests: health 1,
// list 2, create 3, get 4, delete 5, the document 6.
fn setup[&h](heap: &!h Heap) -> [heap] (schema.Schema, int, web.Api, buffer.Buffer) {
    var s = schema.empty(heap);
    // `name` and `email` refuse U+0000: PostgreSQL `text` cannot hold it, and the document says so
    // (a `pattern`), instead of accepting a body the database then rejects. A tag may hold it:
    // it is stored in a `json` column.
    let (s1a, name) = schema.new_string(heap, s, 1, 64);
    let s1 = schema.forbid_nul(s1a, name);
    let (s2a, email) = schema.new_string(heap, s1, 3, 120);
    let s2 = schema.forbid_nul(s2a, email);
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

    // Nodes that only the documentation needs (the validator never runs them): the
    // health answer, the paging parameters, and the id in a path. Added last so the
    // slots of `NewUser`'s fields stay 0..4.
    let (s19, alive) = schema.new_bool(heap, s);
    let (s20, health) = schema.new_object(heap, s19, true);
    s = schema.add_field(heap, s20, health, "ok", alive, true);
    let (s21, limit) = schema.new_int(heap, s, 1, 100);
    let (s22, offset) = schema.new_int(heap, s21, 0, 99999999999999999);
    let (s23, path_id) = schema.new_int(heap, s22, 1, 99999999999999999);
    s = s23;

    var api = web.empty(heap);
    let (a1, op_health) = web.operation(heap, api, "GET", "/health", "health");
    api = web.respond(heap, a1, op_health, 200, "alive", health);

    let (a2, op_list) = web.operation(heap, api, "GET", "/users", "listUsers");
    api = web.query_param(heap, a2, op_list, "limit", limit, false);
    api = web.query_param(heap, api, op_list, "offset", offset, false);
    api = web.respond(heap, api, op_list, 200, "a page", page);
    api = web.respond_problem(heap, api, op_list, 422);

    let (a3, op_create) = web.operation(heap, api, "POST", "/users", "createUser");
    api = web.body(heap, a3, op_create, new_user);
    api = web.respond(heap, api, op_create, 201, "created", user);
    api = web.response_header(heap, api, op_create, "Location");
    api = web.respond_problem(heap, api, op_create, 400);
    api = web.respond_problem(heap, api, op_create, 415);
    api = web.respond_problem(heap, api, op_create, 422);
    api = web.respond_problem(heap, api, op_create, 503);

    let (a4, op_get) = web.operation(heap, api, "GET", "/users/:id", "getUser");
    api = web.path_param(heap, a4, op_get, "id", path_id);
    api = web.respond(heap, api, op_get, 200, "the user", user);
    api = web.respond_problem(heap, api, op_get, 404);
    api = web.respond_problem(heap, api, op_get, 422);

    let (a5, op_delete) = web.operation(heap, api, "DELETE", "/users/:id", "deleteUser");
    api = web.path_param(heap, a5, op_delete, "id", path_id);
    api = web.respond_empty(heap, api, op_delete, 204, "deleted");
    api = web.respond_problem(heap, api, op_delete, 404);
    api = web.respond_problem(heap, api, op_delete, 422);

    let (a6, op_doc) = web.internal(heap, api, "GET", "/openapi.json");
    api = a6;

    api = web.component(heap, api, "NewUser", new_user);
    api = web.component(heap, api, "User", user);
    api = web.component(heap, api, "Page", page);
    api = web.component(heap, api, "Problem", problem);

    var doc = buffer.empty(heap, 16);
    borrow api as &ar in {
        borrow s as &sr in {
            buffer.drop(heap, doc);
            doc = web.openapi(heap, ar, sr, "Users API", "1.0.0");
        }
    }
    return (s, new_user, api, doc);
}

// ---------------------------------------------------------------------
// Answers
// ---------------------------------------------------------------------

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
        answer = server.reply_as(heap, answer, status, "application/problem+json", buffer.bytes(bb), keep, "");
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

// ---------------------------------------------------------------------
// The database
// ---------------------------------------------------------------------

fn unavailable[&h](heap: &!h Heap, out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    return problem(heap, out, 503, "Service Unavailable", "the database did not answer", keep);
}

// Whether a query got an answer that is not an error.
fn answered[&m](reply: &m [byte], status: int) -> [] bool {
    return status == 0 && pg.failure(reply) < 0;
}

// Whether the reply is an error that says the *data* cannot be stored (SQLSTATE class 22), as
// opposed to the database not being there. The first is the client's to fix, a 422; the second a
// 503. Not the contract: the schema already refuses the one such value there is a name for
// (U+0000, in `name` and `email`), so the document and the validator say so before the database
// is asked. This is for a data error the schema does not know of.
fn data_error[&m](reply: &m [byte]) -> [] bool {
    let at = pg.failure(reply);
    if at < 0 {
        return false;
    }
    let (from, to) = pg.error_field(reply, at, 67);
    return to - from == 5 && int_of(reply[from]) == 50 && int_of(reply[from + 1]) == 50;
}

// A string column, escaped into the writer.
fn put_range[&h, &m](heap: &!h Heap, w: json.Writer, reply: &m [byte], range: (int, int)) -> [heap] json.Writer {
    let (from, to) = range;
    return json.put_string(heap, w, reply[from..to]);
}

// The user in row `row` of a `get_user` or `list_users` reply, as the JSON it is answered with:
// `id` first, then whichever of the fields are not NULL. The two queries select the same
// columns in the same order, which is what lets `get_user`'s accessors read both (the
// end-to-end tests compare a page with the users it lists, one by one).
fn row_json[&h, &m](heap: &!h Heap, reply: &m [byte], row: int) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 128);
    w = json.begin_object(heap, w);
    w = json.put_key(heap, w, "id");
    w = json.put_int(heap, w, queries.get_user_id(reply, row));
    w = json.put_key(heap, w, "name");
    w = put_range(heap, w, reply, queries.get_user_name(reply, row));
    if !queries.get_user_email_is_null(reply, row) {
        w = json.put_key(heap, w, "email");
        w = put_range(heap, w, reply, queries.get_user_email(reply, row));
    }
    if !queries.get_user_age_is_null(reply, row) {
        w = json.put_key(heap, w, "age");
        w = json.put_int(heap, w, queries.get_user_age(reply, row));
    }
    if !queries.get_user_role_is_null(reply, row) {
        w = json.put_key(heap, w, "role");
        w = put_range(heap, w, reply, queries.get_user_role(reply, row));
    }
    if !queries.get_user_tags_is_null(reply, row) {
        // the server validated this column as JSON when it was stored (`json`, not `text`)
        let (from, to) = queries.get_user_tags(reply, row);
        w = json.put_key(heap, w, "tags");
        w = json.put_fragment(heap, w, reply[from..to]);
    }
    w = json.end_object(heap, w);
    return json.finish(w);
}

// The decoded text of string `node` of the request, as a buffer of its own.
fn decoded[&h, &b, &t](heap: &!h Heap, body: &b [byte], tape: &t [int], node: int) -> [heap] buffer.Buffer {
    let n = json.string_length(body, tape, node);
    var out = buffer.empty(heap, n + 1);
    if n > 0 {
        let raw = box_slice(heap, n, byte_of(0));
        borrow mut raw as &!rw in {
            let d = contents(rw);
            json.string_into(body, tape, node, d);
            out = buffer.append(heap, out, d);
        }
        unbox_slice(heap, raw);
    }
    return out;
}

// The tags array as compact JSON text, for the `json` column.
fn tags_json[&h, &b, &t](heap: &!h Heap, body: &b [byte], tape: &t [int], node: int) -> [heap] buffer.Buffer {
    var w = json.writer(heap, 64);
    w = json.begin_array(heap, w);
    var j = 0;
    while j < json.count(tape, node) {
        w = put_text(heap, w, body, tape, json.at(tape, node, j));
        j = j + 1;
    }
    w = json.end_array(heap, w);
    return json.finish(w);
}

// `INSERT` the validated request, as the bytes to send: the fields it left out are NULL.
fn insert_user_start[&h, &b, &t, &u](heap: &!h Heap, body: &b [byte], tape: &t [int], slots: &u [int]) -> [heap] buffer.Buffer {
    let name = decoded(heap, body, tape, slots[slot_name()]);
    var email = buffer.empty(heap, 1);
    if slots[slot_email()] >= 0 {
        buffer.drop(heap, email);
        email = decoded(heap, body, tape, slots[slot_email()]);
    }
    var role = buffer.empty(heap, 1);
    if slots[slot_role()] >= 0 {
        buffer.drop(heap, role);
        role = decoded(heap, body, tape, slots[slot_role()]);
    }
    var tags = buffer.empty(heap, 1);
    if slots[slot_tags()] >= 0 {
        buffer.drop(heap, tags);
        tags = tags_json(heap, body, tape, slots[slot_tags()]);
    }
    var age = 0;
    if slots[slot_age()] >= 0 {
        age = schema.to_int(body, tape, slots[slot_age()]);
    }
    var request = buffer.empty(heap, 1);
    borrow name as &nr in {
        borrow email as &er in {
            borrow role as &rr in {
                borrow tags as &tr in {
                    buffer.drop(heap, request);
                    request = queries.add_user_start(heap, buffer.bytes(nr), buffer.bytes(er), slots[slot_email()] >= 0, age, slots[slot_age()] >= 0, buffer.bytes(rr), slots[slot_role()] >= 0, buffer.bytes(tr), slots[slot_tags()] >= 0);
                }
            }
        }
    }
    buffer.drop(heap, name);
    buffer.drop(heap, email);
    buffer.drop(heap, role);
    buffer.drop(heap, tags);
    return request;
}

// ---------------------------------------------------------------------
// A request in two halves
// ---------------------------------------------------------------------
//
// A request that needs the database has a first half, `begin`, that checks it and either answers
// (a 4xx, a route with no query) or says what to ask the database -- the encoded request, ready
// to send -- and a second half, `conclude`, that reads the database's reply and answers or asks
// again (`GET /users` asks twice: how many, then the page). What passes between the halves is a
// record of a few integers, `rec`: nothing that points into the request, because a request that
// is waiting for the database no longer has its parse table or its buffer (`http.server`'s `hold`).
// The blocking service runs the halves one after the other; the other one runs `begin`, sends,
// goes on to the next request, and runs `conclude` when the answer arrives.

fn rec_width() -> [] int {
    return 6;
}

// What the record holds: the route (`web.find`'s id), whether the connection is kept alive, which
// query of the route it is at, and what `GET /users` carries from its first query to its second.
fn rec_route() -> [] int {
    return 0;
}

fn rec_keep() -> [] int {
    return 1;
}

fn rec_phase() -> [] int {
    return 2;
}

fn rec_total() -> [] int {
    return 3;
}

fn rec_limit() -> [] int {
    return 4;
}

fn rec_offset() -> [] int {
    return 5;
}

// What `begin` and `conclude` answer: the response so far, the request to send (empty if there is
// none), and 0 if the response is complete, 1 if the request is to be sent and `conclude` called
// with its reply.
fn done[&h](heap: &!h Heap, out: buffer.Buffer) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    return (out, buffer.empty(heap, 1), 0);
}

// Validate, then the request that stores.
fn create_begin[&h, &sc, &q, &t, &b, &w](heap: &!h Heap, sc: &sc schema.Schema, new_user: int, request: &q [byte], table: &t [int], body: &b [byte], out: buffer.Buffer, keep: bool, rec: &!w [int]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    if !is_json_type(http.header(request, table, "content-type")) {
        return done(heap, problem(heap, out, 415, "Unsupported Media Type", "send Content-Type: application/json", keep));
    }
    let tape = box_slice(heap, json.tape_len(body), 0);
    var answer = out;
    var next = buffer.empty(heap, 1);
    var code = 0;
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
                            answer = server.reply_as(heap, answer, 422, "application/problem+json", buffer.bytes(pb), keep, "");
                        }
                        buffer.drop(heap, p);
                    } else {
                        buffer.drop(heap, next);
                        next = insert_user_start(heap, body, tp, sl);
                        code = 1;
                    }
                }
            }
            unbox_slice(heap, errs);
            unbox_slice(heap, slots);
        }
    }
    unbox_slice(heap, tape);
    return (answer, next, code);
}

// The user the database gave back, as 201.
fn create_conclude[&h, &m](heap: &!h Heap, rep: &m [byte], status: int, out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    if status == 0 && data_error(rep) {
        return problem(heap, out, 422, "Unprocessable Content", "a value cannot be stored", keep);
    }
    if !answered(rep, status) || pg.first_row(rep) < 0 {
        return unavailable(heap, out, keep);
    }
    let row = pg.first_row(rep);
    let id = queries.get_user_id(rep, row);
    if id < 1 {
        return unavailable(heap, out, keep);
    }
    var answer = out;
    let user = row_json(heap, rep, row);
    var location = buffer.append(heap, buffer.empty(heap, 32), "Location: /users/");
    location = buffer.push_nat(heap, location, id);
    location = buffer.append(heap, location, "\r\n");
    borrow user as &ub in {
        borrow location as &lb in {
            answer = server.reply_as(heap, answer, 201, "application/json", buffer.bytes(ub), keep, buffer.bytes(lb));
        }
    }
    buffer.drop(heap, location);
    buffer.drop(heap, user);
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

// Check the query string; the first query is how many users there are.
fn list_begin[&h, &q, &w](heap: &!h Heap, query: &q [byte], out: buffer.Buffer, keep: bool, rec: &!w [int]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    if !query_keys_known(query) {
        return done(heap, problem(heap, out, 422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken", keep));
    }
    let limit = query_number(query, "limit", default_limit());
    let offset = query_number(query, "offset", 0);
    if limit < 1 || limit > max_limit() {
        return done(heap, problem(heap, out, 422, "Unprocessable Content", "limit must be an integer from 1 to 100", keep));
    }
    if offset < 0 {
        return done(heap, problem(heap, out, 422, "Unprocessable Content", "offset must be a non-negative integer", keep));
    }
    rec[rec_limit()] = limit;
    rec[rec_offset()] = offset;
    rec[rec_phase()] = 0;
    return (out, queries.count_users_start(heap), 1);
}

// Two round trips: how many there are, and the page.
fn list_conclude[&h, &m, &w](heap: &!h Heap, rep: &m [byte], status: int, out: buffer.Buffer, keep: bool, rec: &!w [int]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    if rec[rec_phase()] == 0 {
        var total = 0 - 1;
        if answered(rep, status) && pg.first_row(rep) >= 0 {
            total = queries.count_users_total(rep, pg.first_row(rep));
        }
        if total < 0 {
            return done(heap, unavailable(heap, out, keep));
        }
        rec[rec_total()] = total;
        rec[rec_phase()] = 1;
        return (out, queries.list_users_start(heap, rec[rec_limit()], rec[rec_offset()]), 1);
    }
    var page = buffer.append(heap, buffer.empty(heap, 2048), "{\"total\":");
    page = buffer.push_nat(heap, page, rec[rec_total()]);
    page = buffer.append(heap, page, ",\"items\":[");
    var ok = false;
    if answered(rep, status) {
        ok = true;
        var taken = 0;
        var at = pg.first_row(rep);
        while at >= 0 {
            if taken > 0 {
                page = buffer.append(heap, page, ",");
            }
            let item = row_json(heap, rep, at);
            borrow item as &ib in {
                page = buffer.append(heap, page, buffer.bytes(ib));
            }
            buffer.drop(heap, item);
            taken = taken + 1;
            at = pg.next_row(rep, at);
        }
    }
    var answer = out;
    if ok {
        page = buffer.append(heap, page, "]}");
        borrow page as &pb in {
            answer = server.reply(heap, answer, 200, buffer.bytes(pb), keep);
        }
    } else {
        answer = unavailable(heap, answer, keep);
    }
    buffer.drop(heap, page);
    return done(heap, answer);
}

// `GET` or `DELETE /users/{id}`: the id must be a number; the request is the lookup or the delete.
fn one_begin[&h, &p, &s](heap: &!h Heap, path: &s [byte], params: &p [int], remove: bool, out: buffer.Buffer, keep: bool) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    let id = route.param_nat(path, params, 0);
    if id < 1 {
        return done(heap, problem(heap, out, 422, "Unprocessable Content", "id must be a positive integer", keep));
    }
    if remove {
        return (out, queries.delete_user_start(heap, id), 1);
    }
    return (out, queries.get_user_start(heap, id), 1);
}

fn one_conclude[&h, &m](heap: &!h Heap, rep: &m [byte], status: int, remove: bool, out: buffer.Buffer, keep: bool) -> [heap] buffer.Buffer {
    var answer = out;
    if remove {
        var seen = 0 - 1;
        if answered(rep, status) {
            seen = pg.affected(rep);
        }
        if seen < 0 {
            return unavailable(heap, answer, keep);
        }
        if seen == 0 {
            return problem(heap, answer, 404, "Not Found", "no such user", keep);
        }
        return server.reply_empty(heap, answer, 204, keep, "");
    }
    var found = 0;
    if !answered(rep, status) {
        found = 0 - 1;
    } else if pg.first_row(rep) >= 0 {
        found = 1;
        let item = row_json(heap, rep, pg.first_row(rep));
        borrow item as &ib in {
            answer = server.reply(heap, answer, 200, buffer.bytes(ib), keep);
        }
        buffer.drop(heap, item);
    }
    if found < 0 {
        return unavailable(heap, answer, keep);
    }
    if found == 0 {
        return problem(heap, answer, 404, "Not Found", "no such user", keep);
    }
    return answer;
}

// One parsed request in: the response so far and the request for the database, if it needs one.
fn begin[&h, &r, &sc, &d, &q, &t, &p, &b, &w](heap: &!h Heap, api: &r web.Api, sc: &sc schema.Schema, new_user: int, doc: &d [byte], request: &q [byte], table: &t [int], params: &!p [int], body: &b [byte], out: buffer.Buffer, rec: &!w [int]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    let keep = http.keeps_alive(table);
    let path = http.path(request, table);
    let id = web.find(api, http.method(request, table), path, params);
    rec[rec_route()] = id;
    rec[rec_phase()] = 0;
    if keep {
        rec[rec_keep()] = 1;
    } else {
        rec[rec_keep()] = 0;
    }
    if id == 3 {
        return create_begin(heap, sc, new_user, request, table, body, out, keep, rec);
    }
    if id == 2 {
        return list_begin(heap, http.query(request, table), out, keep, rec);
    }
    if id == 4 {
        return one_begin(heap, path, params, false, out, keep);
    }
    if id == 5 {
        return one_begin(heap, path, params, true, out, keep);
    }
    var answer = out;
    if id == 1 {
        answer = server.reply(heap, answer, 200, "{\"ok\":true}", keep);
    } else if id == 6 {
        answer = server.reply(heap, answer, 200, doc, keep);
    } else if id == 0 - 2 {
        var extra = buffer.append(heap, buffer.empty(heap, 48), "Allow: ");
        extra = web.allowed(heap, api, path, params, extra);
        extra = buffer.append(heap, extra, "\r\n");
        borrow extra as &eb in {
            answer = server.failure_with(heap, answer, 405, "method not allowed", keep, buffer.bytes(eb));
        }
        buffer.drop(heap, extra);
    } else {
        answer = problem(heap, answer, 404, "Not Found", "no such route", keep);
    }
    return done(heap, answer);
}

// The database's rep to what `begin` asked (or to what this asked last): the response, or the next request.
fn conclude[&h, &m, &w](heap: &!h Heap, rep: &m [byte], status: int, out: buffer.Buffer, rec: &!w [int]) -> [heap] (buffer.Buffer, buffer.Buffer, int) {
    let route = rec[rec_route()];
    let keep = rec[rec_keep()] == 1;
    if route == 3 {
        return done(heap, create_conclude(heap, rep, status, out, keep));
    }
    if route == 2 {
        return list_conclude(heap, rep, status, out, keep, rec);
    }
    return done(heap, one_conclude(heap, rep, status, route == 5, out, keep));
}

// ---------------------------------------------------------------------
// The loops
// ---------------------------------------------------------------------

// One request to the database on the one connection, waiting for the answer: what `pg.run_named` does.
fn round_trip[&h, &c, &r](heap: &!h Heap, conn: &!c Conn, request: &r [byte]) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
    if !pg.send(conn, request) {
        return (buffer.empty(heap, 8), 6);
    }
    return pg.receive(heap, conn);
}

// The blocking service: `begin`, and while it has a request, send it and wait.
fn handle[&h, &c, &r, &sc, &d, &q, &t, &p, &b, &w](heap: &!h Heap, conn: &!c Conn, api: &r web.Api, sc: &sc schema.Schema, new_user: int, doc: &d [byte], request: &q [byte], table: &t [int], params: &!p [int], body: &b [byte], out: buffer.Buffer, rec: &!w [int]) -> [heap, conn_read, conn_write] buffer.Buffer {
    let (first, req, started) = begin(heap, api, sc, new_user, doc, request, table, params, body, out, rec);
    var answer = first;
    var next = req;
    var code = started;
    while code == 1 {
        var after = buffer.empty(heap, 1);
        borrow next as &nb in {
            let (got, status) = round_trip(heap, conn, buffer.bytes(nb));
            borrow got as &gb in {
                let (o, n, c) = conclude(heap, buffer.bytes(gb), status, answer, rec);
                answer = o;
                buffer.drop(heap, after);
                after = n;
                code = c;
            }
            buffer.drop(heap, got);
        }
        buffer.drop(heap, next);
        next = after;
    }
    buffer.drop(heap, next);
    return answer;
}

fn run[&h, &k, &l, &c](heap: &!h Heap, clock: &k Clock, listener: &!l Listener, conn: &!c Conn) -> [heap, conn_accept, conn_read, conn_write, poll, clock] int {
    match poller_new() {
        Polling::Ok(p) => {
            var srv = server.open(heap, p, listener, 16384, 0, 9);
            let (sc, new_user, api, doc) = setup(heap);
            var widest = 1;
            borrow api as &ar in {
                if web.most_params(ar) > 1 {
                    widest = web.most_params(ar);
                }
            }
            let params = box_slice(heap, 2 * widest, 0);
            let rec = box_slice(heap, rec_width(), 0);
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
                                borrow mut rec as &!rw in {
                                    borrow api as &ar in {
                                        borrow sc as &scr in {
                                            borrow doc as &dr in {
                                                out = handle(heap, conn, ar, scr, new_user, buffer.bytes(dr), server.head(sr), server.parsed(sr), contents(pw), server.body(sr), out, contents(rw));
                                            }
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
            web.drop(heap, api);
            schema.drop(heap, sc);
            unbox_slice(heap, params);
            unbox_slice(heap, rec);
            return 0;
        }
        Polling::Failed(e) => {
            return 4;
        }
    }
}

// The non-blocking service: the same `begin` and `conclude`, but a request that needs the database
// is *held* (`server.hold`), its encoded request is queued on the pool (`pool.submit`), and the loop
// goes on to the next request; the database's reply, when the poller says it has arrived, finishes it.
// The ticket `hold` answers is the pool's tag, and names the request's record.
fn run_pool[&h, &k, &l](heap: &!h Heap, clock: &k Clock, listener: &!l Listener, pl0: pool.Pool) -> [heap, conn_accept, conn_read, conn_write, poll, clock] int {
    var pl = pl0;
    match poller_new() {
        Polling::Ok(p) => {
            var srv = server.open(heap, p, listener, 16384, 0, 9);
            borrow mut srv as &!sw in {
                borrow mut pl as &!qw in {
                    pool.start(qw, server.poller(sw), server.first_token(sw));
                }
            }
            let (sc, new_user, api, doc) = setup(heap);
            var widest = 1;
            borrow api as &ar in {
                if web.most_params(ar) > 1 {
                    widest = web.most_params(ar);
                }
            }
            let params = box_slice(heap, 2 * widest, 0);
            // `begin`'s record while the request is in hand, and one for every ticket's slot after it is held
            let scratch = box_slice(heap, rec_width(), 0);
            let records = box_slice(heap, 2048 * rec_width(), 0);
            // what the poller said about the pool's connections, copied out of the server
            let seen = box_slice(heap, 128, 0);
            var out = buffer.empty(heap, 4096);
            while true {
                srv = server.wait(heap, srv, clock, listener, 1000);
                var events = 0;
                borrow srv as &sr in {
                    borrow mut seen as &!ew in {
                        events = server.foreign_count(sr);
                        var j = 0;
                        while j < 2 * events {
                            contents(ew)[j] = server.foreign(sr)[j];
                            j = j + 1;
                        }
                    }
                }
                var e = 0;
                while e < events {
                    var token = 0 - 1;
                    var readiness = 0;
                    borrow seen as &er in {
                        token = contents(er)[2 * e];
                        readiness = contents(er)[2 * e + 1];
                    }
                    borrow mut srv as &!sw in {
                        borrow mut pl as &!qw in {
                            if pool.owns(qw, token) {
                                pool.pump(qw, server.poller(sw), token, readiness);
                            }
                        }
                    }
                    e = e + 1;
                }
                // the queries that have an answer: finish their requests
                var ticket = 0 - 1;
                borrow mut pl as &!qw in {
                    ticket = pool.next_done(qw);
                }
                while ticket >= 0 {
                    let slot = server.ticket_slot(ticket);
                    borrow mut out as &!ob in {
                        buffer.clear(ob);
                    }
                    var next = buffer.empty(heap, 1);
                    var code = 0;
                    borrow pl as &qr in {
                        borrow mut records as &!rw in {
                            let (o, n, c) = conclude(heap, pool.reply(qr), pool.status(qr), out, contents(rw)[slot * rec_width()..(slot + 1) * rec_width()]);
                            out = o;
                            buffer.drop(heap, next);
                            next = n;
                            code = c;
                        }
                    }
                    if code == 1 {
                        var sent = 0 - 1;
                        borrow next as &nb in {
                            borrow mut pl as &!qw in {
                                sent = pool.submit(qw, ticket, buffer.bytes(nb));
                            }
                        }
                        if sent != 0 {
                            borrow records as &rr in {
                                out = unavailable(heap, out, contents(rr)[slot * rec_width() + rec_keep()] == 1);
                            }
                            code = 0;
                        }
                    }
                    buffer.drop(heap, next);
                    if code == 0 {
                        borrow mut srv as &!sw in {
                            borrow out as &ob in {
                                server.answer(sw, ticket, buffer.bytes(ob));
                            }
                        }
                    }
                    borrow mut pl as &!qw in {
                        ticket = pool.next_done(qw);
                    }
                }
                // new requests
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
                        var request = buffer.empty(heap, 1);
                        var code = 0;
                        var keep = true;
                        borrow srv as &sr in {
                            borrow mut params as &!pw in {
                                borrow mut scratch as &!cw in {
                                    borrow api as &ar in {
                                        borrow sc as &scr in {
                                            borrow doc as &dr in {
                                                let (o, n, c) = begin(heap, ar, scr, new_user, buffer.bytes(dr), server.head(sr), server.parsed(sr), contents(pw), server.body(sr), out, contents(cw));
                                                out = o;
                                                buffer.drop(heap, request);
                                                request = n;
                                                code = c;
                                                keep = contents(cw)[rec_keep()] == 1;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if code == 0 {
                            borrow mut srv as &!sw in {
                                borrow out as &ob in {
                                    server.respond(sw, buffer.bytes(ob));
                                }
                            }
                        } else {
                            var held = 0 - 1;
                            borrow mut srv as &!sw in {
                                held = server.hold(sw);
                            }
                            let at = server.ticket_slot(held) * rec_width();
                            borrow scratch as &cr in {
                                borrow mut records as &!rw in {
                                    var i = 0;
                                    while i < rec_width() {
                                        contents(rw)[at + i] = contents(cr)[i];
                                        i = i + 1;
                                    }
                                }
                            }
                            var sent = 0 - 1;
                            borrow request as &qb in {
                                borrow mut pl as &!qw in {
                                    sent = pool.submit(qw, held, buffer.bytes(qb));
                                }
                            }
                            if sent != 0 {
                                // nowhere to send it: every connection full or gone
                                out = unavailable(heap, out, keep);
                                borrow mut srv as &!sw in {
                                    borrow out as &ob in {
                                        server.answer(sw, held, buffer.bytes(ob));
                                    }
                                }
                            }
                        }
                        buffer.drop(heap, request);
                    }
                }
                // what this turn queued goes out in one write per connection
                borrow mut srv as &!sw in {
                    borrow mut pl as &!qw in {
                        pool.flush(qw, server.poller(sw));
                    }
                }
            }
            server.close(heap, srv);
            pool.close(heap, pl);
            buffer.drop(heap, out);
            buffer.drop(heap, doc);
            web.drop(heap, api);
            schema.drop(heap, sc);
            unbox_slice(heap, params);
            unbox_slice(heap, scratch);
            unbox_slice(heap, records);
            unbox_slice(heap, seen);
            return 0;
        }
        Polling::Failed(e) => {
            pool.close(heap, pl);
            return 4;
        }
    }
}

// An unpredictable client nonce for the SCRAM login: 18 bytes from the kernel, as base64.
fn fresh_nonce[&h, &f](heap: &!h Heap, fs: &f Fs("/dev/urandom")) -> [heap, fs_read("/dev/urandom")] buffer.Buffer {
    var nonce = buffer.empty(heap, 1);
    region a {
        let raw = alloc_slice[a](18, byte_of(0));
        let got = fs_read(fs, "/dev/urandom", raw);
        if got == 18 {
            buffer.drop(heap, nonce);
            nonce = pg.base64_encode(heap, raw);
        }
    }
    return nonce;
}

// Log in to the database and prepare the queries: 0, or a nonzero status for the exit code.
fn login[&h, &g, &c, &z](heap: &!h Heap, args: &g Args, conn: &!c Conn, rng: &z Fs("/dev/urandom")) -> [heap, args, conn_read, conn_write, fs_read("/dev/urandom")] int {
    let nonce = fresh_nonce(heap, rng);
    var hello = buffer.empty(heap, 1);
    var status = 0;
    borrow nonce as &nr in {
        let (reply, st) = pg.login(heap, conn, arg(args, 4), arg(args, 6), arg(args, 5), buffer.bytes(nr));
        buffer.drop(heap, hello);
        hello = reply;
        status = st;
    }
    buffer.drop(heap, nonce);
    buffer.drop(heap, hello);
    if status != 0 {
        return status;
    }
    // every query is parsed once, on this connection, under its name; a schema that no longer fits
    // one is refused here, at start-up, and not by the first request that needs it
    let (refused, prepared) = queries.prepare_all(heap, conn);
    var bad = prepared;
    borrow refused as &fr in {
        if pg.failure(buffer.bytes(fr)) >= 0 {
            bad = 6;
        }
    }
    buffer.drop(heap, refused);
    return bad;
}

// `tcp_listen`'s flags: 1 (SO_REUSEPORT) if there is an eighth argument other than `-`, so that copies
// of this service can share a port and the kernel spreads the connections between them. Each copy has
// its own database connection, so while one waits for PostgreSQL another can run.
fn listen_flags[&g](args: &g Args) -> [args] int {
    if arg_count(args) >= 8 && !bytes.equal(arg(args, 7), "-") {
        return 1;
    }
    return 0;
}

// The ninth argument: how many database connections for the non-blocking service; none (0) for the blocking one.
fn pool_size[&g](args: &g Args) -> [args] int {
    if arg_count(args) == 9 {
        return number_of(arg(args, 8));
    }
    return 0;
}

fn announce[&h, &i](heap: &!h Heap, io: &!i Io, port: int) -> [heap, err_write] int {
    var line = buffer.append(heap, buffer.empty(heap, 64), "listening on ");
    line = buffer.push_nat(heap, line, port);
    line = buffer.push(heap, line, byte_of(10));
    var wrote = 0;
    borrow line as &lb in {
        wrote = io.error_all(io, buffer.bytes(lb));
    }
    buffer.drop(heap, line);
    return wrote;
}

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    let rng = narrow(fs, "/dev/urandom");
    var port = 0 - 1;
    var db_port = 0 - 1;
    var lanes = 0;
    borrow args as &g in {
        if arg_count(g) >= 7 && arg_count(g) <= 9 {
            port = number_of(arg(g, 1));
            db_port = number_of(arg(g, 3));
            lanes = pool_size(g);
        }
    }
    var status = 2;
    if port > 0 && port < 65536 && db_port > 0 && db_port < 65536 && lanes >= 0 {
        status = 3;
        borrow net as &nn in {
            borrow args as &g in {
                if lanes == 0 {
                    match tcp_connect(nn, arg(g, 2), db_port) {
                        Dialed::Ok(dialed) => {
                            var conn = dialed;
                            borrow mut conn as &!ch in {
                                borrow mut heap as &!h in {
                                    status = 5;
                                    borrow rng as &z in {
                                        if login(h, g, ch, z) == 0 {
                                            status = 3;
                                            match tcp_listen(nn, port, 1024, listen_flags(g)) {
                                                Listening::Ok(l) => {
                                                    var listener = l;
                                                    borrow mut listener as &!lh in {
                                                        listener_nonblocking(lh);
                                                        borrow mut io as &!i in {
                                                            announce(h, i, port);
                                                        }
                                                        borrow clock as &c in {
                                                            status = run(h, c, lh, ch);
                                                        }
                                                    }
                                                    listener_close(listener);
                                                }
                                                Listening::Failed(e) => {
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            conn_close(conn);
                        }
                        Dialed::Failed(e) => {
                            status = 4;
                        }
                    }
                } else {
                    borrow mut heap as &!h in {
                        var pl = pool.empty(h, lanes, 64, 131072, 131072);
                        var added = 0;
                        var n = 0;
                        while n < lanes {
                            match tcp_connect(nn, arg(g, 2), db_port) {
                                Dialed::Ok(dialed) => {
                                    var conn = dialed;
                                    var s = 5;
                                    borrow mut conn as &!ch in {
                                        borrow rng as &z in {
                                            s = login(h, g, ch, z);
                                        }
                                    }
                                    if s == 0 {
                                        let (grown, slot) = pool.add(h, pl, conn);
                                        pl = grown;
                                        if slot >= 0 {
                                            added = added + 1;
                                        }
                                    } else {
                                        conn_close(conn);
                                    }
                                }
                                Dialed::Failed(e) => {
                                }
                            }
                            n = n + 1;
                        }
                        if added == lanes {
                            match tcp_listen(nn, port, 1024, listen_flags(g)) {
                                Listening::Ok(l) => {
                                    var listener = l;
                                    borrow mut listener as &!lh in {
                                        listener_nonblocking(lh);
                                        borrow mut io as &!i in {
                                            announce(h, i, port);
                                        }
                                        borrow clock as &c in {
                                            status = run_pool(h, c, lh, pl);
                                        }
                                    }
                                    listener_close(listener);
                                }
                                Listening::Failed(e) => {
                                    pool.close(h, pl);
                                }
                            }
                        } else {
                            status = 5;
                            pool.close(h, pl);
                        }
                    }
                }
            }
        }
    }
    release(rng);
    release(net);
    release(clock);
    release(args);
    release(io);
    release(heap);
    return status;
}
