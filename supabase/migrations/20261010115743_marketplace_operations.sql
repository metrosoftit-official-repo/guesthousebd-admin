begin;

create type public.listing_type as enum ('stay', 'vehicle', 'travel_guide', 'tour_assistant');
create type public.listing_status as enum ('draft', 'published', 'paused', 'archived');
create type public.booking_status as enum ('pending_payment', 'confirmed', 'in_progress', 'completed', 'cancelled', 'expired', 'refunded');
create type public.payment_status as enum ('pending', 'authorized', 'captured', 'failed', 'cancelled', 'refunded', 'partially_refunded');
create type public.stock_movement_type as enum ('receipt', 'sale', 'reservation', 'release', 'adjustment_in', 'adjustment_out', 'transfer_in', 'transfer_out');

create table public.destinations (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete cascade,
	parent_id uuid references public.destinations (id) on delete set null,
	slug text not null,
	name text not null,
	country_code text not null default 'BD',
	region_name text,
	description text,
	image_path text,
	latitude double precision,
	longitude double precision,
	is_active boolean not null default true,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint destinations_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
	constraint destinations_country_format check (country_code ~ '^[A-Z]{2}$'),
	constraint destinations_latitude_range check (latitude is null or latitude between -90 and 90),
	constraint destinations_longitude_range check (longitude is null or longitude between -180 and 180)
);

create unique index destinations_global_slug_idx on public.destinations (country_code, slug) where tenant_id is null;
create unique index destinations_tenant_slug_idx on public.destinations (tenant_id, country_code, slug) where tenant_id is not null;
create index destinations_active_name_idx on public.destinations (name) where is_active;

create table public.amenities (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete cascade,
	slug text not null,
	name text not null,
	category text not null default 'general',
	icon text,
	is_active boolean not null default true,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint amenities_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$')
);

create unique index amenities_global_slug_idx on public.amenities (slug) where tenant_id is null;
create unique index amenities_tenant_slug_idx on public.amenities (tenant_id, slug) where tenant_id is not null;

create table public.listings (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	destination_id uuid references public.destinations (id) on delete set null,
	listing_type public.listing_type not null,
	status public.listing_status not null default 'draft',
	slug text not null,
	name text not null,
	summary text,
	description text,
	address text,
	latitude double precision,
	longitude double precision,
	max_guests integer,
	bedrooms integer,
	bathrooms numeric(4, 1),
	capacity_seats integer,
	capacity_bags integer,
	base_price_minor bigint not null,
	currency_code text not null default 'BDT',
	price_unit text not null default 'night',
	cancellation_policy jsonb not null default '{}'::jsonb,
	attributes jsonb not null default '{}'::jsonb,
	published_at timestamptz,
	created_by uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint listings_tenant_slug_unique unique (tenant_id, slug),
	constraint listings_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
	constraint listings_price_nonnegative check (base_price_minor >= 0),
	constraint listings_currency_format check (currency_code ~ '^[A-Z]{3}$'),
	constraint listings_price_unit_check check (price_unit in ('night', 'hour', 'day', 'trip', 'person', 'item')),
	constraint listings_guests_positive check (max_guests is null or max_guests > 0),
	constraint listings_coordinates_valid check (
		(latitude is null or latitude between -90 and 90)
		and (longitude is null or longitude between -180 and 180)
	),
	constraint listings_type_capacity_check check (
		(listing_type <> 'vehicle' or capacity_seats is not null and capacity_seats > 0)
		and (listing_type <> 'stay' or max_guests is not null)
	)
);

create index listings_tenant_status_type_idx on public.listings (tenant_id, status, listing_type);
create index listings_destination_type_idx on public.listings (destination_id, listing_type) where status = 'published';
create index listings_published_created_idx on public.listings (published_at desc) where status = 'published';

create table public.listing_media (
	id uuid primary key default gen_random_uuid(),
	listing_id uuid not null references public.listings (id) on delete cascade,
	storage_path text not null,
	alt_text text,
	media_type text not null default 'image',
	sort_order integer not null default 0,
	is_cover boolean not null default false,
	created_at timestamptz not null default now(),
	constraint listing_media_type_check check (media_type in ('image', 'video')),
	constraint listing_media_sort_nonnegative check (sort_order >= 0)
);

