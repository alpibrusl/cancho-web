import std.buffer;
import std.bytes;
import std.test;
import schema;
import web;

// The OpenAPI document `web.openapi` writes for what was declared, compared byte for
// byte with documents derived by hand from the declarations -- not from the output.

fn document_is[&h, &a, &s, &w](heap: &!h Heap, api: &a web.Api, sc: &s schema.Schema, want: &w [byte]) -> [heap] int {
    let doc = web.openapi(heap, api, sc, "T", "1");
    borrow doc as &d in {
        test.assert(bytes.equal(buffer.bytes(d), want));
    }
    buffer.drop(heap, doc);
    return 0;
}

fn test_the_smallest_document[&h](heap: &!h Heap) -> [heap] int {
    let (s, flag) = schema.new_bool(heap, schema.empty(heap));
    var api = web.empty(heap);
    let (a1, health) = web.operation(heap, api, "GET", "/health", "health");
    api = web.respond(heap, a1, health, 200, "alive", flag);
    borrow api as &ar in {
        borrow s as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\"},\"paths\":{\"/health\":{\"get\":{\"operationId\":\"health\",\"responses\":{\"200\":{\"description\":\"alive\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"boolean\"}}}}}}}},\"components\":{\"schemas\":{}}}");
        }
    }
    test.assert_eq(web.drop(heap, api), 1);
    schema.drop(heap, s);
    return 0;
}

// A path parameter is written once for the path, whichever operations declare it;
// `/u/:id` is `/u/{id}`; a component is a `$ref` where used and is listed; a problem
// response is a `$ref` to the shared one.
fn test_shared_path_parameters_refs_and_the_problem_response[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, id) = schema.new_int(heap, s, 1, 99);
    let (s2, name) = schema.new_string(heap, s1, 1, 8);
    let (s3, problem) = schema.new_bool(heap, s2);
    var api = web.empty(heap);
    let (a1, get) = web.operation(heap, api, "GET", "/u/:id", "getU");
    api = web.path_param(heap, a1, get, "id", id);
    api = web.respond(heap, api, get, 200, "ok", name);
    api = web.respond_problem(heap, api, get, 404);
    let (a2, del) = web.operation(heap, api, "DELETE", "/u/:id", "delU");
    api = web.path_param(heap, a2, del, "id", id);
    api = web.respond_empty(heap, api, del, 204, "gone");
    api = web.component(heap, api, "Name", name);
    api = web.component(heap, api, "Problem", problem);
    borrow api as &ar in {
        borrow s3 as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\"},\"paths\":{\"/u/{id}\":{\"parameters\":[{\"name\":\"id\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":99}}],\"get\":{\"operationId\":\"getU\",\"responses\":{\"200\":{\"description\":\"ok\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Name\"}}}},\"404\":{\"$ref\":\"#/components/responses/Problem\"}}},\"delete\":{\"operationId\":\"delU\",\"responses\":{\"204\":{\"description\":\"gone\"}}}}},\"components\":{\"responses\":{\"Problem\":{\"description\":\"a problem\",\"content\":{\"application/problem+json\":{\"schema\":{\"$ref\":\"#/components/schemas/Problem\"}}}}},\"schemas\":{\"Name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8},\"Problem\":{\"type\":\"boolean\"}}}}");
        }
    }
    web.drop(heap, api);
    schema.drop(heap, s3);
    return 0;
}

// A query parameter, a request body, a response header, a route that is served and not
// documented -- and the routing the declaration also made.
fn test_query_body_header_internal_routes_and_routing[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, limit) = schema.new_int(heap, s, 1, 100);
    let (s2, name) = schema.new_string(heap, s1, 1, 8);
    var api = web.empty(heap);
    let (a1, list) = web.operation(heap, api, "GET", "/items", "list");
    api = web.query_param(heap, a1, list, "limit", limit, false);
    api = web.respond_empty(heap, api, list, 200, "a page");
    let (a2, create) = web.operation(heap, api, "POST", "/items", "create");
    api = web.body(heap, a2, create, name);
    api = web.respond(heap, api, create, 201, "created", name);
    api = web.response_header(heap, api, create, "Location");
    let (a3, doc) = web.internal(heap, api, "GET", "/doc");
    api = a3;
    // a method the layer does not know registers nothing
    let (a4, bad) = web.operation(heap, api, "TRACE", "/x", "x");
    api = a4;
    test.assert_eq(list, 1);
    test.assert_eq(create, 2);
    test.assert_eq(doc, 3);
    test.assert_eq(bad, 0 - 1);
    borrow api as &cr in {
        test.assert_eq(web.operation_count(cr), 3);
    }
    borrow api as &ar in {
        borrow s2 as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\"},\"paths\":{\"/items\":{\"get\":{\"operationId\":\"list\",\"parameters\":[{\"name\":\"limit\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":100}}],\"responses\":{\"200\":{\"description\":\"a page\"}}},\"post\":{\"operationId\":\"create\",\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8}}}},\"responses\":{\"201\":{\"description\":\"created\",\"headers\":{\"Location\":{\"schema\":{\"type\":\"string\"}}},\"content\":{\"application/json\":{\"schema\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8}}}}}}}},\"components\":{\"schemas\":{}}}");
        }
        let table = box_slice(heap, 2 * web.most_params(ar) + 2, 0);
        borrow mut table as &!tw in {
            let t = contents(tw);
            test.assert_eq(web.find(ar, "GET", "/items", t), 1);
            test.assert_eq(web.find(ar, "POST", "/items", t), 2);
            test.assert_eq(web.find(ar, "GET", "/doc", t), 3);
            test.assert_eq(web.find(ar, "DELETE", "/items", t), 0 - 2);
            test.assert_eq(web.find(ar, "GET", "/nowhere", t), 0 - 1);
        }
        unbox_slice(heap, table);
    }
    web.drop(heap, api);
    schema.drop(heap, s2);
    return 0;
}

