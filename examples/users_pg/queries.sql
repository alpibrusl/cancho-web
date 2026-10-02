-- The queries of users_pg. `pgen` turns this file into queries.ls (see the README):
--
--     pgen <host> <port> <user> users_pg <password|-> examples/users_pg/queries.sql > examples/users_pg/queries.ls
--
-- `get_user`, `list_users` and `add_user` (what it returns) select the same columns in the same order:
-- users_pg reads rows of all three with `get_user`'s accessors, so a created user is answered from the
-- row the database gave back, not from the request, which a request that waits for the database no
-- longer has.

-- name: count_users
select count(*) as total from users

-- name: list_users limit offset
select id, name, email, age, role, tags from users order by id limit $1 offset $2

-- name: get_user id
select id, name, email, age, role, tags from users where id = $1

-- name: add_user name email? age? role? tags?
insert into users (name, email, age, role, tags) values ($1, $2, $3, $4, $5) returning id, name, email, age, role, tags

-- name: delete_user id
delete from users where id = $1