create unique index listing_media_one_cover_idx on public.listing_media (listing_id) where is_cover;
create index listing_media_listing_order_idx on public.listing_media (listing_id, sort_order);

create table public.listing_amenities (
	listing_id uuid not null references public.listings (id) on delete cascade,
	amenity_id uuid not null references public.amenities (id) on delete restrict,
	created_at timestamptz not null default now(),
	primary key (listing_id, amenity_id)
);

create table public.service_rates (
	id uuid primary key default gen_random_uuid(),
	listing_id uuid not null references public.listings (id) on delete cascade,
	rate_unit text not null,
	amount_minor bigint not null,
	currency_code text not null,
	minimum_units numeric(8, 2) not null default 1,
	valid_from date,
	valid_until date,
	is_active boolean not null default true,
	created_at timestamptz not null default now(),
	constraint service_rates_unit_check check (rate_unit in ('hour', 'day', 'trip', 'person')),
	constraint service_rates_amount_nonnegative check (amount_minor >= 0),
	constraint service_rates_currency_format check (currency_code ~ '^[A-Z]{3}$'),
	constraint service_rates_minimum_positive check (minimum_units > 0),
	constraint service_rates_date_range check (valid_until is null or valid_from is null or valid_until >= valid_from)
);

create index service_rates_listing_active_idx on public.service_rates (listing_id, rate_unit) where is_active;

create table public.listing_availability (
	listing_id uuid not null references public.listings (id) on delete cascade,
	stay_date date not null,
	total_units integer not null default 1,
	available_units integer not null default 1,
	nightly_price_minor bigint,
	is_closed boolean not null default false,
	minimum_nights integer not null default 1,
	updated_at timestamptz not null default now(),
	primary key (listing_id, stay_date),
	constraint listing_availability_units_check check (
		total_units > 0 and available_units >= 0 and available_units <= total_units
	),
	constraint listing_availability_price_check check (nightly_price_minor is null or nightly_price_minor >= 0),
	constraint listing_availability_min_nights_check check (minimum_nights > 0)
);

create index listing_availability_date_idx on public.listing_availability (stay_date, listing_id) where not is_closed and available_units > 0;

create table public.bookings (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	customer_id uuid not null references public.profiles (id) on delete restrict,
	booking_code text not null unique,
	status public.booking_status not null default 'pending_payment',
	currency_code text not null,
	subtotal_minor bigint not null default 0,
	discount_minor bigint not null default 0,
	tax_minor bigint not null default 0,
	total_minor bigint not null default 0,
	guest_count integer not null default 1,
	idempotency_key text not null,
	hold_expires_at timestamptz,
	confirmed_at timestamptz,
	cancelled_at timestamptz,
	completed_at timestamptz,
	customer_note text,
	metadata jsonb not null default '{}'::jsonb,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint bookings_customer_idempotency_unique unique (customer_id, idempotency_key),
	constraint bookings_currency_format check (currency_code ~ '^[A-Z]{3}$'),
	constraint bookings_amounts_nonnegative check (
		subtotal_minor >= 0 and discount_minor >= 0 and tax_minor >= 0 and total_minor >= 0
	),
	constraint bookings_guest_count_positive check (guest_count > 0),
	constraint bookings_idempotency_length check (length(idempotency_key) between 8 and 128)
);

create index bookings_tenant_created_idx on public.bookings (tenant_id, created_at desc);
create index bookings_customer_created_idx on public.bookings (customer_id, created_at desc);
create index bookings_tenant_status_idx on public.bookings (tenant_id, status, created_at desc);
create index bookings_expired_holds_idx on public.bookings (hold_expires_at) where status = 'pending_payment';

create table public.booking_items (
	id uuid primary key default gen_random_uuid(),
	booking_id uuid not null references public.bookings (id) on delete cascade,
	listing_id uuid not null references public.listings (id) on delete restrict,
	listing_name_snapshot text not null,
	quantity integer not null default 1,
	unit_price_minor bigint not null,
	line_total_minor bigint not null,
	check_in date,
	check_out date,
	service_starts_at timestamptz,
	service_ends_at timestamptz,
	created_at timestamptz not null default now(),
	constraint booking_items_quantity_positive check (quantity > 0),
	constraint booking_items_amounts_nonnegative check (unit_price_minor >= 0 and line_total_minor >= 0),
	constraint booking_items_stay_dates check (
		(check_in is null and check_out is null) or (check_in is not null and check_out > check_in)
	),
	constraint booking_items_service_dates check (
		(service_starts_at is null and service_ends_at is null)
		or (service_starts_at is not null and service_ends_at > service_starts_at)
	)
);

