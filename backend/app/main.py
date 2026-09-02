import os
import logging
import sqlite3
import sys
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

app = FastAPI(title="NovaCart API", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./novacart.db")
APP_ENV = os.getenv("APP_ENV", "development")
API_VERSION = os.getenv("API_VERSION", "v1")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("novacart")

PRODUCTS = [
    (1, "DevOps Hoodie", 59.00),
    (2, "Cloud Engineer Mug", 18.00),
    (3, "Incident Response Notebook", 14.00),
]

PROMOS = {
    "DEVOPS10": 0.10,
    "NOVA15": 0.15,
    "SHIPFREE": 0.05,
}


class OrderItemInput(BaseModel):
    id: int = Field(..., ge=1)
    quantity: int = Field(..., ge=1)


class CreateOrderRequest(BaseModel):
    items: list[OrderItemInput] = Field(default_factory=list)
    promo_code: str | None = None


def _sqlite_path():
    if not DATABASE_URL.startswith("sqlite:///"):
        return None
    return DATABASE_URL.replace("sqlite:///", "", 1)


def _is_sqlite():
    return _sqlite_path() is not None


def _database_engine():
    return "sqlite" if _is_sqlite() else "postgresql"


@contextmanager
def _open_connection():
    path = _sqlite_path()
    if path:
        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
        finally:
            conn.close()
        return

    import psycopg

    with psycopg.connect(DATABASE_URL) as conn:
        yield conn


def _create_schema(conn):
    if _is_sqlite():
        conn.execute(
            "CREATE TABLE IF NOT EXISTS products ("
            "id INTEGER PRIMARY KEY, "
            "name TEXT NOT NULL, "
            "price REAL NOT NULL"
            ")"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS orders ("
            "order_ref TEXT PRIMARY KEY, "
            "created_at TEXT NOT NULL, "
            "promo_code TEXT, "
            "subtotal REAL NOT NULL, "
            "discount REAL NOT NULL, "
            "total REAL NOT NULL"
            ")"
        )
        conn.execute(
            "CREATE TABLE IF NOT EXISTS order_items ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "order_ref TEXT NOT NULL, "
            "product_id INTEGER NOT NULL, "
            "product_name TEXT NOT NULL, "
            "unit_price REAL NOT NULL, "
            "quantity INTEGER NOT NULL, "
            "line_total REAL NOT NULL, "
            "FOREIGN KEY(order_ref) REFERENCES orders(order_ref)"
            ")"
        )
        return

    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS products ("
            "id INTEGER PRIMARY KEY, "
            "name TEXT NOT NULL, "
            "price NUMERIC(10,2) NOT NULL"
            ")"
        )
        cur.execute(
            "CREATE TABLE IF NOT EXISTS orders ("
            "order_ref TEXT PRIMARY KEY, "
            "created_at TEXT NOT NULL, "
            "promo_code TEXT, "
            "subtotal NUMERIC(10,2) NOT NULL, "
            "discount NUMERIC(10,2) NOT NULL, "
            "total NUMERIC(10,2) NOT NULL"
            ")"
        )
        cur.execute(
            "CREATE TABLE IF NOT EXISTS order_items ("
            "id BIGSERIAL PRIMARY KEY, "
            "order_ref TEXT NOT NULL REFERENCES orders(order_ref) ON DELETE CASCADE, "
            "product_id INTEGER NOT NULL, "
            "product_name TEXT NOT NULL, "
            "unit_price NUMERIC(10,2) NOT NULL, "
            "quantity INTEGER NOT NULL, "
            "line_total NUMERIC(10,2) NOT NULL"
            ")"
        )


def _seed_products(conn):
    if _is_sqlite():
        count = conn.execute("SELECT COUNT(*) FROM products").fetchone()[0]
        if count == 0:
            conn.executemany("INSERT INTO products(id,name,price) VALUES(?,?,?)", PRODUCTS)
            conn.commit()
        return

    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM products")
        if cur.fetchone()[0] == 0:
            cur.executemany("INSERT INTO products(id,name,price) VALUES(%s,%s,%s)", PRODUCTS)


def _fetch_products(conn):
    if _is_sqlite():
        rows = conn.execute("SELECT id,name,price FROM products ORDER BY id").fetchall()
        return [{"id": row["id"], "name": row["name"], "price": float(row["price"])} for row in rows]

    with conn.cursor() as cur:
        cur.execute("SELECT id,name,price FROM products ORDER BY id")
        rows = cur.fetchall()
    return [{"id": row[0], "name": row[1], "price": float(row[2])} for row in rows]


def _fetch_product_map(conn):
    return {product["id"]: product for product in _fetch_products(conn)}


def _fetch_orders(conn, limit=10):
    if _is_sqlite():
        order_rows = conn.execute(
            "SELECT order_ref, created_at, promo_code, subtotal, discount, total "
            "FROM orders ORDER BY created_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
        item_rows = conn.execute(
            "SELECT order_ref, product_id, product_name, unit_price, quantity, line_total "
            "FROM order_items ORDER BY id"
        ).fetchall()
        grouped = {}
        for item in item_rows:
            grouped.setdefault(item["order_ref"], []).append(
                {
                    "product_id": item["product_id"],
                    "product_name": item["product_name"],
                    "unit_price": float(item["unit_price"]),
                    "quantity": item["quantity"],
                    "line_total": float(item["line_total"]),
                }
            )
        return [
            {
                "order_ref": row["order_ref"],
                "created_at": row["created_at"],
                "promo_code": row["promo_code"],
                "subtotal": float(row["subtotal"]),
                "discount": float(row["discount"]),
                "total": float(row["total"]),
                "items": grouped.get(row["order_ref"], []),
            }
            for row in order_rows
        ]

    with conn.cursor() as cur:
        cur.execute(
            "SELECT order_ref, created_at, promo_code, subtotal, discount, total "
            "FROM orders ORDER BY created_at DESC LIMIT %s",
            (limit,),
        )
        order_rows = cur.fetchall()
        cur.execute(
            "SELECT order_ref, product_id, product_name, unit_price, quantity, line_total "
            "FROM order_items ORDER BY id"
        )
        item_rows = cur.fetchall()

    grouped = {}
    for item in item_rows:
        grouped.setdefault(item[0], []).append(
            {
                "product_id": item[1],
                "product_name": item[2],
                "unit_price": float(item[3]),
                "quantity": item[4],
                "line_total": float(item[5]),
            }
        )

    return [
        {
            "order_ref": row[0],
            "created_at": row[1],
            "promo_code": row[2],
            "subtotal": float(row[3]),
            "discount": float(row[4]),
            "total": float(row[5]),
            "items": grouped.get(row[0], []),
        }
        for row in order_rows
    ]


def _persist_order(conn, order_ref, created_at, promo_code, subtotal, discount, total, items):
    if _is_sqlite():
        conn.execute(
            "INSERT INTO orders(order_ref, created_at, promo_code, subtotal, discount, total) VALUES(?,?,?,?,?,?)",
            (order_ref, created_at, promo_code, subtotal, discount, total),
        )
        conn.executemany(
            "INSERT INTO order_items(order_ref, product_id, product_name, unit_price, quantity, line_total) VALUES(?,?,?,?,?,?)",
            [
                (
                    order_ref,
                    item["product_id"],
                    item["product_name"],
                    item["unit_price"],
                    item["quantity"],
                    item["line_total"],
                )
                for item in items
            ],
        )
        conn.commit()
        return

    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO orders(order_ref, created_at, promo_code, subtotal, discount, total) VALUES(%s,%s,%s,%s,%s,%s)",
            (order_ref, created_at, promo_code, subtotal, discount, total),
        )
        cur.executemany(
            "INSERT INTO order_items(order_ref, product_id, product_name, unit_price, quantity, line_total) VALUES(%s,%s,%s,%s,%s,%s)",
            [
                (
                    order_ref,
                    item["product_id"],
                    item["product_name"],
                    item["unit_price"],
                    item["quantity"],
                    item["line_total"],
                )
                for item in items
            ],
        )
    conn.commit()


def init_db():
    with _open_connection() as conn:
        _create_schema(conn)
        _seed_products(conn)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    started = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        duration_ms = (time.perf_counter() - started) * 1000
        logger.exception(
            "event=request_failed method=%s path=%s duration_ms=%.2f",
            request.method,
            request.url.path,
            duration_ms,
        )
        raise

    duration_ms = (time.perf_counter() - started) * 1000
    logger.info(
        "event=request_completed method=%s path=%s status_code=%s duration_ms=%.2f",
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    return response


@app.on_event("startup")
def startup():
    logger.info("event=startup_begin environment=%s database_engine=%s", APP_ENV, _database_engine())
    try:
        init_db()
    except Exception:
        logger.exception("event=startup_failed database_engine=%s", _database_engine())
        raise
    logger.info("event=startup_complete database_engine=%s", _database_engine())


@app.get("/health")
def health():
    return {"status": "ok", "environment": APP_ENV, "checked_at": datetime.now(timezone.utc).isoformat()}


@app.get("/ready")
def ready():
    try:
        with _open_connection() as conn:
            if _is_sqlite():
                conn.execute("SELECT 1")
            else:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
        return {"status": "ready"}
    except Exception as exc:
        logger.exception("event=readiness_failed database_engine=%s", _database_engine())
        raise HTTPException(status_code=503, detail=f"database unavailable: {exc}")


@app.get("/api/products")
def products():
    with _open_connection() as conn:
        return _fetch_products(conn)


@app.get("/api/orders")
def orders(limit: int = 10):
    with _open_connection() as conn:
        return _fetch_orders(conn, limit=limit)


@app.post("/api/orders")
def create_order(payload: CreateOrderRequest):
    if not payload.items:
        logger.warning("event=order_rejected reason=empty_items")
        raise HTTPException(status_code=400, detail="order must include at least one item")

    promo_code = (payload.promo_code or "").strip().upper() or None
    if promo_code and promo_code not in PROMOS:
        logger.warning("event=order_rejected reason=unknown_promo promo_code=%s", promo_code)
        raise HTTPException(status_code=400, detail=f"unknown promo code {promo_code}")

    discount_rate = PROMOS.get(promo_code, 0.0) if promo_code else 0.0
    created_at = datetime.now(timezone.utc).isoformat()
    order_ref = f"NC-{uuid.uuid4().hex[:8].upper()}"

    with _open_connection() as conn:
        product_map = _fetch_product_map(conn)
        items = []
        subtotal = 0.0

        for item in payload.items:
            product = product_map.get(item.id)
            if not product:
                logger.warning("event=order_rejected reason=unknown_product product_id=%s", item.id)
                raise HTTPException(status_code=400, detail=f"unknown product id {item.id}")

            line_total = round(float(product["price"]) * item.quantity, 2)
            subtotal += line_total
            items.append(
                {
                    "product_id": product["id"],
                    "product_name": product["name"],
                    "unit_price": float(product["price"]),
                    "quantity": item.quantity,
                    "line_total": line_total,
                }
            )

        subtotal = round(subtotal, 2)
        discount = round(subtotal * discount_rate, 2)
        total = round(subtotal - discount, 2)
        _persist_order(conn, order_ref, created_at, promo_code, subtotal, discount, total, items)

    logger.info(
        "event=order_created order_ref=%s item_count=%s promo_code=%s subtotal=%.2f discount=%.2f total=%.2f",
        order_ref,
        len(items),
        promo_code or "none",
        subtotal,
        discount,
        total,
    )

    return {
        "order_ref": order_ref,
        "created_at": created_at,
        "promo_code": promo_code,
        "subtotal": subtotal,
        "discount": discount,
        "total": total,
        "items": items,
    }


@app.get("/api/runtime")
def runtime():
    return {"environment": APP_ENV, "api_version": API_VERSION, "database_configured": bool(DATABASE_URL)}
