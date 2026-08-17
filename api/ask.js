// ===========================================================================
// /api/ask  — the only server the app needs
//
// The Anthropic key lives here and never reaches a browser. Anyone who can
// read your client bundle can read anything you put in it, so a key in the
// front end is a key you have given away.
// ===========================================================================

// Two models. Most homestead questions are recall and judgement, which the
// smaller one handles well. Weather questions need the search tool, and the
// search is what actually costs money: a per-search fee plus several thousand
// tokens of retrieved page content folded into the input.
const MODEL_FAST = 'claude-haiku-4-5-20251001';
const MODEL_FULL = 'claude-sonnet-4-6';
const MAX_TOKENS = 1000;

// Only genuinely live information needs the web. Frost dates, planting
// windows, spacings and canning times are all computed locally, so a question
// about any of those must never trigger a search.
const NEEDS_WEB = /\b(weather|forecast|rain|raining|rainfall|temperature|degrees|freeze|freezing|frost tonight|storm|wind|tonight|tomorrow|this weekend|cold snap|heat wave|drought|humidity)\b/i;

// Diagnosis and anything with a health or safety edge gets the larger model.
const NEEDS_CARE = /\b(dying|died|dead|wilting|rot|rotting|blight|disease|sick|pest|infest|mold|mould|why|diagnos|spots?|yellow|curl|holes?|safe|botulism|poison|bad|off feed|not eating|limping|bloat|vet|straining|bleeding|prolapse)\b/i;

function route(question) {
  const q = String(question || '');
  const web = NEEDS_WEB.test(q);
  const care = NEEDS_CARE.test(q);
  return {
    web,
    model: (web || care || q.length > 160) ? MODEL_FULL : MODEL_FAST,
  };
}
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

    // The client does not get to choose the model, the token budget, or
    // whether to search. Those are cost decisions and they belong here.
    const plan = route(body.question);
    const payload = {
      model: plan.model,
      max_tokens: MAX_TOKENS,
      messages: msgs,
      tools: plan.web ? [{ type: 'web_search_20250305', name: 'web_search' }] : undefined,
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

    // Visible in Vercel's runtime logs, so you can see what the mix actually
    // is in the wild rather than guessing at it.
    console.log(JSON.stringify({
      model: plan.model, web: plan.web,
      in_chars: size, status: r.status,
      usage: data && data.usage ? data.usage : null,
    }));

    // TODO once Supabase is wired: record usage against the stead and refuse
    // when the plan quota is spent. The thermometer in the client is a
    // courtesy; this is where the limit is actually enforced.

    return res.status(r.status).json(data);
  } catch (e) {
    return res.status(502).json({ error: { message: 'Advisor is unreachable right now.' } });
  }
}