create index booking_items_booking_idx on public.booking_items (booking_id);
create index booking_items_listing_dates_idx on public.booking_items (listing_id, check_in, check_out);

create table public.payment_transactions (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	booking_id uuid not null references public.bookings (id) on delete restrict,
	provider text not null,
	provider_transaction_id text,
	status public.payment_status not null default 'pending',
	amount_minor bigint not null,
	currency_code text not null,
	payment_method text,
	provider_payload jsonb not null default '{}'::jsonb,
	authorized_at timestamptz,
	captured_at timestamptz,
	refunded_at timestamptz,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint payment_transactions_amount_positive check (amount_minor > 0),
	constraint payment_transactions_currency_format check (currency_code ~ '^[A-Z]{3}$'),
	constraint payment_transactions_provider_format check (provider ~ '^[a-z][a-z0-9_-]{1,49}$')
);

create unique index payment_transactions_provider_ref_idx
	on public.payment_transactions (provider, provider_transaction_id)
	where provider_transaction_id is not null;
create index payment_transactions_booking_idx on public.payment_transactions (booking_id, created_at desc);
create index payment_transactions_tenant_status_idx on public.payment_transactions (tenant_id, status, created_at desc);

create table public.payment_provider_events (
	id uuid primary key default gen_random_uuid(),
	provider text not null,
	provider_event_id text not null,
	event_type text not null,
	payload jsonb not null default '{}'::jsonb,
	received_at timestamptz not null default now(),
	processed_at timestamptz,
	processing_error text,
	constraint payment_provider_events_unique unique (provider, provider_event_id)
);

create index payment_provider_events_unprocessed_idx on public.payment_provider_events (received_at)
	where processed_at is null;

create table public.reviews (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	listing_id uuid not null references public.listings (id) on delete restrict,
	booking_id uuid not null references public.bookings (id) on delete restrict,
	author_id uuid not null references public.profiles (id) on delete restrict,
	rating smallint not null,
	title text,
	body text,
	status text not null default 'pending',
	published_at timestamptz,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint reviews_one_per_booking unique (booking_id),
	constraint reviews_rating_range check (rating between 1 and 5),
	constraint reviews_status_check check (status in ('pending', 'published', 'rejected', 'hidden'))
);

create index reviews_listing_public_idx on public.reviews (listing_id, created_at desc) where status = 'published';

create table public.inventory_locations (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	name text not null,
	address text,
	is_active boolean not null default true,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint inventory_locations_tenant_name_unique unique (tenant_id, name)
);

create table public.inventory_items (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	location_id uuid not null references public.inventory_locations (id) on delete restrict,
	sku text not null,
	name text not null,
	description text,
	unit_name text not null default 'item',
	on_hand_quantity numeric(14, 3) not null default 0,
	reorder_level numeric(14, 3) not null default 0,
	cost_minor bigint,
	sale_price_minor bigint,
	currency_code text not null default 'BDT',
	is_active boolean not null default true,
	attributes jsonb not null default '{}'::jsonb,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint inventory_items_tenant_sku_unique unique (tenant_id, sku),
	constraint inventory_items_quantities_nonnegative check (on_hand_quantity >= 0 and reorder_level >= 0),
	constraint inventory_items_prices_nonnegative check (
		(cost_minor is null or cost_minor >= 0) and (sale_price_minor is null or sale_price_minor >= 0)
	),
	constraint inventory_items_currency_format check (currency_code ~ '^[A-Z]{3}$')
);

create index inventory_items_location_active_idx on public.inventory_items (location_id, name) where is_active;
create index inventory_items_reorder_idx on public.inventory_items (tenant_id, on_hand_quantity, reorder_level)
	where is_active;

