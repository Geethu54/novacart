const defaultApiBase = window.location.protocol === 'file:' ? 'http://localhost:8080/api' : '/api';
const apiBase = window.NOVACART_API_BASE || defaultApiBase;

const statusEl = document.getElementById('status');
const productsEl = document.getElementById('products');
const cartItemsEl = document.getElementById('cart-items');
const cartEmptyEl = document.getElementById('cart-empty');
const cartTotalEl = document.getElementById('cart-total');
const cartCountEl = document.getElementById('cart-count');
const clearCartButton = document.getElementById('clear-cart');
const openCheckoutButton = document.getElementById('open-checkout');
const checkoutBackdropEl = document.getElementById('checkout-backdrop');
const checkoutDrawerEl = document.getElementById('checkout-drawer');
const closeCheckoutButton = document.getElementById('close-checkout');
const checkoutSubtotalEl = document.getElementById('checkout-subtotal');
const checkoutDiscountEl = document.getElementById('checkout-discount');
const checkoutTotalEl = document.getElementById('checkout-total');
const promoFormEl = document.getElementById('promo-form');
const promoCodeEl = document.getElementById('promo-code');
const promoMessageEl = document.getElementById('promo-message');
const placeOrderButton = document.getElementById('place-order');
const orderConfirmationEl = document.getElementById('order-confirmation');
const refreshOrdersButton = document.getElementById('refresh-orders');
const orderHistoryListEl = document.getElementById('order-history-list');

const cart = new Map();
let products = [];
let promo = { code: '', discountRate: 0, label: 'No promo applied' };

function setStatus(message, tone = 'info') {
  statusEl.textContent = message;
  statusEl.dataset.tone = tone;
}

function money(value) {
  return `€${value.toFixed(2)}`;
}

function calculateSubtotal() {
  return [...cart.values()].reduce((sum, item) => sum + item.quantity * item.price, 0);
}

function calculateDiscount(subtotal) {
  return subtotal * promo.discountRate;
}

function updateCheckoutSummary() {
  const subtotal = calculateSubtotal();
  const discount = calculateDiscount(subtotal);
  const total = subtotal - discount;

  checkoutSubtotalEl.textContent = money(subtotal);
  checkoutDiscountEl.textContent = `-${money(discount)}`;
  checkoutTotalEl.textContent = money(total);
  promoMessageEl.textContent = promo.code
    ? `${promo.code.toUpperCase()} applied. ${promo.label}`
    : 'Try `DEVOPS10`, `NOVA15`, or `SHIPFREE`.';
}

function openCheckout() {
  checkoutBackdropEl.hidden = false;
  checkoutDrawerEl.classList.add('is-open');
  checkoutDrawerEl.setAttribute('aria-hidden', 'false');
  orderConfirmationEl.hidden = true;
  orderConfirmationEl.innerHTML = '';
  loadOrderHistory();
  updateCheckoutSummary();
}

function closeCheckout() {
  checkoutBackdropEl.hidden = true;
  checkoutDrawerEl.classList.remove('is-open');
  checkoutDrawerEl.setAttribute('aria-hidden', 'true');
}

function showOrderConfirmation(reference, total) {
  orderConfirmationEl.hidden = false;
  orderConfirmationEl.innerHTML = `
    <strong>Order placed</strong>
    <p>Reference ${reference}. We captured a test order for ${money(total)} and saved it in the database.</p>
  `;
}

function renderOrderHistory(orders) {
  orderHistoryListEl.innerHTML = '';

  if (orders.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'order-history-empty';
    empty.textContent = 'No saved orders yet. Place one to make it stick.';
    orderHistoryListEl.append(empty);
    return;
  }

  orders.forEach((order) => {
    const entry = document.createElement('li');
    entry.className = 'order-history-item';

    const summary = document.createElement('div');
    summary.className = 'order-history-summary';

    const title = document.createElement('strong');
    title.textContent = order.order_ref;

    const meta = document.createElement('span');
    const itemCount = order.items.reduce((sum, item) => sum + item.quantity, 0);
    meta.textContent = `${itemCount} item${itemCount === 1 ? '' : 's'} · ${money(order.total)} · ${order.promo_code ? order.promo_code : 'no promo'}`;

    summary.append(title, meta);

    const timestamp = document.createElement('time');
    timestamp.dateTime = order.created_at;
    timestamp.textContent = new Date(order.created_at).toLocaleString();

    entry.append(summary, timestamp);
    orderHistoryListEl.append(entry);
  });
}

