-- Simulates objects that already exist in the GCP database before Flyway
-- is introduced. Loaded by Postgres on first container init via
-- /docker-entrypoint-initdb.d. Flyway must NOT touch or re-create these.

CREATE TABLE legacy_accounts (
    id serial PRIMARY KEY,
    name text NOT NULL
);

INSERT INTO legacy_accounts (name) VALUES
    ('existing-customer-1'),
    ('existing-customer-2');

CREATE TABLE legacy_settings (
    key text PRIMARY KEY,
    value text
);

INSERT INTO legacy_settings (key, value) VALUES
    ('feature.x', 'enabled'),
    ('feature.y', 'disabled');
