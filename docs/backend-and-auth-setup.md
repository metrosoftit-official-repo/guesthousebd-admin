# Backend and Guest Auth Setup

## Admin UI

The GuesthouseBD operations panel is available at `/admin`. It requires Firebase sign-in and an active non-customer tenant membership before rendering workspace data. Stays, reservations, low-stock alerts, and incident counts use tenant-scoped RLS queries; reservations and safety/inventory details are only queried for roles that are allowed to read them. The app gate is a usability layer: the database RLS policies remain the actual authorization boundary.

The current panel is read-only. Listing CRUD, booking state changes, payments, sales writes, team provisioning, and shift management still need dedicated validated server/RPC workflows; do not grant broader browser write access to speed these up.

## Supabase Migrations

The migrations are imperative, timestamped, forward-only scripts under `supabase/migrations/`:

- `platform_foundation`: tenant memberships and staff roles, profiles, public site pages/settings/feature flags, private audit log, and row-level security helpers.
- `marketplace_operations`: destinations, listings, amenities, rates, date-based stay inventory, bookings, payment records, reviews, stock/sales, guard shifts/incidents, and inquiries.
- `public_catalog_views_and_functions`: RLS-invoker public catalog/calendar/review views, Firebase guest profile bootstrap, idempotent booking holds, and an expiry function.

Never edit a migration after it has been applied to any shared database. Generate a new one with `npx supabase migration new <descriptive_name>` for every later table, view, trigger, policy, or procedure change.

Run the Docker-free embedded-Postgres migration/security smoke suite with:

```powershell
npm run test:migrations
```

It applies the migrations to PGlite, checks that every public table has RLS enabled, creates a Firebase guest profile, verifies booking idempotency and inventory holds, checks guest-to-guest booking isolation and anonymous access, expires a hold as `service_role`, and confirms suspended tenants disappear from public listings.

To test a fresh local database (requires Docker and the Supabase CLI):

```powershell
npx supabase start
npx supabase db reset
npx supabase migration list --local
```

Docker was unavailable during setup, so the full Supabase local stack was not started. The PGlite smoke suite passed. The connected hosted database was inspected and had no public tables or recorded migrations. These scripts have not been applied to it.

Before applying to the connected project:

```powershell
npx supabase link --project-ref zvugxkkqmqzwshwarerj
npx supabase db push --dry-run
```

Review the dry run and migration SQL, then apply deliberately with `npx supabase db push`. The migration set creates public catalog data and transactional records; it is forward-only and should be backed up before production deployment. New public tables have RLS and explicit role grants; payment provider event writes and payment state changes belong in trusted server/webhook code. Never put a Supabase service-role key in a browser bundle.

`create_booking_hold` locks each night in date order, calculates the server-side total, reserves one unit per night, and uses an idempotency key. Pending holds expire after 15 minutes. A trusted scheduler must call `public.expire_booking_holds()` with the service role on a short interval; no payment gateway or scheduler has been configured yet. Payment capture and booking confirmation must be implemented as verified, idempotent provider-webhook operations before accepting real payments.

## Firebase Guest Authentication

The guest account page is `/account`. It uses Firebase email/password and Google sign-in, and the Supabase browser client forwards the current Firebase ID token. Firebase web configuration and the Supabase publishable key are in ignored `.env.local`; copy `.env.example` as a reference. These web API keys identify client projects and are not server secrets. Do not put Firebase Admin credentials or a Supabase secret/service-role key in any `PUBLIC_` variable.

Complete these one-time Firebase/Supabase console steps before guest profiles or booking RPCs can be used:

1. In Firebase Authentication, enable Email/Password and Google providers and add your deployed hostname to authorized domains.
2. In Supabase Authentication → Third-Party Auth, add the Firebase project `guesthousebd-63690`. The local CLI configuration already names this Firebase project.
3. Give every Firebase user that accesses Supabase the trusted custom claim `role: "authenticated"` using Firebase Admin SDK on a trusted server/Cloud Function. Never let a browser assign this claim. Supabase uses it to select the Postgres `authenticated` role. Existing Firebase users need the claim assigned as well; refresh their ID token after the claim is set.
4. Sign into `/account`. The page calls `ensure_guest_profile()` to create a server-mapped profile. Guest booking access uses that mapping and tenant-membership RLS, not Firebase user metadata or client-supplied profile IDs.
5. Staff need a tenant and membership provisioned by a trusted administrator before `/admin` will show workspace data. Insert a row in `tenant_memberships` for the profile ID associated with the staff member's Firebase UID, and grant only the required enum role. Never let guests write membership or role rows.

Example for a trusted Firebase Auth user-created Cloud Function (deploy it through your Firebase project; this repository does not deploy Firebase functions):

```js
const functions = require('firebase-functions/v1');
const admin = require('firebase-admin');

admin.initializeApp();

exports.assignSupabaseRole = functions.auth.user().onCreate(async (user) => {
  await admin.auth().setCustomUserClaims(user.uid, {
    ...(user.customClaims ?? {}),
    role: 'authenticated',
  });
});
```

The function is asynchronous. A newly created user may need to refresh the ID token or sign in again after the claim is applied. Firebase Analytics is not initialized: it is not needed for authentication and should only be added after the site's analytics/consent behavior is decided.

## API Boundaries

- Anonymous: read published pages, active destinations, listings, amenities, public rates, public reviews, and available public stay calendar rows.
- Guest: own profile, own bookings/payment summaries, submit a review only for a completed booking, and create a booking hold through the RPC.
- Tenant staff: scoped by `tenant_memberships` role. Payment state and stock movements are intended to be changed by trusted backend operations; table-level write grants alone do not bypass RLS.
- Service role: webhook processing, audit events, hold expiration, and other trusted background work only.

The schema includes the data foundation, not completed HTTP CRUD endpoints, payment-provider integrations, inventory purchasing, or an admin auth gate. Those should be added as separate service routes/RPCs and migrations as each workflow is implemented.
