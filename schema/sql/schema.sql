-- -*- mode: sql; sql-product: postgres -*-

-- hosts table
create domain hostname_t text check (
  value ~ '^([a-z0-9]+\.)+hashbang\.sh$'
);

create table "hosts" (
  "name" hostname_t primary key,
  "maxusers" integer check(maxusers >= 0),
  "data" jsonb -- extra data added in the stats answer
               -- conforms to the host_data.yaml schema
);

-- data for NSS' passwd
-- there is an implicit primary group for each user
-- UID and GID ranges conform to Debian policy:
--  https://www.debian.org/doc/debian-policy/ch-opersys.html#s9.2.2
create sequence user_id minvalue 4000 maxvalue 59999 no cycle;

create domain username_t text check (
  value ~ '^[a-z][a-z0-9]{0,30}$'
);

create type shell as enum (
  '/bin/sh',
  '/bin/bash',
  '/bin/zsh',
  '/bin/ksh',
  '/bin/dash',
  '/bin/fish',
  '/bin/git-shell',
  '/bin/nologin'
);

create table "passwd" (
  "uid" integer primary key
    check((uid >= 1000 and uid < 60000) or (uid > 65535 and uid < 4294967294))
    default nextval('user_id'),
  "name" username_t unique not null,
  "host" text not null references hosts (name),
  "shell" shell default '/bin/bash',
  "data" jsonb  -- conforms to the user_data.yaml schema
    check(length(data::text) < 1048576) -- max 1M
);

alter sequence user_id owned by passwd.uid;

-- auxiliary groups
create table "group" (
  "gid" integer primary key check(gid < 1000 or (gid >= 60000 and gid < 65000)),
  "name" username_t unique not null
);

create table "aux_groups" (
  "uid" int4 not null references passwd  (uid) on delete cascade,
  "gid" int4 not null references "group" (gid) on delete cascade,
  primary key ("uid", "gid")
);

create type ssh_key_type as enum (
  'dsa',
  'rsa',
  'ecdsa',
  'ed25519',
  'u2f'
);

create table "ssh_public_key" (
  "fingerprint" text not null primary key check (length(fingerprint) = 64),
  "type" ssh_key_type not null,
  "key" text unique not null check(length(key) < 1024),
  "comment" text null check (length(comment) < 100),
  "uid" integer references passwd (uid) on delete cascade
);

create function ssh_public_key_hash() returns trigger as $$
begin
    if new.fingerprint is not null and new.fingerprint != sha256(new.key) then
        raise exception 'fingerprint does not match expected key';
    end if;
    if tg_op = 'insert' OR tg_op = 'update' then
        new.fingerprint = sha256(new.key);
        return new;
    end if;
end;
$$ language plpgsql;
create trigger ssh_public_key_update
before insert or update of key, fingerprint on ssh_public_key
for each row execute procedure ssh_public_key_hash();

-- prevent creation/update of a user/host if the number of users
-- in the group 'users' that have that host
-- is equal to the maxUsers for that host
create function check_hosts_for_hosts() returns trigger
    language plpgsql as $$
    begin
        if ((select count(*) from passwd where passwd.host = new.name) > new.maxusers) then
            raise foreign_key_violation using message = 'current maxUsers too high for host: '||new.name;
        end if;
        return new;
    end $$;
create constraint trigger max_users_on_host
    after update on hosts
    for each row
    when (old.maxusers <> new.maxusers)
    execute procedure check_hosts_for_hosts();

-- prevent creation/update of a user if the number of users
-- associated to that host is equal to maxUsers
create function check_max_users() returns trigger
    language plpgsql as $$
    begin
	if (tg_op = 'INSERT' or old.host <> new.host) and
	   (select count(*) from passwd where passwd.host = new.host) > (select "maxusers" from hosts where hosts.name = new.host) then
	    raise foreign_key_violation using message = 'maxUsers reached for host: '||new.host;
	end if;
	return new;
    end $$;
create constraint trigger max_users
    after insert or update on passwd
    for each row execute procedure check_max_users();

-- prevent users and groups sharing the same name
create function check_invalid_name_for_passwd() returns trigger
    language plpgsql as $$
    begin
        if (exists(select 1 from "group" where new.name = name)) then
            raise check_violation using message = 'group name already exists: '||new.name;
        end if;
	return new;
    end $$;
create constraint trigger check_name_exists_passwd
    after insert or update on passwd
    for each row
    execute procedure check_invalid_name_for_passwd();

create function check_invalid_name_for_group() returns trigger
    language plpgsql as $$
    begin
        if (exists(select 1 from passwd where new.name = name)) then
            raise check_violation using message = 'username already exists: '||new.name;
        end if;
	return new;
    end $$;
create constraint trigger check_name_exists_group
    after insert or update on "group"
    for each row
    execute procedure check_invalid_name_for_group();

-- prevent users from taking names which are typically reserved
create table "reserved_usernames" (
    "name" username_t unique not null
);
create function check_reserved_username() returns trigger
    language plpgsql as $$
    begin
        if (exists(select 1 from reserved_usernames where name = new.name)) then
            raise check_violation using message = 'username reserved: '||new.name;
        end if;
        return new;
    end $$;
create constraint trigger check_reserved_username
    after insert on passwd
    for each row
    execute procedure check_reserved_username();

-- prevent inserting a reserved username that is already taken by a user
create function check_taken_username() returns trigger
    language plpgsql as $$
    begin
        if (exists(select 1 from passwd where name = new.name)) then
            raise check_violation using message = 'A user with that name exists: '||new.name;
        end if;
        return new;
    end $$;
create constraint trigger check_taken_username
    after insert on reserved_usernames
    for each row
    execute procedure check_taken_username();
