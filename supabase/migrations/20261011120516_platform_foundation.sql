begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to anon;
grant usage on schema private to authenticated;

create type public.tenant_role as enum (
	'owner',
	'admin',
	'manager',
	'catalog_manager',
	'booking_manager',
	'finance_manager',
	'inventory_manager',
	'sales_manager',
	'security_guard',
	'support_agent',
	'customer'
);

create table public.profiles (
	id uuid primary key default gen_random_uuid(),
	auth_provider text not null,
	auth_subject text not null,
	email text,
	display_name text,
	phone text,
	avatar_path text,
	preferred_language text not null default 'en',
	preferred_currency text not null default 'BDT',
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint profiles_provider_subject_unique unique (auth_provider, auth_subject),
	constraint profiles_provider_check check (auth_provider in ('supabase', 'firebase')),
	constraint profiles_subject_nonempty check (length(auth_subject) between 1 and 256),
	constraint profiles_language_format check (preferred_language ~ '^[a-z]{2}(-[A-Z]{2})?$'),
	constraint profiles_currency_format check (preferred_currency ~ '^[A-Z]{3}$')
);

create table public.tenants (
	id uuid primary key default gen_random_uuid(),
	slug text not null unique,
	name text not null,
	tenant_type text not null default 'operator',
	status text not null default 'active',
	default_currency text not null default 'BDT',
	country_code text not null default 'BD',
	timezone text not null default 'Asia/Dhaka',
	settings jsonb not null default '{}'::jsonb,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint tenants_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
	constraint tenants_type_check check (tenant_type in ('platform', 'operator', 'host', 'service_provider', 'merchant')),
	constraint tenants_status_check check (status in ('active', 'suspended', 'closed')),
	constraint tenants_currency_format check (default_currency ~ '^[A-Z]{3}$'),
	constraint tenants_country_format check (country_code ~ '^[A-Z]{2}$')
);

create table public.tenant_memberships (
	tenant_id uuid not null references public.tenants (id) on delete cascade,
	user_id uuid not null references public.profiles (id) on delete cascade,
	role public.tenant_role not null,
	is_active boolean not null default true,
	invited_by uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	primary key (tenant_id, user_id),
	constraint tenant_memberships_owner_role check (role <> 'owner' or is_active)
);

create index tenant_memberships_user_active_idx
	on public.tenant_memberships (user_id, tenant_id) where is_active;

