// The users API of examples/users, in Go with fasthttp: a comparison workload.
//
//	go build -o users . && ./users 8000
//
// The same work as benches/go_users (which is net/http): same routes, same limits, same validation rules, same stored
// answer (the user's canonical compact JSON, id first), the same hand-written range checks and encoding/json into a
// struct. Only the server differs: fasthttp is the Go HTTP server written to be fast (no allocation per request on
// its own paths, a worker pool instead of a goroutine per connection), so it is the fairer Go yardstick for a loop
// that does not allocate either. Default settings otherwise; one core visible (`taskset`) makes GOMAXPROCS 1.
//
// Left out, because nothing measures them: /openapi.json. The same known differences at the edges as benches/go_users.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/valyala/fasthttp"
)

const (
	maxUsers = 100000
	maxBody  = 1 << 20
)

type newUser struct {
	Name  *string   `json:"name"`
	Email *string   `json:"email"`
	Age   *int      `json:"age"`
	Role  *string   `json:"role"`
	Tags  *[]string `json:"tags"`
}

type user struct {
	ID    int       `json:"id"`
	Name  string    `json:"name"`
	Email *string   `json:"email,omitempty"`
	Age   *int      `json:"age,omitempty"`
	Role  *string   `json:"role,omitempty"`
	Tags  *[]string `json:"tags,omitempty"`
}

var (
	mu   sync.RWMutex
	rows [][]byte // rows[id-1] is the stored JSON of user id, nil once deleted
	live int
)

func problem(ctx *fasthttp.RequestCtx, status int, title, detail string) {
	b, _ := json.Marshal(map[string]any{"title": title, "status": status, "detail": detail})
	ctx.SetContentType("application/problem+json")
	ctx.SetStatusCode(status)
	ctx.SetBody(b)
}

func reply(ctx *fasthttp.RequestCtx, status int, body []byte) {
	ctx.SetContentType("application/json")
	ctx.SetStatusCode(status)
	ctx.SetBody(body)
}

func between(s string, lo, hi int) bool {
	n := utf8.RuneCountInString(s)
	return n >= lo && n <= hi
}

func (n *newUser) valid() bool {
	if n.Name == nil || !between(*n.Name, 1, 64) {
		return false
	}
	if n.Email != nil && !between(*n.Email, 3, 120) {
		return false
	}
	if n.Age != nil && (*n.Age < 0 || *n.Age > 150) {
		return false
	}
	if n.Role != nil && *n.Role != "admin" && *n.Role != "user" && *n.Role != "guest" {
		return false
	}
	if n.Tags != nil {
		if len(*n.Tags) > 8 {
			return false
		}
		for _, t := range *n.Tags {
			if !between(t, 1, 16) {
				return false
			}
		}
	}
	return true
}

func create(ctx *fasthttp.RequestCtx) {
	ct := string(ctx.Request.Header.ContentType())
	if len(ct) < 16 || !strings.EqualFold(ct[:16], "application/json") {
		problem(ctx, 415, "Unsupported Media Type", "send Content-Type: application/json")
		return
	}
	dec := json.NewDecoder(bytes.NewReader(ctx.PostBody()))
	dec.DisallowUnknownFields()
	var nu newUser
	if err := dec.Decode(&nu); err != nil {
		var syn *json.SyntaxError
		if errors.As(err, &syn) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			problem(ctx, 400, "Bad Request", err.Error())
		} else {
			problem(ctx, 422, "Unprocessable Content", err.Error())
		}
		return
	}
	if _, err := dec.Token(); err != io.EOF {
		problem(ctx, 400, "Bad Request", "trailing data after the document")
		return
	}
	if !nu.valid() {
		problem(ctx, 422, "Unprocessable Content", "the body does not satisfy the schema")
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if len(rows) >= maxUsers {
		problem(ctx, 503, "Service Unavailable", "the store is full")
		return
	}
	id := len(rows) + 1
	b, _ := json.Marshal(user{ID: id, Name: *nu.Name, Email: nu.Email, Age: nu.Age, Role: nu.Role, Tags: nu.Tags})
	rows = append(rows, b)
	live++
	ctx.Response.Header.Set("Location", "/users/"+strconv.Itoa(id))
	reply(ctx, 201, b)
}

