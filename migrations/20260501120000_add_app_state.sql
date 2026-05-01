-- Key-value table for persisting application state (e.g., clustering params)
CREATE TABLE IF NOT EXISTS app_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;