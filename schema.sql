-- ============================================================================
-- Grounded Support Inbox Copilot — complete database schema
--
-- Target: Supabase (PostgreSQL) with the pgvector extension.
-- Run top to bottom on a fresh project. Order matters: extensions, then
-- tables in dependency order, then functions, then triggers, then seed data.
--
-- Design principle throughout: constraints are enforced by the database, not
-- by the orchestration layer. A workflow can have a bug and a human writing
-- SQL can make a typo. The database should refuse both.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Extensions
-- ----------------------------------------------------------------------------

-- pgvector provides the `vector` column type and distance operators used for
-- semantic retrieval. Without it, embeddings can only be stored as text and
-- cannot be searched.
create extension if not exists vector;


-- ----------------------------------------------------------------------------
-- organizations — the tenant root
-- ----------------------------------------------------------------------------
-- Every other table references this. A ticket belongs to an organization; a
-- message belongs to a ticket which belongs to an organization. Multi-tenancy
-- is designed in from the first table rather than retrofitted, because
-- retrofitting it means migrating live customer data while auditing every
-- query ever written.

create table organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);

-- UUIDs rather than sequential integers: sequential IDs leak business
-- information (org #47 implies 47 customers) and collide across systems.


-- ----------------------------------------------------------------------------
-- tickets — one row per customer conversation
-- ----------------------------------------------------------------------------

create table tickets (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id),
  customer_email  text not null,
  subject         text,
  status          text not null default 'new',
  category        text,
  urgency         text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- `subject` is nullable on purpose: real emails do arrive without a subject
-- line, and rejecting those would be wrong. `customer_email` is not nullable,
-- because a ticket with no customer is meaningless.

-- Status lifecycle: new -> awaiting_approval -> answered
--                   new -> escalated
-- The check constraint exists because a typo ('anwsered') did get through
-- during development and silently stranded a ticket that no downstream node
-- would ever pick up. No error was raised. The database now refuses it.
alter table tickets add constraint tickets_status_check
  check (status in ('new', 'awaiting_approval', 'escalated', 'answered'));

-- Category and urgency are null until classification runs, so both allow null
-- and only constrain values once present.
alter table tickets add constraint tickets_category_check
  check (category is null or category in
    ('shipping', 'refund', 'product', 'account', 'other'));

alter table tickets add constraint tickets_urgency_check
  check (urgency is null or urgency in ('low', 'normal', 'high'));

-- Every query in a multi-tenant system filters by org_id, so it is the first
-- index worth creating.
create index tickets_org_id_idx on tickets (org_id);
create index tickets_status_idx on tickets (status);


-- ----------------------------------------------------------------------------
-- messages — individual emails within a ticket
-- ----------------------------------------------------------------------------

create table messages (
  id          uuid primary key default gen_random_uuid(),
  ticket_id   uuid not null references tickets(id),
  org_id      uuid not null references organizations(id),
  direction   text not null,
  sender      text not null,
  body        text not null,
  message_id  text not null,
  created_at  timestamptz not null default now(),

  -- Idempotency. The same email can legitimately arrive twice: mail servers
  -- retry, webhooks fire more than once. A "check whether it exists, then
  -- insert" pattern in the workflow has a race window — two copies arriving
  -- simultaneously can both pass the check before either writes. This
  -- constraint closes that window at the storage layer, where no race is
  -- possible.
  --
  -- Scoped to (org_id, message_id) rather than message_id alone: two different
  -- tenants' mail systems may independently generate the same ID, which is not
  -- a conflict. The same tenant receiving the same message twice is.
  unique (org_id, message_id)
);

alter table messages add constraint messages_direction_check
  check (direction in ('in', 'out'));

create index messages_ticket_id_idx on messages (ticket_id);
create index messages_org_id_idx on messages (org_id);


-- ----------------------------------------------------------------------------
-- kb_chunks — the knowledge base the AI is allowed to answer from
-- ----------------------------------------------------------------------------

create table kb_chunks (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references organizations(id),
  source      text not null,
  content     text not null,
  embedding   vector(768),
  created_at  timestamptz not null default now()
);

-- `source` is what makes citation possible. Retrieval returns the source tag
-- alongside the text, the model is required to cite the sources it used, and a
-- draft with zero citations is escalated rather than sent.

-- The dimension count is load-bearing. Documents and queries must be embedded
-- by the same model at the same dimensionality, or the distance between them
-- is meaningless. 768 matches `gemini-embedding-001` with
-- outputDimensionality: 768. Declaring the size (rather than a bare `vector`)
-- lets Postgres reject wrongly-sized data and allows the column to be indexed.

create index kb_chunks_org_id_idx on kb_chunks (org_id);

-- HNSW index on cosine distance. Not required at small corpus sizes, but the
-- right default: without it, every search reads every row.
create index kb_chunks_embedding_idx on kb_chunks
  using hnsw (embedding vector_cosine_ops);


-- ----------------------------------------------------------------------------
-- agent_runs — audit record of every AI decision
-- ----------------------------------------------------------------------------

create table agent_runs (
  id              uuid primary key default gen_random_uuid(),
  ticket_id       uuid not null references tickets(id),
  org_id          uuid not null references organizations(id),
  model           text not null,
  draft_reply     text,
  citations       jsonb,
  confidence      numeric,
  needs_human     boolean not null default true,
  refusal_reason  text,
  top_similarity  numeric,
  input_tokens    int,
  output_tokens   int,
  created_at      timestamptz not null default now()
);

-- `needs_human` defaults to TRUE, not FALSE. This is a fail-safe default: if
-- the field is ever not set — a workflow bug, a partial write — the row marks
-- itself for human review rather than for automatic sending. When something
-- goes wrong, the system should fail toward the safe side.

-- `citations` is jsonb rather than a separate table: it is a short list read
-- and written together, never queried independently. Storing it inline avoids
-- a join without losing queryability (jsonb is searchable).

-- `top_similarity` is recorded because it is the one safety signal the model
-- cannot provide. The model has no idea how well the retrieved policies
-- matched the question; the retrieval step does. Self-reported confidence
-- alone is not sufficient.

-- Token counts make cost measurable per ticket and per tenant rather than
-- estimated.

create index agent_runs_ticket_id_idx on agent_runs (ticket_id);
create index agent_runs_org_id_idx on agent_runs (org_id);


-- ----------------------------------------------------------------------------
-- approvals — audit record of every human decision
-- ----------------------------------------------------------------------------
-- Deliberately separate from agent_runs. One table records what the model
-- decided; this one records what a person decided about it. When a client asks
-- "why did the AI say that, and who approved it?", both halves of the answer
-- need to exist independently.

create table approvals (
  id              uuid primary key default gen_random_uuid(),
  ticket_id       uuid not null references tickets(id),
  agent_run_id    uuid not null references agent_runs(id),
  org_id          uuid not null references organizations(id),
  proposed_reply  text not null,
  final_reply     text,
  decision        text,
  reviewer        text,
  token           text not null,
  requested_at    timestamptz not null default now(),
  decided_at      timestamptz
);

-- `proposed_reply` and `final_reply` are kept separately so that edits are
-- measurable. The proportion of drafts that ship unchanged is a directly
-- saleable metric.

-- `decision` and `decided_at` start null. Null here is not missing data — it
-- means "not yet decided", which the approval endpoint checks before acting so
-- a forwarded or double-clicked link cannot send the same reply twice.

-- The check constraint exists because a misconfigured field once wrote a
-- timestamp into `decision` and the database accepted it silently, since text
-- columns accept anything.
alter table approvals add constraint approvals_decision_check
  check (decision is null or decision in ('approve', 'reject'));

-- `token` is the security boundary on the approval link. The approval ID alone
-- is not a secret: it appears in emails, logs and browser history. Each
-- approval therefore carries a random token, and the endpoint compares the
-- token in the URL against the stored value before doing anything. `not null`
-- guarantees no approval can be created without one.

create index approvals_ticket_id_idx on approvals (ticket_id);
create index approvals_org_id_idx on approvals (org_id);


-- ============================================================================
-- Functions
-- ============================================================================

-- ----------------------------------------------------------------------------
-- match_kb_chunks — semantic retrieval over one tenant's knowledge base
-- ----------------------------------------------------------------------------
-- Runs inside Postgres rather than in the orchestration layer. Pulling every
-- embedding out to compare them externally works at 8 rows and collapses at
-- 8,000.

create or replace function match_kb_chunks (
  query_embedding text,
  match_org_id    uuid,
  match_count     int default 5
)
returns table (
  id          uuid,
  source      text,
  content     text,
  similarity  float
)
language sql stable
as $$
  select
    kb_chunks.id,
    kb_chunks.source,
    kb_chunks.content,
    -- `<=>` is pgvector's cosine distance operator: smaller means closer.
    -- Subtracting from 1 converts distance into similarity, so larger means
    -- more relevant — easier to reason about and to threshold against.
    1 - (kb_chunks.embedding <=> query_embedding::vector) as similarity
  from kb_chunks
  where kb_chunks.org_id = match_org_id       -- tenant isolation, not optional
    and kb_chunks.embedding is not null
  order by kb_chunks.embedding <=> query_embedding::vector
  limit match_count;
$$;

-- The parameter is `text` and cast to `vector` inside the function rather than
-- typed as `vector` directly. A JSON array arriving over the REST API is not
-- coerced to a vector automatically: the function runs, matches nothing, and
-- returns an empty result with HTTP 200 and no error — a silent failure that
-- is difficult to diagnose. Accepting text and casting explicitly avoids it.

-- PostgREST caches its view of available functions. After creating or changing
-- one, tell it to reload or the new definition will not be callable over the
-- API.
notify pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- set_updated_at — maintain updated_at automatically
-- ----------------------------------------------------------------------------
-- `default now()` only fires on insert. Without a trigger, a ticket can move
-- new -> awaiting_approval -> answered while updated_at still shows its
-- creation time, which quietly breaks any "recently changed" view.

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ============================================================================
-- Triggers
-- ============================================================================

-- `before update` so the modified timestamp is what actually gets written.
-- Placing this in the database rather than in every caller means it holds no
-- matter what performs the update — a workflow, a SQL console, or a future
-- application backend.

create trigger tickets_set_updated_at
  before update on tickets
  for each row
  execute function set_updated_at();


-- ============================================================================
-- Seed data — demo tenant and knowledge base
-- ============================================================================
-- BrightBottle Co. is a fictional direct-to-consumer bottle retailer used to
-- exercise the system. The knowledge base is deliberately small and each chunk
-- is a single self-contained policy rule, so that retrieval returns a complete
-- answer rather than a fragment.

insert into organizations (id, name) values
  ('faaf7dac-5386-4833-9254-46aa9fdbd162', 'BrightBottle Co.');

insert into kb_chunks (org_id, source, content) values
('faaf7dac-5386-4833-9254-46aa9fdbd162', 'shipping-policy',
 'Standard shipping within the US takes 3-5 business days. Orders are dispatched within 24 hours on business days. Express shipping takes 1-2 business days.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'shipping-policy',
 'International shipping to Canada and the EU takes 7-14 business days. Customers are responsible for any customs duties or import taxes.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'shipping-policy',
 'If an order has not arrived 10 business days after the estimated delivery date, it is treated as lost. We will send a free replacement or issue a full refund, at the customer choice.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'returns-policy',
 'Unused items in original packaging can be returned within 30 days of delivery for a full refund. The customer pays return shipping unless the item was faulty.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'returns-policy',
 'Refunds are processed within 5 business days of us receiving the returned item. The refund goes back to the original payment method.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'product-info',
 'All BrightBottle bottles are made from 18/8 food-grade stainless steel and are BPA free. They keep drinks cold for 24 hours and hot for 12 hours.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'product-info',
 'Bottles are dishwasher safe on the top rack. Lids with silicone seals should be hand washed to extend their life.'),

('faaf7dac-5386-4833-9254-46aa9fdbd162', 'warranty',
 'BrightBottle bottles carry a 2 year warranty against manufacturing defects. The warranty does not cover dents from drops, scratches, or normal wear.');

-- Embeddings are populated separately by the SupportCopilot-B-Embeddings
-- workflow: read each chunk, embed the content, write the vector back. Run it
-- once after seeding, and again whenever documents change.


-- ============================================================================
-- Reporting queries
-- ============================================================================
-- The queries behind the measured figures in the README.

-- Ticket distribution by status
--   select status, count(*) from tickets group by status;

-- AI behaviour: confidence, retrieval quality, escalation rate
--   select
--     count(*) as total_runs,
--     round(avg(confidence), 2) as avg_confidence,
--     round(avg(top_similarity), 2) as avg_similarity,
--     count(*) filter (where needs_human) as escalated,
--     round(100.0 * count(*) filter (where needs_human) / count(*), 0) as escalation_pct
--   from agent_runs;

-- Cost per ticket (Claude Haiku 4.5 at $1/$5 per million in/out tokens).
-- Note: covers the drafting call only; classification and embedding tokens are
-- not yet instrumented, so true all-in cost is higher.
--   select
--     sum(input_tokens) as total_in,
--     sum(output_tokens) as total_out,
--     round((sum(input_tokens) / 1000000.0 * 1
--          + sum(output_tokens) / 1000000.0 * 5) / count(*), 6) as usd_per_ticket
--   from agent_runs;

-- Approval latency
--   select
--     count(*) as approvals,
--     round(avg(extract(epoch from (decided_at - requested_at)) / 60), 1) as avg_minutes
--   from approvals
--   where decided_at is not null;

-- Stalled tickets — see "Known limitations" in the README. Nothing currently
-- watches for these; a scheduled check belongs in production.
--   select id, subject, created_at
--   from tickets
--   where status = 'new' and created_at < now() - interval '1 hour';


-- ============================================================================
-- Not yet implemented
-- ============================================================================
-- Row Level Security. Every table carries org_id and every query filters on
-- it, but that filtering currently lives in the application layer, which means
-- it holds only as long as it is remembered — in every query, forever. RLS
-- moves the rule into the database: a query that omits its tenant filter
-- returns nothing instead of everything. Required before any real
-- multi-tenant deployment.
--
--   alter table tickets enable row level security;
--   create policy tenant_isolation on tickets
--     using (org_id = current_setting('request.jwt.claims', true)::json->>'org_id');
--
-- Conditional update for the approval race. The "already decided?" check is
-- currently a read followed by a write, which two simultaneous clicks could
-- both pass. The fix is to make the guard part of the write itself and act on
-- the affected row count:
--
--   update approvals set decision = $1, decided_at = now()
--   where id = $2 and token = $3 and decision is null;
