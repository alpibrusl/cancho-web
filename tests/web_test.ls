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
