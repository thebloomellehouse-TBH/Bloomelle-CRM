# Bloomelle CRM (leads, champ onboarding, round-robin allocation, champ app)

Frontend: `index.html` + `config.js` (GitHub Pages). Backend: Supabase (database, login, private ID storage, lead webhook).

## 1. Supabase (free tier is enough to start)
1. Create a project at supabase.com. Authentication > Providers > Email: turn OFF "Confirm email".
2. Database > Extensions: enable `pg_cron`. SQL Editor: paste and run `supabase/schema.sql`.
3. Project Settings > API: copy the URL and anon key into `config.js`.
4. Authentication > Users > Add user (your executive login). Then run in SQL Editor:
   `insert into staff select id from auth.users where email='YOU@EMAIL';`

## 2. GitHub Pages
Upload `index.html` and `config.js` to your repo, Settings > Pages > main branch. Open the URL: executives see the CRM, champs see the champ app.

## 3. Lead intake function
```
npm i -g supabase && supabase login && supabase link --project-ref YOUR_REF
supabase functions deploy lead-intake --no-verify-jwt
supabase secrets set AUTO_ASSIGN=1 GOOGLE_KEY=choose-a-secret META_VERIFY_TOKEN=choose-a-token WA_VERIFY_TOKEN=choose-a-token META_APP_SECRET=... META_PAGE_TOKEN=...
```
Webhook URL for every source: `https://YOUR_REF.supabase.co/functions/v1/lead-intake?source=website|meta|google|whatsapp`
(AUTO_ASSIGN=1 offers a lead to a champ at once if service and area match; otherwise it waits for the executive.)

- **Website:** POST JSON `{name, phone, email, service, area}`:
  `fetch(URL+"?source=website",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(Object.fromEntries(new FormData(form)))})`
  Add a hidden field `website_url` that real users never fill (spam trap).
- **Meta lead ads:** developers.facebook.com app > Webhooks > Page > subscribe to `leadgen`; callback URL with `?source=meta`, verify token = META_VERIFY_TOKEN; page access token with leads_retrieval permission. Form questions should be named `full_name`, `phone_number`, `email`, `city`, `service`.
- **Google Ads lead forms:** Lead form extension > Webhook: URL with `?source=google`, key = GOOGLE_KEY.
- **WhatsApp Cloud API:** Meta app > WhatsApp > Configuration: callback URL with `?source=whatsapp`, verify token = WA_VERIFY_TOKEN, subscribe to `messages`. A customer's first message creates a lead.
- Instagram DMs / Facebook Messenger can be added the same way later.

## Security notes
- Never put the `service_role` key in `index.html` or `config.js`.
- Aadhaar: only the last 4 digits are stored; the document sits in a private bucket visible to the owner and executives. Add a privacy notice and check DPDP Act obligations.
