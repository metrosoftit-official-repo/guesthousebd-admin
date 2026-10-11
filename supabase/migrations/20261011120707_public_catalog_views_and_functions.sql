begin;

create view public.public_listing_catalog
with (security_invoker = true)
as
select
	listing.id,
	listing.tenant_id,
	listing.destination_id,
	destination.name as destination_name,
	destination.slug as destination_slug,
	listing.listing_type,
	listing.slug,
	listing.name,
	listing.summary,
	listing.address,
	listing.latitude,
	listing.longitude,
	listing.max_guests,
	listing.bedrooms,
	listing.bathrooms,
	listing.capacity_seats,
	listing.capacity_bags,
	listing.base_price_minor,
	listing.currency_code,
	listing.price_unit,
	listing.published_at
from public.listings as listing
left join public.destinations as destination on destination.id = listing.destination_id
where listing.status = 'published'
	and private.is_active_tenant(listing.tenant_id);

create view public.public_listing_review_summary
with (security_invoker = true)
as
select
	review.listing_id,
	count(*)::integer as review_count,
	round(avg(review.rating)::numeric, 2) as average_rating
from public.reviews as review
where review.status = 'published'
group by review.listing_id;

create view public.public_listing_calendar
with (security_invoker = true)
as
select
	availability.listing_id,
	availability.stay_date,
	availability.available_units,
	coalesce(availability.nightly_price_minor, listing.base_price_minor) as price_minor,
	listing.currency_code,
	availability.minimum_nights
from public.listing_availability as availability
join public.listings as listing on listing.id = availability.listing_id
where listing.status = 'published'
	and private.is_active_tenant(listing.tenant_id)
	and not availability.is_closed
	and availability.available_units > 0
	and listing.listing_type = 'stay';

create view public.inventory_reorder_alerts
with (security_invoker = true)
as
select
	item.id,
	item.tenant_id,
	item.sku,
	item.name,
	item.on_hand_quantity,
	item.reorder_level,
	item.unit_name
from public.inventory_items as item
where item.is_active and item.on_hand_quantity <= item.reorder_level;

grant select on public.public_listing_catalog,
	public.public_listing_review_summary,
	public.public_listing_calendar to anon, authenticated;
grant select on public.inventory_reorder_alerts to authenticated;

create or replace function public.ensure_guest_profile()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
	v_subject text := (select auth.jwt() ->> 'sub');
	v_issuer text := (select auth.jwt() ->> 'iss');
	v_email text := (select auth.jwt() ->> 'email');
	v_display_name text := (select auth.jwt() -> 'user_metadata' ->> 'name');
	v_profile_id uuid;
begin
	if v_subject is null
		or v_issuer <> 'https://securetoken.google.com/guesthousebd-63690'
		or (select auth.jwt() ->> 'aud') <> 'guesthousebd-63690'
		or (select auth.jwt() ->> 'role') <> 'authenticated'
	then
		raise exception 'A verified GuesthouseBD Firebase account is required' using errcode = '28000';
	end if;

	insert into public.profiles (auth_provider, auth_subject, email, display_name)
	values ('firebase', v_subject, v_email, nullif(btrim(v_display_name), ''))
	on conflict (auth_provider, auth_subject) do update
		set email = excluded.email,
				display_name = coalesce(excluded.display_name, public.profiles.display_name)
	returning id into v_profile_id;

	return v_profile_id;
end;
$$;

revoke all on function public.ensure_guest_profile() from public, anon;
grant execute on function public.ensure_guest_profile() to authenticated;