create table public.sales (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	customer_id uuid references public.profiles (id) on delete set null,
	booking_id uuid references public.bookings (id) on delete set null,
	sale_number text not null,
	status text not null default 'draft',
	currency_code text not null,
	subtotal_minor bigint not null default 0,
	discount_minor bigint not null default 0,
	tax_minor bigint not null default 0,
	total_minor bigint not null default 0,
	sold_at timestamptz,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint sales_tenant_number_unique unique (tenant_id, sale_number),
	constraint sales_status_check check (status in ('draft', 'pending', 'paid', 'cancelled', 'refunded')),
	constraint sales_amounts_nonnegative check (
		subtotal_minor >= 0 and discount_minor >= 0 and tax_minor >= 0 and total_minor >= 0
	),
	constraint sales_currency_format check (currency_code ~ '^[A-Z]{3}$')
);

create index sales_tenant_sold_idx on public.sales (tenant_id, sold_at desc);

create table public.sale_items (
	id uuid primary key default gen_random_uuid(),
	sale_id uuid not null references public.sales (id) on delete cascade,
	inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
	sku_snapshot text not null,
	name_snapshot text not null,
	quantity numeric(14, 3) not null,
	unit_price_minor bigint not null,
	line_total_minor bigint not null,
	created_at timestamptz not null default now(),
	constraint sale_items_quantity_positive check (quantity > 0),
	constraint sale_items_amounts_nonnegative check (unit_price_minor >= 0 and line_total_minor >= 0)
);

create index sale_items_sale_idx on public.sale_items (sale_id);

create table public.stock_movements (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	inventory_item_id uuid not null references public.inventory_items (id) on delete restrict,
	sale_item_id uuid references public.sale_items (id) on delete restrict,
	movement_type public.stock_movement_type not null,
	quantity numeric(14, 3) not null,
	note text,
	actor_id uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	constraint stock_movements_quantity_positive check (quantity > 0)
);

create index stock_movements_item_created_idx on public.stock_movements (inventory_item_id, created_at desc);
create index stock_movements_tenant_created_idx on public.stock_movements (tenant_id, created_at desc);

create table public.guard_shifts (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	guard_user_id uuid not null references public.profiles (id) on delete restrict,
	location_id uuid references public.inventory_locations (id) on delete set null,
	starts_at timestamptz not null,
	ends_at timestamptz not null,
	status text not null default 'scheduled',
	check_in_at timestamptz,
	check_out_at timestamptz,
	notes text,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint guard_shifts_time_range check (ends_at > starts_at),
	constraint guard_shifts_status_check check (status in ('scheduled', 'in_progress', 'completed', 'cancelled'))
);

create index guard_shifts_guard_time_idx on public.guard_shifts (guard_user_id, starts_at desc);
create index guard_shifts_tenant_time_idx on public.guard_shifts (tenant_id, starts_at desc);

create table public.security_incidents (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid not null references public.tenants (id) on delete restrict,
	reported_by uuid references public.profiles (id) on delete set null,
	assigned_to uuid references public.profiles (id) on delete set null,
	booking_id uuid references public.bookings (id) on delete set null,
	title text not null,
	description text,
	severity text not null default 'medium',
	status text not null default 'open',
	occurred_at timestamptz not null default now(),
	resolved_at timestamptz,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint security_incidents_severity_check check (severity in ('low', 'medium', 'high', 'critical')),
	constraint security_incidents_status_check check (status in ('open', 'investigating', 'resolved', 'closed'))
);

create index security_incidents_tenant_status_idx on public.security_incidents (tenant_id, status, occurred_at desc);
create index security_incidents_assigned_idx on public.security_incidents (assigned_to, occurred_at desc);

create table public.contact_inquiries (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete set null,
	sender_name text not null,
	sender_email text not null,
	subject text not null,
	message text not null,
	status text not null default 'new',
	assigned_to uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint contact_inquiries_status_check check (status in ('new', 'in_progress', 'resolved', 'spam'))
);

create index contact_inquiries_tenant_status_idx on public.contact_inquiries (tenant_id, status, created_at desc);

create or replace function private.apply_stock_movement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
	v_delta numeric(14, 3);
