// The users API of examples/users, in Go's standard library: a comparison workload.
//
//	go build -o users . && ./users 8000
//
// Same routes, same limits, same validation rules as examples/users/users.ls (name
// 1..64 code points, email 3..120, age 0..150, role in admin/user/guest, up to 8 tags
// of 1..16, no unknown fields; limit 1..100) and the same stored answer: the user's
// canonical compact JSON, id first. It is written the ordinary way -- net/http,
// encoding/json into a struct, hand-written range checks, since the standard library
// has no validator -- not the fastest way Go could do it.
//
// Left out, because nothing measures them: /openapi.json. Known differences at the
// edges, none of them in benches/equivalent.py's cases: encoding/json matches field
// names case-insensitively and replaces invalid UTF-8, and takes `150.0` as not an
// integer.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"sync"
	"unicode/utf8"
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

func problem(w http.ResponseWriter, status int, title, detail string) {
	b, _ := json.Marshal(map[string]any{"title": title, "status": status, "detail": detail})
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	w.Write(b)
}

func reply(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
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

func create(w http.ResponseWriter, r *http.Request) {
	ct := r.Header.Get("Content-Type")
	if len(ct) < 16 || !bytes.EqualFold([]byte(ct[:16]), []byte("application/json")) {
		problem(w, 415, "Unsupported Media Type", "send Content-Type: application/json")
		return
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	var nu newUser
	if err := dec.Decode(&nu); err != nil {
		var syn *json.SyntaxError
		if errors.As(err, &syn) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			problem(w, 400, "Bad Request", err.Error())
		} else {
			problem(w, 422, "Unprocessable Content", err.Error())
		}
		return
	}
	if _, err := dec.Token(); err != io.EOF {
		problem(w, 400, "Bad Request", "trailing data after the document")
		return
	}
	if !nu.valid() {
		problem(w, 422, "Unprocessable Content", "the body does not satisfy the schema")
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if len(rows) >= maxUsers {
		problem(w, 503, "Service Unavailable", "the store is full")
		return
	}
	id := len(rows) + 1
	b, _ := json.Marshal(user{ID: id, Name: *nu.Name, Email: nu.Email, Age: nu.Age, Role: nu.Role, Tags: nu.Tags})
	rows = append(rows, b)
	live++
	w.Header().Set("Location", "/users/"+strconv.Itoa(id))
	reply(w, 201, b)
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

func list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, offset := 20, 0
	for k, v := range q {
		switch k {
		case "limit":
			limit = digits(v[0])
		case "offset":
			offset = digits(v[0])
		default:
			problem(w, 422, "Unprocessable Content", "unknown query parameter: only limit and offset are taken")
			return
		}
	}
	if limit < 1 || limit > 100 {
		problem(w, 422, "Unprocessable Content", "limit must be an integer from 1 to 100")
		return
	}
	if offset < 0 {
		problem(w, 422, "Unprocessable Content", "offset must be a non-negative integer")
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
	reply(w, 200, out.Bytes())
}

func one(remove bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := digits(r.PathValue("id"))
		if id < 1 {
			problem(w, 422, "Unprocessable Content", "id must be a positive integer")
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
			problem(w, 404, "Not Found", "no such user")
		case remove:
			w.WriteHeader(204)
		default:
			reply(w, 200, row)
		}
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { reply(w, 200, []byte(`{"ok":true}`)) })
	mux.HandleFunc("GET /users", list)
	mux.HandleFunc("POST /users", create)
	mux.HandleFunc("GET /users/{id}", one(false))
	mux.HandleFunc("DELETE /users/{id}", one(true))
	port := "8000"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	if err := http.ListenAndServe("127.0.0.1:"+port, mux); err != nil {
		panic(err)
	}
}
