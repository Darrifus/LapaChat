-- PostgreSQL. Проектная схема; сервер и миграции не реализованы.
-- UUID создаются приложением, поэтому дополнительные расширения не требуются.
CREATE TABLE users (
    id uuid PRIMARY KEY,
    phone varchar(16) NOT NULL UNIQUE,
    display_name varchar(60) NOT NULL CHECK (length(trim(display_name)) > 0),
    city varchar(80) NOT NULL CHECK (length(trim(city)) > 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Кода ещё не зарегистрированного человека нельзя связать обязательным FK с users.
CREATE TABLE verification_challenges (
    id uuid PRIMARY KEY,
    phone varchar(16) NOT NULL,
    code_hash text NOT NULL,
    provider varchar(16) NOT NULL CHECK (provider IN ('primary','backup')),
    status varchar(16) NOT NULL CHECK (status IN ('pending','sent','failed')),
    attempts smallint NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    CHECK (expires_at > created_at)
);
CREATE INDEX verification_phone_created ON verification_challenges (phone, created_at DESC);

CREATE TABLE sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    refresh_token_hash text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);

CREATE TABLE pets (
    id uuid PRIMARY KEY,
    owner_id uuid NOT NULL REFERENCES users(id),
    name varchar(60) NOT NULL CHECK (length(trim(name)) > 0),
    species varchar(8) NOT NULL CHECK (species IN ('dog','cat','bird','rodent','other')),
    birth_year integer CHECK (birth_year BETWEEN 1980 AND 2026),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pets_owner ON pets(owner_id);
CREATE INDEX pets_species_owner ON pets(species, owner_id);

CREATE TABLE chats (
    id uuid PRIMARY KEY,
    type varchar(8) NOT NULL CHECK (type IN ('direct','group')),
    title varchar(100),
    created_by uuid NOT NULL REFERENCES users(id),
    direct_pair_key varchar(73) UNIQUE,
    next_message_seq bigint NOT NULL DEFAULT 1 CHECK (next_message_seq >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((type = 'direct' AND title IS NULL AND direct_pair_key IS NOT NULL)
        OR (type = 'group' AND title IS NOT NULL AND length(trim(title)) > 0 AND direct_pair_key IS NULL))
);

CREATE TABLE chat_members (
    chat_id uuid NOT NULL REFERENCES chats(id),
    user_id uuid NOT NULL REFERENCES users(id),
    role varchar(8) NOT NULL CHECK (role IN ('owner','member')),
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX members_user ON chat_members(user_id, chat_id);

CREATE TABLE messages (
    id uuid PRIMARY KEY,
    chat_id uuid NOT NULL REFERENCES chats(id),
    sender_id uuid NOT NULL,
    client_message_id uuid NOT NULL,
    seq bigint NOT NULL CHECK (seq >= 1),
    body varchar(4000) NOT NULL CHECK (length(trim(body)) > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (sender_id, client_message_id),
    UNIQUE (chat_id, seq),
    FOREIGN KEY (chat_id, sender_id) REFERENCES chat_members(chat_id, user_id)
);

CREATE TABLE read_receipts (
    chat_id uuid NOT NULL,
    user_id uuid NOT NULL,
    last_read_seq bigint NOT NULL CHECK (last_read_seq >= 1),
    read_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, user_id),
    FOREIGN KEY (chat_id, user_id) REFERENCES chat_members(chat_id, user_id),
    FOREIGN KEY (chat_id, last_read_seq) REFERENCES messages(chat_id, seq)
);

-- Правила, требующие проверки в транзакции приложения:
-- direct содержит ровно 2 участников, group от 3 до 100; создатель включён.
-- direct_pair_key = сортированные UUID двух участников, соединённые ':'.
-- Проверка и погашение одноразового кода атомарны; код проверяется по HMAC
-- с серверным секретом, секрет не хранится в БД и репозитории.
-- seq выдаётся под SELECT ... FOR UPDATE строки chats; счётчик и сообщение
-- фиксируются одной транзакцией. Повтор client_message_id не меняет счётчик.
-- last_read_seq обновляется только вперёд; участники в MVP не удаляются.
-- Не более 5 питомцев: проверка под блокировкой строки владельца users.
