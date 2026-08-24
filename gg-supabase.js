// Games Grid — Supabase connection
// Publishable key only. Never put the service_role key in this file.
window.GG_SUPABASE = {
  url: "https://mrbpcfcnrsuqrvxhuhxb.supabase.co",
  key: "sb_publishable_OCxtFW-PnSez2nzIQGPDEg_hTdmtjvP"
};

// Thin REST wrapper — no SDK, so pages stay fast and offline-safe.
window.GG = (function () {
  const { url, key } = window.GG_SUPABASE;
  const base = url.replace(/\/$/, "");
  let token = null;

  // A staff token expires after an hour. Reading its own expiry lets public
  // pages fall back to the publishable key instead of failing with "JWT expired".
  function expired(t) {
    try {
      const payload = JSON.parse(atob(t.split(".")[1]));
      return !payload.exp || payload.exp * 1000 <= Date.now() + 5000;
    } catch (e) {
      return true;
    }
  }

  function activeToken() {
    if (!token) {
      try { token = sessionStorage.getItem("ggToken") || null; } catch (e) { /* storage blocked */ }
    }
    if (token && expired(token)) {
      token = null;
      try { sessionStorage.removeItem("ggToken"); } catch (e) {}
    }
    return token;
  }

  function headers(extra) {
    return Object.assign({
      apikey: key,
      Authorization: "Bearer " + (activeToken() || key),
      "Content-Type": "application/json"
    }, extra || {});
  }

  async function req(path, opts) {
    const res = await fetch(base + path, Object.assign({}, opts, { headers: headers(opts && opts.headers) }));
    const text = await res.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch (e) { body = text; }
    if (!res.ok) {
      const msg = (body && (body.message || body.error_description || body.error)) || res.statusText;
      // A rejected token is never useful again — drop it and retry anonymously
      // so a stale admin session can't break the public site.
      if (res.status === 401 && token && /jwt|token/i.test(String(msg))) {
        token = null;
        try { sessionStorage.removeItem("ggToken"); } catch (e) {}
        const retry = await fetch(base + path, Object.assign({}, opts, { headers: headers(opts && opts.headers) }));
        const rt = await retry.text();
        let rb = null;
        try { rb = rt ? JSON.parse(rt) : null; } catch (e) { rb = rt; }
        if (retry.ok) return rb;
        throw new Error((rb && (rb.message || rb.error)) || retry.statusText);
      }
      throw new Error(msg);
    }
    return body;
  }

  return {
    setToken(t) { token = t; },
    getToken() { return activeToken(); },
    signedIn() { return !!activeToken(); },

    // PostgREST select: GG.select('games', 'available=eq.true&order=sort_order')
    select(table, query) {
      return req("/rest/v1/" + table + (query ? "?" + query : ""));
    },

    insert(table, rows) {
      return req("/rest/v1/" + table, {
        method: "POST",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify(rows)
      });
    },

    update(table, query, patch) {
      return req("/rest/v1/" + table + "?" + query, {
        method: "PATCH",
        headers: { Prefer: "return=representation" },
        body: JSON.stringify(patch)
      });
    },

    remove(table, query) {
      return req("/rest/v1/" + table + "?" + query, { method: "DELETE" });
    },

    // Database function: GG.rpc('day_availability', {p_kind:'ps5', p_date:'2026-08-22', p_hours:1})
    rpc(fn, args) {
      return req("/rest/v1/rpc/" + fn, {
        method: "POST",
        body: JSON.stringify(args || {})
      });
    },

    async signIn(email, password) {
      const res = await fetch(base + "/auth/v1/token?grant_type=password", {
        method: "POST",
        headers: { apikey: key, "Content-Type": "application/json" },
        body: JSON.stringify({ email, password })
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error_description || body.msg || "Sign in failed");
      token = body.access_token;
      try { sessionStorage.setItem("ggToken", token); } catch (e) {}
      return body;
    },

    signOut() {
      token = null;
      try { sessionStorage.removeItem("ggToken"); } catch (e) {}
    },

    restore() {
      token = null;
      return activeToken();
    },

    async me() {
      if (!activeToken()) return null;
      try {
        const rows = await req("/rest/v1/staff?select=id,full_name,role&limit=1");
        return rows && rows[0] ? rows[0] : null;
      } catch (e) { return null; }
    },

    money(paise) {
      return "₹" + Math.round((paise || 0) / 100).toLocaleString("en-IN");
    },
    toPaise(rupees) {
      return Math.round(Number(rupees || 0) * 100);
    }
  };
})();
