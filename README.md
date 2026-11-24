# DocpreneurFin Pro

A DPR (Detailed Project Report) filing studio for doctors and healthcare projects — clinics, nursing homes, hospitals, diagnostic centres, IVF, dialysis, dental, eye care, pharmacy and AYUSH.

Plain HTML + JavaScript. No build step, no backend required to run.

## Live site

https://anuragmanisonkar87-maker.github.io/medidpr-pro/ (GitHub Pages, deploys from `main`)

## Files

| File | What it is |
|---|---|
| `index.html` | Landing page (hero, challenge, workflow, financial simulator, specialities, funding routes, contact, FAQ) |
| `studio.html` | **Create My DPR** — 8-step wizard (mandatory fields + optional extras), no login, OTP-gated PDF download |
| `i18n.tsv` | English → Hindi → Marathi translations (tab-separated) used by `studio.html` |
| `samples/` | Fictional sample documents to test Smart Document Auto-Fill |
| `samples/images/` | 4 sample photos (logo, building, OT equipment, team) to test Step 13 uploads |
| `supabase/schema.sql` | Database tables + secure save function — run once in Supabase SQL Editor |
| `supabase/storage.sql` | Private photo bucket `dpr-images` (upload-only) — run after schema.sql |
| `supabase/resume.sql` | Resume an old application by its code — `load_dpr()` function — run after schema.sql |
| `supabase/step_tables.sql` | One table per form step (19 tables) filled automatically by a trigger + `dpr_full_view` — run after storage.sql |

## Run locally

Open `index.html` (or `studio.html`) in Chrome / Edge. Keep both files in the same folder.

## DPR Studio features

- 8 steps: Facility & Applicant, Doctors & Team, Services & Capacity, Market & SWOT, Equipment & Staff, Premises & Project Cost, Projections & Credit, Declaration & Report. Each step shows required fields (*) first; extra details sit under "More details (optional)". Save & Continue checks required fields.
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
4. View data in Supabase → **Table Editor** → `dpr_applications`, `inquiries`, or the `dpr_overview` view.

What gets saved:

| Table | When | Contents |
|---|---|---|
| `dpr_applications` | Every change (1.5 s after typing), then status `generated` and `downloaded` | All steps as `form_data` (JSON) + quick columns: facility, contact, email, phone, city, project cost, loan, DSCR, verified flags, step, download count |
| `inquiries` | Home-page contact form | Name, organisation, email, phone, city, speciality, purpose |
| Storage `dpr-images` | When a Step 13 photo is chosen | Logo, building, equipment/OT, team photos — resized to max 1600 px JPEG, saved as `<submission-id>/<slot>-<time>.jpg`; path stored in `form_data.images` |

Per-step tables (filled automatically from every save):

| Step | Table(s) |
|---|---|
| 1 Basic Information | `dpr_step01_basic_info` |
| 2 Doctors & Management | `dpr_step02_team_profile`, `dpr_step02_members` (one row per person) |
| 3 Medical Services | `dpr_step03_medical_services` |
| 4 Medical Equipment | `dpr_step04_equipment_vendor`, `dpr_step04_equipment` (one row per item) |
| 5 Market Strategy | `dpr_step05_market` |
| 6 Staffing Plan | `dpr_step06_staffing_plan`, `dpr_step06_staff` (one row per category) |
| 7 Cost & Financing | `dpr_step07_cost_finance` |
| 8 Financial Projections | `dpr_step08_projections` (one row per year), `dpr_step08_viability` |
| 9 Infrastructure | `dpr_step09_infrastructure` |
| 10 SWOT | `dpr_step10_swot` |
| 11 Community Health Impact | `dpr_step11_community_impact` |
| 12 Credit Standing | `dpr_step12_credit` |
| 13 Licences & Site Images | `dpr_step13_licences`, `dpr_step13_images` |
| 14 Declaration & Report | `dpr_step14_declaration` |

`dpr_full_view` joins the key columns of all steps into one row per DPR.

Security: the website can only **write**. `dpr_applications` is written through the `save_dpr()` function using a random per-browser token; nobody can read data with the anon key. Photos go to a private bucket: the website can upload but never list or read them.

## Resume an old application

Every application shows a private **application code** (`XXXX-XXXX-XXXX-XXXX`) at the top of the form, with **Copy code** and **Copy resume link** buttons.

- **Resume old application** → enter the code → all answers and the last step are loaded, and further edits update the same application.
- A resume link (`studio.html?resume=CODE`) opens it directly.
- Only someone with the code can load or change that application (`load_dpr()` returns just that one record). Photos uploaded earlier stay in storage; choose them again to show them in the PDF.

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


## Delete an application

Run `supabase/delete.sql` once. The **🗑 Delete application** button (in the application-code bar) calls `delete_dpr(id, code)`: it deletes that one application (and its per-step rows) only when the code matches, removes its photos, and records the id in `dpr_deleted` so an open tab can't re-create it.


## Database: Application Master (`application_id`)

`supabase/migrate_application_master.sql` is the one script to run (Supabase → SQL Editor). It works on an existing database (migrates it without losing data) and on an empty one (full install). It is safe to re-run.

- **Master table** `dpr_applications` — one row per application, primary key **`application_id`** (uuid).
- **Sub-tables** `dpr_step01_…` – `dpr_step14_…` (19 tables) — every row has `application_id` → `dpr_applications(application_id)` **ON DELETE CASCADE ON UPDATE CASCADE**.
- **Create / update:** the website calls `save_dpr(application_id, code, …)`; a trigger fills all sub-tables in the same transaction.
- **Fetch everything for one application:** `select public.get_application('<application_id>');` → master row + every sub-table as JSON (admin only).
- **Delete everything for one application:** `select public.delete_application('<application_id>');` (admin) or the website's 🗑 Delete button (`delete_dpr`, needs the code). Sub-table rows go automatically via cascade.
- Website users resume with their code via `load_dpr(code)`.