// Who may call: bearer schemes, an operation's alternatives (any one will do), an open
// operation under a document default, an operation that inherits the default, and the
// shared error response of an API whose errors are not problem+json. Nothing is written
// for any of it unless it was declared (the tests above).
fn test_security_schemes_alternatives_defaults_and_the_error_response[&h](heap: &!h Heap) -> [heap] int {
    let (s1, flag) = schema.new_bool(heap, schema.empty(heap));
    let (s2, error) = schema.new_bool(heap, s1);
    var api = web.empty(heap);
    api = web.bearer_scheme(heap, api, "ingest", "the ingest token");
    api = web.bearer_scheme(heap, api, "admin", "");
    api = web.default_require(heap, api, "admin");
    let (a1, post) = web.operation(heap, api, "POST", "/e", "post");
    api = web.require(heap, a1, post, "ingest");
    api = web.require(heap, api, post, "admin");
    api = web.respond(heap, api, post, 202, "ok", flag);
    api = web.respond_error(heap, api, post, 400, "bad");
    let (a2, health) = web.operation(heap, api, "GET", "/h", "health");
    api = web.no_auth(heap, a2, health);
    api = web.respond_empty(heap, api, health, 200, "alive");
    let (a3, x) = web.operation(heap, api, "GET", "/x", "x");
    api = web.respond_empty(heap, a3, x, 200, "ok");
    api = web.component(heap, api, "Error", error);
    borrow api as &ar in {
        borrow s2 as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\"},\"security\":[{\"admin\":[]}],\"paths\":{\"/e\":{\"post\":{\"operationId\":\"post\",\"security\":[{\"ingest\":[]},{\"admin\":[]}],\"responses\":{\"202\":{\"description\":\"ok\",\"content\":{\"application/json\":{\"schema\":{\"type\":\"boolean\"}}}},\"400\":{\"$ref\":\"#/components/responses/Error\",\"description\":\"bad\"}}}},\"/h\":{\"get\":{\"operationId\":\"health\",\"security\":[],\"responses\":{\"200\":{\"description\":\"alive\"}}}},\"/x\":{\"get\":{\"operationId\":\"x\",\"responses\":{\"200\":{\"description\":\"ok\"}}}}},\"components\":{\"responses\":{\"Error\":{\"description\":\"an error\",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/Error\"}}}}},\"securitySchemes\":{\"ingest\":{\"type\":\"http\",\"scheme\":\"bearer\",\"description\":\"the ingest token\"},\"admin\":{\"type\":\"http\",\"scheme\":\"bearer\"}},\"schemas\":{\"Error\":{\"type\":\"boolean\"}}}}");
        }
    }
    web.drop(heap, api);
    schema.drop(heap, s2);
    return 0;
}

