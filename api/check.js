// TEMPORARY diagnostic. Delete this file once the advisor works.
// Reports only names and lengths. It never returns the secret itself.
export default function handler(req, res) {
  const key = process.env.ANTHROPIC_API_KEY;
  const related = Object.keys(process.env)
    .filter(k => /ANTHROPIC|API|KEY|SK/i.test(k))
    .sort();

  res.status(200).json({
    exact_name_found: typeof key === 'string',
    length: key ? key.length : 0,
    looks_like_a_key: key ? key.startsWith('sk-ant-') : false,
    has_whitespace: key ? key !== key.trim() : false,
    similar_names_present: related,
    vercel_env: process.env.VERCEL_ENV || 'unknown',
  });
}
