"""The users API of examples/users, in FastAPI + pydantic: the comparison workload.

    uvicorn app:app --port 8000                  # or --loop uvloop --http httptools
    LEAN=1 uvicorn app:app --port 8000           # no response_model: the fastest honest FastAPI

Same routes, same limits, same validation rules as examples/users/users.ls
(name 1..64, email 3..120, age 0..150, role in admin/user/guest, up to 8 tags of
1..16, no unknown fields; limit 1..100). Not the same error *format*: FastAPI's 422
is its own, and the benchmark compares work, not error documents.

`typical` (the default) is how most FastAPI code is written: a `response_model`, so
every answer is validated and serialized by pydantic again. `LEAN=1` returns the
stored bytes, as the lex-sys service does.
"""
import json
import os
from typing import Annotated, Literal, Optional

from fastapi import FastAPI, Query, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

LEAN = bool(os.environ.get("LEAN"))

Tag = Annotated[str, Field(min_length=1, max_length=16)]


class NewUser(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    name: Annotated[str, Field(min_length=1, max_length=64)]
    email: Optional[Annotated[str, Field(min_length=3, max_length=120)]] = None
    age: Optional[Annotated[int, Field(ge=0, le=150)]] = None
    role: Optional[Literal["admin", "user", "guest"]] = None
    tags: Optional[Annotated[list[Tag], Field(max_length=8)]] = None


class User(NewUser):
    id: int


app = FastAPI()
rows: list = []  # the stored answer for user k + 1: a dict, or its JSON bytes if LEAN


@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/users", response_model=None if LEAN else dict)
async def list_users(limit: int = Query(20, ge=1, le=100), offset: int = Query(0, ge=0)):
    page = rows[offset:offset + limit]
    if LEAN:
        return Response(b'{"total":%d,"items":[%s]}' % (len(rows), b",".join(page)), media_type="application/json")
    return {"total": len(rows), "items": page}


@app.post("/users", status_code=201, response_model=None if LEAN else User, response_model_exclude_none=True)
async def create(user: NewUser):
    n = len(rows) + 1
    body = {"id": n, **user.model_dump(exclude_none=True)}
    if LEAN:
        raw = json.dumps(body, separators=(",", ":")).encode()
        rows.append(raw)
        return Response(raw, status_code=201, media_type="application/json", headers={"Location": "/users/%d" % n})
    rows.append(body)
    return JSONResponse(body, status_code=201, headers={"Location": "/users/%d" % n})


@app.get("/users/{id}", response_model=None if LEAN else User, response_model_exclude_none=True)
async def get_user(id: int):
    if not 1 <= id <= len(rows):
        return JSONResponse({"detail": "no such user"}, status_code=404)
    row = rows[id - 1]
    return Response(row, media_type="application/json") if LEAN else row
