"""The users API of examples/users_pg, in FastAPI with PostgreSQL: the comparison workload.

    PGDATABASE=... uvicorn app:app --port 8000 --loop uvloop --http httptools        # SQLAlchemy 2 (async) + asyncpg
    LEAN=1 PGDATABASE=... uvicorn app:app --port 8000 --loop uvloop --http httptools   # asyncpg directly, hand-built JSON

Same routes, limits, validation and table (`examples/users_pg/schema.sql`) as the cancho service,
including that `name` and `email` refuse U+0000, which PostgreSQL text cannot hold (so the same
work is done; `pattern` is what the cancho document says). Not the same error *format*.

`typical` (the default) is how most FastAPI + SQLAlchemy code is written: an async session per
request from a pool, the ORM, a `response_model` that validates and serializes every answer again.
`LEAN=1` is the fastest honest version: a pool of asyncpg connections, the SQL of
`examples/users_pg/queries.sql`, and the answer built without a model.

The connection comes from the usual PG* variables; the pool holds 10 connections (the cancho
service holds one: `http.server` is one loop and a query blocks it).
"""
import json
import os
from typing import Annotated, Literal, Optional

from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

LEAN = bool(os.environ.get("LEAN"))
HOST = os.environ.get("PGHOST", "127.0.0.1")
PORT = int(os.environ.get("PGPORT", "5432"))
USER = os.environ.get("PGUSER", "postgres")
DATABASE = os.environ.get("PGDATABASE", "users_pg")
PASSWORD = os.environ.get("PGPASSWORD") or None

NOT_NUL = r"^[^\x00]*$"
Tag = Annotated[str, Field(min_length=1, max_length=16)]


class NewUser(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    name: Annotated[str, Field(min_length=1, max_length=64, pattern=NOT_NUL)]
    email: Optional[Annotated[str, Field(min_length=3, max_length=120, pattern=NOT_NUL)]] = None
    age: Optional[Annotated[int, Field(ge=0, le=150)]] = None
    role: Optional[Literal["admin", "user", "guest"]] = None
    tags: Optional[Annotated[list[Tag], Field(max_length=8)]] = None


class User(NewUser):
    id: int


app = FastAPI()


@app.get("/health")
async def health():
    return {"ok": True}


if LEAN:
    import asyncpg

    pool = None

    @app.on_event("startup")
    async def start():
        global pool
        pool = await asyncpg.create_pool(host=HOST, port=PORT, user=USER, database=DATABASE, password=PASSWORD,
                                         min_size=10, max_size=10)

    def render(row):
        out = {"id": row["id"], "name": row["name"]}
        for k in ("email", "age", "role"):
            if row[k] is not None:
                out[k] = row[k]
        if row["tags"] is not None:
            out["tags"] = json.loads(row["tags"])
        return out

    COLUMNS = "id, name, email, age, role, tags::text as tags"

    @app.get("/users")
    async def list_users(limit: int = Query(20, ge=1, le=100), offset: int = Query(0, ge=0)):
        async with pool.acquire() as c:
            total = await c.fetchval("select count(*) from users")
            rows = await c.fetch("select %s from users order by id limit $1 offset $2" % COLUMNS, limit, offset)
        return Response(json.dumps({"total": total, "items": [render(r) for r in rows]}, separators=(",", ":")).encode(),
                        media_type="application/json")

    @app.post("/users", status_code=201)
    async def create(user: NewUser):
        async with pool.acquire() as c:
            n = await c.fetchval(
                "insert into users (name, email, age, role, tags) values ($1, $2, $3, $4, $5::text::json) returning id",
                user.name, user.email, user.age, user.role,
                None if user.tags is None else json.dumps(user.tags, separators=(",", ":")))
        body = {"id": n, **user.model_dump(exclude_none=True)}
        return Response(json.dumps(body, separators=(",", ":")).encode(), status_code=201,
                        media_type="application/json", headers={"Location": "/users/%d" % n})

    @app.get("/users/{id}")
    async def get_user(id: int):
        async with pool.acquire() as c:
            row = await c.fetchrow("select %s from users where id = $1" % COLUMNS, id)
        if row is None:
            return JSONResponse({"detail": "no such user"}, status_code=404)
        return Response(json.dumps(render(row), separators=(",", ":")).encode(), media_type="application/json")

    @app.delete("/users/{id}", status_code=204)
    async def delete_user(id: int):
        async with pool.acquire() as c:
            tag = await c.execute("delete from users where id = $1", id)
        if tag == "DELETE 0":
            return JSONResponse({"detail": "no such user"}, status_code=404)
        return Response(status_code=204)

else:
    from sqlalchemy import BigInteger, Integer, Text, delete, func, select
    from sqlalchemy.dialects.postgresql import JSON
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
    from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

    class Base(DeclarativeBase):
        pass

    class UserRow(Base):
        __tablename__ = "users"
        id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
        name: Mapped[str] = mapped_column(Text)
        email: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
        age: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
        role: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
        tags: Mapped[Optional[list]] = mapped_column(JSON, nullable=True)

    engine = None
    Session = None

    @app.on_event("startup")
    async def start():
        global engine, Session
        engine = create_async_engine(
            "postgresql+asyncpg://%s%s@%s:%d/%s" % (USER, ":" + PASSWORD if PASSWORD else "", HOST, PORT, DATABASE),
            pool_size=10, max_overflow=0)
        Session = async_sessionmaker(engine, expire_on_commit=False)

    def as_user(row):
        return User(id=row.id, name=row.name, email=row.email, age=row.age, role=row.role, tags=row.tags)

    @app.get("/users", response_model=dict)
    async def list_users(limit: int = Query(20, ge=1, le=100), offset: int = Query(0, ge=0)):
        async with Session() as s:
            total = (await s.execute(select(func.count()).select_from(UserRow))).scalar_one()
            rows = (await s.execute(select(UserRow).order_by(UserRow.id).limit(limit).offset(offset))).scalars().all()
        return {"total": total, "items": [as_user(r).model_dump(exclude_none=True) for r in rows]}

    @app.post("/users", status_code=201, response_model=User, response_model_exclude_none=True)
    async def create(user: NewUser):
        row = UserRow(**user.model_dump())
        async with Session() as s:
            s.add(row)
            await s.commit()
        return JSONResponse(as_user(row).model_dump(exclude_none=True), status_code=201,
                            headers={"Location": "/users/%d" % row.id})

    @app.get("/users/{id}", response_model=User, response_model_exclude_none=True)
    async def get_user(id: int):
        async with Session() as s:
            row = await s.get(UserRow, id)
        if row is None:
            return JSONResponse({"detail": "no such user"}, status_code=404)
        return as_user(row)

    @app.delete("/users/{id}", status_code=204)
    async def delete_user(id: int):
        async with Session() as s:
            result = await s.execute(delete(UserRow).where(UserRow.id == id))
            await s.commit()
        if result.rowcount == 0:
            return JSONResponse({"detail": "no such user"}, status_code=404)
        return Response(status_code=204)