begin
	if tg_op <> 'INSERT' then
		raise exception 'Stock movements are append-only' using errcode = '55000';
	end if;

	if new.movement_type in ('receipt', 'release', 'adjustment_in', 'transfer_in') then
		v_delta := new.quantity;
	else
		v_delta := -new.quantity;
	end if;

	if (select auth.jwt() ->> 'role') = 'authenticated' then
		new.actor_id := (select private.current_profile_id());
	end if;

	if new.sale_item_id is not null and not exists (
		select 1
		from public.sale_items as sale_item
		join public.sales as sale on sale.id = sale_item.sale_id
		where sale_item.id = new.sale_item_id
			and sale.tenant_id = new.tenant_id
			and sale_item.inventory_item_id = new.inventory_item_id
	) then
		raise exception 'Stock movement sale reference does not match its tenant or item'
			using errcode = '23514';
	end if;

	update public.inventory_items as item
	set on_hand_quantity = item.on_hand_quantity + v_delta,
			updated_at = now()
	where item.id = new.inventory_item_id
		and item.tenant_id = new.tenant_id
		and item.on_hand_quantity + v_delta >= 0;

	if not found then
		raise exception 'Stock movement would produce invalid or insufficient inventory'
			using errcode = '23514';
	end if;

	return new;
end;
$$;

revoke all on function private.apply_stock_movement() from public, anon, authenticated;
create trigger stock_movements_apply_stock
	before insert or update or delete on public.stock_movements
	for each row execute function private.apply_stock_movement();

create trigger destinations_set_updated_at before update on public.destinations
	for each row execute function private.set_updated_at();
create trigger amenities_set_updated_at before update on public.amenities
	for each row execute function private.set_updated_at();
create trigger listings_set_updated_at before update on public.listings
	for each row execute function private.set_updated_at();
create trigger site_listings_availability_set_updated_at before update on public.listing_availability
	for each row execute function private.set_updated_at();
create trigger bookings_set_updated_at before update on public.bookings
	for each row execute function private.set_updated_at();
create trigger payment_transactions_set_updated_at before update on public.payment_transactions
	for each row execute function private.set_updated_at();
create trigger reviews_set_updated_at before update on public.reviews
	for each row execute function private.set_updated_at();
create trigger inventory_locations_set_updated_at before update on public.inventory_locations
	for each row execute function private.set_updated_at();
create trigger inventory_items_set_updated_at before update on public.inventory_items
	for each row execute function private.set_updated_at();
create trigger sales_set_updated_at before update on public.sales
	for each row execute function private.set_updated_at();
create trigger guard_shifts_set_updated_at before update on public.guard_shifts
	for each row execute function private.set_updated_at();
create trigger security_incidents_set_updated_at before update on public.security_incidents
	for each row execute function private.set_updated_at();
create trigger contact_inquiries_set_updated_at before update on public.contact_inquiries
	for each row execute function private.set_updated_at();

alter table public.destinations enable row level security;
alter table public.amenities enable row level security;
alter table public.listings enable row level security;
alter table public.listing_media enable row level security;
alter table public.listing_amenities enable row level security;
alter table public.service_rates enable row level security;
alter table public.listing_availability enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_items enable row level security;
alter table public.payment_transactions enable row level security;
alter table public.payment_provider_events enable row level security;
alter table public.reviews enable row level security;
alter table public.inventory_locations enable row level security;
alter table public.inventory_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.guard_shifts enable row level security;
alter table public.security_incidents enable row level security;
alter table public.contact_inquiries enable row level security;

create policy "Active destinations are public" on public.destinations
	for select to anon, authenticated using (
		is_active and (tenant_id is null or private.is_active_tenant(tenant_id))
		or (tenant_id is not null and private.has_tenant_role(tenant_id))
	);
create policy "Catalog managers manage destinations" on public.destinations
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	))
	with check (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	));

create policy "Active amenities are public" on public.amenities
	for select to anon, authenticated using (
		is_active and (tenant_id is null or private.is_active_tenant(tenant_id))
		or (tenant_id is not null and private.has_tenant_role(tenant_id))
	);
create policy "Catalog managers manage amenities" on public.amenities
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	))
	with check (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	));

create policy "Published listings are public" on public.listings
	for select to anon, authenticated using (
		(status = 'published' and private.is_active_tenant(tenant_id))
		or private.has_tenant_role(
			tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager', 'booking_manager']::public.tenant_role[]
		)
	);
create policy "Catalog managers manage listings" on public.listings
	for all to authenticated
	using (private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	))
	with check (private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	));

create policy "Listing media follows listing visibility" on public.listing_media
	for select to anon, authenticated using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_media.listing_id and listing.status = 'published'
			and private.is_active_tenant(listing.tenant_id)
	) or exists (
		select 1 from public.listings as listing
		where listing.id = listing_media.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));
