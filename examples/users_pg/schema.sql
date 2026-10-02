-- The table users_pg stores users in. The service does not create it.
--
--     createdb users_pg && psql users_pg -f examples/users_pg/schema.sql
--
-- `tags` is `json`, not `text`: the server checks it is JSON when it is stored, so the
-- service can put it into an answer without trusting it.
drop table if exists users;
create table users (
    id bigserial primary key,
    name text not null,
    email text,
    age int,
    role text,
    tags json
);
