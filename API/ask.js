// ===========================================================================
// /api/ask  — the only server the app needs
//
// The Anthropic key lives here and never reaches a browser. Anyone who can
// read your client bundle can read anything you put in it, so a key in the
// front end is a key you have given away.
// ===========================================================================

const MODEL = 'claude-sonnet-4-6';
const MAX_TOKENS = 1000;
const MAX_PROMPT = 12000;          // characters, generous for the profile block

// Rate limiting in module scope is per warm instance only. It stops a runaway
// loop, not a determined abuser. For real limits put Vercel KV or Upstash
// behind this, keyed on the signed-in user, and enforce the plan quota there.
const hits = new Map();
const WINDOW_MS = 60_000;
const PER_WINDOW = 8;

function limited(key) {
  const now = Date.now();
  const rec = hits.get(key) || { n: 0, until: now + WINDOW_MS };
  if (now > rec.until) { rec.n = 0; rec.until = now + WINDOW_MS; }
  rec.n += 1;
  hits.set(key, rec);
  if (hits.size > 5000) hits.clear();
  return rec.n > PER_WINDOW;
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: { message: 'POST only' } });
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    return res.status(500).json({ error: { message: 'ANTHROPIC_API_KEY is not set on the server' } });
  }

  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  if (limited(ip)) {
    return res.status(429).json({ error: { message: 'Too many questions in a short time. Wait a minute.' } });
  }

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : (req.body || {});
    const msgs = Array.isArray(body.messages) ? body.messages : [];
    if (!msgs.length) return res.status(400).json({ error: { message: 'no messages' } });

    const size = JSON.stringify(msgs).length;
    if (size > MAX_PROMPT) {
      return res.status(413).json({ error: { message: 'That question carried too much context.' } });
    }

    // The client does not get to choose the model or the token budget. Those
    // are cost decisions and they belong on this side of the wire.
    const payload = {
      model: MODEL,
      max_tokens: MAX_TOKENS,
      messages: msgs,
      tools: body.tools ? [{ type: 'web_search_20250305', name: 'web_search' }] : undefined,
    };

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': process.env.ANTHROPIC_API_KEY,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify(payload),
    });

    const data = await r.json();

    // TODO once Supabase is wired: record usage against the stead and refuse
    // when the plan quota is spent. The thermometer in the client is a
    // courtesy; this is where the limit is actually enforced.

    return res.status(r.status).json(data);
  } catch (e) {
    return res.status(502).json({ error: { message: 'Advisor is unreachable right now.' } });
  }
}