create policy "Catalog managers manage listing media" on public.listing_media
	for all to authenticated
	using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_media.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	))
	with check (exists (
		select 1 from public.listings as listing
		where listing.id = listing_media.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));

create policy "Listing amenities follow listing visibility" on public.listing_amenities
	for select to anon, authenticated using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_amenities.listing_id and listing.status = 'published'
			and private.is_active_tenant(listing.tenant_id)
	) or exists (
		select 1 from public.listings as listing
		where listing.id = listing_amenities.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));
create policy "Catalog managers manage listing amenities" on public.listing_amenities
	for all to authenticated
	using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_amenities.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	))
	with check (exists (
		select 1 from public.listings as listing
		where listing.id = listing_amenities.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));

create policy "Rates for visible listings are readable" on public.service_rates
	for select to anon, authenticated using (exists (
		select 1 from public.listings as listing
		where listing.id = service_rates.listing_id and listing.status = 'published'
			and private.is_active_tenant(listing.tenant_id)
	) or exists (
		select 1 from public.listings as listing
		where listing.id = service_rates.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));
create policy "Catalog managers manage listing rates" on public.service_rates
	for all to authenticated
	using (exists (
		select 1 from public.listings as listing
		where listing.id = service_rates.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	))
	with check (exists (
		select 1 from public.listings as listing
		where listing.id = service_rates.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		)
	));

create policy "Availability for visible stays is readable" on public.listing_availability
	for select to anon, authenticated using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_availability.listing_id and listing.status = 'published'
			and private.is_active_tenant(listing.tenant_id)
	) or exists (
		select 1 from public.listings as listing
		where listing.id = listing_availability.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'booking_manager', 'catalog_manager']::public.tenant_role[]
		)
	));
create policy "Booking managers manage availability" on public.listing_availability
	for all to authenticated
	using (exists (
		select 1 from public.listings as listing
		where listing.id = listing_availability.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'booking_manager', 'catalog_manager']::public.tenant_role[]
		)
	))
	with check (exists (
		select 1 from public.listings as listing
		where listing.id = listing_availability.listing_id and private.has_tenant_role(
			listing.tenant_id,
			array['owner', 'admin', 'manager', 'booking_manager', 'catalog_manager']::public.tenant_role[]
		)
	));

create policy "Customers and tenant booking staff can read bookings" on public.bookings
	for select to authenticated using (
		customer_id = (select private.current_profile_id())
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'booking_manager', 'support_agent']::public.tenant_role[])
	);
create policy "Booking customers and staff can read booking items" on public.booking_items
	for select to authenticated using (exists (
		select 1 from public.bookings as booking
		where booking.id = booking_items.booking_id and (
			booking.customer_id = (select private.current_profile_id())
			or private.has_tenant_role(booking.tenant_id, array['owner', 'admin', 'manager', 'booking_manager', 'support_agent']::public.tenant_role[])
		)
	));

create policy "Payment owners and finance staff can read transactions" on public.payment_transactions
	for select to authenticated using (
		exists (select 1 from public.bookings as booking
			where booking.id = payment_transactions.booking_id and booking.customer_id = (select private.current_profile_id()))
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'finance_manager']::public.tenant_role[])
	);

create policy "Published reviews are public" on public.reviews
	for select to anon, authenticated using (
		status = 'published'
		or author_id = (select private.current_profile_id())
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'support_agent']::public.tenant_role[])
	);
create policy "Customers can submit reviews for completed bookings" on public.reviews
	for insert to authenticated with check (
		author_id = (select private.current_profile_id())
		and exists (select 1 from public.bookings as booking
			where booking.id = reviews.booking_id
				and booking.customer_id = (select private.current_profile_id())
				and booking.tenant_id = reviews.tenant_id
				and booking.status = 'completed'
				and exists (select 1 from public.booking_items as item
					where item.booking_id = booking.id and item.listing_id = reviews.listing_id))
	);
create policy "Catalog managers moderate reviews" on public.reviews
	for update to authenticated
	using (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]))
	with check (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]));

create policy "Inventory staff can read locations" on public.inventory_locations
	for select to authenticated using (private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'inventory_manager', 'security_guard']::public.tenant_role[]
	));
create policy "Inventory managers manage locations" on public.inventory_locations
	for all to authenticated
	using (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'inventory_manager']::public.tenant_role[]))
	with check (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'inventory_manager']::public.tenant_role[]));

