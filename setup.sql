-- 1. Enable the vector extension
ALTER EXTENSION vector UPDATE;

-- 2. Emails metadata and content storage
CREATE TABLE IF NOT EXISTS emails (
    id SERIAL PRIMARY KEY,
    imap_uid BIGINT NOT NULL,
    mailbox VARCHAR(255) NOT NULL,
    message_id VARCHAR(255) UNIQUE NOT NULL, -- Prevents duplicates
    subject TEXT,
    sender TEXT,
    recipient TEXT,
    date_sent TIMESTAMP WITH TIME ZONE,
    is_unread BOOLEAN DEFAULT TRUE,
    is_archived BOOLEAN DEFAULT FALSE,
    body_text TEXT,
    body_html TEXT,
    raw_mime TEXT
);

-- 3. Embeddings storage
CREATE TABLE IF NOT EXISTS email_embeddings (
    id SERIAL PRIMARY KEY,
    idemail INTEGER UNIQUE REFERENCES emails(id) ON DELETE CASCADE,
    embedding vector(1024) NOT NULL
);

-- 4. Fast similarity search index (HNSW index)
CREATE INDEX IF NOT EXISTS email_embeddings_ivfflat_idx 
ON email_embeddings USING ivfflat (embedding vector_cosine_ops) 
WITH (lists = 100);

-- 5. Helper index for standard search queries
CREATE INDEX IF NOT EXISTS emails_mailbox_uid_idx ON emails(mailbox, imap_uid);