function loadOrderHistory() {
  fetch(`${apiBase}/orders?limit=5`)
    .then(async (response) => {
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      return response.json();
    })
    .then(renderOrderHistory)
    .catch(() => {
      orderHistoryListEl.innerHTML = '';
      const errorItem = document.createElement('li');
      errorItem.className = 'order-history-empty';
      errorItem.textContent = 'Could not load saved orders right now.';
      orderHistoryListEl.append(errorItem);
    });
}

function updateCartSummary() {
  const entries = [...cart.values()];
  const count = entries.reduce((sum, item) => sum + item.quantity, 0);
  const total = entries.reduce((sum, item) => sum + item.quantity * item.price, 0);

  cartCountEl.textContent = `${count} item${count === 1 ? '' : 's'}`;
  cartTotalEl.textContent = money(total);
  cartEmptyEl.hidden = entries.length > 0;
  cartItemsEl.innerHTML = '';
  updateCheckoutSummary();

  entries.forEach((item) => {
    const row = document.createElement('li');
    row.className = 'cart-item';

    const label = document.createElement('div');
    label.className = 'cart-item-label';

    const name = document.createElement('strong');
    name.textContent = item.name;

    const details = document.createElement('span');
    details.textContent = `${item.quantity} × ${money(item.price)} = ${money(item.quantity * item.price)}`;

    label.append(name, details);

    const controls = document.createElement('div');
    controls.className = 'cart-item-controls';

    const removeButton = document.createElement('button');
    removeButton.className = 'ghost-button';
    removeButton.type = 'button';
    removeButton.textContent = 'Remove one';
    removeButton.addEventListener('click', () => {
      const nextQuantity = item.quantity - 1;
      if (nextQuantity <= 0) {
        cart.delete(item.id);
      } else {
        cart.set(item.id, { ...item, quantity: nextQuantity });
      }
      updateCartSummary();
      syncProductButtons();
    });

    controls.append(removeButton);
    row.append(label, controls);
    cartItemsEl.append(row);
  });
}

function syncProductButtons() {
  document.querySelectorAll('[data-product-id]').forEach((button) => {
    const productId = Number(button.dataset.productId);
    const quantity = cart.get(productId)?.quantity ?? 0;

    if (button.dataset.action === 'decrement') {
      button.disabled = quantity === 0;
      return;
    }

    if (button.dataset.action === 'quantity') {
      button.textContent = quantity;
      return;
    }

    if (button.dataset.action === 'increment') {
      button.textContent = quantity > 0 ? `+ Add more` : '+ Add';
      button.classList.toggle('is-active', quantity > 0);
      return;
    }
  });
}

function renderProducts(items) {
  productsEl.innerHTML = '';
  items.forEach((product) => {
    const card = document.createElement('article');
    card.className = 'product-card';

    const title = document.createElement('h3');
    title.textContent = product.name;

    const price = document.createElement('p');
    price.className = 'price';
    price.textContent = money(product.price);

    const description = document.createElement('p');
    description.className = 'product-copy';
    description.textContent = 'Use the steppers to build a tiny order and watch the summary react.';

    const controls = document.createElement('div');
    controls.className = 'product-stepper';

    const decrementButton = document.createElement('button');
    decrementButton.className = 'stepper-button';
    decrementButton.type = 'button';
    decrementButton.dataset.productId = product.id;
    decrementButton.dataset.action = 'decrement';
    decrementButton.textContent = '−';
    decrementButton.addEventListener('click', () => {
      const current = cart.get(product.id);
      if (!current) {
        return;
      }
      const nextQuantity = current.quantity - 1;
      if (nextQuantity <= 0) {
        cart.delete(product.id);
      } else {
        cart.set(product.id, { ...product, quantity: nextQuantity });
      }
      updateCartSummary();
      syncProductButtons();
    });

    const quantityLabel = document.createElement('span');
    quantityLabel.className = 'stepper-count';
    quantityLabel.dataset.productId = product.id;
    quantityLabel.dataset.action = 'quantity';
    quantityLabel.textContent = '0';

    const incrementButton = document.createElement('button');
    incrementButton.className = 'stepper-button add-button';
    incrementButton.type = 'button';
    incrementButton.dataset.productId = product.id;
    incrementButton.dataset.action = 'increment';
    incrementButton.textContent = '+ Add';
    incrementButton.addEventListener('click', () => {
      const current = cart.get(product.id);
      const nextQuantity = (current?.quantity ?? 0) + 1;
      cart.set(product.id, { ...product, quantity: nextQuantity });
      updateCartSummary();
      syncProductButtons();
    });

    controls.append(decrementButton, quantityLabel, incrementButton);
    card.append(title, description, price, controls);
    productsEl.append(card);
  });

  syncProductButtons();
}

