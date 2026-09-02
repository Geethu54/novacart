import os
import tempfile

fd, dbpath = tempfile.mkstemp(suffix=".db"); os.close(fd)
os.environ["DATABASE_URL"] = f"sqlite:///{dbpath}"

from fastapi.testclient import TestClient
from app.main import app

def test_health_products_and_orders_persist():
    with TestClient(app) as c:
        assert c.get('/health').status_code == 200
        assert c.get('/ready').status_code == 200
        r = c.get('/api/products')
        assert r.status_code == 200
        products = r.json()
        assert len(products) >= 3

        order_response = c.post(
            '/api/orders',
            json={
                'items': [{'id': products[0]['id'], 'quantity': 2}],
                'promo_code': 'DEVOPS10',
            },
        )
        assert order_response.status_code == 200
        order = order_response.json()
        assert order['order_ref'].startswith('NC-')
        assert order['total'] < order['subtotal']

        saved_orders = c.get('/api/orders').json()
        assert len(saved_orders) == 1
        assert saved_orders[0]['order_ref'] == order['order_ref']
        assert saved_orders[0]['items'][0]['quantity'] == 2