// Words and the rest of what a real API has: a summary and a description of an operation, a header
// parameter, descriptions of parameters (the path's, which is written once, and a header's), a plain-text
// response, and the document's own description (an empty summary is left out).
fn test_words_header_parameters_and_plain_text[&h](heap: &!h Heap) -> [heap] int {
    var s = schema.empty(heap);
    let (s1, key) = schema.new_string(heap, s, 1, 255);
    let (s2, page) = schema.new_int(heap, s1, 0, 9);
    let (s3, id) = schema.new_int(heap, s2, 1, 99);
    var api = web.empty(heap);
    api = web.about(heap, api, "", "Only a description.");
    let (a1, post) = web.operation(heap, api, "POST", "/e", "post");
    api = web.summary(heap, a1, post, "Post it");
    api = web.describe(heap, api, post, "More.");
    api = web.header_param(heap, api, post, "Idempotency-Key", key, false);
    api = web.describe_param(heap, api, post, "Idempotency-Key", "A key.");
    api = web.query_param(heap, api, post, "page", page, false);
    api = web.respond_text(heap, api, post, 200, "text");
    let (a2, get) = web.operation(heap, api, "GET", "/f/:id", "f");
    api = web.path_param(heap, a2, get, "id", id);
    api = web.describe_param(heap, api, get, "id", "The id.");
    api = web.respond_empty(heap, api, get, 200, "ok");
    borrow api as &ar in {
        borrow s3 as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\",\"description\":\"Only a description.\"},\"paths\":{\"/e\":{\"post\":{\"operationId\":\"post\",\"summary\":\"Post it\",\"description\":\"More.\",\"parameters\":[{\"name\":\"Idempotency-Key\",\"in\":\"header\",\"required\":false,\"description\":\"A key.\",\"schema\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":255}},{\"name\":\"page\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":9}}],\"responses\":{\"200\":{\"description\":\"text\",\"content\":{\"text/plain\":{\"schema\":{\"type\":\"string\"}}}}}}},\"/f/{id}\":{\"parameters\":[{\"name\":\"id\",\"in\":\"path\",\"required\":true,\"description\":\"The id.\",\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":99}}],\"get\":{\"operationId\":\"f\",\"responses\":{\"200\":{\"description\":\"ok\"}}}}},\"components\":{\"schemas\":{}}}");
        }
    }
    web.drop(heap, api);
    schema.drop(heap, s3);
    return 0;
}

// A request body that may be left out says `required: false`.
fn test_an_optional_body[&h](heap: &!h Heap) -> [heap] int {
    let (s, name) = schema.new_string(heap, schema.empty(heap), 1, 8);
    var api = web.empty(heap);
    let (a1, op) = web.operation(heap, api, "POST", "/p", "p");
    api = web.optional_body(heap, a1, op, name);
    api = web.respond_empty(heap, api, op, 204, "done");
    borrow api as &ar in {
        borrow s as &sr in {
            document_is(heap, ar, sr, "{\"openapi\":\"3.1.0\",\"info\":{\"title\":\"T\",\"version\":\"1\"},\"paths\":{\"/p\":{\"post\":{\"operationId\":\"p\",\"requestBody\":{\"required\":false,\"content\":{\"application/json\":{\"schema\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":8}}}},\"responses\":{\"204\":{\"description\":\"done\"}}}}},\"components\":{\"schemas\":{}}}");
        }
    }
    web.drop(heap, api);
    schema.drop(heap, s);
    return 0;
}

// Asking the declaration who may call an operation: the alternatives it declared, in order; the document's default when it declared none; nothing
// for an open one, for an operation that does not exist, or when neither it nor the document says anything.
fn test_asking_who_may_call[&h](heap: &!h Heap) -> [heap] int {
    var api = web.empty(heap);
    api = web.bearer_scheme(heap, api, "ingest", "");
    api = web.bearer_scheme(heap, api, "admin", "");
    api = web.default_require(heap, api, "admin");
    let (a1, post) = web.operation(heap, api, "POST", "/e", "post");
    api = web.require(heap, a1, post, "ingest");
    api = web.require(heap, api, post, "admin");
    let (a2, health) = web.operation(heap, api, "GET", "/h", "health");
    api = web.no_auth(heap, a2, health);
    let (a3, x) = web.operation(heap, api, "GET", "/x", "x");
    api = a3;
    borrow api as &ar in {
        test.assert_eq(web.requirements(ar, post), 2);
        test.assert(bytes.equal(web.requirement(ar, post, 0), "ingest"));
        test.assert(bytes.equal(web.requirement(ar, post, 1), "admin"));
        test.assert_eq(len(web.requirement(ar, post, 2)), 0);
        test.assert(!web.is_open(ar, post));
        test.assert(web.is_open(ar, health));
        test.assert_eq(web.requirements(ar, health), 0);
        test.assert_eq(len(web.requirement(ar, health, 0)), 0);
        test.assert(!web.is_open(ar, x));
        test.assert_eq(web.requirements(ar, x), 1);
        test.assert(bytes.equal(web.requirement(ar, x, 0), "admin"));
        test.assert_eq(web.requirements(ar, 0), 0);
        test.assert_eq(web.requirements(ar, 4), 0);
        test.assert_eq(len(web.requirement(ar, 4, 0)), 0);
        test.assert_eq(len(web.requirement(ar, post, 0 - 1)), 0);
    }
    web.drop(heap, api);
    // no default and no call: nothing is said, and it is not "open"
    var bare = web.empty(heap);
    let (b1, y) = web.operation(heap, bare, "GET", "/y", "y");
    bare = b1;
    borrow bare as &br in {
        test.assert_eq(web.requirements(br, y), 0);
        test.assert(!web.is_open(br, y));
    }
    web.drop(heap, bare);
    return 0;
}