// digits: a decimal number of at most 17 digits, else -1.
func digits(s string) int {
	if len(s) == 0 || len(s) > 17 {
		return -1
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return -1
		}
		n = n*10 + int(s[i]-'0')
	}
	return n
}

func list(ctx *fasthttp.RequestCtx) {
	limit, offset := 20, 0
	unknown := false
	seenLimit, seenOffset := false, false
	ctx.QueryArgs().VisitAll(func(k, v []byte) {
		switch string(k) {
		case "limit":
			if !seenLimit {
				limit = digits(string(v))
				seenLimit = true
			}
		case "offset":
			if !seenOffset {
				offset = digits(string(v))
				seenOffset = true
			}
		default:
			unknown = true
		}
	})
	if unknown {
		problem(ctx, 422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken")
		return
	}
	if limit < 1 || limit > 100 {
		problem(ctx, 422, "Unprocessable Content", "limit must be an integer from 1 to 100")
		return
	}
	if offset < 0 {
		problem(ctx, 422, "Unprocessable Content", "offset must be a non-negative integer")
		return
	}
	var out bytes.Buffer
	mu.RLock()
	out.WriteString(`{"total":`)
	out.WriteString(strconv.Itoa(live))
	out.WriteString(`,"items":[`)
	taken, skipped := 0, 0
	for i := 0; i < len(rows) && taken < limit; i++ {
		if rows[i] == nil {
			continue
		}
		if skipped < offset {
			skipped++
			continue
		}
		if taken > 0 {
			out.WriteByte(',')
		}
		out.Write(rows[i])
		taken++
	}
	mu.RUnlock()
	out.WriteString("]}")
	reply(ctx, 200, out.Bytes())
}

func one(ctx *fasthttp.RequestCtx, idText string, remove bool) {
	id := digits(idText)
	if id < 1 {
		problem(ctx, 422, "Unprocessable Content", "id must be a positive integer")
		return
	}
	var row []byte
	mu.Lock()
	if id <= len(rows) {
		row = rows[id-1]
		if remove && row != nil {
			rows[id-1] = nil
			live--
		}
	}
	mu.Unlock()
	switch {
	case row == nil:
		problem(ctx, 404, "Not Found", "no such user")
	case remove:
		ctx.SetStatusCode(204)
	default:
		reply(ctx, 200, row)
	}
}

func notAllowed(ctx *fasthttp.RequestCtx) {
	ctx.SetStatusCode(405)
}

func handler(ctx *fasthttp.RequestCtx) {
	path := string(ctx.Path())
	method := string(ctx.Method())
	switch {
	case path == "/health":
		if method != "GET" {
			notAllowed(ctx)
			return
		}
		reply(ctx, 200, []byte(`{"ok":true}`))
	case path == "/users":
		switch method {
		case "GET":
			list(ctx)
		case "POST":
			create(ctx)
		default:
			notAllowed(ctx)
		}
	case strings.HasPrefix(path, "/users/") && len(path) > 7 && !strings.Contains(path[7:], "/"):
		switch method {
		case "GET":
			one(ctx, path[7:], false)
		case "DELETE":
			one(ctx, path[7:], true)
		default:
			notAllowed(ctx)
		}
	default:
		ctx.SetStatusCode(404)
	}
}

func main() {
	port := "8000"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	s := &fasthttp.Server{Handler: handler, MaxRequestBodySize: maxBody, Name: "fasthttp"}
	if err := s.ListenAndServe("127.0.0.1:" + port); err != nil {
		panic(err)
	}
}