create or replace function public.create_booking_hold(
	p_listing_id uuid,
	p_check_in date,
	p_check_out date,
	p_guest_count integer,
	p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
	v_customer_id uuid := (select private.current_profile_id());
	v_tenant_id uuid;
	v_listing_name text;
	v_listing_currency text;
	v_base_price bigint;
	v_max_guests integer;
	v_nights integer;
	v_calendar_days integer;
	v_available_days integer;
	v_minimum_nights integer;
	v_subtotal bigint;
	v_existing_booking_id uuid;
	v_booking_id uuid;
	v_booking_code text;
begin
	if v_customer_id is null then
		raise exception 'Guest profile has not been initialized' using errcode = '28000';
	end if;

	if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
		raise exception 'Check-out must be after check-in' using errcode = '22023';
	end if;

	v_nights := p_check_out - p_check_in;
	if v_nights > 90 then
		raise exception 'Stay length exceeds the allowed limit' using errcode = '22023';
	end if;

	if p_guest_count is null or p_guest_count < 1
		or length(coalesce(p_idempotency_key, '')) not between 8 and 128
	then
		raise exception 'Reservation details are invalid' using errcode = '22023';
	end if;

	select booking.id into v_existing_booking_id
	from public.bookings as booking
	where booking.customer_id = v_customer_id
		and booking.idempotency_key = p_idempotency_key;

	if v_existing_booking_id is not null then
		if not exists (
			select 1
			from public.bookings as booking
			join public.booking_items as item on item.booking_id = booking.id
			where booking.id = v_existing_booking_id
				and booking.guest_count = p_guest_count
				and item.listing_id = p_listing_id
				and item.check_in = p_check_in
				and item.check_out = p_check_out
		) then
			raise exception 'Idempotency key has already been used for another reservation'
				using errcode = '23505';
		end if;
		return v_existing_booking_id;
	end if;

	select listing.tenant_id, listing.name, listing.currency_code,
		listing.base_price_minor, listing.max_guests
	into v_tenant_id, v_listing_name, v_listing_currency, v_base_price, v_max_guests
	from public.listings as listing
	join public.tenants as tenant on tenant.id = listing.tenant_id and tenant.status = 'active'
	where listing.id = p_listing_id
		and listing.listing_type = 'stay'
		and listing.status = 'published';

	if not found then
		raise exception 'Stay is not available' using errcode = 'P0002';
	end if;

	if p_guest_count > v_max_guests then
		raise exception 'Guest count exceeds the stay limit' using errcode = '22023';
	end if;

	perform availability.stay_date
	from public.listing_availability as availability
	where availability.listing_id = p_listing_id
		and availability.stay_date >= p_check_in
		and availability.stay_date < p_check_out
	order by availability.stay_date
	for update;

	select
		count(*)::integer,
		count(*) filter (where availability.available_units > 0 and not availability.is_closed)::integer,
		max(availability.minimum_nights)::integer,
		sum(coalesce(availability.nightly_price_minor, v_base_price))::bigint
	into v_calendar_days, v_available_days, v_minimum_nights, v_subtotal
	from public.listing_availability as availability
	where availability.listing_id = p_listing_id
		and availability.stay_date >= p_check_in
		and availability.stay_date < p_check_out;

	if v_calendar_days <> v_nights or v_available_days <> v_nights then
		raise exception 'Stay is not available for the selected dates' using errcode = 'P0001';
	end if;

	if v_nights < coalesce(v_minimum_nights, 1) then
		raise exception 'Stay is shorter than the minimum-night requirement' using errcode = '22023';
	end if;

	update public.listing_availability as availability
	set available_units = availability.available_units - 1,
			updated_at = now()
	where availability.listing_id = p_listing_id
		and availability.stay_date >= p_check_in
		and availability.stay_date < p_check_out
		and not availability.is_closed
		and availability.available_units > 0;

	v_booking_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

	insert into public.bookings (
		tenant_id, customer_id, booking_code, status, currency_code,
		subtotal_minor, total_minor, guest_count, idempotency_key, hold_expires_at
	) values (
		v_tenant_id, v_customer_id, v_booking_code, 'pending_payment', v_listing_currency,
		v_subtotal, v_subtotal, p_guest_count, p_idempotency_key, now() + interval '15 minutes'
	) returning id into v_booking_id;

	insert into public.booking_items (
		booking_id, listing_id, listing_name_snapshot, quantity,
		unit_price_minor, line_total_minor, check_in, check_out
	) values (
		v_booking_id, p_listing_id, v_listing_name, 1,
		v_subtotal / v_nights, v_subtotal, p_check_in, p_check_out
	);

	return v_booking_id;
end;
$$;

revoke all on function public.create_booking_hold(uuid, date, date, integer, text) from public, anon;
grant execute on function public.create_booking_hold(uuid, date, date, integer, text) to authenticated;

create or replace function public.expire_booking_holds(p_limit integer default 200)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
	v_booking record;
	v_item record;
	v_expired_count integer := 0;
	v_limit integer := greatest(1, least(coalesce(p_limit, 200), 1000));
begin
	for v_booking in
		select booking.id
		from public.bookings as booking
		where booking.status = 'pending_payment'
			and booking.hold_expires_at <= now()
		order by booking.hold_expires_at
		limit v_limit
		for update skip locked
	loop
		for v_item in
			select item.listing_id, item.check_in, item.check_out, item.quantity
			from public.booking_items as item
			where item.booking_id = v_booking.id
				and item.check_in is not null
				and item.check_out is not null
		loop
			update public.listing_availability as availability
			set available_units = least(availability.total_units, availability.available_units + v_item.quantity),
				updated_at = now()
			where availability.listing_id = v_item.listing_id
				and availability.stay_date >= v_item.check_in
				and availability.stay_date < v_item.check_out;
		end loop;

		update public.bookings
		set status = 'expired', hold_expires_at = null
		where id = v_booking.id and status = 'pending_payment';

		v_expired_count := v_expired_count + 1;
	end loop;

	return v_expired_count;
end;
$$;

revoke all on function public.expire_booking_holds(integer) from public, anon, authenticated;
grant execute on function public.expire_booking_holds(integer) to service_role;

commit;
