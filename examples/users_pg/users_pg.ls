edition 5;

// `users_pg` -- the `users` API with PostgreSQL as its store: the same routes, the same
// `schema`, the same OpenAPI document, the same answers, byte for byte -- what changes is
// that a user lives in a table and the service reaches it through the functions `pgen`
// wrote from `queries.sql`.
//
//     users_pg <port> <db host> <db port> <db user> <db name> <db password|->
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

// `INSERT` the validated request: the fields it left out are NULL. Answers the reply and a status.
fn insert_user[&h, &c, &b, &t, &u](heap: &!h Heap, conn: &!c Conn, body: &b [byte], tape: &t [int], slots: &u [int]) -> [heap, conn_read, conn_write] (buffer.Buffer, int) {
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
    var reply = buffer.empty(heap, 1);
    var status = 0;
    borrow name as &nr in {
        borrow email as &er in {
            borrow role as &rr in {
                borrow tags as &tr in {
                    let (r, s) = queries.add_user(heap, conn, buffer.bytes(nr), buffer.bytes(er), slots[slot_email()] >= 0, age, slots[slot_age()] >= 0, buffer.bytes(rr), slots[slot_role()] >= 0, buffer.bytes(tr), slots[slot_tags()] >= 0);
                    buffer.drop(heap, reply);
                    reply = r;
                    status = s;
                }
            }
        }
    }
    buffer.drop(heap, name);
    buffer.drop(heap, email);
    buffer.drop(heap, role);
    buffer.drop(heap, tags);
    return (reply, status);
}

