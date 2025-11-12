-- PostgreSQL schema for Secret Santa
-- Derived from Diagrams/05.data_model.mmd
-- Uses pgcrypto for gen_random_uuid()

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enums
CREATE TYPE participant_status AS ENUM ('invited', 'joined', 'confirmed', 'withdrawn');
CREATE TYPE message_role AS ENUM ('SANTA', 'RECIPIENT');

-- NOTE: The model specifies Group.revealMode as enum but values were not provided.
-- Placeholder values below — please confirm/adjust as needed.
CREATE TYPE reveal_mode AS ENUM ('manual', 'auto_at_exchange', 'never');

-- Tables

-- groups (avoid reserved word "group")
CREATE TABLE groups (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  budget      numeric(12,2) NOT NULL CHECK (budget >= 0),
  exchange_at timestamptz NOT NULL,
  timezone    text NOT NULL,  -- IANA TZ name; app-level validation recommended
  reveal_mode reveal_mode NOT NULL,
  created_by  uuid NOT NULL   -- No referenced table in model; kept as raw UUID
);

-- participants
CREATE TABLE participants (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id  uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  name      text NOT NULL,
  email     text NOT NULL,
  status    participant_status NOT NULL DEFAULT 'invited',
  address   jsonb
);

-- Provide composite uniqueness so other tables can reference (group_id, id)
ALTER TABLE participants
  ADD CONSTRAINT uq_participants_group_id_id UNIQUE (group_id, id);

-- Helpful: prevent duplicate emails within a group (case-insensitive)
CREATE UNIQUE INDEX uq_participants_group_email
  ON participants (group_id, lower(email));

CREATE INDEX ix_participants_group_id ON participants (group_id);
CREATE INDEX ix_participants_status ON participants (status);

-- exclusions (cannot pair a <-> b within a group)
CREATE TABLE exclusions (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id  uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  a_id      uuid NOT NULL,
  b_id      uuid NOT NULL,
  CHECK (a_id <> b_id),
  -- Ensure a_id and b_id refer to participants in the same group
  FOREIGN KEY (group_id, a_id) REFERENCES participants (group_id, id) ON DELETE CASCADE,
  FOREIGN KEY (group_id, b_id) REFERENCES participants (group_id, id) ON DELETE CASCADE
);

-- Uniqueness across unordered pair within the same group
CREATE UNIQUE INDEX ux_exclusions_group_pair
  ON exclusions (group_id, LEAST(a_id, b_id), GREATEST(a_id, b_id));

CREATE INDEX ix_exclusions_group_id ON exclusions (group_id);

-- assignments
CREATE TABLE assignments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id     uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  santa_id     uuid NOT NULL,
  recipient_id uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (santa_id <> recipient_id),
  FOREIGN KEY (group_id, santa_id)     REFERENCES participants (group_id, id) ON DELETE CASCADE,
  FOREIGN KEY (group_id, recipient_id) REFERENCES participants (group_id, id) ON DELETE CASCADE,
  -- Each person can be Santa once per group
  UNIQUE (group_id, santa_id),
  -- Each person can be Recipient once per group
  UNIQUE (group_id, recipient_id),
  -- Composite unique key to support 1:1 threads via composite FK
  UNIQUE (group_id, santa_id, recipient_id)
);

CREATE INDEX ix_assignments_group_id ON assignments (group_id);

-- wishlist_items
CREATE TABLE wishlist_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id uuid NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
  title          text NOT NULL,
  url            text,
  notes          text,
  price          numeric(12,2),
  CHECK (price IS NULL OR price >= 0)
);

CREATE INDEX ix_wishlist_items_participant_id ON wishlist_items (participant_id);

-- message_threads (optional 1:1 with assignment)
CREATE TABLE message_threads (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id     uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  santa_id     uuid NOT NULL,
  recipient_id uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  -- Ensure both participants belong to the group
  FOREIGN KEY (group_id, santa_id)     REFERENCES participants (group_id, id) ON DELETE CASCADE,
  FOREIGN KEY (group_id, recipient_id) REFERENCES participants (group_id, id) ON DELETE CASCADE,
  -- Enforce the thread maps to a valid assignment and is 1:1
  UNIQUE (group_id, santa_id, recipient_id),
  FOREIGN KEY (group_id, santa_id, recipient_id)
    REFERENCES assignments (group_id, santa_id, recipient_id) ON DELETE CASCADE
);

CREATE INDEX ix_message_threads_group_id ON message_threads (group_id);

-- messages
CREATE TABLE messages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  thread_id  uuid NOT NULL REFERENCES message_threads(id) ON DELETE CASCADE,
  from_role  message_role NOT NULL,
  text       text NOT NULL CHECK (char_length(text) > 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_messages_thread_id ON messages (thread_id);

COMMIT;