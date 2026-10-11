import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const migrationDirectory = fileURLToPath(new URL('../supabase/migrations/', import.meta.url));
const migrationFiles = [
	'20261010115738_platform_foundation.sql',
	'20261010115743_marketplace_operations.sql',
	'20261010115748_public_catalog_views_and_functions.sql',
];

const database = new PGlite();

try {
	await database.exec(`
		create role anon;
		create role authenticated;
		create role service_role bypassrls;
		create schema auth;
		create table auth.users (
			id uuid primary key,
			email text,
			raw_user_meta_data jsonb not null default '{}'::jsonb
		);
		create function auth.jwt() returns jsonb language sql stable as
		$$ select nullif(current_setting('request.jwt.claims', true), '')::jsonb $$;
		create function auth.uid() returns uuid language sql stable as
		$$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
		grant usage on schema auth to anon, authenticated, service_role;
		grant execute on function auth.jwt(), auth.uid() to anon, authenticated, service_role;
		grant all on auth.users to postgres;
	`);

	for (const migrationFile of migrationFiles) {
		const sql = await readFile(join(migrationDirectory, migrationFile), 'utf8');
		await database.exec(sql);
		console.log(`Applied ${migrationFile}`);
	}

	const tableState = await database.query(`
		select count(*)::integer as table_count
		from information_schema.tables
		where table_schema = 'public' and table_type = 'BASE TABLE'
	`);
	assert.equal(tableState.rows[0].table_count, 26, 'Expected all marketplace and platform tables');

	const rlsState = await database.query(`
		select count(*)::integer as enabled_count
		from pg_class as relation
		join pg_namespace as namespace on namespace.oid = relation.relnamespace
		where namespace.nspname = 'public'
			and relation.relkind = 'r'
			and relation.relrowsecurity
	`);
	assert.equal(rlsState.rows[0].enabled_count, tableState.rows[0].table_count, 'Every public table must enable RLS');

	await database.exec(`
		insert into public.tenants (id, slug, name)
		values ('10000000-0000-4000-8000-000000000001', 'guesthousebd', 'GuesthouseBD');
		insert into public.destinations (id, slug, name)
		values ('20000000-0000-4000-8000-000000000001', 'dhaka', 'Dhaka');
		insert into public.listings (
			id, tenant_id, destination_id, listing_type, status, slug, name,
			max_guests, base_price_minor, currency_code
		) values (
			'30000000-0000-4000-8000-000000000001',
			'10000000-0000-4000-8000-000000000001',
			'20000000-0000-4000-8000-000000000001',
			'stay', 'published', 'test-room', 'Test room', 3, 5000, 'BDT'
		);
		insert into public.listing_availability (listing_id, stay_date, total_units, available_units, nightly_price_minor)
		select '30000000-0000-4000-8000-000000000001', date '2030-01-01' + day_offset, 1, 1, 5000
		from generate_series(0, 2) as day_offset;
		select set_config('request.jwt.claims', '{
			"iss":"https://securetoken.google.com/guesthousebd-63690",
			"aud":"guesthousebd-63690",
			"sub":"firebase-guest-uid-123",
			"role":"authenticated",
			"email":"guest@example.com",
			"user_metadata":{"name":"Test Guest"}
		}'::jsonb::text, false);
		set role authenticated;
	`);

	const profile = await database.query('select public.ensure_guest_profile() as id');
	assert.ok(profile.rows[0].id, 'Guest profile RPC should create a profile');

	const booking = await database.query(`
		select public.create_booking_hold(
			'30000000-0000-4000-8000-000000000001',
			date '2030-01-01',
			date '2030-01-04',
			2,
			'hold-test-key-0001'
		) as id
	`);
	assert.ok(booking.rows[0].id, 'Booking hold RPC should create a booking');

	const repeatedBooking = await database.query(`
		select public.create_booking_hold(
			'30000000-0000-4000-8000-000000000001',
			date '2030-01-01',
			date '2030-01-04',
			2,
			'hold-test-key-0001'
		) as id
	`);
	assert.equal(repeatedBooking.rows[0].id, booking.rows[0].id, 'Repeated idempotency key must return the same booking');

	const inventory = await database.query(`
		select available_units from public.listing_availability
		where listing_id = '30000000-0000-4000-8000-000000000001'
		order by stay_date
	`);
	assert.deepEqual(inventory.rows.map((row) => row.available_units), [0, 0, 0], 'Hold must reserve each night exactly once');

	const ownBookings = await database.query('select id from public.bookings');
	assert.equal(ownBookings.rows.length, 1, 'Guest must read their own booking');

	await database.exec('reset role; select set_config(\'request.jwt.claims\', \'{}\', false); set role anon;');
	const publicListings = await database.query('select id from public.public_listing_catalog');
	assert.equal(publicListings.rows.length, 1, 'Anonymous users must read the public listing view');
	await assert.rejects(
		database.query('select id from public.bookings'),
		(error) => error.code === '42501',
		'Anonymous users must not have SQL privileges to read guest bookings',
	);

	await database.exec(`
		reset role;
		select set_config('request.jwt.claims', '{
			"iss":"https://securetoken.google.com/guesthousebd-63690",
			"aud":"guesthousebd-63690",
			"sub":"firebase-guest-uid-456",
			"role":"authenticated",
			"email":"other@example.com"
		}'::jsonb::text, false);
		set role authenticated;
	`);
	await database.query('select public.ensure_guest_profile()');
	const otherGuestBookings = await database.query('select id from public.bookings');
	assert.equal(otherGuestBookings.rows.length, 0, 'A different Firebase guest must not read another guest booking');
	await assert.rejects(
		database.query(`select public.create_booking_hold(
			'30000000-0000-4000-8000-000000000001',
			date '2030-01-01', date '2030-01-04', 1, 'hold-test-key-0002'
		)`),
		(error) => error.code === 'P0001',
		'Unavailable dates must not accept another guest booking hold',
	);

	await database.exec(`
		reset role;
		update public.bookings set hold_expires_at = now() - interval '1 minute'
		where id = '${booking.rows[0].id}';
		set role service_role;
	`);
	const expired = await database.query('select public.expire_booking_holds() as count');
	assert.equal(expired.rows[0].count, 1, 'Service role should expire the pending hold');
	await database.exec('reset role');
	const releasedInventory = await database.query(`
		select available_units from public.listing_availability
		where listing_id = '30000000-0000-4000-8000-000000000001'
		order by stay_date
	`);
	assert.deepEqual(releasedInventory.rows.map((row) => row.available_units), [1, 1, 1], 'Expired holds must release inventory');

	await database.exec(`
		update public.tenants
		set status = 'suspended'
		where id = '10000000-0000-4000-8000-000000000001';
		select set_config('request.jwt.claims', '{}', false);
		set role anon;
	`);
	const suspendedListings = await database.query('select id from public.public_listing_catalog');
	assert.equal(suspendedListings.rows.length, 0, 'Suspended tenant listings must not appear publicly');

	console.log('Migration smoke tests passed.');
} finally {
	await database.close();
}