clearCartButton.addEventListener('click', () => {
  cart.clear();
  updateCartSummary();
  syncProductButtons();
});

openCheckoutButton.addEventListener('click', openCheckout);
closeCheckoutButton.addEventListener('click', closeCheckout);
checkoutBackdropEl.addEventListener('click', closeCheckout);
refreshOrdersButton.addEventListener('click', loadOrderHistory);

promoFormEl.addEventListener('submit', (event) => {
  event.preventDefault();
  const raw = promoCodeEl.value.trim().toUpperCase();
  const presets = {
    DEVOPS10: { discountRate: 0.1, label: '10% off your test order.' },
    NOVA15: { discountRate: 0.15, label: '15% off for the NovaCart crowd.' },
    SHIPFREE: { discountRate: 0.05, label: 'A small bonus discount to simulate free shipping.' },
  };

  if (!raw) {
    promo = { code: '', discountRate: 0, label: 'No promo applied' };
    promoMessageEl.textContent = 'Enter a promo code first.';
    updateCheckoutSummary();
    return;
  }

  if (!presets[raw]) {
    promoMessageEl.textContent = `${raw} is not a valid promo code. Try DEVOPS10, NOVA15, or SHIPFREE.`;
    promo = { code: '', discountRate: 0, label: 'No promo applied' };
    updateCheckoutSummary();
    return;
  }

  promo = { code: raw, ...presets[raw] };
  updateCheckoutSummary();
});

placeOrderButton.addEventListener('click', () => {
  const count = [...cart.values()].reduce((sum, item) => sum + item.quantity, 0);
  if (count === 0) {
    setStatus('Add something to the cart before placing a test order.', 'error');
    return;
  }

  const items = [...cart.values()].map((item) => ({ id: item.id, quantity: item.quantity }));

  placeOrderButton.disabled = true;
  placeOrderButton.textContent = 'Saving order...';

  fetch(`${apiBase}/orders`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      items,
      promo_code: promo.code || null,
    }),
  })
    .then(async (response) => {
      if (!response.ok) {
        const detail = await response.text();
        throw new Error(detail || `HTTP ${response.status}`);
      }
      return response.json();
    })
    .then((order) => {
      cart.clear();
      updateCartSummary();
      syncProductButtons();
      promo = { code: '', discountRate: 0, label: 'No promo applied' };
      promoCodeEl.value = '';
      updateCheckoutSummary();
      showOrderConfirmation(order.order_ref, order.total);
      loadOrderHistory();
      setStatus(
        `Test order placed for ${count} item${count === 1 ? '' : 's'}. Reference ${order.order_ref}.`,
        'success'
      );
    })
    .catch((error) => {
      setStatus(`Order could not be saved. ${error.message}`, 'error');
    })
    .finally(() => {
      placeOrderButton.disabled = false;
      placeOrderButton.textContent = 'Place test order';
    });
});

setStatus('Loading products...');
loadOrderHistory();

fetch(`${apiBase}/products`)
  .then(async (response) => {
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return response.json();
  })
  .then((items) => {
    products = items;
    renderProducts(products);
    updateCartSummary();
    setStatus(`${items.length} products available`, 'success');
  })
  .catch((error) => {
    productsEl.innerHTML = '';
    setStatus(
      `Unable to load products from ${apiBase}. Start the backend and reload. (${error.message})`,
      'error'
    );
  });
