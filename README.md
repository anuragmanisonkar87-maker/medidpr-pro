# MediDPR Pro

A DPR (Detailed Project Report) filing studio for doctors and healthcare projects — clinics, nursing homes, hospitals, diagnostic centres, IVF, dialysis, dental, eye care, pharmacy and AYUSH.

Plain HTML + JavaScript. No build step, no backend required to run.

## Live site

https://anuragmanisonkar87-maker.github.io/medidpr-pro/ (GitHub Pages, deploys from `main`)

## Files

| File | What it is |
|---|---|
| `index.html` | Landing page (hero, challenge, workflow, financial simulator, specialities, funding routes, contact, FAQ) |
| `studio.html` | **Create My DPR** — 14-step wizard, no login, OTP-gated PDF download |
| `i18n.tsv` | English → Hindi → Marathi translations (tab-separated) used by `studio.html` |
| `samples/` | Fictional sample documents to test Smart Document Auto-Fill |
| `supabase/schema.sql` | Database tables + secure save function — run once in Supabase SQL Editor |
| `supabase/storage.sql` | Private photo bucket `dpr-images` (upload-only) — run after schema.sql |

## Run locally

Open `index.html` (or `studio.html`) in Chrome / Edge. Keep both files in the same folder.

## DPR Studio features

- 14 steps: Basic Information, Doctors & Management, Medical Services, Medical Equipment, Market Strategy, Staffing Plan, Cost & Financing, Financial Projections, Infrastructure, SWOT, Community Health Impact, Credit Standing, Licences & Site Images, Declaration & Report
- Question-by-question or show-all view; sidebar lists every step and its sections
- Live financial model: project cost, means of finance, 5-year P&L, DSCR, break-even, sensitivity
- Language switch: EN / HI / MR
- Smart Document Auto-Fill: up to 10 files at once — text PDFs (read in the browser with pdf.js), JSON, TXT
- Email + mobile OTP required for **every** report generation / PDF download
- One-click PDF download (html2pdf.js), saved to the Downloads folder

## Saving data to Supabase

All DPR answers and home-page inquiries can be stored in Supabase.

1. Supabase → **SQL Editor** → paste `supabase/schema.sql` → **Run**.
2. Supabase → **Project Settings → API** → copy **Project URL** and **anon public key**.
3. Put them in **both** `studio.html` and `index.html`:
   ```js
   const SUPABASE_URL='https://xxxx.supabase.co';
   const SUPABASE_ANON_KEY='eyJ...';
   ```
4. View data in Supabase → **Table Editor** → `dpr_submissions`, `inquiries`, or the `dpr_overview` view.

What gets saved:

| Table | When | Contents |
|---|---|---|
| `dpr_submissions` | Every change (1.5 s after typing), then status `generated` and `downloaded` | All 14 steps as `form_data` (JSON) + quick columns: facility, contact, email, phone, city, project cost, loan, DSCR, verified flags, step, download count |
| `inquiries` | Home-page contact form | Name, organisation, email, phone, city, speciality, purpose |
| Storage `dpr-images` | When a Step 13 photo is chosen | Logo, building, equipment/OT, team photos — resized to max 1600 px JPEG, saved as `<submission-id>/<slot>-<time>.jpg`; path stored in `form_data.images` |

Security: the website can only **write**. `dpr_submissions` is written through the `save_dpr()` function using a random per-browser token; nobody can read data with the anon key. Photos go to a private bucket: the website can upload but never list or read them.

## Configuration (`studio.html`)

Search for these constants near the OTP section:

```js
// Email OTP via EmailJS (current)
const EMAILJS_PUBLIC_KEY  = '...';
const EMAILJS_SERVICE_ID  = '...';
const EMAILJS_TEMPLATE_ID = '...';   // template needs To Email = {{to_email}} and {{otp}} in the body

// OR email OTP via Supabase Auth (more secure — code is checked server-side)
const SUPABASE_URL      = '';
const SUPABASE_ANON_KEY = '';         // anon public key only — never the service_role key
const EMAIL_OTP_PROVIDER = 'emailjs'; // or 'supabase'

// Mobile OTP (and/or email) via your own backend
const OTP_API = '';                   // POST {OTP_API}/send {channel,to}; POST {OTP_API}/verify {channel,to,code} -> {ok}
```

With nothing configured, OTP runs in **demo mode** (the code is shown on screen).

> EmailJS checks the code in the browser, so it is fine for testing / low-risk use. Use Supabase or `OTP_API` for production.

## Not yet connected

- Mobile OTP SMS provider (MSG91 / Twilio) — demo mode
- OCR for photos / scanned PDFs (needs a server)
- Payment gateway (removed by design)

## Notes

- Sample documents in `samples/` are fictional and marked "SAMPLE – FOR SOFTWARE TESTING ONLY".
- Financial projections are estimates; reports should be reviewed by a Chartered Accountant before submission to a bank.