create policy "Inventory staff can read stock items" on public.inventory_items
	for select to authenticated using (private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'inventory_manager', 'sales_manager']::public.tenant_role[]
	));
create policy "Inventory managers manage stock items" on public.inventory_items
	for all to authenticated
	using (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'inventory_manager']::public.tenant_role[]))
	with check (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'inventory_manager']::public.tenant_role[]));

create policy "Sales staff can read sales" on public.sales
	for select to authenticated using (
		customer_id = (select private.current_profile_id())
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'sales_manager', 'finance_manager']::public.tenant_role[])
	);
create policy "Sales staff can read sale items" on public.sale_items
	for select to authenticated using (exists (
		select 1 from public.sales as sale where sale.id = sale_items.sale_id and (
			sale.customer_id = (select private.current_profile_id())
			or private.has_tenant_role(sale.tenant_id, array['owner', 'admin', 'manager', 'sales_manager', 'finance_manager']::public.tenant_role[])
		)
	));

create policy "Inventory managers can read stock movements" on public.stock_movements
	for select to authenticated using (private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'inventory_manager', 'finance_manager']::public.tenant_role[]
	));
create policy "Inventory managers can record stock movements" on public.stock_movements
	for insert to authenticated with check (
		private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'inventory_manager']::public.tenant_role[])
		and (actor_id is null or actor_id = (select private.current_profile_id()))
	);

create policy "Guards and managers can read assigned shifts" on public.guard_shifts
	for select to authenticated using (
		guard_user_id = (select private.current_profile_id())
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager']::public.tenant_role[])
	);
create policy "Managers manage guard shifts" on public.guard_shifts
	for all to authenticated
	using (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager']::public.tenant_role[]))
	with check (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager']::public.tenant_role[]));

create policy "Incident reporters assignees and managers can read incidents" on public.security_incidents
	for select to authenticated using (
		reported_by = (select private.current_profile_id())
		or assigned_to = (select private.current_profile_id())
		or private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'security_guard']::public.tenant_role[])
	);
create policy "Security staff manage incidents" on public.security_incidents
	for all to authenticated
	using (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'security_guard']::public.tenant_role[]))
	with check (private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'security_guard']::public.tenant_role[]));

create policy "Support staff can read inquiries" on public.contact_inquiries
	for select to authenticated using (
		assigned_to = (select private.current_profile_id())
		or (tenant_id is not null and private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'support_agent']::public.tenant_role[]))
	);
create policy "Support staff manage tenant inquiries" on public.contact_inquiries
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'support_agent']::public.tenant_role[]))
	with check (tenant_id is not null and private.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'support_agent']::public.tenant_role[]));

grant select on public.destinations, public.amenities, public.listings, public.listing_media,
	public.listing_amenities, public.service_rates, public.listing_availability, public.reviews
	to anon, authenticated;
grant select on public.bookings, public.booking_items, public.payment_transactions,
	public.inventory_locations, public.inventory_items, public.sales, public.sale_items,
	public.stock_movements, public.guard_shifts, public.security_incidents, public.contact_inquiries
	to authenticated;
grant insert on public.reviews to authenticated;
grant select, insert, update, delete on public.destinations, public.amenities, public.listings,
	public.listing_media, public.listing_amenities, public.service_rates, public.listing_availability
	to authenticated;
grant select, insert, update, delete on public.inventory_locations,
	public.sales, public.sale_items, public.guard_shifts, public.security_incidents, public.contact_inquiries
	to authenticated;
grant select, insert on public.inventory_items to authenticated;
grant update (location_id, sku, name, description, unit_name, reorder_level, cost_minor,
	sale_price_minor, currency_code, is_active, attributes) on public.inventory_items to authenticated;
grant select, insert on public.stock_movements to authenticated;
grant all privileges on table public.destinations, public.amenities, public.listings,
	public.listing_media, public.listing_amenities, public.service_rates,
	public.listing_availability, public.bookings, public.booking_items,
	public.payment_transactions, public.payment_provider_events, public.reviews,
	public.inventory_locations, public.inventory_items, public.sales,
	public.sale_items, public.stock_movements, public.guard_shifts,
	public.security_incidents, public.contact_inquiries to service_role;

commit;