// Validate, store, answer.
fn create[&h, &c, &sc, &q, &t, &b](heap: &!h Heap, conn: &!c Conn, sc: &sc schema.Schema, new_user: int, request: &q [byte], table: &t [int], body: &b [byte], out: buffer.Buffer, keep: bool) -> [heap, conn_read, conn_write] buffer.Buffer {
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
                            answer = server.reply_as(heap, answer, 422, "application/problem+json", buffer.bytes(pb), keep, "");
                        }
                        buffer.drop(heap, p);
                    } else {
                        let (reply, status) = insert_user(heap, conn, body, tp, sl);
                        var id = 0 - 1;
                        var refused = false;
                        borrow reply as &rr in {
                            let m = buffer.bytes(rr);
                            if answered(m, status) && pg.first_row(m) >= 0 {
                                id = queries.add_user_id(m, pg.first_row(m));
                            } else if status == 0 && data_error(m) {
                                refused = true;
                            }
                        }
                        buffer.drop(heap, reply);
                        if refused {
                            answer = problem(heap, answer, 422, "Unprocessable Content", "a value cannot be stored", keep);
                        } else if id < 1 {
                            answer = unavailable(heap, answer, keep);
                        } else {
                            let user = render_user(heap, id, body, tp, sl);
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
                        }
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

fn list[&h, &c, &q](heap: &!h Heap, conn: &!c Conn, query: &q [byte], out: buffer.Buffer, keep: bool) -> [heap, conn_read, conn_write] buffer.Buffer {
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
    // two round trips: how many there are, and the page
    let (counted, count_status) = queries.count_users(heap, conn);
    var total = 0 - 1;
    borrow counted as &cr in {
        let m = buffer.bytes(cr);
        if answered(m, count_status) && pg.first_row(m) >= 0 {
            total = queries.count_users_total(m, pg.first_row(m));
        }
    }
    buffer.drop(heap, counted);
    if total < 0 {
        return unavailable(heap, out, keep);
    }
    let (rows, status) = queries.list_users(heap, conn, limit, offset);
    var page = buffer.append(heap, buffer.empty(heap, 2048), "{\"total\":");
    page = buffer.push_nat(heap, page, total);
    page = buffer.append(heap, page, ",\"items\":[");
    var ok = false;
    borrow rows as &rr in {
        let m = buffer.bytes(rr);
        if answered(m, status) {
            ok = true;
            var taken = 0;
            var at = pg.first_row(m);
            while at >= 0 {
                if taken > 0 {
                    page = buffer.append(heap, page, ",");
                }
                let item = row_json(heap, m, at);
                borrow item as &ib in {
                    page = buffer.append(heap, page, buffer.bytes(ib));
                }
                buffer.drop(heap, item);
                taken = taken + 1;
                at = pg.next_row(m, at);
            }
        }
    }
    buffer.drop(heap, rows);
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
    return answer;
}

fn one[&h, &c, &p, &s](heap: &!h Heap, conn: &!c Conn, path: &s [byte], params: &p [int], remove: bool, out: buffer.Buffer, keep: bool) -> [heap, conn_read, conn_write] buffer.Buffer {
    let id = route.param_nat(path, params, 0);
    if id < 1 {
        return problem(heap, out, 422, "Unprocessable Content", "id must be a positive integer", keep);
    }
    var answer = out;
    if remove {
        let (got, status) = queries.delete_user(heap, conn, id);
        var seen = 0 - 1;
        borrow got as &rr in {
            if answered(buffer.bytes(rr), status) {
                seen = pg.affected(buffer.bytes(rr));
            }
        }
        buffer.drop(heap, got);
        if seen < 0 {
            return unavailable(heap, answer, keep);
        }
        if seen == 0 {
            return problem(heap, answer, 404, "Not Found", "no such user", keep);
        }
        return server.reply_empty(heap, answer, 204, keep, "");
    }
    let (got, status) = queries.get_user(heap, conn, id);
    var found = 0;
    borrow got as &rr in {
        let m = buffer.bytes(rr);
        if !answered(m, status) {
            found = 0 - 1;
        } else if pg.first_row(m) >= 0 {
            found = 1;
            let item = row_json(heap, m, pg.first_row(m));
            borrow item as &ib in {
                answer = server.reply(heap, answer, 200, buffer.bytes(ib), keep);
            }
            buffer.drop(heap, item);
        }
    }
    buffer.drop(heap, got);
    if found < 0 {
        return unavailable(heap, answer, keep);
    }
    if found == 0 {
        return problem(heap, answer, 404, "Not Found", "no such user", keep);
    }
    return answer;
}

// One parsed request in, one response appended to `out`.
fn handle[&h, &c, &r, &sc, &d, &q, &t, &p, &b](heap: &!h Heap, conn: &!c Conn, api: &r web.Api, sc: &sc schema.Schema, new_user: int, doc: &d [byte], request: &q [byte], table: &t [int], params: &!p [int], body: &b [byte], out: buffer.Buffer) -> [heap, conn_read, conn_write] buffer.Buffer {
    let keep = http.keeps_alive(table);
    let path = http.path(request, table);
    let id = web.find(api, http.method(request, table), path, params);
    if id == 3 {
        return create(heap, conn, sc, new_user, request, table, body, out, keep);
    }
    var answer = out;
    if id == 1 {
        answer = server.reply(heap, answer, 200, "{\"ok\":true}", keep);
    } else if id == 2 {
        answer = list(heap, conn, http.query(request, table), answer, keep);
    } else if id == 4 {
        answer = one(heap, conn, path, params, false, answer, keep);
    } else if id == 5 {
        answer = one(heap, conn, path, params, true, answer, keep);
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
    return answer;
}

// ---------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------

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
                                borrow api as &ar in {
                                    borrow sc as &scr in {
                                        borrow doc as &dr in {
                                            out = handle(heap, conn, ar, scr, new_user, buffer.bytes(dr), server.head(sr), server.parsed(sr), contents(pw), server.body(sr), out);
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
            return 0;
        }
        Polling::Failed(e) => {
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

fn main(world: World) -> [] int {
    let Split { io, ffi, fs, heap, args, net, clock } = split(world);
    release(ffi);
    let rng = narrow(fs, "/dev/urandom");
    var port = 0 - 1;
    var db_port = 0 - 1;
    borrow args as &g in {
        if arg_count(g) == 7 {
            port = number_of(arg(g, 1));
            db_port = number_of(arg(g, 3));
        }
    }
    var status = 2;
    if port > 0 && port < 65536 && db_port > 0 && db_port < 65536 {
        status = 3;
        borrow net as &nn in {
            borrow args as &g in {
                match tcp_connect(nn, arg(g, 2), db_port) {
                    Dialed::Ok(dialed) => {
                        var conn = dialed;
                        borrow mut conn as &!ch in {
                            borrow mut heap as &!h in {
                                status = 5;
                                borrow rng as &z in {
                                    if login(h, g, ch, z) == 0 {
                                        status = 3;
                                        match tcp_listen(nn, port, 1024, 0) {
                                            Listening::Ok(l) => {
                                                var listener = l;
                                                borrow mut listener as &!lh in {
                                                    listener_nonblocking(lh);
                                                    borrow mut io as &!i in {
                                                        var line = buffer.append(h, buffer.empty(h, 64), "listening on ");
                                                        line = buffer.push_nat(h, line, port);
                                                        line = buffer.push(h, line, byte_of(10));
                                                        borrow line as &lb in {
                                                            io.error_all(i, buffer.bytes(lb));
                                                        }
                                                        buffer.drop(h, line);
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