create table public.site_pages (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete cascade,
	slug text not null,
	locale text not null default 'en',
	title text not null,
	summary text,
	content jsonb not null default '{}'::jsonb,
	status text not null default 'draft',
	published_at timestamptz,
	created_by uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint site_pages_slug_format check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
	constraint site_pages_locale_format check (locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
	constraint site_pages_status_check check (status in ('draft', 'published', 'archived'))
);

create unique index site_pages_global_slug_locale_idx
	on public.site_pages (slug, locale) where tenant_id is null;
create unique index site_pages_tenant_slug_locale_idx
	on public.site_pages (tenant_id, slug, locale) where tenant_id is not null;
create index site_pages_public_idx on public.site_pages (locale, slug) where status = 'published';

create table public.site_settings (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete cascade,
	setting_key text not null,
	setting_value jsonb not null default 'null'::jsonb,
	is_public boolean not null default false,
	updated_by uuid references public.profiles (id) on delete set null,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint site_settings_key_format check (setting_key ~ '^[a-z][a-z0-9_.-]{1,99}$')
);

create unique index site_settings_global_key_idx
	on public.site_settings (setting_key) where tenant_id is null;
create unique index site_settings_tenant_key_idx
	on public.site_settings (tenant_id, setting_key) where tenant_id is not null;

create table public.feature_flags (
	id uuid primary key default gen_random_uuid(),
	tenant_id uuid references public.tenants (id) on delete cascade,
	flag_key text not null,
	enabled boolean not null default false,
	configuration jsonb not null default '{}'::jsonb,
	is_public boolean not null default false,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint feature_flags_key_format check (flag_key ~ '^[a-z][a-z0-9_.-]{1,99}$')
);

create unique index feature_flags_global_key_idx
	on public.feature_flags (flag_key) where tenant_id is null;
create unique index feature_flags_tenant_key_idx
	on public.feature_flags (tenant_id, flag_key) where tenant_id is not null;

create table private.audit_logs (
	id bigint generated always as identity primary key,
	tenant_id uuid references public.tenants (id) on delete set null,
	actor_user_id uuid references public.profiles (id) on delete set null,
	action text not null,
	entity_type text not null,
	entity_id text,
	request_id text,
	ip_address inet,
	details jsonb not null default '{}'::jsonb,
	created_at timestamptz not null default now()
);

create index audit_logs_tenant_created_idx on private.audit_logs (tenant_id, created_at desc);
create index audit_logs_entity_idx on private.audit_logs (entity_type, entity_id, created_at desc);

create or replace function private.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
	select profile.id
	from public.profiles as profile
	where profile.auth_subject = (select auth.jwt() ->> 'sub')
		and profile.auth_provider = case
			when (select auth.jwt() ->> 'iss') like 'https://securetoken.google.com/%' then 'firebase'
			else 'supabase'
		end
	limit 1;
$$;

revoke all on function private.current_profile_id() from public, anon;
grant execute on function private.current_profile_id() to authenticated;

create or replace function private.is_active_tenant(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.tenants as tenant
		where tenant.id = p_tenant_id and tenant.status = 'active'
	);
$$;

revoke all on function private.is_active_tenant(uuid) from public;
grant execute on function private.is_active_tenant(uuid) to anon, authenticated;

create or replace function private.has_tenant_role(
	p_tenant_id uuid,
	p_roles public.tenant_role[] default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
	select exists (
		select 1
		from public.tenant_memberships as membership
		where membership.tenant_id = p_tenant_id
			and membership.user_id = (select private.current_profile_id())
			and membership.is_active
			and (p_roles is null or membership.role = any (p_roles))
	);
$$;

revoke all on function private.has_tenant_role(uuid, public.tenant_role[]) from public;
grant execute on function private.has_tenant_role(uuid, public.tenant_role[]) to anon, authenticated;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
	new.updated_at := now();
	return new;
end;
$$;

revoke all on function private.set_updated_at() from public, anon, authenticated;

create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	insert into public.profiles (id, auth_provider, auth_subject, email, display_name)
	values (
		new.id,
		'supabase',
		new.id::text,
		new.email,
		nullif(btrim(new.raw_user_meta_data ->> 'display_name'), '')
	)
	on conflict (auth_provider, auth_subject) do nothing;
	return new;
end;
$$;

revoke all on function private.handle_new_auth_user() from public, anon, authenticated;
grant usage on schema private to service_role;
grant select, insert on private.audit_logs to service_role;
grant usage, select on sequence private.audit_logs_id_seq to service_role;

create trigger on_auth_user_created
	after insert on auth.users
	for each row execute function private.handle_new_auth_user();

create trigger profiles_set_updated_at before update on public.profiles
	for each row execute function private.set_updated_at();
create trigger tenants_set_updated_at before update on public.tenants
	for each row execute function private.set_updated_at();
create trigger tenant_memberships_set_updated_at before update on public.tenant_memberships
	for each row execute function private.set_updated_at();
create trigger site_pages_set_updated_at before update on public.site_pages
	for each row execute function private.set_updated_at();
create trigger site_settings_set_updated_at before update on public.site_settings
	for each row execute function private.set_updated_at();
create trigger feature_flags_set_updated_at before update on public.feature_flags
	for each row execute function private.set_updated_at();

alter table public.profiles enable row level security;
alter table public.tenants enable row level security;
alter table public.tenant_memberships enable row level security;
alter table public.site_pages enable row level security;
alter table public.site_settings enable row level security;
alter table public.feature_flags enable row level security;
alter table private.audit_logs enable row level security;

create policy "Users can read their own profile" on public.profiles
	for select to authenticated using (id = (select private.current_profile_id()));
create policy "Users can update their own profile" on public.profiles
	for update to authenticated using (id = (select private.current_profile_id()))
	with check (id = (select private.current_profile_id()));

create policy "Members can read their tenants" on public.tenants
	for select to authenticated using (private.has_tenant_role(id));
create policy "Members can read their memberships" on public.tenant_memberships
	for select to authenticated using (user_id = (select private.current_profile_id()) or private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager']::public.tenant_role[]
	));

create policy "Published site pages are public" on public.site_pages
	for select to anon, authenticated using (
		(status = 'published' and (tenant_id is null or private.is_active_tenant(tenant_id)))
		or (tenant_id is not null and private.has_tenant_role(
			tenant_id,
			array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
		))
	);
create policy "Catalog managers manage site pages" on public.site_pages
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	))
	with check (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager', 'catalog_manager']::public.tenant_role[]
	));

create policy "Public settings are readable" on public.site_settings
	for select to anon, authenticated using (
		is_public and (tenant_id is null or exists (
			select 1 where private.is_active_tenant(site_settings.tenant_id)
		))
		or (tenant_id is not null and private.has_tenant_role(
			tenant_id,
			array['owner', 'admin', 'manager']::public.tenant_role[]
		))
	);
create policy "Managers manage site settings" on public.site_settings
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager']::public.tenant_role[]
	))
	with check (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager']::public.tenant_role[]
	));

create policy "Public feature flags are readable" on public.feature_flags
	for select to anon, authenticated using (
		is_public and enabled and (tenant_id is null or private.is_active_tenant(tenant_id))
	);
create policy "Managers manage feature flags" on public.feature_flags
	for all to authenticated
	using (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager']::public.tenant_role[]
	))
	with check (tenant_id is not null and private.has_tenant_role(
		tenant_id,
		array['owner', 'admin', 'manager']::public.tenant_role[]
	));

grant select on public.site_pages, public.site_settings, public.feature_flags to anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, phone, avatar_path, preferred_language, preferred_currency)
	on public.profiles to authenticated;
grant select on public.tenants, public.tenant_memberships to authenticated;
grant insert, update, delete on public.site_pages, public.site_settings, public.feature_flags to authenticated;
commit;
